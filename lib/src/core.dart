/// The Cell kernel for Dart — v2 (`#lzcellkernel`).
///
/// A pure-Dart port of the lazily reactive family (`lazily-py`, `lazily-js`,
/// `lazily-zig`), mirroring `lazily-rs`. See
/// `lazily-spec/docs/reactive-graph.md` and
/// `tasks/software/lazily-cell-kernel-design.md` §1/§4/§9.3.
///
/// **Cell** is the value-bearing *node concept* — a reactive that holds a
/// readable value. It is not a type here: there is no `Cell<T, K>` genus. The
/// two concrete *cell* kinds are the handles a caller holds:
///
/// - [Source] — a value written from *outside* the graph (`get` / `set` /
///   `merge`); the writable kind. A [MergeCell] is a [Source] whose write folds
///   under a non-`KeepLatest` policy (`Source ≡ MergeCell(KeepLatest)`). The
///   name [Cell] is retained as a compatibility spelling of [Source].
/// - [Computed] — a value computed from *upstream* (`get`, `.eager()`,
///   `.lazy()`, `isEager`). **Guarded, always**: an equal recompute (`==`)
///   suppresses the downstream cascade, exactly as TC39 `Signal.Computed`. Lazy
///   by default; made *eager* by [Computed.eager].
///
/// [Effect] is the value-less sink outside the cell hierarchy — nothing can
/// depend on it — and is the eager-push primitive for side effects.
///
/// Dart has no compile-time read/write split (design §4): the kind is
/// *convention*, never a runtime gate. A [Source] exposes `set` / `merge`; a
/// [Computed] simply has no such method (method-presence, no runtime rejection).
///
/// [Slot] is retained as the lower-level storage/computation position (spec
/// §5.0) and the **unguarded** callable lazy computed — the primitive to reach
/// for when a value is not `==`-comparable or the guard is unwanted. The
/// *guarded* derived value is [Computed]; there is no separate `memo` kind (its
/// equality guard folded into [Computed]).
///
/// **The eager construction is `computed(ctx, f).eager()`** — it retires the
/// former standalone `Signal`. Eagerness is graph state (an `_eager` bit plus
/// the [_eagerBy] side table holding the puller [Effect]), not a distinct node
/// kind. Because the only way to make a computed eager is to attach a
/// *scheduled* Effect, the `#lzsignaleager` per-write puller — recomputing
/// inline during the invalidation wave — is structurally unrepresentable here.
/// The former standalone `Signal` / `signal` are **gone** — an eager derived
/// value is spelled `computed(ctx, f).eager()`.
///
/// Values are **lazy by default**: dependents are marked dirty on invalidation
/// but only recompute when accessed. When you need eager push-style semantics,
/// call [Computed.eager].
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
/// Sealed: [Slot] (and its guarded backing), [Source] (a.k.a. [Cell]),
/// [Computed], and [Effect] are the
/// only implementations, and the type cannot be
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
/// All [Slot]s, [Source]s, and [Computed]s that should react to each other
/// must be created with (and thus share) the same [Context]. The cache keys on
/// object identity, so each reactive instance is cached independently.
class Context implements ComputeOps {
  /// The value cache lives ON-NODE ([Slot._cachedValue] / [Slot._cacheGen]):
  /// a slot is "cached" iff its `_cacheGen == _generation`. [clear] bumps this
  /// counter, invalidating every slot in O(1) without the [Context] having to
  /// enumerate them (mirrors lazily-rs `SlotNode.value: Option<…>` as a direct
  /// field). This drops the former `Map.identity` cache — the single biggest
  /// allocation and per-lookup-cost source at viewport scale.
  int _generation = 0;
  int _cachedCount = 0;

  /// Depth of the explicit **untracked** escape (`#lzcellkernel`). While it is
  /// non-zero every read reports *no* current dependent, so a read made through
  /// [Compute.untracked] (or [Context], the untracked surface) registers no
  /// dependency edge — the mirror of `lazily-rs`'s `Compute::untracked() ->
  /// &Context`, whose reads form no edge. See [runUntracked].
  int _untrackedDepth = 0;

  /// Monotonic recompute counter (`#lzcellkernel`). Each [Compute] view is
  /// stamped with the value this held when it was minted; a view whose stamp no
  /// longer matches — because its recompute finished, or the node was
  /// disposed/recycled mid-recompute — is *stale* and any tracked read through
  /// it throws [StaleComputeError]. This is the runtime half of the
  /// non-escapability fortification Dart cannot express in the type system the
  /// way `lazily-rs` does with a lifetime + `!Send`.
  int _computeEpoch = 0;

  int _batchDepth = 0;
  Set<Source>? _batchedCells;
  Set<Slot>? _batchedSlots;
  final List<Effect> _pendingEffects = [];
  int _pendingEffectsHead = 0;
  final Set<Effect> _scheduledEffects = Set.identity();
  bool _flushingEffects = false;

  /// The eager re-materialization of an eager [Computed] is an ordinary
  /// [Effect] (the puller), so `#lzsignaleager` clause 3 is inherited from the
  /// effect scheduler rather than special-cased here. The puller is *scheduled*,
  /// never run inline from an invalidation hook: N writes inside a [batch] mark
  /// the computed's plain backing [Slot] dirty (no recompute) and coalesce into
  /// ONE scheduled puller rerun at the flush, which recomputes the computed once.
  /// An inline pull would recompute once per invalidated source — the same value
  /// at a multiple of the work, which is why the defect shipped unnoticed
  /// elsewhere until `signal_materializes_once_per_batch.json` counted the
  /// computes. Because the only way to make a computed eager is to attach that
  /// scheduled Effect ([Computed.eager]), the per-write puller is structurally
  /// unrepresentable.

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
  /// - A guarded [Slot] backing skips its equality recompute and propagates
  ///   unconditionally, for the same reason: it would recompute *through* the
  ///   disposed node. An eager [Computed]'s puller is a scheduled [Effect],
  ///   so it is dropped by the [_scheduleEffect] guard above with every other
  ///   effect.
  int _disposalDepth = 0;

  /// The number of cached slot values.
  int get size => _cachedCount;

  /// Whether [node] currently has a cached value. Only [Slot]s cache values
  /// directly; a [Computed] delegates to its guarded backing slot; sources hold
  /// their value directly and effects never cache.
  bool contains(_ReactiveNode node) {
    if (node is Computed) return node._backing._isCachedInGeneration(this);
    return node is Slot && node._isCachedInGeneration(this);
  }

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

  /// Whether tracking is currently suppressed by an [runUntracked] /
  /// [Compute.untracked] window. A [Compute.get] performed while this holds
  /// forms no dependency edge — the value-threaded mirror of the old
  /// `_current == null` short-circuit.
  bool get _trackingSuppressed => _untrackedDepth > 0;

  /// Run [body] with dependency tracking suppressed: reads inside it register no
  /// edge against whatever node is currently recomputing. The scoped form of the
  /// untracked escape; [Compute.untracked] delegates here. Re-entrant.
  R runUntracked<R>(R Function() body) {
    _untrackedDepth++;
    try {
      return body();
    } finally {
      _untrackedDepth--;
    }
  }

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

  /// Called by [Source] when its value changes. Routes through the batch queue
  /// when a batch is active, otherwise cascades immediately + flushes effects.
  void _cellChanged(Source cell) {
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
    // writes a [Source], so these sets are not re-populated mid-flush.
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
  /// An eager [Computed]'s re-materialization does not reenter here —
  /// its puller is a scheduled [Effect] that recomputes from the flush, outside
  /// this walk.
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
  void disposeCell(Source<Object?> cell) => cell._disposeNode();

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
      // lazily-rs `VecDeque::pop_front`). A drained effect may schedule more
      // effects — including an eager [Computed]'s puller, and the consumers
      // that puller's change-cascade schedules — so the loop re-reads `length`
      // each pass. A puller is enqueued (and thus reruns) before any consumer
      // its re-materialization schedules, so a consumer that reads an eager
      // computed observes the fresh value, not the pre-write one.
      while (_pendingEffectsHead < _pendingEffects.length) {
        final effect = _pendingEffects[_pendingEffectsHead];
        _pendingEffectsHead++;
        if (naivePendingScan) {
          // Naive form under audit: scan the pending collection for an entry
          // that the head pointer has already consumed. Result discarded.
          _naiveScanSink += _pendingEffects.indexOf(effect);
        }
        _scheduledEffects.remove(effect);
        effect._rerun();
      }
      _pendingEffects.clear();
      _pendingEffectsHead = 0;
    } finally {
      _flushingEffects = false;
    }
  }

  // -- ComputeOps surface (`#lzcellkernel`) ---------------------------------
  //
  // The [Context] is one of the two implementors of [ComputeOps] (the other is
  // [Compute]). It is the **untracked** surface: a read through it registers no
  // dependency edge, the mirror of `lazily-rs`'s `impl ComputeOps for Context`
  // whose reads are untracked. Construction ops are identical to [Compute]'s.

  @override
  Source<T> source<T>(T value) => Source<T>(this, value);

  @override
  Source<T> cell<T>(T value) => Source<T>(this, value);

  @override
  Computed<T> computed<T>(T Function(Compute cx) compute) =>
      Computed<T>(this, compute);

  @override
  Computed<T> computedRippleWhen<T>(
    T Function(Compute cx) compute,
    bool Function(T old, T neu) changed,
  ) =>
      Computed<T>(this, compute, changed: changed);

  @override
  Slot<T> slot<T>(T Function(Compute cx) compute, {String? name}) =>
      Slot<T>(this, compute, name: name);

  @override
  Effect effect(EffectRun run) => Effect(this, run);

  /// Read [handle]'s value **untracked** — the [Context] is the untracked
  /// surface, so this forms no dependency edge even when called from inside a
  /// recompute. Use [Compute.get] for a tracked read.
  @override
  T get<T>(ComputeReadable<T> handle) => runUntracked(handle._read);

  /// Write a source cell (a write is never a dependency).
  @override
  void set<T>(Source<T> cell, T value) => cell.value = value;
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

  /// Register [reader] as a dependent of this node (downstream edge) and the
  /// reverse dependency edge on [reader]. The value-threaded replacement for the
  /// former ambient `_track`: the recomputing identity is supplied by the
  /// [Compute] view performing the read ([Compute.get] / [ComputeReadable.
  /// _readTrackedBy]), never read from a `Context`-owned current-node stack.
  @pragma('vm:prefer-inline')
  void _wireEdge(_ReactiveNode reader) {
    _addDependent(reader);
    reader._addDependency(this);
  }

  /// Enter a recompute of this node (`#lzcellkernel`).
  ///
  /// Mints a fortified [Compute] view that carries **this node as a value** —
  /// the recomputing identity is threaded through the closure argument, not read
  /// from an ambient global, so it survives an `await` (the view is captured by
  /// the closure) exactly as `lazily-rs`'s `Compute` does. There is **no** ambient
  /// current-node stack: a tracked read is exclusively [Compute.get], which wires
  /// the edge against the node this view carries as a value.
  Compute _beginCompute() {
    return Compute._(ctx, this, ctx._computeEpoch++);
  }

  /// Leave a recompute: retire the [Compute] view so a later (escaped) tracked
  /// read through it throws [StaleComputeError].
  void _endCompute(Compute cx) {
    cx._valid = false;
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
  /// which serves as the visited mark). Overridden by the guarded [Slot]
  /// backing to gate the cascade behind its equality guard.
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
/// the value (tracking every [Source], [Computed], or [Slot] read during
/// computation as a dependency), caches it, and returns it. When any
/// dependency changes, the cached value is invalidated and the next read
/// recomputes.
///
/// Example::
///
///     final ctx = Context();
///     final a = Source<int>(ctx, 2);
///     final doubled = Slot<int>(ctx, (_) => a.value * 2);
///     doubled(); // 4
///     a.value = 10;
///     doubled(); // 20
class Slot<T> extends _ReactiveNode implements ComputeReadable<T> {
  /// Creates a lazy slot bound to [ctx].
  Slot(this.ctx, T Function(Compute cx) compute, {this.name})
      : _compute = compute;

  /// The context this slot belongs to.
  @override
  final Context ctx;
  final T Function(Compute cx) _compute;

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
  /// **Untracked** on its own: it forms no dependency edge for a reader. Tracking
  /// is the job of the reading [Compute] via [_readTrackedBy]; a bare `slot()`
  /// call (outside a compute, or a legacy call site) simply reads/recomputes.
  ///
  /// Throws [DisposedNodeError] if this slot has been disposed.
  T call() {
    if (_disposed) throw DisposedNodeError(this);
    final gen = ctx._generation;
    if (_cacheGen == gen) {
      return _cachedValue as T;
    }
    _detachUpstream();
    final cx = _beginCompute();
    try {
      final value = _compute(cx);
      if (_cacheGen != gen) {
        ctx._cachedCount++;
        _cacheGen = gen;
      }
      _cachedValue = value;
      return value;
    } finally {
      _endCompute(cx);
    }
  }

  /// The untracked read used by [ComputeOps.get] on [Context] — reading a slot
  /// is recomputing/reading it through [call], forming no reader edge.
  @override
  T _read() => call();

  /// The tracked read used by [Compute.get]: wires [reader] ← this slot, then
  /// reads (recomputing if stale). The disposed check precedes the edge so a
  /// reader never leaves an edge pointing at a torn-down node.
  @override
  T _readTrackedBy(_ReactiveNode reader) {
    if (_disposed) throw DisposedNodeError(this);
    _wireEdge(reader);
    return call();
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

/// The **source cell** of the Cell kernel — a value written from *outside* the
/// graph (`#lzcellkernel`).
///
/// [Source] is the writable *cell* handle: `get` / `set` / `merge`. A write
/// triggers a cascade only when the new value is not equal (`!=`) to the old one
/// — the `PartialEq` store-guard (all cells guarded, always). `merge` folds the
/// incoming operand under a merge policy; the default is keep-latest
/// (`Source ≡ MergeCell(KeepLatest)`), so a bare `merge` is a `set`. For a
/// non-`KeepLatest` fold, use `mergeCell(ctx, v, policy)` from
/// `package:lazily/src/merge.dart`.
///
/// Reading [value] inside a [Slot] / [Computed] computation registers a
/// dependency.
///
/// A [Source] carries **no callback registry**. Observation in a reactive graph
/// is a declared dependency edge, not a registered listener: use an [Effect]
/// (eager push, batching-aware, glitch-free) for side effects such as Flutter
/// `ValueNotifier` bridges and `setState` wrappers, and a `Topic` when a
/// consumer genuinely needs a stream of every transition. A per-cell listener
/// list would bypass the graph, ignore [Context.batch], and cost memory on
/// every cell whether or not anything is listening.
class Source<T> extends _ReactiveNode implements ComputeReadable<T> {
  Source(this.ctx, T initialValue) : _value = initialValue;

  /// The context this cell belongs to.
  @override
  final Context ctx;
  T _value;

  /// The untracked read used by [ComputeOps.get] on [Context].
  @override
  T _read() => value;

  /// The tracked read used by [Compute.get]: wires [reader] ← this cell, then
  /// returns the value.
  @override
  T _readTrackedBy(_ReactiveNode reader) {
    if (_disposed) throw DisposedNodeError(this);
    _wireEdge(reader);
    return _value;
  }

  /// The current value. **Untracked** on its own — a bare `cell.value` read
  /// forms no dependency edge. Reading inside a computation subscribes the reader
  /// only through [Compute.get] (`cx.get(cell)`), which threads the reader.
  ///
  /// Throws [DisposedNodeError] if this cell has been disposed —
  /// `disposeCell` and `disposeSlot` share one read-after-dispose contract.
  T get value {
    if (_disposed) throw DisposedNodeError(this);
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

  /// Fold [op] into the current value under keep-latest (a plain replace),
  /// routing through the `!=`-guarded setter. This is the [Source] side of the
  /// v2 `get` / `set` / `merge` surface; a [MergeCell] overrides the fold with a
  /// non-`KeepLatest` policy.
  void merge(T op) => value = op;

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
  String toString() => 'Source($_value)';
}

/// Deprecated compatibility spelling of [Source] (`#lzcellkernel` v2).
///
/// **Cell** is the value-node *concept* in v2 — a reactive that holds a readable
/// value — not a genus type: there is no `Cell<T, K>`. The concrete
/// source-cell handle is [Source] (`Source ≡ MergeCell(KeepLatest)`); use it
/// directly. This alias is retained only so existing `Cell<T>` call sites keep
/// compiling.
@Deprecated('Use Source — the canonical source-cell handle (#lzcellkernel)')
typedef Cell<T> = Source<T>;

/// Create a [Source] (a keep-latest cell) over [ctx].
///
/// The Cell-kernel constructor for a written-from-outside value; the spelling of
/// the reference's `ctx.source(v)`. For a non-`KeepLatest` fold, use
/// `mergeCell(ctx, v, policy)` from `package:lazily/src/merge.dart`.
Source<T> source<T>(Context ctx, T initialValue) => Source<T>(ctx, initialValue);

/// The `eager_by` side table (`reactive-graph.md` §9.3.3): the `_eager` bit on
/// a [Computed] answers "am I eager?" for free (making [Computed.eager]
/// idempotent with no lookup); this table holds "which effect pulls me" for
/// exactly the rare eager computeds, and nothing for the lazy ones. Owner-keyed
/// by the [Computed] instance by *identity*.
///
/// Dart object identity is stable for the object's lifetime and a disposed
/// computed is never recycled onto a live one (unlike Rust's `SlotId`), so the
/// generation-tag hazard of §9.3.5 does not arise. The strong reference to the
/// puller is released on [Computed.lazy] / [Computed.dispose] so a
/// torn-down computed (and its puller) becomes collectable.
final Map<Computed<Object?>, Effect> _eagerBy =
    HashMap<Computed<Object?>, Effect>.identity();

/// A **computed cell** — a value computed from *upstream* (`#lzcellkernel` v2).
///
/// The derived *cell* handle. Construct with [computed]; it is **guarded,
/// always** — an equal recompute (`==`) suppresses the downstream cascade,
/// matching TC39 `Signal.Computed`. There is no unguarded mode and no separate
/// `memo` kind: the equality guard folded into [Computed]. (For a value that is
/// not `==`-comparable, reach for the lower-level unguarded [Slot].)
///
/// Lazy by default: an upstream change marks the value stale, the guarded
/// backing recomputes on the next read, and an equal result stops the cascade.
///
/// Calling [eager] makes it **eager**: the value is materialized now and
/// re-materialized whenever a tracked dependency changes. The eager construction
/// is `computed(ctx, f).eager()`, which retires the former standalone `Signal`.
/// Eagerness is graph state — an [_eager] bit plus the [_eagerBy] side table
/// holding the puller [Effect] — not a distinct node kind. The puller is an
/// ordinary [Effect] over a **plain** backing [Slot] (the backing's inline guard
/// is switched off while eager), so it is *scheduled*: N writes inside one
/// [Context.batch] re-materialize the computed ONCE at the flush, not once per
/// write (`reactive-graph.md` clause 3). Because the only way to make a computed
/// eager is to attach that scheduled Effect, the `#lzsignaleager` per-write
/// puller is structurally unrepresentable.
///
/// Reading [value] inside another computation registers a dependency, so
/// downstream reactives invalidate when this computed's value changes. Like every
/// reactive in this library, a [Computed] exposes **no observer API** — see
/// [Source] for the rationale.
class Computed<T> extends _ReactiveNode implements ComputeReadable<T> {
  /// Creates a **lazy** computed bound to [ctx]. Call [eager] for the eager form.
  ///
  /// When [changed] is supplied, downstream propagation is gated by that
  /// **pure** predicate instead of the value's natural `==` — see
  /// [computedRippleWhen], which is the public spelling of this form.
  Computed(this.ctx, T Function(Compute cx) compute,
      {bool Function(T old, T neu)? changed})
      : _changed = changed,
        _backing = _GuardedSlot<T>(ctx, compute, changed: changed);

  @override
  final Context ctx;

  /// The custom propagate predicate (`#lzcellkernel`), mirrored from the backing
  /// so the eager puller ([_pull]) applies the same guard the lazy backing does.
  final bool Function(T old, T neu)? _changed;

  /// The backing [_GuardedSlot] — the storage/computation position (spec §5.0).
  /// **Guarded while lazy**: it recomputes inline on invalidation and suppresses
  /// an equal (`==`) cascade, which is where a lazy computed's guard lives.
  /// **Un-guarded while eager**: its inline guard is switched off (via
  /// `_guardEnabled`) so, under a multi-write batch, an eager computed does not
  /// recompute once per written source; the equality guard then lives on the
  /// puller ([_pull]), applied to the single coalesced re-materialization.
  final _GuardedSlot<T> _backing;

  /// The materialized value, valid whenever [_eager]. `_hasValue` distinguishes
  /// the first materialization (at [eager]) from a later guarded recompute.
  late T _value;
  bool _hasValue = false;
  bool _eager = false;

  /// The current value; reading inside a computation subscribes the reader.
  ///
  /// Eager: returns the materialized value. Lazy: recomputes through the guarded
  /// backing slot on read (which also tracks the reader as a dependency of the
  /// backing slot, so an upstream change still invalidates the reader — and an
  /// equal recompute is suppressed by the backing's guard).
  T get value {
    if (!_eager) return _backing();
    return _value;
  }

  /// Read the value (alias for [value]).
  T get() => value;

  /// Read the value (callable alias for [value]) — the lower-level `slot()`
  /// spelling, for call sites that fold a computed like a [Slot].
  T call() => value;

  /// The untracked read used by [ComputeOps.get] on [Context].
  @override
  T _read() => value;

  /// The tracked read used by [Compute.get]. Wires [reader] ← this computed;
  /// while **lazy** it also wires [reader] ← the guarded backing slot, so an
  /// upstream change that ripples through the backing invalidates the reader
  /// (the value-threaded form of the former dual `_track` this getter performed
  /// through both the computed and its backing). While **eager** the puller
  /// owns the backing edge and drives this computed's cascade, so only the
  /// reader ← computed edge is wired here.
  @override
  T _readTrackedBy(_ReactiveNode reader) {
    _wireEdge(reader);
    if (!_eager) {
      _backing._wireEdge(reader);
      return _backing();
    }
    return _value;
  }

  /// The current value without registering a dependency.
  T get peek => _eager ? _value : (_backing.peek ?? _backing());

  /// Make this computed **eager**, and return **this same** computed.
  ///
  /// Idempotent — a second [eager] is a no-op, so `c.eager().eager()` never
  /// attaches two pullers (which would double the eager compute). Switches the
  /// backing slot's inline guard off (so the puller, not the backing, is the
  /// point of coalescing), attaches a *scheduled* puller [Effect] over the
  /// backing [Slot], and records it in the [_eagerBy] side table — materializing
  /// the value once now (clause 1) and establishing the dependency edges.
  /// Because the puller is an [Effect] it is scheduled, not inline: N writes
  /// inside one [Context.batch] coalesce into ONE re-materialization at the
  /// flush (clause 3).
  ///
  /// Returns the same handle with graph state mutated — `g = c.eager()` gives
  /// `identical(g, c)`, both eager; it is not builder-style `with(...)`.
  Computed<T> eager() {
    if (_eager) return this;
    _eager = true;
    // Hand coalescing to the scheduled puller, not the backing's inline guard.
    _backing._guardEnabled = false;
    // The Effect constructor runs the body once now, materializing the value
    // without a read (clause 1) and wiring the puller -> backing edge.
    final puller = Effect(ctx, _pull);
    _eagerBy[this] = puller;
    return this;
  }

  /// Puller-Effect body: re-materialize the backing slot into [_value], applying
  /// the equality guard so an equal recompute fires no downstream cascade.
  void Function()? _pull(Compute cx) {
    final newValue = cx.get(_backing);
    if (!_hasValue) {
      _hasValue = true;
      _value = newValue;
    } else if (_changed != null ? _changed(_value, newValue) : newValue != _value) {
      _value = newValue;
      // Cascade to *this computed's* dependents. Scheduled effects (consumers)
      // are enqueued after this puller, so they observe the fresh value.
      _invalidate();
    }
    return null;
  }

  /// Reverse of [eager]: stop eager recomputation and dispose the puller.
  ///
  /// The value stays readable and reverts to **lazy recompute-on-read**. No-op
  /// if not eager. Clears the [_eager] bit and the [_eagerBy] entry
  /// (`reactive-graph.md` clause 4) so no puller is stranded.
  ///
  /// The backing's inline guard is deliberately **left off** here: clause 4
  /// (`dispose_signal_reverts_to_lazy`) requires that an invalidating write to a
  /// reverted computed does NOT re-materialize — only a subsequent read
  /// recomputes. Re-enabling the inline guard would recompute on the write to
  /// check equality, which the fixture pins as a violation. A reverted computed
  /// is therefore an ordinary unguarded lazy pull (the v1 `undrive` behaviour);
  /// only a *freshly constructed* lazy computed carries the inline push-guard.
  void lazy() {
    if (!_eager) return;
    _eager = false;
    final puller = _eagerBy.remove(this);
    puller?.dispose();
  }

  /// Tear down the eager puller (if any); the value reverts to lazy.
  ///
  /// Disposing an eager computed tears down its puller (`reactive-graph.md`
  /// clause 4); the backing slot is untouched, so the value stays readable and
  /// correct and simply stops re-materializing on write. This is the former
  /// `Signal.dispose` / the corpus `dispose_signal` semantics — a puller
  /// teardown, not a full node teardown. To tear the computed out of the graph
  /// entirely, use [Context.disposeNode].
  void dispose() => lazy();

  /// Whether this computed is currently eager (has an active puller).
  bool get isEager => _eager;

  @override
  void onInvalidate() {
    // The computed holds its materialized value directly; nothing to evict. The
    // eager re-materialization is driven by the puller Effect, not this hook.
  }

  @override
  void onDispose() {
    // A full node teardown (via [Context.disposeNode]) also tears down the
    // puller and the backing slot, so nothing is stranded.
    lazy();
    _backing.dispose();
  }

  @override
  String toString() =>
      _eager ? 'Computed(eager, $_value)' : 'Computed(lazy)';
}

/// Create a lazy, guarded [Computed] bound to [ctx].
///
/// The canonical derived-value constructor of the Cell kernel — it is the
/// spelling of the reference's `ctx.computed(f)`, **guarded by default** (an
/// equal recompute suppresses the downstream cascade). It replaces the old
/// `formula` / `memo` names. Call [Computed.eager] for the eager form:
///
///     final n = source(ctx, 1);
///     final doubled = computed(ctx, (_) => n.value * 2).eager();
///     doubled.value; // 2, kept fresh eagerly
Computed<T> computed<T>(Context ctx, T Function(Compute cx) compute) =>
    Computed<T>(ctx, compute);

/// Create a **guarded [Computed]** with an explicit change predicate
/// (`#lzcellkernel`).
///
/// Like [computed], but downstream propagation (the "ripple" to dependents) is
/// gated by `changed(old, new)` instead of the value's natural `==`: `changed`
/// returns `true` to **propagate** the recompute downstream, `false` to
/// **suppress** it (treat it as "no meaningful change"). It is implemented over
/// the existing guarded-computed engine by installing equality = `!changed`.
///
/// Two identities anchor it:
///
/// - `computed(ctx, f)` ≡ `computedRippleWhen(ctx, f, (o, n) => o != n)` — the
///   default guard is natural inequality.
/// - the pass-through `slot(f)` ≡ `computedRippleWhen(ctx, f, (_, __) => true)`
///   — always propagate, no suppression.
///
/// Reach for it for a **custom significance policy**: dedup a large value by a
/// version/hash field, epsilon float compare, hysteresis, a monotonic gate, or
/// "propagate every N" when the counter lives in the value.
///
/// The value is **always computed** (the predicate needs `new`); `changed`
/// gates only the downstream cascade, not the computation — it is a *propagate*
/// guard, not a *compute* guard. `changed` MUST be a **pure** function of
/// `(old, new)`: reading value-carried state (a version / counter / sequence
/// field carried inside the value) is fine and stays deterministic; capturing
/// **external mutable state** is not — under laziness it keys off recompute /
/// read frequency and breaks determinism.
Computed<T> computedRippleWhen<T>(
  Context ctx,
  T Function(Compute cx) compute,
  bool Function(T old, T neu) changed,
) =>
    Computed<T>(ctx, compute, changed: changed);

/// A side-effect function that may return a cleanup callback.
///
/// The cleanup (if returned) is invoked before the next rerun and on dispose.
/// The [Compute] passed in is the effect's fortified tracking view: reads
/// through `cx.get(...)` register the effect as a dependent; `cx.untracked`
/// escapes.
typedef EffectRun = void Function()? Function(Compute cx);

/// A side-effect observer that reruns whenever a tracked dependency changes.
///
/// [Effect] is the eager-push primitive for side effects (logging, DOM writes,
/// I/O). It registers dependencies dynamically: any [Source], [Slot], or
/// [Computed] read inside [run] during the current execution becomes a
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
      final cx = _beginCompute();
      try {
        _cleanup = _run(cx);
      } finally {
        _endCompute(cx);
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

/// The **guarded backing slot** of a [Computed] — a lazy, cached,
/// dependency-tracking computation with an equality guard (`#lzcellkernel` v2).
///
/// It behaves like [Slot] but, **while its inline guard is enabled**, suppresses
/// downstream invalidation when a recompute yields a value equal (`==`) to the
/// previous one. This is the memo-equality invariant from the lazily-spec: "a
/// dirty computed that recomputes equal emits no `SlotValue` and no downstream
/// `Invalidate`." On invalidation it eagerly recomputes (to check equality)
/// rather than waiting for a read; if the new value equals the old, the
/// downstream cascade is aborted and dependents stay cached.
///
/// This replaces the former public `Memo` type — the equality guard is folded
/// into [Computed], which owns one of these as its backing. While the owning
/// [Computed] is **eager**, [_guardEnabled] is switched off and this reverts to
/// plain [Slot] behaviour so the scheduled puller is the single point of
/// coalescing (`reactive-graph.md` clause 3); the guard then lives on the puller.
class _GuardedSlot<T> extends Slot<T> {
  _GuardedSlot(super.ctx, super.compute, {super.name, bool Function(T old, T neu)? changed})
      : _changed = changed;

  /// Optional **custom propagate predicate** (`#lzcellkernel`). When non-null,
  /// the inline guard propagates a recompute downstream iff `changed(old, new)`
  /// is `true`, replacing the default natural-equality guard (`old != new`). It
  /// is the negation of "equal/suppress": the engine suppresses exactly when
  /// `!changed(old, new)`. MUST be pure in `(old, new)` — see
  /// [computedRippleWhen].
  final bool Function(T old, T neu)? _changed;

  /// Should a recompute from [old] to [neu] ripple downstream? Custom predicate
  /// when installed; otherwise the natural-equality guard (propagate iff `!=`).
  @pragma('vm:prefer-inline')
  bool _shouldRipple(T old, T neu) =>
      _changed != null ? _changed(old, neu) : old != neu;

  /// Whether the inline equality guard is active. On while the owning [Computed]
  /// is lazy; switched off while it is eager.
  bool _guardEnabled = true;
  bool _guardActive = false;

  @override
  void _invalidateInto(List<_ReactiveNode> stack) {
    if (!_guardEnabled) {
      // Eager owner: behave as a plain [Slot] — mark dirty (via [onInvalidate])
      // and push dependents, letting the puller recompute once at flush.
      super._invalidateInto(stack);
      return;
    }
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
      final cx = _beginCompute();
      T newValue;
      try {
        newValue = _compute(cx);
      } finally {
        _endCompute(cx);
      }
      final gen = ctx._generation;
      if (_cacheGen == gen) {
        if (!_shouldRipple(_cachedValue as T, newValue)) {
          // No meaningful change (per the guard) — suppress the downstream
          // cascade. Dependents stay cached; edges are already re-established
          // by the recompute. Default guard: `old == new`; custom guard:
          // `!changed(old, new)`.
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
    // While guarded, this slot manages its own cache lifecycle inside
    // [_invalidateInto]; the default eviction is intentionally bypassed. While
    // un-guarded (an eager owner), behave as a plain [Slot] and evict here.
    if (!_guardEnabled) _uncache(ctx);
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

  /// Create a [Source] (source cell) owned by this scope — the canonical
  /// spelling (`#lzcellkernel`).
  Source<T> source<T>(T initialValue) => adopt(Source<T>(ctx, initialValue));

  /// Compatibility alias for [source]. Retained (not deprecated) because the
  /// async wrapper's scope adopts through it.
  Source<T> cell<T>(T initialValue) => source<T>(initialValue);

  /// Create a lazily-computed [Slot] owned by this scope.
  Slot<T> slot<T>(T Function(Compute cx) compute, {String? name}) =>
      adopt(Slot<T>(ctx, compute, name: name));

  /// Create a guarded [Computed] owned by this scope.
  Computed<T> computed<T>(T Function(Compute cx) compute) =>
      adopt(Computed<T>(ctx, compute));

  /// Create a guarded [Computed] with a custom propagate predicate, owned by
  /// this scope (`#lzcellkernel`). See top-level [computedRippleWhen].
  Computed<T> computedRippleWhen<T>(
    T Function(Compute cx) compute,
    bool Function(T old, T neu) changed,
  ) =>
      adopt(Computed<T>(ctx, compute, changed: changed));

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

/// Thrown when a stale [Compute] view is used for a tracked read
/// (`#lzcellkernel`).
///
/// A [Compute] is valid **only for the duration of the recompute it was minted
/// for**. `lazily-rs` makes this unrepresentable in the type system — the view
/// is lifetime-bound and `!Send`, so it cannot be stored past its recompute or
/// moved to another thread. Dart has neither lifetimes nor `!Send`, so
/// non-escapability is enforced *dynamically* instead: the view is retired when
/// its recompute ends, and a tracked read through a retired view throws this
/// rather than silently registering an edge against the wrong (or a dead) node.
class StaleComputeError extends StateError {
  StaleComputeError()
      : super('a Compute view was used after its recompute finished — it must '
            'not be captured and read outside the compute/effect it was passed '
            'to (#lzcellkernel)');
}

/// A value that can be read through the tracking surfaces ([Compute] tracked,
/// [Context] untracked). Implemented by [Source], [Computed], and [Slot].
///
/// `_read` performs the **untracked** read (the node's ordinary `value` /
/// `call()`, forming no reader edge); [_readTrackedBy] performs the **tracked**
/// read, wiring the supplied recomputing node as a dependent before returning
/// the value. Which one runs is decided by the surface: [Compute.get] threads
/// its carried node into [_readTrackedBy]; [ComputeOps.get] on [Context] calls
/// [_read] (no edge).
abstract interface class ComputeReadable<T> {
  T _read();
  T _readTrackedBy(_ReactiveNode reader);
}

/// The **compute-time operations subset** of the [Context] API
/// (`#lzcellkernel`) — the mirror of `lazily-rs`'s `ComputeOps` trait.
///
/// Exactly the operations a compute/effect closure may perform: read
/// ([get]) / write ([set]) / construct ([source] / [cell] / [computed] /
/// [computedRippleWhen] / [slot] / [effect]) / [batch]. Revision control,
/// degree introspection, teardown-scope creation, and disposal are deliberately
/// **off** this surface.
///
/// **Implemented by exactly two types**, differing only in read discipline:
/// - [Context] — the owning graph; its [get] is **untracked**.
/// - [Compute] — the per-recompute view; its [get] **tracks** against the
///   recomputing node, which it carries as a value.
abstract interface class ComputeOps {
  /// Read [handle] with this surface's tracking discipline: a [Compute]
  /// registers a dependency edge against the recomputing node; a bare [Context]
  /// registers nothing.
  T get<T>(ComputeReadable<T> handle);

  /// Write a source cell (a write is an argument, never a dependency).
  void set<T>(Source<T> cell, T value);

  /// Create a source cell.
  Source<T> source<T>(T value);

  /// Create a source cell (compatibility spelling of [source]).
  Source<T> cell<T>(T value);

  /// Create a guarded [Computed].
  Computed<T> computed<T>(T Function(Compute cx) compute);

  /// Create a guarded [Computed] with an explicit change predicate.
  Computed<T> computedRippleWhen<T>(
    T Function(Compute cx) compute,
    bool Function(T old, T neu) changed,
  );

  /// Create a pass-through (unguarded) derived [Slot].
  Slot<T> slot<T>(T Function(Compute cx) compute, {String? name});

  /// Register an [Effect].
  Effect effect(EffectRun run);

  /// Run [run] inside a batch (coalesced invalidation).
  void batch(void Function() run);
}

/// The fortified, per-recompute **compute view** (`#lzcellkernel`) — the sole
/// *tracking* surface handed to every compute/effect closure.
///
/// It carries the recomputing node **as a value** ([_node]), not as ambient
/// (thread-local / zone) state. This is the value-threaded dependency-tracking
/// the spec mandates: because the identity is a captured argument, it survives
/// suspension (an `await` inside an async compute reads the right node
/// afterwards) and works where no ambient carrier exists. `lazily-rs` threads a
/// `slot_id`; this threads the node reference.
///
/// > Dart alternative — a suspension-surviving ambient carrier does exist
/// > (`Zone`), and the spec explicitly permits bindings that have one to use it.
/// > The *family* choice is uniform value-threading, so this mirrors
/// > `lazily-rs` and threads the value; `Zone` is noted only as the road not
/// > taken.
///
/// ## Fortification (and its Dart limits)
///
/// - **Sole tracking surface.** A tracked read is [get] on this view; the
///   untracked escape is [untracked] (or reading through the owning [Context]).
///   There is no ambient current-node stack: a bare handle read (`value` /
///   `call()`) forms **no** dependency edge, so every dependency a compute
///   declares is threaded through [get] against the node this view carries.
///   *Dart limit:* Dart cannot make a bare handle read a compile error the way
///   `lazily-rs` does by only implementing `Read` for `Compute`; it simply does
///   not track, so every read that must subscribe MUST go through [get].
/// - **Non-escapable.** The view is retired when its recompute ends; a tracked
///   read through an escaped view throws [StaleComputeError]. *Dart limit:*
///   this is a **runtime** guard — `lazily-rs` forbids the escape at compile
///   time with a lifetime + `!Send`, which Dart has no equivalent of.
/// - **Rebind per recompute.** A fresh view is minted every recompute and the
///   node's upstream edges are detached first, so a conditional read drops the
///   branch not taken — unchanged from the ambient design.
class Compute implements ComputeOps {
  Compute._(this._ctx, this._node, this._epoch);

  final Context _ctx;
  final _ReactiveNode _node;

  /// The stamp this view was minted with (its recompute's ordinal). Retained
  /// for debugging / error context; validity itself is [_valid].
  final int _epoch;

  /// Cleared by [_ReactiveNode._endCompute] when the recompute finishes.
  bool _valid = true;

  void _checkValid() {
    if (!_valid || _node._disposed) throw StaleComputeError();
  }

  /// The owning context — the **untracked** escape surface. Reads through it
  /// register no dependency edge (it is [ComputeOps] with untracked [get]).
  /// Prefer the scoped [untracked] for reads; this getter is for construction
  /// and for handing the context to APIs that need it.
  Context get context => _ctx;

  /// Run [body] with tracking suppressed — the explicit untracked-read escape.
  /// Reads inside [body] form no dependency edge against the recomputing node.
  /// Mirrors `lazily-rs`'s `Compute::untracked() -> &Context`, adapted to a
  /// scoped closure because a Dart getter cannot bound the untracked window.
  R untracked<R>(R Function() body) {
    _checkValid();
    return _ctx.runUntracked(body);
  }

  /// Read [handle], registering a dependency edge against **this recompute's
  /// node** (value-threaded). Throws [StaleComputeError] if this view has been
  /// retired (used outside its recompute).
  @override
  T get<T>(ComputeReadable<T> handle) {
    _checkValid();
    // Value-threaded: the edge is attributed to `_node` — the recomputing node
    // this view carries — not to any ambient current-node stack. An [untracked]
    // window suppresses the edge (mirrors the old `_current == null` path).
    if (_ctx._trackingSuppressed) return handle._read();
    return handle._readTrackedBy(_node);
  }

  /// Write a source cell (untracked — a write is never a dependency).
  @override
  void set<T>(Source<T> cell, T value) {
    _checkValid();
    cell.value = value;
  }

  @override
  Source<T> source<T>(T value) => _ctx.source<T>(value);

  @override
  Source<T> cell<T>(T value) => _ctx.cell<T>(value);

  @override
  Computed<T> computed<T>(T Function(Compute cx) compute) =>
      _ctx.computed<T>(compute);

  @override
  Computed<T> computedRippleWhen<T>(
    T Function(Compute cx) compute,
    bool Function(T old, T neu) changed,
  ) =>
      _ctx.computedRippleWhen<T>(compute, changed);

  @override
  Slot<T> slot<T>(T Function(Compute cx) compute, {String? name}) =>
      _ctx.slot<T>(compute, name: name);

  @override
  Effect effect(EffectRun run) => _ctx.effect(run);

  @override
  void batch(void Function() run) => _ctx.batch(run);

  @override
  String toString() =>
      'Compute(#$_epoch, ${_valid ? 'active' : 'retired'}, $_node)';
}
