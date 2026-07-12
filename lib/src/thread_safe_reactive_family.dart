/// Thread-safe keyed reactive map ([ThreadSafeReactiveMap]) — the
/// run-to-completion flavor of [ReactiveMap] (`#reactivemap`, thread-safe).
///
/// Spec:   `lazily-spec/cell-model.md` § Keyed cell collections.
/// Formal: `lazily-formal/LazilyFormal/Materialization.lean`
///   (`materialize_present_comm` / `materialize_observe_comm` — the confluence
///    pair; `materialize_present_monotone`; `cell_entries_materialized_in_every_mode`;
///    `slot_entries_deferred_under_lazy`; `eager_lazy_observationally_equivalent`).
/// Rust reference: `lazily-rs/src/thread_safe_reactive_family.rs`
///   (`ThreadSafeReactiveMap` / `ThreadSafeCellMap` / `ThreadSafeSlotMap`).
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
/// and the cell-only [ThreadSafeCellMap.set] / slot-only
/// [ThreadSafeSlotMap.materializeAll] surface.
///
/// It obeys the same laws as the single-threaded map:
///   - **Eager/lazy contract**: eager pre-mints every key
///     ([ThreadSafeSlotMap.materializeAll]); lazy defers each derived slot to
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

/// The run-to-completion keyed reactive map (`#reactivemap`): keys `K` map to
/// per-entry cached values, allocated on access, with every present-set mutation
/// framed by a reentrant guard.
///
/// The two specializations are [ThreadSafeCellMap] (input cells, adds [set]) and
/// [ThreadSafeSlotMap] (derived slots, adds [ThreadSafeSlotMap.materializeAll]).
/// The shared surface — [getOrInsertWith] / [observe] / membership / present-set
/// — lives here.
abstract class ThreadSafeReactiveMap<K, V> {
  ThreadSafeReactiveMap(this._ctx);

  // Retained for structural parity with ReactiveMap and future graph
  // integration; the value axis is served from the guarded cache below.
  // ignore: unused_field
  final Context _ctx;

  /// Reentrancy depth of the run-to-completion guard framing present-set
  /// mutations (Dart isolates need no OS lock; see the library doc).
  int _depth = 0;

  /// Current reentrancy depth (`> 0` while inside a guarded section).
  int get depth => _depth;

  /// Present (materialized) entries and each entry's cached canonical value.
  /// Grows on materialize, never shrinks.
  final Map<K, V> _materialized = {};

  /// First-materialization order of the present set (grows only).
  final List<K> _order = [];

  /// This map's entry kind ([EntryKind.cell] for a [ThreadSafeCellMap],
  /// [EntryKind.slot] for a [ThreadSafeSlotMap]).
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

  /// Allocate [key]'s value on first access via [factory] and cache it,
  /// recording first-materialization order. A warm key is a no-op — the present
  /// set only grows.
  V _mint(K key, V Function(K key) factory) {
    final existing = _materialized[key];
    if (existing != null || _materialized.containsKey(key)) {
      return _materialized[key] as V;
    }
    final value = factory(key);
    _materialized[key] = value;
    _order.add(key);
    return value;
  }

  /// Get [key]'s value, minting it via [factory] on first access (the lazy
  /// pull) under the guard. A warm key returns its cached value without
  /// re-running [factory].
  V getOrInsertWith(K key, V Function(K key) factory) =>
      _guarded(() => _mint(key, factory));

  /// Non-blocking observe of an existing entry: its cached value, or `null` if
  /// [key] is not materialized. Non-minting.
  V? observe(K key) => _guarded(() => _materialized[key]);

  /// The existing entry handle for [key] — the cached value, or `null`.
  /// Non-minting. (Value-cache flavor: the handle *is* the value.)
  V? handle(K key) => observe(key);

  /// Whether [key] is currently materialized. Non-reactive.
  bool isPresent(K key) => _guarded(() => _materialized.containsKey(key));

  /// A stable snapshot of the currently-materialized keys, in
  /// first-materialization order (a copy — the present set only grows).
  List<K> presentKeys() => _guarded(() => List<K>.of(_order));

  /// The number of currently-materialized entries.
  int presentCount() => _guarded(() => _order.length);
}

/// A thread-safe **input-cell** map: every entry is an always-materialized,
/// settable input. Adds cell-only [set]. `H = Cell` (elided — value cache).
class ThreadSafeCellMap<K, V> extends ThreadSafeReactiveMap<K, V> {
  ThreadSafeCellMap(super.ctx);

  @override
  EntryKind get entryKind => EntryKind.cell;

  /// Set [key]'s value, inserting a new input cell if absent, and return `true`.
  /// Updating an existing entry overwrites in place (no re-order). Cell-only: an
  /// input is settable; a derived [ThreadSafeSlotMap] slot is not.
  bool set(K key, V value) => _guarded(() {
        _mint(key, (_) => value);
        _materialized[key] = value; // overwrite in place; no re-order.
        return true;
      });

  /// **Eager materialization**: pre-mint a resolved input cell for every entry
  /// in [values], up front.
  void materializeAll(Map<K, V> values) => _guarded(() {
        values.forEach((k, v) => set(k, v));
      });
}

/// A thread-safe **derived-slot** map: entries are derived values minted lazily
/// on access ([getOrInsertWith]) or eagerly via [materializeAll]. No `set`.
/// `H = Slot` (elided — value cache).
class ThreadSafeSlotMap<K, V> extends ThreadSafeReactiveMap<K, V> {
  ThreadSafeSlotMap(super.ctx);

  @override
  EntryKind get entryKind => EntryKind.slot;

  /// **Eager materialization**: pre-mint a derived slot for every key in [keys]
  /// via [factory], up front. Observationally identical to minting each key
  /// lazily on first read ([getOrInsertWith]).
  void materializeAll(Iterable<K> keys, V Function(K key) factory) =>
      _guarded(() {
        for (final key in keys) {
          _mint(key, factory);
        }
      });
}
