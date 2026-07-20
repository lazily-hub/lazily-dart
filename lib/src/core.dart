/// Lazy reactive primitives for Dart: `Slot` -> `Cell` -> `Signal`.
///
/// A pure-Dart port of the lazily reactive family (`lazily-py`, `lazily-js`,
/// `lazily-zig`), mirroring `lazily-rs`.
///
/// - [Slot] — a lazily-computed cached value that automatically tracks its
///   dependencies and recomputes only when read after an upstream change.
/// - [Cell] — a mutable source value that invalidates dependent Slots/Signals
///   when it changes.
/// - [Signal] — an *eager* derived value that recomputes the instant a
///   dependency changes, with no intermediate unset value.
///
/// Values are **lazy by default**: dependents are marked dirty on invalidation
/// but only recompute when accessed. When you need eager push-style semantics,
/// reach for [Signal].
///
/// A [Context] is the shared scope: it holds an identity-keyed cache and the
/// computation stack used for automatic dependency tracking. All reactives that
/// react to each other must share a [Context].
library;

import 'dart:collection';

/// Degree at which a node's edge list promotes from linear-scan dedup to a
/// hash index (`#lzspecedgeindex`).
///
/// **Measured for Dart, not copied.** The spec is explicit that this constant
/// is not portable, and lazily-rs's value (40, or 170 before its hash change)
/// does not transfer.
///
/// Two measurements set it. First, the *pure-strategy* crossover — scan-only
/// versus indexed-from-the-start, on the exact pattern
/// [_ReactiveNode._addDependent] uses, medians of 9 — lands at **~60 under AOT**
/// (`dart compile exe`) and **~96 under the JIT** (`dart run`). The two
/// execution modes disagree by 1.6x from the compilation strategy alone, so a
/// threshold below ~96 regresses JIT'd code.
///
/// Second, and decisive: this implementation is a *hybrid*, not a pure
/// strategy. A list that reaches degree T pays the full O(T^2) scan on the way
/// up **and then** the O(T) index build — with, at exactly degree T, no
/// subsequent indexed insert to amortise it against. Every threshold therefore
/// has a localised regression at precisely its own width, which the
/// pure-strategy crossover cannot predict. Sweeping the real implementation
/// (`benchmark/edge_index_load.dart --narrow`, ns/registration against the
/// unfixed tree) shows the penalty is always parked on T and shrinks as T
/// rises:
///
/// | T | worst regression | at width | width 512 | width 1024 |
/// |---|---|---|---|---|
/// | 64 | 1.63x | 64 | 0.45x | 0.23x |
/// | 96 | 1.47x | 97 | 0.47x | 0.23x |
/// | **128** | **1.31x** | **128** | **0.48x** | **0.23x** |
/// | 192 | 1.26x | 192 | 0.53x | 0.28x |
/// | 256 | 1.27x | 256 | 0.70x | 0.29x |
///
/// 128 is the knee: it keeps essentially all of the mid-range win (0.48x at
/// 512, 0.23x at 1024 — indistinguishable from T=64) while cutting the
/// boundary penalty to 1.31x, and it sits above both pure-strategy crossovers
/// so promotion never happens while scanning is still the faster strategy.
/// Going higher buys ~0.05x off the boundary and costs real mid-range
/// throughput. Degrees 8..97 and 192+ measure within noise of the unfixed
/// tree, so the **common low-degree case — the regression the spec says this
/// threshold exists to prevent — is untouched**.
const int edgeIndexPromoteThreshold = 128;

/// Degree at which an indexed edge list demotes back to linear-scan dedup.
///
/// Set to a quarter of [edgeIndexPromoteThreshold] as **hysteresis**. Edges are
/// removed and re-registered on every recompute, so a dependent list sitting
/// at the promote threshold oscillates by one; a single shared promote/demote
/// boundary would rebuild the index on every recompute (~4x steady-state cost
/// at exactly threshold+1, and invisible at every other width). A 4x gap means
/// a list must shed three quarters of its degree before it demotes.
const int edgeIndexDemoteThreshold = edgeIndexPromoteThreshold ~/ 4;

/// A node in a [Context]'s reactive graph (`#lzspecedgeindex`).
///
/// Sealed: [Slot] (and its subclasses [Memo] / `_SignalSlot`), [Cell],
/// [Signal], and [Effect] are the only implementations, and the type cannot be
/// implemented downstream. It exists so [Context.dependentCount],
/// [Context.dependencyCount], [Context.disposeNode], and [TeardownScope] can
/// accept any node kind *without* exposing the node's edge lists or its cache
/// slot — the mirror of `lazily-rs`'s sealed `GraphNode` trait, which exposes a
/// node id and nothing else.
///
/// The introspection surface is deliberately **counts, not lists**: a caller
/// can assert on graph shape without a path to the internals and without any
/// storage strategy (linear scan, promoted hash index) becoming part of the
/// contract.
sealed class GraphNode {}

/// Thrown when a disposed node is read (`read_after_dispose`).
///
/// Disposal is not a value: a binding that answers a read on a torn-down node
/// with its last-computed value, a zero, or `null` makes "torn down"
/// indistinguishable from "legitimately this value", and a use-after-dispose
/// bug then surfaces as a wrong number far from its cause.
class DisposedNodeError extends StateError {
  DisposedNodeError(this.node)
      : super('read after dispose: $node has been disposed');

  /// The node that was read.
  final Object node;
}

/// A reactive scope: an identity-keyed value cache plus the computation stack.
///
/// All [Slot]s, [Cell]s, and [Signal]s that should react to each other must be
/// created with (and thus share) the same [Context]. The cache keys on object
/// identity, so each reactive instance is cached independently.
class Context {
  /// The value cache lives ON-NODE ([Slot._cachedValue] / [Slot._cacheGen]):
  /// a slot is "cached" iff its `_cacheGen == _generation`. [clear] bumps this
  /// counter, invalidating every slot in O(1) without the [Context] having to
  /// enumerate them (mirrors lazily-rs `SlotNode.value: Option<…>` as a direct
  /// field). This drops the former `Map.identity` cache — the single biggest
  /// allocation and per-lookup-cost source at viewport scale.
  int _generation = 0;
  int _cachedCount = 0;

  final List<_ReactiveNode> _stack = [];

  int _batchDepth = 0;
  Set<Cell>? _batchedCells;
  Set<Slot>? _batchedSlots;
  final List<Effect> _pendingEffects = [];
  int _pendingEffectsHead = 0;
  final Set<Effect> _scheduledEffects = Set.identity();
  bool _flushingEffects = false;

  /// Eager [Signal] pulls queued for the current flush (`#lzsignaleager`
  /// clause 3).
  ///
  /// The puller is *scheduled*, exactly like an [Effect], rather than run
  /// inline from `_SignalSlot.onInvalidate`. That is the whole of clause 3:
  /// N writes inside a [batch] must produce ONE re-materialization, and
  /// invalidation is earlier than the flush — `_flushBatch` cascades once per
  /// written cell, so an inline pull recomputed once per invalidated source.
  /// Both forms end at the same value, which is why the defect is a cost
  /// multiplier rather than a wrong answer and shipped unnoticed here until
  /// `signal_materializes_once_per_batch.json` counted the computes.
  ///
  /// Dedup is by identity, so a signal reached from several written cells in
  /// one batch is pulled once.
  final List<Signal> _pendingSignals = [];
  int _pendingSignalsHead = 0;
  final Set<Signal> _scheduledSignals = Set.identity();

  /// Audit-only escape hatch (`#lzspecedgeindex`). When compiled with
  /// `-Dlazily.naive_pending_scan=true` the flush and dispose paths perform the
  /// linear `_pendingEffects` scan that `lazily-rs`/`lazily-cpp` (`run_effect`)
  /// and `lazily-kt` (`disposeEffect`) carried before their O(1) fixes. The
  /// scan result is discarded, so behaviour is identical either way — the flag
  /// exists purely so a benchmark can prove the harness is able to *detect* a
  /// per-publish/per-teardown scan of the pending collection. It is a
  /// compile-time constant, so the naive branch is tree-shaken out of normal
  /// builds at zero cost.
  static const bool naivePendingScan =
      bool.fromEnvironment('lazily.naive_pending_scan');

  /// Sink that keeps the audit scan above from being optimised away. Only
  /// written when [naivePendingScan] is set.
  int _naiveScanSink = 0;

  /// Reusable DFS stack for invalidation cascades (see [_cascadeFrom]).
  /// Allocated once per [Context]; cleared at the end of each top-level cascade.
  final List<_ReactiveNode> _invalidateStack = [];
  int _invalidateNesting = 0;

  /// Depth of the disposal-driven invalidation cascade (`#lzspecedgeindex`).
  ///
  /// Non-zero while [_invalidateDisposedDependents] is walking the cone left
  /// behind by a teardown. The walk exists because detaching edges is not
  /// enough: a dependent that still holds a cached value computed *through* the
  /// disposed node would serve it forever, so the surviving cone must be
  /// marked dirty and error on its next recompute (`lazily-rs` 5db90d2;
  /// `lazily-js` had the identical bug in 4d20670).
  ///
  /// It is a depth counter rather than a flag so the eager members of the
  /// family can consult it. While it is set the cascade is **mark-only**:
  ///
  /// - [_scheduleEffect] drops the effect. Disposal is not a publish; running
  ///   an effect here re-enters a compute that reads the node being torn down,
  ///   turning `dispose` into a throw and breaking teardown idempotence. The
  ///   contract is "errors on the next recompute", and that recompute is driven
  ///   by a real write.
  /// - [Memo._invalidateInto] skips its equality recompute and propagates
  ///   unconditionally, and [_scheduleSignalPull] drops the queued eager pull,
  ///   for the same reason: both would recompute *through* the disposed node.
  int _disposalDepth = 0;

  /// The number of cached slot values.
  int get size => _cachedCount;

  /// Whether [node] currently has a cached value. Only [Slot]s (and subclasses
  /// like [Memo] / `_SignalSlot`) cache values; cells hold their value directly
  /// and effects never cache.
  bool contains(_ReactiveNode node) =>
      node is Slot && node._isCachedInGeneration(this);

  /// The cached value for [node] (untyped), or `null` if absent.
  Object? read(_ReactiveNode node) {
    final slot = node as Slot;
    return slot._isCachedInGeneration(this) ? slot._cachedValue : null;
  }

  /// Cache a value for [node].
  void write(_ReactiveNode node, Object? value) =>
      (node as Slot)._markCachedValue(value, this);

  /// Remove the cached value for [node].
  void evict(_ReactiveNode node) => (node as Slot)._uncache(this);

  /// Drop every cached value in O(1) by bumping the generation: each slot's
  /// `_cacheGen` is now stale, so it reports uncached and recomputes on next
  /// read. Dependency edges are re-established lazily as slots are read again.
  void clear() {
    _generation++;
    _cachedCount = 0;
  }

  /// The slot currently computing, if any.
  _ReactiveNode? get _current => _stack.isEmpty ? null : _stack.last;

  /// Whether a [batch] is currently active.
  bool get isBatching => _batchDepth > 0;

  /// Run [run] inside a batch. Cell writes inside the batch defer their
  /// invalidation cascades until the outermost batch exits, at which point a
  /// single coalesced cascade fires and pending [Effect]s flush once.
  ///
  /// Re-entrant: nested [batch] calls bump the depth; only the outermost exit
  /// triggers the flush.
  void batch(void Function() run) {
    if (_batchDepth == 0) {
      _batchedCells ??= Set.identity();
      _batchedSlots ??= Set.identity();
    }
    _batchDepth++;
    try {
      run();
    } finally {
      _batchDepth--;
      if (_batchDepth == 0) _flushBatch();
    }
  }

  /// Called by [Cell] when its value changes. Routes through the batch queue
  /// when a batch is active, otherwise cascades immediately + flushes effects.
  void _cellChanged(Cell cell) {
    if (_batchDepth > 0) {
      _batchedCells!.add(cell);
    } else {
      cell._invalidate();
      _flushEffects();
    }
  }

  void _flushBatch() {
    final cells = _batchedCells;
    final slots = _batchedSlots;
    if ((cells == null || cells.isEmpty) && (slots == null || slots.isEmpty)) {
      _flushEffects();
      return;
    }
    // Drop the references and iterate the locals directly — no `.toList()`
    // snapshot needed. `_batchDepth` is already 0 here, and a cascade never
    // writes a [Cell], so these sets are not re-populated mid-flush.
    _batchedCells = null;
    _batchedSlots = null;
    if (cells != null) {
      for (final cell in cells) {
        cell._invalidate();
      }
    }
    if (slots != null) {
      for (final slot in slots) {
        slot._invalidate();
      }
    }
    _flushEffects();
  }

  /// Batch-aware external invalidation of derived slots — the mechanism behind
  /// demand-driven readers (e.g. [QueueCell] reader-kinds) that derive from an
  /// out-of-graph mutation source. Evicts each slot's cache and cascades to its
  /// dependents, then flushes effects once. Inside a [batch] the flush is
  /// deferred to the boundary. A slot with no dependents cascades to nothing, so
  /// an unobserved op pays effectively nothing (store-without-cascade).
  void invalidateSlots(List<Slot> slots) {
    if (_batchDepth > 0) {
      _batchedSlots!.addAll(slots);
      return;
    }
    for (final slot in slots) {
      slot._invalidate();
    }
    _flushEffects();
  }

  /// Iterative DFS invalidation cascade. Fires [root]'s invalidation hook and
  /// every transitively-reached dependent's hook (once per reach), clearing each
  /// node's `_dependents` set as it is expanded — that clear is the visited
  /// mark, so a node reached through multiple parents is expanded at most once.
  ///
  /// Replaces the former recursive cascade which allocated a `.toList()`
  /// snapshot per node (mirrors `mark_frontier_locked` in lazily-rs). The stack
  /// is owned by the [Context] and reused across cascades; reentrant cascades
  /// fall back to a fresh local stack so the outer iteration is not corrupted.
  /// Eager [Signal] pulls no longer reenter here — they are scheduled onto
  /// [_pendingSignals] and cascade from the flush, outside this walk.
  void _cascadeFrom(_ReactiveNode root) {
    final nested = _invalidateNesting > 0;
    final List<_ReactiveNode> stack =
        nested ? <_ReactiveNode>[] : _invalidateStack;
    _invalidateNesting++;
    stack.add(root);
    try {
      while (stack.isNotEmpty) {
        final node = stack.removeLast();
        node._invalidateInto(stack);
      }
    } finally {
      stack.clear();
      _invalidateNesting--;
    }
  }

  /// Mark the cone left behind by a disposal dirty, without scheduling
  /// anything (`#lzspecedgeindex`).
  ///
  /// Reuses [_cascadeFrom] — the same iterative DFS every publish walks —
  /// rather than a second traversal, so there is exactly one definition of
  /// "transitively reached" in this library and the two cannot drift.
  void _invalidateDisposedDependents(List<_ReactiveNode> roots) {
    if (roots.isEmpty) return;
    _disposalDepth++;
    try {
      for (final root in roots) {
        if (root._disposed) continue;
        _cascadeFrom(root);
      }
    } finally {
      _disposalDepth--;
    }
  }

  void _scheduleEffect(Effect effect) {
    // Disposal is not a publish — see [_disposalDepth].
    if (_disposalDepth > 0) return;
    if (_scheduledEffects.add(effect)) {
      _pendingEffects.add(effect);
    }
  }

  /// Queue [signal]'s eager re-materialization for the current flush. See
  /// [_pendingSignals].
  void _scheduleSignalPull(Signal signal) {
    // A disposal cascade is mark-only: pulling here would recompute *through*
    // the node being torn down. See [_disposalDepth].
    if (_disposalDepth > 0) return;
    if (_scheduledSignals.add(signal)) {
      _pendingSignals.add(signal);
    }
  }

  // -- Disposal and degree introspection (`#lzspecedgeindex`) ---------------

  /// How many nodes currently depend on [node] — the size of its reverse edge
  /// set.
  ///
  /// This is the observable the disposal contract is written against: a
  /// subscribe/unsubscribe cycle that disposes what it creates must leave this
  /// at its starting value, no matter how many cycles run. A binding that leaks
  /// reports total-ever-created here instead of live-subscriber count.
  ///
  /// Returns 0 for a disposed node and for [Effect]s, which are pure sinks.
  int dependentCount(GraphNode node) {
    final n = node as _ReactiveNode;
    if (n._disposed) return 0;
    return n._dependents?.length ?? 0;
  }

  /// How many nodes [node] currently depends on — the size of its forward edge
  /// set.
  ///
  /// Counterpart to [dependentCount]. Disposal must detach both directions, and
  /// a binding that detaches only one leaves a dangling half-edge visible here.
  ///
  /// Returns 0 for a disposed node and for [Cell]s, which are pure sources.
  int dependencyCount(GraphNode node) {
    final n = node as _ReactiveNode;
    if (n._disposed) return 0;
    return n._dependencies?.length ?? 0;
  }

  /// Whether [node] has been torn down. A disposed node reads as a
  /// [DisposedNodeError].
  bool isNodeDisposed(GraphNode node) => (node as _ReactiveNode)._disposed;

  /// Tear down [node], dispatching on its own kind.
  ///
  /// Detaches both edge directions, marks the surviving dependent cone dirty
  /// (see [_invalidateDisposedDependents]), and makes the node read as a
  /// [DisposedNodeError]. Idempotent: disposing an already-disposed node is a
  /// no-op, so teardown paths compose.
  ///
  /// Without this a node is permanent. Dart handles are ordinary object
  /// references and the graph holds a *strong* reverse edge to every dependent,
  /// so a long-lived source retains every node that ever read it: dropping the
  /// last user-held reference reclaims nothing, and a source's dependent list
  /// keeps lengthening under subscribe/unsubscribe churn even though the live
  /// subscriber count is constant. The cost is paid twice — memory, and
  /// propagation, since every publish walks the whole list.
  ///
  /// Callers must ensure nothing still reads [node] in a live computation:
  /// a dependent that does errors on its next recompute.
  void disposeNode(GraphNode node) => (node as _ReactiveNode)._disposeNode();

  /// Tear down a derived slot. See [disposeNode].
  void disposeSlot(Slot<Object?> slot) => slot._disposeNode();

  /// Tear down a source cell. See [disposeNode].
  void disposeCell(Cell<Object?> cell) => cell._disposeNode();

  /// Tear down an effect. See [disposeNode]; equivalent to [Effect.dispose].
  void disposeEffect(Effect effect) => effect._disposeNode();

  /// Open a teardown scope: nodes created through it are disposed when it ends.
  ///
  /// Grouping bounds *teardown*, not visibility — a scoped node reads
  /// parent-owned and sibling-scope-owned nodes freely, and scoping never
  /// restricts what an edge may point at.
  ///
  /// Same caveat as [disposeNode]: ending a scope tears down its nodes even if
  /// something outside the scope still reads them, and that reader then errors
  /// on its next recompute. Prefer [withScope] when the scope's lifetime is
  /// lexical.
  TeardownScope scope() => TeardownScope._(this);

  /// Run [body] with a teardown scope that is ended when [body] returns, even
  /// on a throw.
  ///
  /// This is the closest Dart gets to `lazily-rs`'s scope-ends-on-drop: Dart has
  /// no destructor, so a scope's end has to be an explicit statement, and the
  /// only way to make it unmissable is to own the bracket here.
  ///
  ///     final live = ctx.withScope((conn) {
  ///       final a = conn.slot<int>((_) => topic.value + 1);
  ///       return a();
  ///     }); // `a` is disposed here
  R withScope<R>(R Function(TeardownScope scope) body) {
    final scope = this.scope();
    try {
      return body(scope);
    } finally {
      scope.end();
    }
  }

  void _flushEffects() {
    if (_flushingEffects) return;
    _flushingEffects = true;
    try {
      // FIFO with a head pointer instead of O(n) `removeAt(0)` (mirrors
      // lazily-rs `VecDeque::pop_front`). A drained entry may append more of
      // either kind; the loop re-reads `length` each pass so they are
      // processed in order.
      while (true) {
        // Signal pulls drain ahead of effects: an effect body that reads a
        // signal must observe the re-materialized value, not the pre-write
        // one. A pull may cascade and schedule further pulls or effects, so
        // this re-checks rather than draining the queue once.
        if (_pendingSignalsHead < _pendingSignals.length) {
          final signal = _pendingSignals[_pendingSignalsHead];
          _pendingSignalsHead++;
          _scheduledSignals.remove(signal);
          signal._eagerRecompute();
          continue;
        }
        if (_pendingEffectsHead < _pendingEffects.length) {
          final effect = _pendingEffects[_pendingEffectsHead];
          _pendingEffectsHead++;
          if (naivePendingScan) {
            // Naive form under audit: scan the pending collection for an entry
            // that the head pointer has already consumed. Result discarded.
            _naiveScanSink += _pendingEffects.indexOf(effect);
          }
          _scheduledEffects.remove(effect);
          effect._rerun();
          continue;
        }
        break;
      }
      _pendingEffects.clear();
      _pendingEffectsHead = 0;
      _pendingSignals.clear();
      _pendingSignalsHead = 0;
    } finally {
      _flushingEffects = false;
    }
  }
}

/// Base class for nodes that participate in dependency tracking.
///
/// Edges are bidirectional and refreshed on every recompute:
/// - [_dependents] — nodes that read this one (downstream).
/// - [_dependencies] — nodes this one read during its last computation
///   (upstream). When this node recomputes, it first detaches from its prior
///   upstream edges so stale edges never accumulate.
///
/// Edges are stored as lazily-allocated [List]s rather than per-node [Set]s
/// (mirrors lazily-rs `SmallVec<[SlotId; 2]>`). The overwhelming majority of
/// reactive nodes have 0–2 edges on either side, so a linear-scan dedup on a
/// tiny list beats the allocation + hash overhead of an empty `Set` per node
/// (4M `Set` allocations at the 2M-cell scale benchmark become ~0 for never-
/// connected nodes).
///
/// That scan is O(degree) per registration, so a *wide* node — one read by
/// thousands of dependents — would build its edge set in O(n^2) and degrade
/// every propagation with it. Once a list reaches
/// [edgeIndexPromoteThreshold] it therefore promotes to a hash index
/// ([_dependentIndex] / [_dependencyIndex]) and registration returns to
/// amortized O(1), demoting again only at [edgeIndexDemoteThreshold]
/// (`#lzspecedgeindex`). The edge *set* is identical either way — dedup
/// strategy is not observable.
abstract class _ReactiveNode implements GraphNode {
  List<_ReactiveNode>? _dependents;
  List<_ReactiveNode>? _dependencies;

  /// Whether this node has been torn down (`#lzspecedgeindex`). A disposed node
  /// has no edges in either direction and reads as a [DisposedNodeError].
  bool _disposed = false;

  /// Hash index over [_dependents], mapping each dependent to its position in
  /// the list. Allocated only once the list crosses
  /// [edgeIndexPromoteThreshold]; `null` means "dedup by linear scan".
  ///
  /// Holding the position (rather than a bare membership [Set]) is what makes
  /// [_removeDependent] O(1) too: it swap-removes and repairs the moved
  /// entry's position, so tearing a wide fan-out down is O(n) overall instead
  /// of O(n^2).
  Map<_ReactiveNode, int>? _dependentIndex;

  /// Membership index over [_dependencies]. Upstream edges are only ever
  /// added or bulk-cleared — never removed individually — so a [Set] suffices.
  Set<_ReactiveNode>? _dependencyIndex;

  static Map<_ReactiveNode, int> _buildDependentIndex(
    List<_ReactiveNode> deps,
  ) {
    final index = HashMap<_ReactiveNode, int>.identity();
    for (var i = 0; i < deps.length; i++) {
      index[deps[i]] = i;
    }
    return index;
  }

  /// The context this node belongs to. Concrete subclasses provide this as a
  /// field; the base declares it so [_invalidate] / [_detachUpstream] can route
  /// through the [Context]-owned cascade stack and cache.
  Context get ctx;

  /// Hook called when this node is invalidated, before the downstream cascade.
  void onInvalidate() {}

  /// Register [child] as a dependent of this node (downstream edge), allocating
  /// the edge list on first use. Identity-deduped to survive a slot reading
  /// this node more than once in a single computation.
  @pragma('vm:prefer-inline')
  void _addDependent(_ReactiveNode child) {
    final deps = _dependents;
    if (deps == null) {
      _dependents = [child];
      return;
    }
    final index = _dependentIndex;
    if (index != null) {
      if (index.containsKey(child)) return;
      index[child] = deps.length;
      deps.add(child);
      return;
    }
    if (deps.contains(child)) return;
    deps.add(child);
    if (deps.length >= edgeIndexPromoteThreshold) {
      _dependentIndex = _buildDependentIndex(deps);
    }
  }

  /// Register [dep] as an upstream dependency of this node, allocating the edge
  /// list on first use. Identity-deduped (symmetric with [_addDependent]).
  @pragma('vm:prefer-inline')
  void _addDependency(_ReactiveNode dep) {
    final deps = _dependencies;
    if (deps == null) {
      _dependencies = [dep];
      return;
    }
    final index = _dependencyIndex;
    if (index != null) {
      if (index.add(dep)) deps.add(dep);
      return;
    }
    if (deps.contains(dep)) return;
    deps.add(dep);
    if (deps.length >= edgeIndexPromoteThreshold) {
      _dependencyIndex = HashSet<_ReactiveNode>.identity()..addAll(deps);
    }
  }

  /// Remove [child] from this node's downstream edge list (identity match).
  ///
  /// While indexed this is O(1) via swap-remove. Swap-remove reorders the
  /// dependent list, which is unobservable: the cascade is a set-expansion
  /// whose resulting graph state is order-independent (`disposeAll_order_
  /// independent` in lazily-formal). The unindexed path keeps [List.remove]'s
  /// order-preserving behaviour, so narrow graphs are bit-for-bit unchanged.
  void _removeDependent(_ReactiveNode child) {
    final deps = _dependents;
    if (deps == null) return;
    final index = _dependentIndex;
    if (index == null) {
      deps.remove(child);
      return;
    }
    final at = index.remove(child);
    if (at == null) return;
    final last = deps.length - 1;
    if (at != last) {
      final moved = deps[last];
      deps[at] = moved;
      index[moved] = at;
    }
    deps.removeLast();
    // Hysteresis: demote only once the list has shrunk to a quarter of the
    // promote threshold. A shared boundary would rebuild the index on every
    // recompute for a list oscillating by one at the threshold.
    if (deps.length <= edgeIndexDemoteThreshold) _dependentIndex = null;
  }

  /// Remove [dep] from this node's upstream edge list (identity match).
  ///
  /// Only disposal needs this. Every other path clears the whole upstream list
  /// at once ([_detachUpstream]), which is why [_dependencyIndex] is a bare
  /// membership [Set] and this is an O(degree) scan rather than the O(1)
  /// swap-remove [_removeDependent] gets — a node is disposed once, but its
  /// dependents are re-registered on every recompute.
  void _removeDependency(_ReactiveNode dep) {
    final deps = _dependencies;
    if (deps == null) return;
    deps.remove(dep);
    _dependencyIndex?.remove(dep);
  }

  /// Hook run after this node has been detached from the graph. Slots evict
  /// their cache here; effects run their pending cleanup.
  void onDispose() {}

  /// Tear this node out of the graph (`#lzspecedgeindex`).
  ///
  /// The order is load-bearing:
  ///
  /// 1. Mark disposed first, so the mark-only cascade in step 4 skips this node
  ///    and so a re-entrant disposal (an [onDispose] cleanup that disposes its
  ///    own scope) is a no-op rather than a second teardown.
  /// 2. Detach *upstream* — remove this node from each dependency's dependent
  ///    list. Skipping this is the upstream leak the disposal contract exists
  ///    for: the source's dependent list grows without bound under churn.
  /// 3. Detach *downstream* — remove this node from each dependent's dependency
  ///    list, so no surviving node holds a dangling half-edge.
  /// 4. Mark the surviving dependent cone dirty. This is the step that is easy
  ///    to omit and that leaves a live reader frozen on a value it computed
  ///    *through* this node; see [Context._disposalDepth].
  void _disposeNode() {
    if (_disposed) return;
    _disposed = true;

    final dependents = _dependents;
    _dependents = null;
    _dependentIndex = null;

    _detachUpstream();
    _dependencies = null;
    _dependencyIndex = null;

    if (dependents != null && dependents.isNotEmpty) {
      for (final dependent in dependents) {
        dependent._removeDependency(this);
      }
      ctx._invalidateDisposedDependents(dependents);
    }

    onDispose();
  }

  /// Register the currently-computing slot (if any) as a dependent of this
  /// node, and record the reverse edge on the computing slot. Called whenever
  /// this node is read.
  @pragma('vm:prefer-inline')
  void _track(Context ctx) {
    final parent = ctx._current;
    if (parent != null) {
      _addDependent(parent);
      parent._addDependency(this);
    }
  }

  /// Detach this node from all of its current upstream dependencies. Called
  /// before a recompute so dependency edges reflect only the most recent
  /// computation. The list is cleared in place (reused on the next recompute).
  void _detachUpstream() {
    final deps = _dependencies;
    if (deps == null || deps.isEmpty) return;
    for (final dep in deps) {
      dep._removeDependent(this);
    }
    deps.clear();
    // The list is the index's only referent — a cleared list must never keep a
    // stale index, or the next computation's edges alias the previous run's.
    _dependencyIndex = null;
  }

  /// Invalidate this node: run its [onInvalidate] hook and cascade the
  /// invalidation to every transitively-reached dependent. Driven by the
  /// [Context]-owned iterative DFS (see [Context._cascadeFrom]).
  void _invalidate() => ctx._cascadeFrom(this);

  /// Expand this node's invalidation into [stack]: fire [onInvalidate], then
  /// push this node's current dependents onto [stack] (clearing the local list,
  /// which serves as the visited mark). Overridden by [Memo] to gate the
  /// cascade behind its equality guard.
  void _invalidateInto(List<_ReactiveNode> stack) {
    onInvalidate();
    final deps = _dependents;
    if (deps == null || deps.isEmpty) return;
    for (final dep in deps) {
      stack.add(dep);
    }
    deps.clear();
    _dependentIndex = null;
  }
}

/// A lazy, cached, dependency-tracking computation.
///
/// Reading [call] returns the cached value if present; otherwise it computes
/// the value (tracking every [Cell], [Signal], or [Slot] read during
/// computation as a dependency), caches it, and returns it. When any
/// dependency changes, the cached value is invalidated and the next read
/// recomputes.
///
/// Example::
///
///     final ctx = Context();
///     final a = Cell<int>(ctx, 2);
///     final doubled = Slot<int>(ctx, (_) => a.value * 2);
///     doubled(); // 4
///     a.value = 10;
///     doubled(); // 20
class Slot<T> extends _ReactiveNode {
  /// Creates a lazy slot bound to [ctx].
  Slot(this.ctx, T Function(Context ctx) compute, {this.name})
      : _compute = compute;

  /// The context this slot belongs to.
  @override
  final Context ctx;
  final T Function(Context ctx) _compute;

  /// Optional human-readable name for debugging.
  final String? name;

  // -- On-node value cache (replaces the former `Context._cache` Map) --------
  //
  // A slot is cached iff [_cacheGen] equals [Context._generation]. The cached
  // value lives directly on the node as [_cachedValue], so reads/writes are
  // plain field accesses — no `Map.identity` lookup, no hashing, no per-entry
  // storage. Only the owning slot touches its own cache entry.
  T? _cachedValue;
  int _cacheGen = -1;

  /// Whether this slot holds a value cached in [ctx]'s current generation.
  @pragma('vm:prefer-inline')
  bool _isCachedInGeneration(Context ctx) => _cacheGen == ctx._generation;

  /// Mark this slot cached with [value] against [ctx]'s current generation.
  /// Called via [Context.write]; transitions absent→present increment the
  /// context's cached count exactly once.
  void _markCachedValue(Object? value, Context ctx) {
    final gen = ctx._generation;
    if (_cacheGen != gen) {
      ctx._cachedCount++;
      _cacheGen = gen;
    }
    _cachedValue = value as T;
  }

  /// Evict this slot's cached value (if any). Called via [Context.evict].
  void _uncache(Context ctx) {
    if (_cacheGen == ctx._generation) {
      _cacheGen = -1;
      ctx._cachedCount--;
    }
  }

  /// Read (and cache if needed) the value. The object is callable: `slot()`.
  ///
  /// Throws [DisposedNodeError] if this slot has been disposed. The check comes
  /// *before* [_track] deliberately: a reader that hits a disposed node must not
  /// leave an edge pointing at it, so the throw happens before any edge is
  /// registered and the reader's next recompute starts from a clean upstream
  /// set.
  T call() {
    if (_disposed) throw DisposedNodeError(this);
    _track(ctx);
    final gen = ctx._generation;
    if (_cacheGen == gen) {
      return _cachedValue as T;
    }
    _detachUpstream();
    ctx._stack.add(this);
    try {
      final value = _compute(ctx);
      if (_cacheGen != gen) {
        ctx._cachedCount++;
        _cacheGen = gen;
      }
      _cachedValue = value;
      return value;
    } finally {
      ctx._stack.removeLast();
    }
  }

  /// The cached value without recomputing, or `null` if not currently cached.
  T? get peek => _cacheGen == ctx._generation ? _cachedValue : null;

  /// Detach this slot from the graph: evict its cached value and invalidate its
  /// dependents. Used by [SlotMap] when an entry is removed — the orphaned slot
  /// stops driving its dependents (mirrors `SlotHandle::clear` in lazily-rs).
  void clearDependents() {
    _invalidate();
    ctx._flushEffects();
  }

  @override
  void onInvalidate() => _uncache(ctx);

  @override
  void onDispose() => _uncache(ctx);

  /// Tear this slot out of the graph. See [Context.disposeNode].
  void dispose() => _disposeNode();

  /// Whether this slot has been disposed.
  bool get isDisposed => _disposed;

  @override
  String toString() => name != null ? 'Slot(${name!})' : 'Slot';
}

/// A mutable source value that invalidates dependents when it changes.
///
/// Reading [value] inside a [Slot] / [Signal] computation registers a
/// dependency. Writing [value] triggers a cascade only when the new value is
/// not equal (`!=`) to the old one — the `PartialEq` guard.
///
/// A [Cell] carries **no callback registry**. Observation in a reactive graph
/// is a declared dependency edge, not a registered listener: use an [Effect]
/// (eager push, batching-aware, glitch-free) for side effects such as Flutter
/// `ValueNotifier` bridges and `setState` wrappers, and a `Topic` when a
/// consumer genuinely needs a stream of every transition. A per-cell listener
/// list would bypass the graph, ignore [Context.batch], and cost memory on
/// every cell whether or not anything is listening.
class Cell<T> extends _ReactiveNode {
  Cell(this.ctx, T initialValue) : _value = initialValue;

  /// The context this cell belongs to.
  final Context ctx;
  T _value;

  /// The current value. Reading inside a computation subscribes the reader.
  ///
  /// Throws [DisposedNodeError] if this cell has been disposed —
  /// `disposeCell` and `disposeSlot` share one read-after-dispose contract.
  T get value {
    if (_disposed) throw DisposedNodeError(this);
    _track(ctx);
    return _value;
  }

  /// Set a new value. If `newValue != _value`, dependents are invalidated.
  ///
  /// Throws [DisposedNodeError] on a disposed cell: a write that silently
  /// vanishes is the same failure mode as a read that silently returns stale.
  set value(T newValue) {
    if (_disposed) throw DisposedNodeError(this);
    if (newValue != _value) {
      _value = newValue;
      ctx._cellChanged(this);
    }
  }

  /// Read the value (alias for [value]).
  T get() => value;

  /// The current value without registering a dependency. Use this outside of
  /// reactive computations (e.g. inside event handlers).
  T get peek => _value;

  /// Set the value (alias for `value =`).
  void set(T newValue) => value = newValue;

  /// Force-invalidate this cell's dependents without changing the value.
  ///
  /// Used by collection layers when an entry is removed: the orphaned cell
  /// stops driving its dependents, mirroring `CellHandle::clear_dependents` in
  /// lazily-rs. The cell's own value is untouched; only the downstream cascade
  /// fires.
  void invalidate() {
    _invalidate();
    ctx._flushEffects();
  }

  @override
  void onInvalidate() {
    // Cells hold their value directly; nothing to evict.
  }

  /// Tear this cell out of the graph. See [Context.disposeNode].
  ///
  /// Cells are pure sources with no dependencies, so only downstream edges are
  /// detached — but the surviving dependent cone is still marked dirty, or a
  /// dependent that cached a value read through this cell would serve it
  /// forever instead of erroring.
  void dispose() => _disposeNode();

  /// Whether this cell has been disposed.
  bool get isDisposed => _disposed;

  @override
  String toString() => 'Cell($_value)';
}

/// An eager derived value — recomputes immediately when a dependency changes.
///
/// Unlike [Slot] (which recomputes on the next read), a [Signal] computes its
/// value once at construction and recomputes the instant any tracked
/// dependency changes. A recompute that yields an equal value (`!=` guard)
/// suppresses the downstream cascade.
///
/// Reading [value] inside another computation registers a dependency, so
/// downstream reactives invalidate when this signal's value changes.
class Signal<T> extends _ReactiveNode {
  /// Creates an eager signal bound to [ctx]. The value is computed once now.
  Signal(this.ctx, T Function(Context ctx) compute)
      : _backing = _SignalSlot<T>(ctx, compute) {
    _backing.signal = this;
    // Eager activation: compute once now so there is no intermediate unset
    // value, and so dependency edges are established immediately.
    _value = _backing();
  }

  final Context ctx;
  final _SignalSlot<T> _backing;
  late T _value;
  bool _active = true;
  bool _recomputing = false;

  /// The current materialized value. Reading inside a computation subscribes
  /// the reader.
  T get value {
    _track(ctx);
    if (!_active) {
      // Disposed: the eager puller is gone, so behave lazily.
      return _backing();
    }
    return _value;
  }

  /// Read the value (alias for [value]).
  T get() => value;

  /// Eagerly recompute. If the value changed, cascade to dependents.
  void _eagerRecompute() {
    if (!_active || _recomputing) return;
    _recomputing = true;
    final T newValue;
    try {
      newValue = _backing();
    } finally {
      _recomputing = false;
    }
    if (newValue != _value) {
      _value = newValue;
      _invalidate();
    }
  }

  /// Remove the eager puller. The value remains readable but reverts to lazy
  /// behavior: it will only recompute on the next explicit read.
  void dispose() {
    _active = false;
    _backing.signal = null;
  }

  /// Whether the eager puller is still installed.
  bool get isActive => _active;

  @override
  void onInvalidate() {
    // The signal holds its value directly; nothing to evict. The eager
    // recompute is driven by the backing slot's invalidation hook.
  }

  @override
  String toString() => 'Signal($_value)';
}

/// Backing slot for [Signal]. Its invalidation eagerly re-pulls the signal
/// instead of leaving it dirty.
class _SignalSlot<T> extends Slot<T> {
  _SignalSlot(super.ctx, super.compute);

  Signal<T>? signal;

  @override
  void onInvalidate() {
    // Evict the cached slot value so the re-pull actually recomputes, then
    // eagerly recompute the owning signal (which re-establishes upstream
    // edges and cascades downstream only if the value changed).
    _uncache(ctx);
    // Scheduled, never inline (`#lzsignaleager` clause 3): invalidation is
    // earlier than the flush, so pulling here would re-materialize once per
    // invalidated source instead of once per batch. [Context._scheduleSignalPull]
    // also drops the pull during a disposal cascade, which is mark-only.
    final owner = signal;
    if (owner != null) ctx._scheduleSignalPull(owner);
  }
}

/// A side-effect function that may return a cleanup callback.
///
/// The cleanup (if returned) is invoked before the next rerun and on dispose.
typedef EffectRun = void Function()? Function(Context ctx);

/// A side-effect observer that reruns whenever a tracked dependency changes.
///
/// [Effect] is the eager-push primitive for side effects (logging, DOM writes,
/// I/O). It registers dependencies dynamically: any [Cell], [Slot], or
/// [Signal] read inside [run] during the current execution becomes a
/// dependency. When any dependency changes, the effect is scheduled and reruns
/// after the current cascade (or at [batch] exit).
///
/// The [run] callback may return a cleanup function. Cleanup runs before each
/// rerun and on [dispose], so resources are never leaked across reruns.
///
///     final ctx = Context();
///     final a = Cell<int>(ctx, 1);
///   final log = <int>[];
///   final dispose = Effect(ctx, (_) {
///   log.add(a.value);
///   return null;
///   }).dispose;
///   a.value = 2; // log is now [1, 2]
///   dispose();
///   a.value = 3; // log is unchanged — effect disposed
class Effect extends _ReactiveNode {
  Effect(this.ctx, EffectRun run) : _run = run {
    _rerun();
  }

  /// The context this effect belongs to.
  final Context ctx;
  final EffectRun _run;
  void Function()? _cleanup;
  bool _running = false;

  /// Remove the eager observer. Unsubscribes from all dependencies, then
  /// invokes the last cleanup. Idempotent.
  ///
  /// Routes through the shared [_disposeNode] so an effect tears down by
  /// exactly the same rules as a slot or a cell — the point of
  /// `disposeScope_eq_disposeAll` is that a scope names a set and a moment and
  /// introduces no disposal semantics of its own, which only holds if the three
  /// kinds share one teardown.
  void dispose() => _disposeNode();

  @override
  void onDispose() {
    // Do NOT remove from `_pendingEffects` by value — that would shift entries
    // and corrupt the FIFO head pointer. A queued-but-disposed effect is a
    // no-op when popped (`_rerun` guards on `_disposed`), and the upstream
    // detach in `_disposeNode` ensures its `onInvalidate` never fires again.
    if (Context.naivePendingScan) {
      // Naive form under audit, mirroring lazily-kt `disposeEffect`'s
      // `ArrayDeque.indexOf`. Result discarded.
      ctx._naiveScanSink += ctx._pendingEffects.indexOf(this);
    }
    ctx._scheduledEffects.remove(this);
    final c = _cleanup;
    _cleanup = null;
    if (c != null) c();
  }

  /// Whether the effect is still active (not disposed).
  bool get isActive => !_disposed;

  void _rerun() {
    if (_disposed || _running) return;
    _running = true;
    try {
      _detachUpstream();
      final prev = _cleanup;
      _cleanup = null;
      if (prev != null) prev();
      ctx._stack.add(this);
      try {
        _cleanup = _run(ctx);
      } finally {
        ctx._stack.removeLast();
      }
    } finally {
      _running = false;
    }
  }

  @override
  void onInvalidate() {
    ctx._scheduleEffect(this);
  }

  @override
  String toString() => 'Effect(${_disposed ? 'disposed' : 'active'})';
}

/// A lazy, cached, dependency-tracking computation with an equality guard.
///
/// [Memo] behaves like [Slot] but suppresses downstream invalidation when a
/// recompute yields a value equal (`==`) to the previous one. This is the
/// memo-equality invariant from the lazily-spec: "a dirty `memo()` that
/// recomputes equal emits no `SlotValue` and no downstream `Invalidate`."
///
/// On invalidation, [Memo] eagerly recomputes (to check equality) rather than
/// waiting for a read. If the new value equals the old, the downstream cascade
/// is aborted and dependents stay cached.
///
///     final ctx = Context();
///   final width = Cell<int>(ctx, 10);
///   // area only cascades when width is even — odd widths give the same tag.
///   final area = Memo<String>(ctx, (_) => width.value.isEven ? 'even' : 'odd');
///   // Observe it with an Effect; `area` only cascades when the tag changes.
///   final effect = Effect(ctx, (_) { print(area()); return null; });
class Memo<T> extends Slot<T> {
  Memo(super.ctx, super.compute, {super.name});

  bool _guardActive = false;

  @override
  void _invalidateInto(List<_ReactiveNode> stack) {
    if (_guardActive) return;
    if (ctx._disposalDepth > 0) {
      // A disposal cascade is mark-only, so the equality guard is skipped and
      // the cascade propagates unconditionally. Recomputing here to *check*
      // equality would read through the node being torn down and throw out of
      // `dispose`. Propagating unconditionally is the conservative direction:
      // dependents are marked dirty and recompute (and error, if they still
      // name the disposed node) on their next read. See
      // [Context._disposalDepth].
      super._invalidateInto(stack);
      _uncache(ctx);
      return;
    }
    _guardActive = true;
    try {
      _detachUpstream();
      ctx._stack.add(this);
      T newValue;
      try {
        newValue = _compute(ctx);
      } finally {
        ctx._stack.removeLast();
      }
      final gen = ctx._generation;
      if (_cacheGen == gen) {
        if (newValue == _cachedValue) {
          // Value unchanged — suppress the downstream cascade. Dependents
          // stay cached; edges are already re-established by the recompute.
          return;
        }
      } else {
        // First compute — count this newly cached slot.
        ctx._cachedCount++;
        _cacheGen = gen;
      }
      // Value changed (or first compute) — update cache and cascade by pushing
      // dependents onto the shared DFS stack (no per-node `.toList()`).
      _cachedValue = newValue;
      final deps = _dependents;
      if (deps == null || deps.isEmpty) return;
      for (final dependent in deps) {
        stack.add(dependent);
      }
      deps.clear();
      _dependentIndex = null;
    } finally {
      _guardActive = false;
    }
  }

  @override
  void onInvalidate() {
    // Memo manages its own cache lifecycle inside [_invalidate]; the
    // default eviction is intentionally bypassed.
  }
}

/// A teardown scope over a [Context]: nodes created through it are disposed
/// when it ends (`#lzspecedgeindex`).
///
/// ## Why this is not "scope-ends-on-drop"
///
/// `lazily-rs` ends a scope in `Drop`, so the scope's lifetime is the block's
/// and there is nothing to forget. Dart has no destructor and no deterministic
/// finalization — `Finalizer` is explicitly best-effort and may never run — so
/// that shape does not transfer, and a scope whose teardown depends on the GC
/// would be strictly worse than no scope at all: the leak it exists to prevent
/// would come back non-deterministically.
///
/// The end therefore has to be a statement, and this class offers it in the two
/// shapes real callers need:
///
/// - [Context.withScope] brackets the scope around a callback and ends it in a
///   `finally`. This is the direct analogue of the Rust block scope and the
///   idiom Dart already uses wherever a lifetime is lexical, and it is what to
///   reach for by default.
/// - [end] ends the scope explicitly, for the case `withScope` cannot express:
///   a scope whose lifetime is a *connection*, a *subscription*, or a
///   *route* — opened in one callback and ended in another, across an
///   asynchronous gap. That is the primary use of scopes, so it cannot be
///   callback-only.
///
/// Both are idempotent, so the two compose: a scope ended early inside
/// `withScope` is not ended twice.
///
/// ## What it stores
///
/// Just the node references, in creation order. Teardown walks them in
/// **reverse** creation order — dependents before what they read — so the scope
/// never transiently dangles inside itself while tearing down. Graph state is
/// order-independent (`disposeAll_order_independent` in lazily-formal), but
/// effect *cleanups* are side effects, and their order is observable; ending a
/// scope is proved observationally equal to disposing each member
/// (`disposeScope_eq_disposeAll`).
class TeardownScope {
  TeardownScope._(this.ctx);

  /// The context this scope belongs to.
  final Context ctx;

  final List<GraphNode> _owned = [];
  bool _ended = false;

  /// How many nodes this scope currently owns.
  int get length => _owned.length;

  /// Whether this scope owns nothing — either because nothing was created
  /// through it, because it was [disarm]ed, or because it has [end]ed.
  bool get isEmpty => _owned.isEmpty;

  /// Whether this scope owns at least one node.
  bool get isNotEmpty => _owned.isNotEmpty;

  /// Whether [end] has already run.
  bool get isEnded => _ended;

  /// Take ownership of an existing [node], so this scope disposes it at
  /// end-of-life.
  ///
  /// The factories below are the ordinary path; this exists for nodes built by
  /// a helper that does not know about scopes. A node adopted twice by the same
  /// scope is disposed once (disposal is idempotent), and adopting into an
  /// already-ended scope is a no-op rather than an immediate disposal — the
  /// scope's moment has passed.
  T adopt<T extends GraphNode>(T node) {
    if (!_ended) _owned.add(node);
    return node;
  }

  /// Create a source [Cell] owned by this scope.
  Cell<T> cell<T>(T initialValue) => adopt(Cell<T>(ctx, initialValue));

  /// Create a lazily-computed [Slot] owned by this scope.
  Slot<T> slot<T>(T Function(Context ctx) compute, {String? name}) =>
      adopt(Slot<T>(ctx, compute, name: name));

  /// Create a [Memo] owned by this scope.
  Memo<T> memo<T>(T Function(Context ctx) compute, {String? name}) =>
      adopt(Memo<T>(ctx, compute, name: name));

  /// Register an [Effect] owned by this scope.
  Effect effect(EffectRun run) => adopt(Effect(ctx, run));

  /// Cancel this scope's teardown: ending it afterwards disposes nothing, and
  /// its nodes revert to plain context ownership — the state every unscoped
  /// node is already in.
  ///
  /// The nodes themselves are untouched: they keep their values, keep their
  /// edges in both directions, keep propagating, and remain individually
  /// disposable. The only thing that changes is whether this scope fires at
  /// end-of-life, which is what the name says — the same sense as defusing a
  /// guard.
  void disarm() => _owned.clear();

  /// Dispose every node this scope owns, in reverse creation order.
  ///
  /// Idempotent, and safe over members whose own dependencies were already
  /// disposed: teardown flows from the scope's owned set, not from
  /// reachability.
  void end() {
    if (_ended) return;
    _ended = true;
    // Reverse creation order: dependents before what they read.
    for (var i = _owned.length - 1; i >= 0; i--) {
      ctx.disposeNode(_owned[i]);
    }
    _owned.clear();
  }

  @override
  String toString() =>
      'TeardownScope(${_ended ? 'ended' : '${_owned.length} owned'})';
}
