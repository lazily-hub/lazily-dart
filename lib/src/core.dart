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

/// A reactive scope: an identity-keyed value cache plus the computation stack.
///
/// All [Slot]s, [Cell]s, and [Signal]s that should react to each other must be
/// created with (and thus share) the same [Context]. The cache keys on object
/// identity, so each reactive instance is cached independently.
class Context {
  final Map<Object, Object?> _cache = Map.identity();
  final List<_ReactiveNode> _stack = [];

  /// The number of cached values.
  int get size => _cache.length;

  /// Whether [node] currently has a cached value.
  bool contains(_ReactiveNode node) => _cache.containsKey(node);

  /// The cached value for [node] (untyped), or `null` if absent.
  Object? read(_ReactiveNode node) => _cache[node];

  /// Cache a value for [node].
  void write(_ReactiveNode node, Object? value) => _cache[node] = value;

  /// Remove the cached value for [node].
  void evict(_ReactiveNode node) => _cache.remove(node);

  /// Drop every cached value. Dependency edges are re-established lazily as
  /// slots are read again.
  void clear() => _cache.clear();

  /// The slot currently computing, if any.
  _ReactiveNode? get _current => _stack.isEmpty ? null : _stack.last;
}

/// Base class for nodes that participate in dependency tracking.
///
/// Edges are bidirectional and refreshed on every recompute:
/// - [_dependents] — nodes that read this one (downstream).
/// - [_dependencies] — nodes this one read during its last computation
///   (upstream). When this node recomputes, it first detaches from its prior
///   upstream edges so stale edges never accumulate.
abstract class _ReactiveNode {
  final Set<_ReactiveNode> _dependents = {};
  final Set<_ReactiveNode> _dependencies = {};

  /// Hook called when this node is invalidated, before the downstream cascade.
  void onInvalidate() {}

  /// Register the currently-computing slot (if any) as a dependent of this
  /// node, and record the reverse edge on the computing slot. Called whenever
  /// this node is read.
  void _track(Context ctx) {
    final parent = ctx._current;
    if (parent != null) {
      _dependents.add(parent);
      parent._dependencies.add(this);
    }
  }

  /// Detach this node from all of its current upstream dependencies. Called
  /// before a recompute so dependency edges reflect only the most recent
  /// computation.
  void _detachUpstream() {
    for (final dep in _dependencies) {
      dep._dependents.remove(this);
    }
    _dependencies.clear();
  }

  /// Invalidate this node: run its [onInvalidate] hook, snapshot its
  /// dependents, clear them, and cascade.
  void _invalidate() {
    onInvalidate();
    if (_dependents.isEmpty) return;
    final snapshot = _dependents.toList();
    _dependents.clear();
    for (final dependent in snapshot) {
      dependent._invalidate();
    }
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
  final Context ctx;
  final T Function(Context ctx) _compute;

  /// Optional human-readable name for debugging.
  final String? name;

  /// Read (and cache if needed) the value. The object is callable: `slot()`.
  T call() {
    _track(ctx);
    if (ctx.contains(this)) {
      return ctx.read(this) as T;
    }
    _detachUpstream();
    ctx._stack.add(this);
    try {
      final value = _compute(ctx);
      ctx.write(this, value);
      return value;
    } finally {
      ctx._stack.removeLast();
    }
  }

  /// The cached value without recomputing, or `null` if not currently cached.
  T? get peek => ctx.contains(this) ? ctx.read(this) as T : null;

  @override
  void onInvalidate() => ctx.evict(this);

  @override
  String toString() => name != null ? 'Slot(${name!})' : 'Slot';
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
  final List<void Function()> _observers = [];

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
      _invalidate();
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
    void wrapper() => observer(_value);
    _observers.add(wrapper);
    return () => _observers.remove(wrapper);
  }

  /// Force-invalidate this cell's dependents without changing the value.
  ///
  /// Used by collection layers when an entry is removed: the orphaned cell
  /// stops driving its dependents, mirroring `CellHandle::clear_dependents` in
  /// lazily-rs. The cell's own value is untouched; only the downstream cascade
  /// fires.
  void invalidate() => _invalidate();

  void _notifyObservers() {
    for (final observer in _observers.toList()) {
      observer();
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
    ctx.evict(this);
    signal?._eagerRecompute();
  }
}
