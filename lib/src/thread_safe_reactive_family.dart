/// Thread-safe keyed reactive family ([ThreadSafeReactiveFamily]) — the
/// run-to-completion flavor of [ReactiveFamily] (`#lzmatmode`, thread-safe).
///
/// Spec:   `lazily-spec/cell-model.md` § Materialization mode.
/// Formal: `lazily-formal/LazilyFormal/Materialization.lean`
///   (`materialize_present_comm` / `materialize_observe_comm` — the confluence
///    pair; `materialize_present_monotone`; `cell_entries_materialized_in_every_mode`;
///    `slot_entries_deferred_under_lazy`; `eager_lazy_observationally_equivalent`).
/// Rust reference: `lazily-rs/src/thread_safe_reactive_family.rs`.
/// Go reference:   `lazily-go/thread_safe_reactive_family.go`.
///
/// Where [ReactiveFamily] (`reactive_family.dart`) is a keyed reactive family
/// over the (unsynchronized) reactive graph, this family guards its present-set
/// state — the materialized value cache + first-materialization order — behind a
/// reentrant run-to-completion guard, and caches canonical values directly (a
/// pure factory produces each) rather than routing through a per-node reactive
/// [Context]. Like the Zig/Rust flavors it carries its own guard, so it needs no
/// separate thread-safe context type.
///
/// DART RUNTIME PREMISE. See `thread_safe.dart`: a synchronous isolate runs to
/// completion and never yields, so the "lock" degrades to a reentrant depth
/// guard exactly as JS degrades its `Atomics` mutex without `SharedArrayBuffer`.
/// The guard is retained for structural parity and to frame the present-set
/// mutations that Go serializes with a `sync.Mutex`.
///
/// It obeys the same three laws as the single-threaded family:
///   - **Eager/lazy contract**: eager materializes every declared node at build;
///     lazy defers derived (slot) nodes to first read. Cell entries are always
///     materialized regardless of mode
///     (`cell_entries_materialized_in_every_mode` / `slot_entries_deferred_under_lazy`).
///   - **Observational transparency**: [observe] returns an identical value
///     under either mode (`eager_lazy_observationally_equivalent`).
///   - **Present-set monotonicity**: the materialized set only grows (deferral,
///     never de-allocation) (`materialize_present_monotone`).
///
/// plus **materialization confluence**: the present set and every observed value
/// are independent of the order in which keys are materialized. A guard admits a
/// concurrent workload as *some* sequential order of the per-key
/// materializations; confluence (`materialize_present_comm` /
/// `materialize_observe_comm`) is what makes any such order observationally
/// identical.
library;

import 'core.dart';
import 'reactive_family.dart';

/// The run-to-completion keyed reactive family (`#lzmatmode`): keys `K` map to
/// per-entry cached values of one [EntryKind], allocated per its
/// [MaterializationMode], with every present-set mutation framed by a reentrant
/// guard.
///
/// See the library doc for the eager/lazy contract, observational transparency,
/// present-set monotonicity, and confluence.
class ThreadSafeReactiveFamily<K, V> {
  /// Build a thread-safe family of entry [kind] and materialization [mode] over
  /// [keys], with [factory] producing each key's canonical value. Under eager,
  /// every declared key is materialized now; under lazy, only cell entries are
  /// materialized at build and slot entries defer to first read.
  ThreadSafeReactiveFamily(
    this._ctx,
    this._kind,
    this._mode,
    Iterable<K> keys,
    V Function(K key) factory,
  ) : _factory = factory {
    // No re-entrancy hazard at build: no other caller can observe the family
    // before the constructor returns. A cell entry is always materialized
    // regardless of mode; a slot entry only under eager.
    for (final key in keys) {
      if (_kind == EntryKind.cell || _mode == MaterializationMode.eager) {
        _materializeKey(key);
      }
    }
  }

  /// Build an **eager** thread-safe family of derived slots.
  static ThreadSafeReactiveFamily<K, V> eagerSlotFamily<K, V>(
    Context ctx,
    Iterable<K> keys,
    V Function(K key) factory,
  ) =>
      ThreadSafeReactiveFamily<K, V>(
          ctx, EntryKind.slot, MaterializationMode.eager, keys, factory);

  /// Build a **lazy** thread-safe family of derived slots; each slot is deferred
  /// to its first read.
  static ThreadSafeReactiveFamily<K, V> lazySlotFamily<K, V>(
    Context ctx,
    Iterable<K> keys,
    V Function(K key) factory,
  ) =>
      ThreadSafeReactiveFamily<K, V>(
          ctx, EntryKind.slot, MaterializationMode.lazy, keys, factory);

  /// Build an **eager** thread-safe family of input cells (cells are always
  /// materialized at build, any mode).
  static ThreadSafeReactiveFamily<K, V> eagerCellFamily<K, V>(
    Context ctx,
    Iterable<K> keys,
    V Function(K key) factory,
  ) =>
      ThreadSafeReactiveFamily<K, V>(
          ctx, EntryKind.cell, MaterializationMode.eager, keys, factory);

  /// Build a thread-safe family of input cells declared under **lazy** mode;
  /// cell entries still materialize at build.
  static ThreadSafeReactiveFamily<K, V> lazyCellFamily<K, V>(
    Context ctx,
    Iterable<K> keys,
    V Function(K key) factory,
  ) =>
      ThreadSafeReactiveFamily<K, V>(
          ctx, EntryKind.cell, MaterializationMode.lazy, keys, factory);

  // Retained for structural parity with ReactiveFamily and future graph
  // integration; the value axis is served from the guarded cache below.
  // ignore: unused_field
  final Context _ctx;
  final EntryKind _kind;
  final MaterializationMode _mode;
  final V Function(K key) _factory;

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

  /// Run [fn] under the reentrant guard.
  T _guarded<T>(T Function() fn) {
    _depth++;
    try {
      return fn();
    } finally {
      _depth--;
    }
  }

  /// Allocate [key]'s value on first access and cache it (the lazy pull),
  /// recording first-materialization order. A warm key is a no-op — the present
  /// set only grows.
  void _materializeKey(K key) {
    if (_materialized.containsKey(key)) return; // warm.
    _materialized[key] = _factory(key);
    _order.add(key);
  }

  /// Get [key]'s value, materializing it on first access (the lazy pull) under
  /// the guard. Under eager an entry is already present.
  V get(K key) => _guarded(() {
        _materializeKey(key);
        return _materialized[key] as V;
      });

  /// Observe [key]'s value — the transparency law: identical under either mode.
  /// Materializes the entry if absent.
  V observe(K key) => get(key);

  /// Overwrite an input cell entry's value (cells are writable inputs),
  /// materializing it if absent, and report success. Fails (`false`) on a slot
  /// family, whose entries are derived.
  bool set(K key, V value) {
    if (_kind != EntryKind.cell) return false;
    return _guarded(() {
      _materializeKey(key);
      _materialized[key] = value; // overwrite in place; no re-order.
      return true;
    });
  }

  /// Whether [key] is currently materialized. Non-reactive.
  bool isPresent(K key) => _guarded(() => _materialized.containsKey(key));

  /// A stable snapshot of the currently-materialized keys, in
  /// first-materialization order (a copy — the present set only grows).
  List<K> presentKeys() => _guarded(() => List<K>.of(_order));

  /// The number of currently-materialized entries.
  int presentCount() => _guarded(() => _order.length);

  /// This family's materialization mode.
  MaterializationMode get mode => _mode;

  /// This family's entry kind.
  EntryKind get entryKind => _kind;
}
