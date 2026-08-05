/// Thread-safe keyed reactive map ([ThreadSafeReactiveMap]) — the
/// run-to-completion flavor of [ReactiveMap] (`#reactivemap`, thread-safe).
///
/// Spec:   `lazily-spec/cell-model.md` § Keyed cell collections.
/// Formal: `lazily-formal/LazilyFormal/Materialization.lean`
///   (`materialize_present_comm` / `materialize_observe_comm` — the confluence
///    pair; `materialize_present_monotone`; `cell_entries_materialized_in_every_mode`;
///    `slot_entries_deferred_under_lazy`; `eager_lazy_observationally_equivalent`).
/// Rust reference: `lazily-rs/src/thread_safe_reactive_family.rs`
///   (`ThreadSafeReactiveMap` / `ThreadSafeSourceMap` / `ThreadSafeComputedMap`).
///
/// Where [ReactiveMap] (`collections.dart`) is a keyed reactive map over the
/// (unsynchronized) reactive graph, this flavor guards its present-set state —
/// the materialized value cache + first-materialization order — behind a
/// reentrant run-to-completion guard, and caches canonical values directly (a
/// pure factory produces each) rather than routing through a per-node reactive
/// [Context]. Like the Zig/Rust flavors it carries its own guard, so it needs
/// no separate thread-safe context type.
///
/// DART RUNTIME PREMISE. See `thread_safe.dart`: a synchronous isolate runs to
/// completion and never yields, so the "lock" degrades to a reentrant depth
/// guard exactly as JS degrades its `Atomics` mutex without `SharedArrayBuffer`.
/// The guard is retained for structural parity and to frame the present-set
/// mutations that Go serializes with a `sync.Mutex`. Dart is single-isolate, so
/// this flavor is a value-cache model — there are no distinct thread-safe handle
/// types, so `H` is elided; the two specializations differ only by entry kind
/// and the cell-only [ThreadSafeSourceMap.set] / slot-only
/// [ThreadSafeComputedMap.materializeAll] surface.
///
/// It obeys the same laws as the single-threaded map:
///   - **Eager/lazy contract**: eager pre-mints every key
///     ([ThreadSafeComputedMap.materializeAll]); lazy defers each derived slot to
///     first read ([getOrInsertWith]). Input cells are always materialized
///     (`cell_entries_materialized_in_every_mode` / `slot_entries_deferred_under_lazy`).
///   - **Observational transparency**: [observe] returns an identical value
///     under either strategy (`eager_lazy_observationally_equivalent`).
///   - **Present-set monotonicity**: the materialized set only grows (deferral,
///     never de-allocation) (`materialize_present_monotone`).
///
/// plus **materialization confluence**: the present set and every observed value
/// are independent of the order in which keys are materialized
/// (`materialize_present_comm` / `materialize_observe_comm`).
library;

import 'collections.dart';
import 'core.dart';
import 'keyed_order.dart';

/// The run-to-completion keyed reactive map (`#reactivemap`): keys `K` map to
/// per-entry cached values, allocated on access, with every present-set mutation
/// framed by a reentrant guard.
///
/// The two specializations are [ThreadSafeSourceMap] (input cells, adds [set]) and
/// [ThreadSafeComputedMap] (derived slots, adds [ThreadSafeComputedMap.materializeAll]).
/// The shared surface — [getOrInsertWith] / [observe] / membership / present-set
/// — lives here.
abstract class ThreadSafeReactiveMap<K, V> {
  ThreadSafeReactiveMap(this._ctx)
      : _membership = Source<int>(_ctx, 0),
        _orderSignal = Source<int>(_ctx, 0);

  final Context _ctx;

  /// Reentrancy depth of the run-to-completion guard framing present-set
  /// mutations (Dart isolates need no OS lock; see the library doc).
  int _depth = 0;

  /// Current reentrancy depth (`> 0` while inside a guarded section).
  int get depth => _depth;

  /// Present set + key order + the move algebra, shared with the other two
  /// flavors. Graph-agnostic; the reactivity below is this flavor's own.
  ///
  /// Entries are real [Source] nodes on the owning [Context]. Before the
  /// Core-surface work this map stored plain values in a `Map<K, V>` and its
  /// `_ctx` was annotated `// ignore: unused_field` — dead. A "thread-safe map"
  /// with no reactive nodes is a cache wearing the reactive family's name.
  final KeyedOrder<K, Source<V>> _keyed = KeyedOrder<K, Source<V>>();

  /// Reactive *set-membership* signal, minted on THIS flavor's graph. A shared
  /// graph-agnostic core cannot supply reactivity.
  final Source<int> _membership;

  /// Reactive *order* signal: bumped on add/remove **and on move/reorder**.
  final Source<int> _orderSignal;

  int _membershipVersion = 0;
  int _orderVersion = 0;

  /// This map's entry kind ([EntryKind.source] for a [ThreadSafeSourceMap],
  /// [EntryKind.computed] for a [ThreadSafeComputedMap]).
  EntryKind get entryKind;

  /// Run [fn] under the reentrant guard.
  T _guarded<T>(T Function() fn) {
    _depth++;
    try {
      return fn();
    } finally {
      _depth--;
    }
  }

  void _bumpOrder() {
    _orderVersion += 1;
    _orderSignal.value = _orderVersion;
  }

  void _bumpMembership() {
    _membershipVersion += 1;
    _membership.value = _membershipVersion;
    _bumpOrder();
  }

  bool _applyMove(MapMove outcome) {
    if (!outcome.applied) return false;
    if (outcome.changed) _bumpOrder();
    return true;
  }

  /// Allocate [key]'s node on first access via [factory] and cache the handle,
  /// recording order. A warm key keeps its existing node (cell-identity).
  Source<V> _mintHandle(K key, V Function(K key) factory) {
    final warm = _keyed.get(key);
    if (warm != null) return warm;
    final minted = Source<V>(_ctx, factory(key));
    final (stored, mutation) = _keyed.insert(key, minted);
    if (mutation.changed) _bumpMembership();
    return stored;
  }

  /// Get [key]'s value, minting the entry via [factory] on first access (the
  /// lazy pull). A warm key returns its current value without re-running
  /// [factory]. Pass [cx] to value-thread the per-entry read.
  V getOrInsertWith(K key, V Function(K key) factory, [Compute? cx]) =>
      _guarded(() {
        final handle = _mintHandle(key, factory);
        return cx == null ? handle.value : cx.get(handle);
      });

  /// Non-blocking observe of an existing entry, or `null` if [key] is not
  /// materialized. Non-minting. Pass [cx] to value-thread the edge.
  V? observe(K key, [Compute? cx]) => _guarded(() {
        final handle = _keyed.get(key);
        if (handle == null) return null;
        return cx == null ? handle.value : cx.get(handle);
      });

  /// The existing entry node for [key], or `null`. Non-minting.
  Source<V>? handle(K key) => _guarded(() => _keyed.get(key));

  /// Whether [key] is currently materialized. Non-reactive.
  bool isPresent(K key) => _guarded(() => _keyed.contains(key));

  /// A stable snapshot of the currently-materialized keys, in current order.
  /// Non-reactive — see [keys] for the tracked read.
  List<K> presentKeys() => _guarded(() => _keyed.keys());

  /// The number of currently-materialized entries.
  int presentCount() => _guarded(() => _keyed.length);

  // --- Core surface: ordering, atomic move, reactive membership ---
  //
  // These bind every flavor. The move algebra touches no entry handle and awaits
  // nothing, so it is neither thread- nor async-coloured.

  /// Reactive snapshot of the keys in their current order. Subscribes the caller
  /// to **order** changes (add/remove **and move/reorder**), not to per-entry
  /// value changes. Pass [cx] to value-thread the edge.
  List<K> keys([Compute? cx]) {
    if (cx == null) {
      _orderSignal.value;
    } else {
      cx.get(_orderSignal);
    }
    return presentKeys();
  }

  /// Reactive entry count. Subscribes the caller to membership changes only.
  int len([Compute? cx]) {
    if (cx == null) {
      _membership.value;
    } else {
      cx.get(_membership);
    }
    return presentCount();
  }

  /// Reactive emptiness check.
  bool get isEmpty => len() == 0;

  /// Reactive membership test for [key]. Subscribes the caller to membership
  /// changes (add/remove of any key), not to value changes.
  bool containsKey(K key, [Compute? cx]) {
    if (cx == null) {
      _membership.value;
    } else {
      cx.get(_membership);
    }
    return isPresent(key);
  }

  /// Non-reactive count.
  int get lenUntracked => presentCount();

  /// Current 0-based position of [key] in the order, or `null`. Non-reactive.
  int? position(K key) => _guarded(() => _keyed.position(key));

  /// Atomically move [key] to [index] (`#lzcellmove`). The entry keeps the
  /// **same** node, its dependents, and its lineage — unlike a remove + re-mint,
  /// which re-allocates and bumps membership twice. Only the order signal is
  /// bumped, so [keys] readers recompute while [len] readers stay cached.
  /// [index] is clamped to `[0, len)`.
  bool moveTo(K key, int index) =>
      _applyMove(_guarded(() => _keyed.moveTo(key, index)));

  /// Atomically move [key] to just before [anchor] (`#lzcellmove`).
  bool moveBefore(K key, K anchor) =>
      _applyMove(_guarded(() => _keyed.moveBefore(key, anchor)));

  /// Atomically move [key] to just after [anchor] (`#lzcellmove`).
  bool moveAfter(K key, K anchor) =>
      _applyMove(_guarded(() => _keyed.moveAfter(key, anchor)));

  /// Remove [key]'s entry, clearing the removed node's dependents so no reader
  /// is left on a stale value, and bump reactive membership.
  bool remove(K key) {
    final (removed, mutation) = _guarded(() => _keyed.remove(key));
    if (!mutation.changed) return false;
    removed!.invalidate();
    _bumpMembership();
    return true;
  }
}

/// A thread-safe **input-cell** map: every entry is an always-materialized,
/// settable input. Adds cell-only [set]. `H = Cell` (elided — value cache).
class ThreadSafeSourceMap<K, V> extends ThreadSafeReactiveMap<K, V> {
  ThreadSafeSourceMap(super.ctx);

  @override
  EntryKind get entryKind => EntryKind.source;

  /// Set [key]'s value, inserting a new input cell if absent, and return `true`.
  /// Updating an existing entry overwrites in place (no re-order). Cell-only: an
  /// input is settable; a derived [ThreadSafeComputedMap] slot is not.
  bool set(K key, V value) => _guarded(() {
        final warm = _keyed.get(key);
        if (warm != null) {
          // Overwrite in place: the entry keeps its node, membership and order
          // are untouched, and only this entry's readers see a change.
          warm.value = value;
          return true;
        }
        _mintHandle(key, (_) => value);
        return true;
      });

  /// **Eager materialization**: pre-mint a resolved input cell for every entry
  /// in [values], up front.
  void materializeAll(Map<K, V> values) => _guarded(() {
        values.forEach((k, v) => set(k, v));
      });
}

/// Thread-safe exact-key dependency publication.
class ThreadSafeDependencyMap<K, V>
    extends ThreadSafeSourceMap<K, DependencyAvailability<V>> {
  ThreadSafeDependencyMap(super.ctx);

  DependencyAvailability<V> observeDependency(K key, [Compute? cx]) =>
      getOrInsertWith(
        key,
        (_) => DependencyAvailability<V>.unavailable(),
        cx,
      );

  void publish(K key, V value) =>
      set(key, DependencyAvailability<V>.available(value));

  void unpublish(K key) => set(key, DependencyAvailability<V>.unavailable());
}

/// A thread-safe **derived-slot** map: entries are derived values minted lazily
/// on access ([getOrInsertWith]) or eagerly via [materializeAll]. No `set`.
/// `H = Slot` (elided — value cache).
class ThreadSafeComputedMap<K, V> extends ThreadSafeReactiveMap<K, V> {
  ThreadSafeComputedMap(super.ctx);

  @override
  EntryKind get entryKind => EntryKind.computed;

  /// **Eager materialization**: pre-mint a derived slot for every key in [keys]
  /// via [factory], up front. Observationally identical to minting each key
  /// lazily on first read ([getOrInsertWith]).
  void materializeAll(Iterable<K> keys, V Function(K key) factory) =>
      _guarded(() {
        for (final key in keys) {
          _mintHandle(key, factory);
        }
      });
}

/// Former name of [ThreadSafeSourceMap], kept so existing callers still compile.
@Deprecated('renamed to ThreadSafeSourceMap')
typedef ThreadSafeCellMap<K, V> = ThreadSafeSourceMap<K, V>;

/// Former name of [ThreadSafeComputedMap], kept so existing callers still
/// compile.
@Deprecated('renamed to ThreadSafeComputedMap')
typedef ThreadSafeSlotMap<K, V> = ThreadSafeComputedMap<K, V>;
