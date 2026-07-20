/// Async reactive context (docs/async.md).
///
/// A separate reactive surface for computations whose values are produced by
/// `async`/future-returning functions. It is **not** an overload of the
/// synchronous [Context]; it is a distinct graph with its own handles, because
/// futures introduce in-flight state, cancellation, stale completion, and
/// dependency tracking across suspension points that the synchronous graph
/// does not have.
///
/// This is **compute, not protocol** — only resolved slot values cross IPC/FFI
/// as ordinary cell payloads, exactly like the synchronous graph.
///
/// Implements the full cancellation contract (docs/async.md § Cancellation
/// contract):
/// 1. Waiter cancellation is safe (dropping one future does not cancel a shared
///    in-flight computation while other waiters still need it).
/// 2. Stale completion is discarded, not published (revision tracking).
/// 3. Explicit cancellation (a hard clear, invalidation, or disposal may mark
///    the in-flight revision canceled).
/// 4. Context disposal cancels all in-flight computations.
/// 5. Effect cleanup completes before the next effect body starts.

import 'dart:async';

// `DisposedNodeError` is shared with the synchronous graph on purpose: a caller
// that tears down nodes on both surfaces catches one error type, and the
// read-after-dispose contract is stated once.
import 'core.dart' show DisposedNodeError;

/// The finite-state-machine state of an async slot (docs/async.md § Async slot
/// state machine).
enum AsyncSlotState {
  /// No cached value, no in-flight computation. Entered on creation and after
  /// a hard clear.
  empty,

  /// A handle tracks the in-flight future for the current revision. Concurrent
  /// `getAsync` callers attach as waiters to the same in-flight result instead
  /// of spawning duplicate futures.
  computing,

  /// The cached value is fresh, until dependency invalidation transitions back
  /// to [computing].
  resolved,

  /// The last computation failed; callers receive the error or retry on the
  /// next `getAsync`.
  error,
}

/// Internal sentinel thrown through an in-flight future when the slot revision
/// has advanced (stale) or the slot was invalidated. Caught by the re-resolve
/// loop in [AsyncSlotHandle.getAsync].
class _Superseded implements Exception {
  const _Superseded();
}

/// A node in an [AsyncContext]'s graph (`#lzspecedgeindex`).
///
/// Sealed: [AsyncCellHandle], [AsyncSlotHandle], and [AsyncEffectHandle] are
/// the only implementations. The async mirror of the synchronous `GraphNode`,
/// and the same rationale: [AsyncContext.dependentCount],
/// [AsyncContext.dependencyCount], [AsyncContext.disposeNode], and
/// [AsyncTeardownScope] accept any node kind while exposing **counts, not edge
/// lists** — assertable graph shape with no path to the internals and no
/// storage strategy pinned by the contract.
sealed class AsyncGraphNode {}

/// A mutable input cell on the async graph (the synchronous input layer of
/// [AsyncContext]). Reads inside an async compute/effect register a dependency
/// edge; writes invalidate dependents.
class AsyncCellHandle<T> implements AsyncGraphNode {
  AsyncCellHandle(this._ctx, T initialValue) : _value = initialValue;

  final AsyncContext _ctx;
  T _value;

  /// Whether this cell has been torn down (`#lzspecedgeindex`).
  bool _nodeDisposed = false;

  /// Whether this cell has been disposed. A disposed cell reads as a
  /// [DisposedNodeError].
  bool get isDisposed => _nodeDisposed;

  /// Read the value (synchronous). Registers a dependency when called inside
  /// an async compute/effect.
  ///
  /// Throws [DisposedNodeError] if this cell has been disposed — the async
  /// graph shares one read-after-dispose contract with the synchronous one.
  T get() {
    if (_nodeDisposed) throw DisposedNodeError(this);
    _ctx._track(this);
    return _value;
  }

  /// Set a new value (synchronous). If `newValue != _value`, dependent async
  /// slots/effects are scheduled for rerun.
  void set(T newValue) {
    if (_nodeDisposed) throw DisposedNodeError(this);
    if (newValue != _value) {
      _value = newValue;
      _ctx._invalidateDependents(this);
    }
  }

  /// Read the value without registering a dependency (non-reactive).
  T get peek => _value;

  /// Tear this cell out of the graph. See [AsyncContext.disposeNode].
  void dispose() => _ctx.disposeNode(this);

  @override
  String toString() => 'AsyncCellHandle($_value)';
}

/// Equality predicate for memo guards.
typedef Equals<T> = bool Function(T a, T b);

/// A computed async slot handle.
///
/// Wraps a [Future]-returning computation that recomputes when its
/// dependencies change. Holds the cached value when [state] is
/// [AsyncSlotState.resolved], the in-flight future + revision when
/// [computing], or the error when [error].
class AsyncSlotHandle<T> implements AsyncGraphNode {
  AsyncSlotHandle(this._ctx, this._compute, {Equals<T>? eq}) : _eq = eq;

  /// Whether this node has been torn down (`#lzspecedgeindex`). Declared on the
  /// slot rather than only on the effect subclass so all three async node kinds
  /// share one disposal flag and one read-after-dispose contract.
  bool _nodeDisposed = false;

  /// Whether this slot has been disposed. A disposed slot reads as a
  /// [DisposedNodeError].
  bool get isDisposed => _nodeDisposed;

  final AsyncContext _ctx;
  final Future<T> Function(AsyncComputeContext ctx) _compute;
  final Equals<T>? _eq;

  AsyncSlotState _state = AsyncSlotState.empty;
  int _revision = 0; // bumped on every invalidation
  T? _value;
  Object? _error;
  Completer<T>? _inFlight;
  // dependency node -> did we register in _ctx._dependents? Cleared on rerun.
  final Set<Object> _dependencies = {};

  /// The current state-machine state.
  AsyncSlotState get state => _state;

  /// The current revision (incremented on each invalidation; a completing
  /// future with a stale revision is discarded).
  int get revision => _revision;

  /// The cached value when resolved; `null` otherwise.
  T? get value => _state == AsyncSlotState.resolved ? _value : null;

  /// Synchronous cached read; returns the value if [state] is
  /// [AsyncSlotState.resolved], or `null` otherwise (warm-path fast path).
  T? get() {
    if (_nodeDisposed) throw DisposedNodeError(this);
    _ctx._track(this);
    return _state == AsyncSlotState.resolved ? _value : null;
  }

  /// Await a slot value; uses [get] for resolved slots, otherwise spawns async
  /// compute. Concurrent callers await the same in-flight result instead of
  /// spawning duplicate futures (in-flight deduplication).
  Future<T> getAsync() async {
    if (_nodeDisposed) throw DisposedNodeError(this);
    if (_state == AsyncSlotState.resolved) {
      _ctx._track(this);
      return _value as T;
    }
    return _awaitResolved();
  }

  Future<T> _awaitResolved() async {
    // Re-resolve loop (docs/async.md § get_async re-resolve contract). Each
    // pass re-reads via get() (which may have transitioned to Resolved between
    // the lock and the re-lock) and then attaches to or spawns a computation.
    while (true) {
      if (_nodeDisposed) throw DisposedNodeError(this);
      if (_ctx._disposed) {
        throw StateError('AsyncContext disposed');
      }
      if (_state == AsyncSlotState.resolved) return _value as T;
      if (_state == AsyncSlotState.error) {
        throw _error!;
      }
      final existing = _inFlight;
      if (existing != null) {
        // Attach to the existing in-flight future for this revision.
        try {
          return await existing.future;
        } on _Superseded {
          // The world changed: re-resolve from the current slot state.
          continue;
        }
      }
      // Spawn a fresh computation for this revision.
      _spawnCompute();
      try {
        return await _inFlight!.future;
      } on _Superseded {
        continue;
      }
    }
  }

  void _spawnCompute() {
    final revision = _revision;
    _state = AsyncSlotState.computing;
    final completer = Completer<T>();
    _inFlight = completer;
    // Detach prior dependencies before re-tracking.
    for (final dep in _dependencies) {
      _ctx._dependents[dep]?.remove(this);
    }
    _dependencies.clear();
    final cc = AsyncComputeContext._(this);
    final previous = _ctx._currentAsync;
    _ctx._currentAsync = this;
    Future<T> runner;
    try {
      runner = _compute(cc);
    } catch (e, st) {
      _ctx._currentAsync = previous;
      _onCompleteError(revision, e, st);
      return;
    }
    _ctx._currentAsync = previous;
    runner.then((value) {
      _onCompleteOk(revision, value);
    }).catchError((Object e, StackTrace st) {
      _onCompleteError(revision, e, st);
    });
  }

  void _onCompleteOk(int revision, T value) {
    if (revision != _revision) {
      // Stale completion: discard, do not publish. A new future has already
      // been spawned for the updated revision (or the slot was cleared).
      _failInFlight(const _Superseded());
      return;
    }
    if (_eq != null && _state != AsyncSlotState.empty && _value is T && _eq(_value as T, value)) {
      // Memo equality suppression: keep the cached value, do not cascade.
      _state = AsyncSlotState.resolved;
      _inFlight?.complete(_value as T);
      _inFlight = null;
      return;
    }
    _value = value;
    _error = null;
    _state = AsyncSlotState.resolved;
    _inFlight?.complete(value);
    _inFlight = null;
  }

  void _onCompleteError(int revision, Object e, StackTrace st) {
    if (revision != _revision) {
      _failInFlight(const _Superseded());
      return;
    }
    _error = e;
    _state = AsyncSlotState.error;
    _inFlight?.completeError(e, st);
    _inFlight = null;
  }

  void _failInFlight(Object error) {
    final f = _inFlight;
    _inFlight = null;
    f?.completeError(error);
  }

  /// Invoked by [AsyncContext] when a dependency changed. Advances the
  /// revision, schedules an async rerun, and fails any in-flight future for
  /// the prior revision (stale).
  void _onInvalidate() {
    _revision += 1;
    _state = AsyncSlotState.computing;
    _failInFlight(const _Superseded());
  }

  /// Track that this slot read [dep] during its current computation.
  ///
  /// A disposed dep registers no edge: the read that follows throws
  /// [DisposedNodeError], and leaving an edge pointing at a torn-down node
  /// would resurrect it in the next propagation walk.
  void _trackDep(Object dep) {
    if (AsyncContext._isDisposedNode(dep)) return;
    if (_dependencies.add(dep)) {
      _ctx._dependents.putIfAbsent(dep, () => <Object>{}).add(this);
    }
  }
}

/// The compute context handed to an async callback: exposes [getAsync] and
/// [getCell] that register dependency edges **before** the awaited read.
class AsyncComputeContext {
  AsyncComputeContext._(this._slot);

  final AsyncSlotHandle<dynamic> _slot;

  /// Await [slot]'s value, recording it as a dependency before the awaited
  /// read.
  Future<T> getAsync<T>(AsyncSlotHandle<T> slot) async {
    _slot._trackDep(slot);
    return slot.getAsync();
  }

  /// Read [cell]'s value synchronously, recording it as a dependency.
  T getCell<T>(AsyncCellHandle<T> cell) {
    _slot._trackDep(cell);
    return cell.get();
  }
}

/// The async reactive surface: a distinct graph with its own handles.
class AsyncContext {
  final Map<Object, Set<Object>> _dependents =
      {}; // dependency -> {dependent slots/effects}
  AsyncSlotHandle<dynamic>? _currentAsync;
  bool _disposed = false;
  final Set<_AsyncEffectHandle> _effects = {};

  /// Create a mutable input cell (the synchronous input layer).
  AsyncCellHandle<T> cell<T>(T value) => AsyncCellHandle<T>(this, value);

  /// Read a cell's value (synchronous).
  T getCell<T>(AsyncCellHandle<T> handle) => handle.get();

  /// Update a cell and invalidate dependents (synchronous).
  void setCell<T>(AsyncCellHandle<T> handle, T value) => handle.set(value);

  /// Create an async computed slot.
  AsyncSlotHandle<T> computedAsync<T>(
          Future<T> Function(AsyncComputeContext ctx) compute) =>
      AsyncSlotHandle<T>(this, compute);

  /// Like [computedAsync] with an equality memo guard. A recompute that yields
  /// an equal value (per [eq]) suppresses the dependency cascade.
  AsyncSlotHandle<T> memoAsync<T>(
          Future<T> Function(AsyncComputeContext ctx) compute, Equals<T> eq) =>
      AsyncSlotHandle<T>(this, compute, eq: eq);

  /// Synchronous batch boundary. Cell updates queue invalidation roots; at
  /// batch exit, queued roots trigger propagation. Async slots are marked
  /// stale (their next `getAsync` respawns) but do not execute inside the
  /// batch callback — async reruns fire after the batch returns.
  void batch(void Function() run) {
    final wasBatching = _batching;
    _batching = true;
    try {
      run();
    } finally {
      _batching = wasBatching;
      if (!_batching) {
        // Propagate queued invalidations now (outermost batch exit).
        final queue = List<Object>.of(_batchQueue);
        _batchQueue.clear();
        for (final dep in queue) {
          _invalidateDependents(dep);
        }
      }
    }
  }

  bool _batching = false;
  final Set<Object> _batchQueue = {};

  void _track(Object dependency) {
    final current = _currentAsync;
    if (current == null) return;
    if (_isDisposedNode(dependency)) return;
    if (current._dependencies.add(dependency)) {
      _dependents.putIfAbsent(dependency, () => <Object>{}).add(current);
    }
  }

  /// Whether [node] is a torn-down graph node. Static because the walk and the
  /// tracking path both need it over a heterogeneous `Object` edge set.
  static bool _isDisposedNode(Object node) {
    if (node is AsyncSlotHandle) return node._nodeDisposed;
    if (node is AsyncCellHandle) return node._nodeDisposed;
    return false;
  }

  void _invalidateDependents(Object dependency) {
    if (_disposed) return;
    if (_batching) {
      _batchQueue.add(dependency);
      return;
    }
    // Iterative invalidation frontier walk, mirroring `lazily-rs`
    // `invalidate_frontier_async`: a slot that depends on a slot must itself be
    // invalidated, so the walk covers the whole transitive dependent cone
    // instead of stopping one level below the written cell.
    //
    // Termination: each visit *removes* the node's dependent set from
    // `_dependents`, consuming those edges. Revisiting a node yields `null` and
    // the branch dies, so every edge is traversed at most once — diamonds and
    // dependency cycles terminate without an explicit visited set. Edges
    // re-register on the next recompute via `_trackDep`.
    final stack = <Object>[dependency];
    // Effects are scheduled after the walk so that a rerun's freshly
    // re-registered edges are not consumed by the still-running walk.
    final effects = <_AsyncEffectHandle>[];
    while (stack.isNotEmpty) {
      final current = stack.removeLast();
      final affected = _dependents.remove(current);
      if (affected == null) continue;
      for (final dep in affected) {
        // Effect check first: _AsyncEffectHandle extends AsyncSlotHandle<void>,
        // so the slot branch would shadow it. Effects are frontier leaves —
        // nothing can depend on an effect — so the walk does not continue
        // through one.
        if (dep is _AsyncEffectHandle) {
          effects.add(dep);
        } else if (dep is AsyncSlotHandle) {
          dep._onInvalidate();
          stack.add(dep);
        }
      }
    }
    for (final effect in effects) {
      effect._scheduleRerun();
    }
  }

  // -- Disposal and degree introspection (`#lzspecedgeindex`) ---------------

  /// Mark the cone left behind by a disposal dirty, without scheduling
  /// anything.
  ///
  /// The same frontier walk as [_invalidateDependents], seeded from the
  /// disposed node's dependents rather than from a written dependency, with one
  /// deliberate difference: **effects reached here are not rerun**. Disposal is
  /// not a publish; running an effect during teardown re-enters a compute that
  /// reads the node being torn down, so `dispose` itself would throw and
  /// teardown would stop being idempotent. The contract is "errors on the next
  /// recompute", and that recompute is driven by a real write.
  ///
  /// Marking is not optional. Detaching edges without it leaves a dependent
  /// that cached a value computed *through* the disposed node serving that
  /// value forever — the defect fixed in `lazily-rs` 5db90d2 and `lazily-js`
  /// 4d20670.
  void _invalidateDisposedDependents(Iterable<Object> roots) {
    final stack = <Object>[];
    for (final root in roots) {
      // Effects are frontier leaves and are marked-not-run; nothing can depend
      // on one, so the walk does not continue through it either.
      if (root is _AsyncEffectHandle) continue;
      if (root is AsyncSlotHandle && !root._nodeDisposed) {
        root._onInvalidate();
        stack.add(root);
      }
    }
    while (stack.isNotEmpty) {
      final current = stack.removeLast();
      // Removing the edge set is the visited mark, exactly as in
      // `_invalidateDependents`: revisiting yields null and the branch dies, so
      // diamonds and cycles terminate without an explicit visited set.
      final affected = _dependents.remove(current);
      if (affected == null) continue;
      for (final dep in affected) {
        if (dep is _AsyncEffectHandle) continue;
        if (dep is AsyncSlotHandle && !dep._nodeDisposed) {
          dep._onInvalidate();
          stack.add(dep);
        }
      }
    }
  }

  /// Detach [node] from the graph in both directions and dirty what survives.
  ///
  /// [dependencies] is the node's own upstream set (empty for a cell, which is
  /// a pure source). Detaching only one direction leaves a dangling half-edge:
  /// upstream, the source's dependent set grows without bound under
  /// subscribe/unsubscribe churn; downstream, a reader keeps pointing at a node
  /// that is gone.
  void _detachAndDirty(Object node, Set<Object> dependencies) {
    for (final dep in dependencies) {
      _dependents[dep]?.remove(node);
    }
    dependencies.clear();
    final dependents = _dependents.remove(node);
    if (dependents == null || dependents.isEmpty) return;
    for (final dependent in dependents) {
      if (dependent is AsyncSlotHandle) dependent._dependencies.remove(node);
    }
    _invalidateDisposedDependents(dependents);
  }

  /// Tear down [node], dispatching on its own kind.
  ///
  /// Idempotent: disposing an already-disposed node is a no-op, so teardown
  /// paths compose. Effects additionally await their pending cleanup, which is
  /// why this returns a [Future]; for a slot or a cell the returned future is
  /// already complete.
  ///
  /// Without this a node is permanent. The graph holds a *strong* reverse edge
  /// to every dependent, so dropping the last user-held reference reclaims
  /// nothing and a long-lived source retains every node that ever read it.
  Future<void> disposeNode(AsyncGraphNode node) async {
    switch (node) {
      case _AsyncEffectHandle():
        await node.disposeAsync();
      case AsyncEffectHandle():
        await node.disposeAsync();
      case AsyncSlotHandle():
        if (node._nodeDisposed) return;
        node._nodeDisposed = true;
        _detachAndDirty(node, node._dependencies);
        node._failInFlight(const _Superseded());
      case AsyncCellHandle():
        if (node._nodeDisposed) return;
        node._nodeDisposed = true;
        // A cell is a pure source: no upstream set to detach.
        _detachAndDirty(node, <Object>{});
    }
  }

  /// Tear down a derived async slot. See [disposeNode].
  Future<void> disposeSlot(AsyncSlotHandle<Object?> slot) => disposeNode(slot);

  /// Tear down an async source cell. See [disposeNode].
  Future<void> disposeCell(AsyncCellHandle<Object?> cell) => disposeNode(cell);

  /// Tear down an async effect. See [disposeNode].
  Future<void> disposeEffect(AsyncEffectHandle effect) => disposeNode(effect);

  /// How many nodes currently depend on [node] — the size of its reverse edge
  /// set.
  ///
  /// The observable the disposal contract is written against: a
  /// subscribe/unsubscribe cycle that disposes what it creates must leave this
  /// at its starting value no matter how many cycles run. Returns 0 for a
  /// disposed node.
  int dependentCount(AsyncGraphNode node) {
    if (_isDisposedNode(node)) return 0;
    return _dependents[node]?.length ?? 0;
  }

  /// How many nodes [node] currently depends on — the size of its forward edge
  /// set. Returns 0 for a disposed node and for cells, which are pure sources.
  int dependencyCount(AsyncGraphNode node) {
    if (_isDisposedNode(node)) return 0;
    if (node is AsyncSlotHandle) return node._dependencies.length;
    return 0;
  }

  /// Whether [node] has been torn down.
  bool isNodeDisposed(AsyncGraphNode node) => _isDisposedNode(node);

  /// Whether [effect] is still registered.
  bool isEffectActive(AsyncEffectHandle effect) =>
      effect is _AsyncEffectHandle && !effect._nodeDisposed;

  /// Open a teardown scope over this context. See [AsyncTeardownScope].
  AsyncTeardownScope scope() => AsyncTeardownScope._(this);

  /// Run [body] with a teardown scope that is ended (and awaited) when [body]
  /// completes, even on a throw. The async analogue of the synchronous
  /// `Context.withScope`.
  Future<R> withScope<R>(
      FutureOr<R> Function(AsyncTeardownScope scope) body) async {
    final scope = this.scope();
    try {
      return await body(scope);
    } finally {
      await scope.end();
    }
  }

  /// Create an async effect with an async cleanup. The body receives a compute
  /// context; reruns are serialized per effect (a rerun does not start until
  /// the previous cleanup future completes), and disposal awaits the current
  /// cleanup before removing the node.
  ///
  /// The body returns an optional cleanup callback (a sync or async function
  /// to run before the next body starts).
  AsyncEffectHandle effectAsync(
      Future<dynamic> Function(AsyncComputeContext ctx) body) {
    final handle = _AsyncEffectHandle(this, body);
    _effects.add(handle);
    handle._scheduleRerun();
    return handle;
  }

  /// Dispose the context: cancel all in-flight computations. Awaits completion
  /// of all active cleanup futures before returning. Subsequent cell writes are
  /// no-ops.
  Future<void> disposeAsync() async {
    _disposed = true;
    final pending = <Future<void>>[];
    for (final effect in List<_AsyncEffectHandle>.of(_effects)) {
      pending.add(effect.disposeAsync());
    }
    await Future.wait(pending);
    _dependents.clear();
    _effects.clear();
  }
}

/// Handle for an async effect returned by [AsyncContext.effectAsync].
abstract class AsyncEffectHandle implements AsyncGraphNode {
  /// Dispose this effect and await its cleanup future.
  Future<void> disposeAsync();
}

class _AsyncEffectHandle extends AsyncSlotHandle<void>
    implements AsyncEffectHandle {
  _AsyncEffectHandle(AsyncContext ctx, this._body) : super(ctx, (_) async {});

  final Future<dynamic> Function(AsyncComputeContext ctx) _body;
  Future<void> Function()? _cleanup;
  bool _rerunScheduled = false;
  bool _running = false;

  void _scheduleRerun() {
    if (_nodeDisposed) return;
    if (_running) {
      _rerunScheduled = true;
      return;
    }
    _run();
  }

  Future<void> _run() async {
    if (_running) {
      _rerunScheduled = true;
      return;
    }
    _running = true;
    while (true) {
      if (_nodeDisposed) break;
      // Cleanup before next body: the previous run's cleanup completes before
      // the next body starts.
      final cleanup = _cleanup;
      _cleanup = null;
      if (cleanup != null) {
        try {
          await cleanup();
        } catch (_) {
          // Cleanup errors are best-effort.
        }
      }
      if (_nodeDisposed) break;
      // Detach prior dependencies before re-tracking, mirroring
      // `_spawnCompute`. Invalidation consumes the `_ctx._dependents` edge
      // sets, so without clearing `_dependencies` here `_trackDep` would treat
      // each dependency as already registered and the effect would rerun
      // exactly once, then go deaf to every later write.
      for (final dep in _dependencies) {
        _ctx._dependents[dep]?.remove(this);
      }
      _dependencies.clear();
      // Run the body inside a tracking context. Dependencies register through
      // _ctx._currentAsync so source invalidation schedules a rerun.
      final previous = _ctx._currentAsync;
      _ctx._currentAsync = this;
      try {
        final cc = AsyncComputeContext._(this);
        final cleanupResult = await _body(cc);
        if (cleanupResult is Future<void> Function()) {
          _cleanup = cleanupResult;
        } else if (cleanupResult is void Function()) {
          _cleanup = () async => cleanupResult();
        }
      } catch (_) {
        // Body errors are swallowed (effects never publish values).
      } finally {
        _ctx._currentAsync = previous;
      }
      _running = false;
      if (!_rerunScheduled || _nodeDisposed) break;
      _rerunScheduled = false;
      _running = true;
    }
  }

  @override
  Future<void> disposeAsync() async {
    if (_nodeDisposed) return;
    _nodeDisposed = true;
    _ctx._effects.remove(this);
    // Detach both edge directions BEFORE running the cleanup. Without this the
    // effect stayed in `_ctx._dependents[dep]` for every dependency it had
    // read, so a subscribe/unsubscribe cycle left the source's dependent set
    // growing without bound even though the live subscriber count was constant
    // — the exact leak `churn_returns_to_baseline` pins. An effect is a
    // frontier leaf, so there is no surviving cone to dirty.
    _ctx._detachAndDirty(this, _dependencies);
    final cleanup = _cleanup;
    _cleanup = null;
    if (cleanup != null) {
      try {
        await cleanup();
      } catch (_) {
        // Best-effort.
      }
    }
  }
}

/// A teardown scope over an [AsyncContext]: nodes created through it are
/// disposed when it ends (`#lzspecedgeindex`).
///
/// The async counterpart of the synchronous `TeardownScope`, and the same shape
/// for the same reason: Dart has no destructor, so the end of a scope has to be
/// a statement. [AsyncContext.withScope] brackets it around a callback;
/// [end] ends it explicitly for the case a callback cannot express — a scope
/// whose lifetime is a connection or a subscription, opened in one callback and
/// ended in another.
///
/// [end] is a [Future] because effect teardown awaits the effect's pending
/// cleanup; that is the async graph's existing disposal contract (docs/async.md
/// § Cancellation contract, rule 5) and a scope must not weaken it.
class AsyncTeardownScope {
  AsyncTeardownScope._(this.ctx);

  /// The context this scope belongs to.
  final AsyncContext ctx;

  final List<AsyncGraphNode> _owned = [];
  bool _ended = false;

  /// How many nodes this scope currently owns.
  int get length => _owned.length;

  /// Whether this scope owns nothing.
  bool get isEmpty => _owned.isEmpty;

  /// Whether this scope owns at least one node.
  bool get isNotEmpty => _owned.isNotEmpty;

  /// Whether [end] has already run.
  bool get isEnded => _ended;

  /// Take ownership of an existing [node]. Adopting into an ended scope is a
  /// no-op rather than an immediate disposal — the scope's moment has passed.
  T adopt<T extends AsyncGraphNode>(T node) {
    if (!_ended) _owned.add(node);
    return node;
  }

  /// Create a source cell owned by this scope.
  AsyncCellHandle<T> cell<T>(T value) => adopt(ctx.cell<T>(value));

  /// Create a computed async slot owned by this scope.
  AsyncSlotHandle<T> computedAsync<T>(
          Future<T> Function(AsyncComputeContext ctx) compute) =>
      adopt(ctx.computedAsync<T>(compute));

  /// Create a memoized async slot owned by this scope.
  AsyncSlotHandle<T> memoAsync<T>(
          Future<T> Function(AsyncComputeContext ctx) compute, Equals<T> eq) =>
      adopt(ctx.memoAsync<T>(compute, eq));

  /// Register an async effect owned by this scope.
  AsyncEffectHandle effectAsync(
          Future<dynamic> Function(AsyncComputeContext ctx) body) =>
      adopt(ctx.effectAsync(body));

  /// Cancel this scope's teardown: ending it afterwards disposes nothing, and
  /// its nodes revert to plain context ownership. The nodes themselves are
  /// untouched — same values, same edges in both directions, still
  /// individually disposable.
  void disarm() => _owned.clear();

  /// Dispose every node this scope owns, in reverse creation order —
  /// dependents before what they read, so the scope never transiently dangles
  /// inside itself. Idempotent.
  Future<void> end() async {
    if (_ended) return;
    _ended = true;
    for (var i = _owned.length - 1; i >= 0; i--) {
      await ctx.disposeNode(_owned[i]);
    }
    _owned.clear();
  }

  @override
  String toString() =>
      'AsyncTeardownScope(${_ended ? 'ended' : '${_owned.length} owned'})';
}
