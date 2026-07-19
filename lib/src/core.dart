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
  /// (e.g. an eager [Signal] recompute fired from within `_SignalSlot.onInvalidate`)
  /// fall back to a fresh local stack so the outer iteration is not corrupted.
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

  void _scheduleEffect(Effect effect) {
    if (_scheduledEffects.add(effect)) {
      _pendingEffects.add(effect);
    }
  }

  void _flushEffects() {
    if (_flushingEffects) return;
    _flushingEffects = true;
    try {
      // FIFO with a head pointer instead of O(n) `removeAt(0)` (mirrors
      // lazily-rs `VecDeque::pop_front`). `_rerun` may append more effects; the
      // loop re-reads `length` each iteration so they are processed in order.
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
abstract class _ReactiveNode {
  List<_ReactiveNode>? _dependents;
  List<_ReactiveNode>? _dependencies;

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
  T call() {
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
  String toString() => name != null ? 'Slot(${name!})' : 'Slot';
}

/// One registered [Cell.subscribe] observer (`#lzdartobservercow`).
///
/// The disposer returned by [Cell.subscribe] captures this object rather than a
/// bare index, which is what makes both removal O(1) *and* compaction safe:
/// [Cell._compactSlots] rewrites [index] in place, so every outstanding
/// disposer stays valid. A null [callback] marks a disposed (tombstoned) slot.
class _ObserverSlot<T> {
  _ObserverSlot(this.callback, this.index);

  void Function(T value)? callback;
  int index;
}

/// A mutable source value that invalidates dependents when it changes.
///
/// Reading [value] inside a [Slot] / [Signal] computation registers a
/// dependency. Writing [value] triggers a cascade only when the new value is
/// not equal (`!=`) to the old one — the `PartialEq` guard.
///
/// [subscribe] registers a persistent observer that is NOT cleared on
/// invalidation (unlike internal dependency edges). This is the hook for
/// Flutter `ValueNotifier` bridges, `setState` wrappers, and side effects.
class Cell<T> extends _ReactiveNode {
  Cell(this.ctx, T initialValue) : _value = initialValue;

  /// The context this cell belongs to.
  final Context ctx;
  T _value;

  // Observer storage (`#lzdartobservercow`). Slots are appended and tombstoned
  // in place; a cached snapshot is rebuilt only when the live set actually
  // changed since the last notification.
  //
  // This replaced a copy-on-write immutable list, which bought an
  // allocation-free notify at the price of an O(W) copy on *every*
  // subscribe/unsubscribe — O(W^2) to build or tear down W observers.
  // Measured churn cost at W=16384 was 46855 ns/op, a 163.8x wide/narrow ratio;
  // this shape reports 41.7 ns/op and 1.1x. Notify stays allocation-free in the
  // steady state because [_snapshotDirty] is only set when the set changes, so
  // a stable subscriber set reuses [_snapshot] forever.
  //
  // Reentrancy is preserved by the same argument copy-on-write used: a rebuild
  // allocates a *fresh* list and [_notifyObservers] holds it in a local, so a
  // subscribe during notification cannot extend the in-flight iteration. The
  // empty cases share singleton `const []`.
  //
  // The snapshot holds the *slots*, not the bare callbacks, so an unsubscribe
  // during notification takes effect immediately: the disposer tombstones the
  // slot (`callback = null`) and [_notifyObservers] re-checks liveness before
  // each call, skipping an entry the pass has not yet reached. Observers the
  // loop already visited are unaffected — disposal is not retroactive
  // (`#lzdartobservercow`, lazily-spec docs/reactive-graph.md).
  List<_ObserverSlot<T>?> _slots = const [];
  int _liveObservers = 0;
  List<_ObserverSlot<T>?> _snapshot = const [];
  bool _snapshotDirty = false;

  /// The current value. Reading inside a computation subscribes the reader.
  T get value {
    _track(ctx);
    return _value;
  }

  /// Set a new value. If `newValue != _value`, dependents are invalidated.
  set value(T newValue) {
    if (newValue != _value) {
      _value = newValue;
      _notifyObservers();
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

  /// Register a persistent observer fired with the new value on each change.
  /// Returns a disposer; call it to stop observing. Observers are not cleared
  /// on invalidation.
  void Function() subscribe(void Function(T value) observer) {
    final slots = _slots.isEmpty ? (_slots = <_ObserverSlot<T>?>[]) : _slots;
    final slot = _ObserverSlot<T>(observer, slots.length);
    slots.add(slot);
    _liveObservers++;
    _snapshotDirty = true;
    return () {
      // The disposer holds its own slot, so removal is O(1) — no `indexOf`
      // scan. Idempotent: a disposed slot has a null callback.
      if (slot.callback == null) return;
      slot.callback = null;
      _slots[slot.index] = null;
      _liveObservers--;
      _snapshotDirty = true;
      if (_liveObservers == 0) {
        // Full teardown — the common churn shape. Drop the backing store so a
        // repeatedly rebuilt observer set cannot accumulate tombstones.
        _slots = const [];
      } else if (_slots.length >= _compactThreshold &&
          _liveObservers * 2 <= _slots.length) {
        _compactSlots();
      }
    };
  }

  /// Tombstone density at which [_compactSlots] runs. Below this the scan is
  /// cheaper than the compaction.
  static const int _compactThreshold = 32;

  /// Drop tombstones, rewriting each surviving slot's [_ObserverSlot.index].
  ///
  /// Outstanding disposers hold the slot *object*, not a bare integer, so
  /// rewriting the index keeps every live disposer valid across compaction.
  /// This is what bounds memory under interleaved subscribe/unsubscribe that
  /// never reaches zero live observers.
  void _compactSlots() {
    final slots = _slots;
    var write = 0;
    for (var read = 0; read < slots.length; read++) {
      final slot = slots[read];
      if (slot == null) continue;
      slot.index = write;
      slots[write++] = slot;
    }
    slots.length = write;
  }

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

  void _notifyObservers() {
    if (_liveObservers == 0) return;
    if (_snapshotDirty) {
      // Rebuild into a *fresh* list — never mutate the old one, which an
      // enclosing notification may still be iterating (`#lzdartobservercow`).
      final rebuilt = List<_ObserverSlot<T>?>.filled(_liveObservers, null);
      var write = 0;
      final slots = _slots;
      for (var i = 0; i < slots.length; i++) {
        final slot = slots[i];
        if (slot?.callback != null) rebuilt[write++] = slot;
      }
      _snapshot = rebuilt;
      _snapshotDirty = false;
    }
    // Held in a local so a reentrant subscribe (which only marks the snapshot
    // dirty) leaves this iteration bounded by the pre-callback set. An
    // unsubscribe, by contrast, must take effect within this pass, so each
    // entry's liveness is re-read immediately before the call: a slot
    // tombstoned by an earlier callback in this same pass is skipped.
    // [_compactSlots] rewrites `_slots` but never this list, and it mutates
    // only slot indices, so a concurrent compaction cannot perturb the pass.
    final observers = _snapshot;
    for (var i = 0; i < observers.length; i++) {
      final callback = observers[i]?.callback;
      if (callback != null) callback(_value);
    }
  }

  @override
  void onInvalidate() {
    // Cells hold their value directly; nothing to evict.
  }

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
    signal?._eagerRecompute();
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
  bool _active = true;
  bool _running = false;

  /// Remove the eager observer. Invokes the last cleanup, then unsubscribes
  /// from all dependencies. Idempotent.
  void dispose() {
    if (!_active) return;
    _active = false;
    // Do NOT remove from `_pendingEffects` by value — that would shift entries
    // and corrupt the FIFO head pointer. A queued-but-disposed effect is a
    // no-op when popped (`_rerun` guards on `_active`), and `_detachUpstream`
    // below ensures its `onInvalidate` never fires again.
    if (Context.naivePendingScan) {
      // Naive form under audit, mirroring lazily-kt `disposeEffect`'s
      // `ArrayDeque.indexOf`. Result discarded.
      ctx._naiveScanSink += ctx._pendingEffects.indexOf(this);
    }
    ctx._scheduledEffects.remove(this);
    _detachUpstream();
    final c = _cleanup;
    _cleanup = null;
    if (c != null) c();
  }

  /// Whether the effect is still active (not disposed).
  bool get isActive => _active;

  void _rerun() {
    if (!_active || _running) return;
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
  String toString() => 'Effect(${_active ? 'active' : 'disposed'})';
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
///   final dispose = area.subscribe... // (use an Effect to observe)
class Memo<T> extends Slot<T> {
  Memo(super.ctx, super.compute, {super.name});

  bool _guardActive = false;

  @override
  void _invalidateInto(List<_ReactiveNode> stack) {
    if (_guardActive) return;
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
