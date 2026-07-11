/// Async keyed reactive family ([AsyncReactiveFamily]) — the async flavor of
/// [ReactiveFamily] (`#lzmatmode`, async).
///
/// Spec:   `lazily-spec/cell-model.md` § Materialization mode (async).
/// Formal: `lazily-formal/LazilyFormal/AsyncMaterialization.lean`
///   (`eventual_transparency`, `async_resolved_matches_sync`,
///    `observe_pending_is_none`, `cell_resolved_at_build`, `resolve_monotone`,
///    `resolve_preserves_observe`).
/// Rust reference: `lazily-rs/src/async_reactive_family.rs`.
/// Go reference:   `lazily-go/async_reactive_family.go`.
///
/// Keys `K` map to per-entry async reactive nodes allocated per the family's
/// [MaterializationMode]. Like the thread-safe flavor it frames its state behind
/// a reentrant run-to-completion guard (Dart isolates need no OS lock; see
/// `thread_safe.dart` for the DART RUNTIME PREMISE).
///
/// Async adds a **resolution axis** orthogonal to the present-set (allocation)
/// axis of the single-threaded family: a derived (slot) entry is *pending* until
/// it is driven to resolution ([drive], the analog of `AsyncContext.getAsync`),
/// then *resolved*. Input (cell) entries are resolved at build
/// (`cell_resolved_at_build`). A non-blocking read therefore returns
/// `(value, resolved)`: `(null, false)` while pending
/// (`observe_pending_is_none`), `(value, true)` once resolved.
///
/// The single-threaded transparency law weakens to **eventual transparency**:
/// once a node resolves, its observed value is the canonical value — identical
/// to what the synchronous family observes (`eventual_transparency`,
/// `async_resolved_matches_sync`). Resolution only ever flips `false → true`
/// (`resolve_monotone`).
library;

import 'core.dart';
import 'reactive_family.dart';

/// One allocated (present) async family entry: [resolved] tracks the async
/// resolution axis, [value] caches its canonical value once resolved. A pending
/// entry's [value] is `null` and unspecified.
class _AsyncEntry<V> {
  _AsyncEntry(this.resolved, this.value);

  bool resolved;
  V? value;
}

/// The async keyed reactive family (`#lzmatmode`): keys `K` map to per-entry
/// async reactive nodes of one [EntryKind], allocated per its
/// [MaterializationMode], each carrying a resolution flag.
///
/// See the library doc for the eager/lazy contract, present-set monotonicity,
/// and the eventual-transparency law.
class AsyncReactiveFamily<K, V> {
  /// Build an async family of entry [kind] and materialization [mode] over
  /// [keys], with [factory] producing each key's canonical value. Cell entries
  /// are allocated and resolved at build (any mode); slot entries are allocated
  /// under eager (but start pending — the async value is only produced when
  /// driven), deferred under lazy.
  AsyncReactiveFamily(
    this._ctx,
    this._kind,
    this._mode,
    Iterable<K> keys,
    V Function(K key) factory,
  ) : _factory = factory {
    for (final key in keys) {
      if (_kind == EntryKind.cell || _mode == MaterializationMode.eager) {
        _materializeKey(key);
      }
    }
  }

  /// Build an **eager** async family of derived slots (allocated now but pending
  /// until driven).
  static AsyncReactiveFamily<K, V> eagerSlotFamily<K, V>(
    Context ctx,
    Iterable<K> keys,
    V Function(K key) factory,
  ) =>
      AsyncReactiveFamily<K, V>(
          ctx, EntryKind.slot, MaterializationMode.eager, keys, factory);

  /// Build a **lazy** async family of derived slots (deferred to first touch,
  /// then driven to resolve).
  static AsyncReactiveFamily<K, V> lazySlotFamily<K, V>(
    Context ctx,
    Iterable<K> keys,
    V Function(K key) factory,
  ) =>
      AsyncReactiveFamily<K, V>(
          ctx, EntryKind.slot, MaterializationMode.lazy, keys, factory);

  /// Build an **eager** async family of input cells (resolved at build).
  static AsyncReactiveFamily<K, V> eagerCellFamily<K, V>(
    Context ctx,
    Iterable<K> keys,
    V Function(K key) factory,
  ) =>
      AsyncReactiveFamily<K, V>(
          ctx, EntryKind.cell, MaterializationMode.eager, keys, factory);

  /// Build an async family of input cells declared under **lazy** mode; cell
  /// entries still materialize (and resolve) at build.
  static AsyncReactiveFamily<K, V> lazyCellFamily<K, V>(
    Context ctx,
    Iterable<K> keys,
    V Function(K key) factory,
  ) =>
      AsyncReactiveFamily<K, V>(
          ctx, EntryKind.cell, MaterializationMode.lazy, keys, factory);

  // Retained for structural parity with ReactiveFamily; the value axis is served
  // from the guarded cache below.
  // ignore: unused_field
  final Context _ctx;
  final EntryKind _kind;
  final MaterializationMode _mode;
  final V Function(K key) _factory;

  /// Reentrancy depth of the run-to-completion guard.
  int _depth = 0;

  /// Current reentrancy depth (`> 0` while inside a guarded section).
  int get depth => _depth;

  /// Present (allocated) entries. Grows on materialize, never shrinks. Resolution
  /// only ever flips `false → true` (`resolve_monotone`).
  final Map<K, _AsyncEntry<V>> _materialized = {};

  /// First-materialization order of the present set (grows only).
  final List<K> _order = [];

  T _guarded<T>(T Function() fn) {
    _depth++;
    try {
      return fn();
    } finally {
      _depth--;
    }
  }

  /// Allocate [key] if absent (present-set grows), recording order. A cell entry
  /// is resolved immediately with its value; a slot entry starts pending
  /// (`resolved = false`). A warm key is a no-op — the present set only grows.
  void _materializeKey(K key) {
    if (_materialized.containsKey(key)) return; // warm.
    _materialized[key] = _kind == EntryKind.cell
        ? _AsyncEntry<V>(true, _factory(key))
        : _AsyncEntry<V>(false, null);
    _order.add(key);
  }

  /// Drive [key] to resolution — the analog of `AsyncContext.getAsync`: allocate
  /// if absent, resolve if pending (produce + cache the canonical value), and
  /// return the resolved value. A warm-resolved key returns its cached value
  /// unchanged. The eventual-transparency completion (`eventual_transparency`).
  V drive(K key) => _guarded(() {
        _materializeKey(key);
        final entry = _materialized[key]!;
        if (!entry.resolved) {
          entry.value = _factory(key);
          entry.resolved = true;
        }
        return entry.value as V;
      });

  /// A non-blocking read: `(value, true)` once resolved, `(null, false)` while
  /// pending (`observe_pending_is_none`). Allocates the entry if absent — a
  /// freshly allocated slot is pending, so a first [observe] of a slot returns
  /// `(null, false)` until it is [drive]n; a cell is resolved at allocation, so
  /// it returns `(value, true)` immediately.
  (V?, bool) observe(K key) => _guarded(() {
        _materializeKey(key);
        final entry = _materialized[key]!;
        return entry.resolved ? (entry.value, true) : (null, false);
      });

  /// Overwrite an input cell entry's value (cells are writable, always
  /// resolved), materializing it if absent, and report success. Fails (`false`)
  /// on a slot family, whose entries are derived.
  bool set(K key, V value) {
    if (_kind != EntryKind.cell) return false;
    return _guarded(() {
      _materializeKey(key);
      final entry = _materialized[key]!;
      entry.value = value;
      entry.resolved = true;
      return true;
    });
  }

  /// Whether [key] is currently allocated (present). Non-reactive.
  bool isPresent(K key) => _guarded(() => _materialized.containsKey(key));

  /// Whether [key] is allocated AND resolved (a non-blocking [observe] would
  /// return a value).
  bool isResolved(K key) => _guarded(() {
        final entry = _materialized[key];
        return entry != null && entry.resolved;
      });

  /// A stable snapshot of the currently-allocated keys, in first-materialization
  /// order (a copy).
  List<K> presentKeys() => _guarded(() => List<K>.of(_order));

  /// The number of currently-allocated entries.
  int presentCount() => _guarded(() => _order.length);

  /// This family's materialization mode.
  MaterializationMode get mode => _mode;

  /// This family's entry kind.
  EntryKind get entryKind => _kind;
}
