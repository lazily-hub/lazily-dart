/// Async keyed reactive map ([AsyncReactiveMap]) — the async flavor of
/// [ReactiveMap] (`#reactivemap`, async).
///
/// Spec:   `lazily-spec/cell-model.md` § Keyed cell collections (async).
/// Formal: `lazily-formal/LazilyFormal/AsyncMaterialization.lean`
///   (`eventual_transparency`, `async_resolved_matches_sync`,
///    `observe_pending_is_none`, `cell_resolved_at_build`, `resolve_monotone`,
///    `resolve_preserves_observe`).
/// Rust reference: `lazily-rs/src/async_reactive_family.rs`
///   (`AsyncReactiveMap` / `AsyncCellMap` / `AsyncSlotMap`).
///
/// Keys `K` map to per-entry async reactive nodes. Like the thread-safe flavor
/// it frames its state behind a reentrant run-to-completion guard (Dart isolates
/// need no OS lock; see `thread_safe.dart` for the DART RUNTIME PREMISE). Dart
/// is single-isolate, so this is a value-cache model — there are no distinct
/// async handle types, so `H` is elided; the two specializations differ only by
/// entry kind and their cell-only / slot-only surface.
///
/// Async adds a **resolution axis** orthogonal to the present-set (allocation)
/// axis of the single-threaded map: a derived (slot) entry is *pending* until it
/// is driven to resolution ([AsyncSlotMap.drive], the analog of
/// `AsyncContext.getAsync`), then *resolved*. Input (cell) entries are resolved
/// at allocation (`cell_resolved_at_build`). A non-blocking read therefore
/// returns `(value, resolved)`: `(null, false)` while pending
/// (`observe_pending_is_none`), `(value, true)` once resolved.
///
/// The single-threaded transparency law weakens to **eventual transparency**:
/// once a node resolves, its observed value is the canonical value — identical
/// to what the synchronous map observes (`eventual_transparency`,
/// `async_resolved_matches_sync`). Resolution only ever flips `false → true`
/// (`resolve_monotone`).
library;

import 'collections.dart';
import 'core.dart';

/// One allocated (present) async map entry: [resolved] tracks the async
/// resolution axis, [value] caches its canonical value once resolved. A pending
/// entry's [value] is `null` and unspecified.
class _AsyncEntry<V> {
  _AsyncEntry(this.resolved, this.value);

  bool resolved;
  V? value;
}

/// The async keyed reactive map (`#reactivemap`): keys `K` map to per-entry
/// async reactive nodes, each carrying a resolution flag.
///
/// The two specializations are [AsyncCellMap] (input cells — resolved at
/// allocation, adds [AsyncCellMap.set]) and [AsyncSlotMap] (derived slots —
/// pending until [AsyncSlotMap.drive]n). The shared surface — [observe] /
/// [isResolved] / membership / present-set — lives here. See the library doc
/// for the eventual-transparency law.
abstract class AsyncReactiveMap<K, V> {
  AsyncReactiveMap(this._ctx);

  // Retained for structural parity with ReactiveMap; the value axis is served
  // from the guarded cache below.
  // ignore: unused_field
  final Context _ctx;

  /// Reentrancy depth of the run-to-completion guard.
  int _depth = 0;

  /// Current reentrancy depth (`> 0` while inside a guarded section).
  int get depth => _depth;

  /// Present (allocated) entries. Grows on materialize, never shrinks.
  /// Resolution only ever flips `false → true` (`resolve_monotone`).
  final Map<K, _AsyncEntry<V>> _materialized = {};

  /// First-materialization order of the present set (grows only).
  final List<K> _order = [];

  /// This map's entry kind ([EntryKind.cell] for an [AsyncCellMap],
  /// [EntryKind.slot] for an [AsyncSlotMap]).
  EntryKind get entryKind;

  T _guarded<T>(T Function() fn) {
    _depth++;
    try {
      return fn();
    } finally {
      _depth--;
    }
  }

  /// Allocate [key] if absent (present-set grows), recording order, with the
  /// given initial resolution state. A warm key returns its existing entry
  /// unchanged — the present set only grows.
  _AsyncEntry<V> _ensure(K key, {required bool resolved, V? value}) {
    final existing = _materialized[key];
    if (existing != null) return existing;
    final entry = _AsyncEntry<V>(resolved, value);
    _materialized[key] = entry;
    _order.add(key);
    return entry;
  }

  /// A non-blocking read: `(value, true)` once resolved, `(null, false)` while
  /// pending or absent (`observe_pending_is_none`). Non-minting.
  (V?, bool) observe(K key) => _guarded(() {
        final entry = _materialized[key];
        if (entry != null && entry.resolved) return (entry.value, true);
        return (null, false);
      });

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
}

/// An async **input-cell** map: every entry is an always-resolved input. Adds
/// cell-only [set]. `H = AsyncCell` (elided — value cache).
class AsyncCellMap<K, V> extends AsyncReactiveMap<K, V> {
  AsyncCellMap(super.ctx);

  @override
  EntryKind get entryKind => EntryKind.cell;

  /// Set [key]'s value (an input cell — always resolved), allocating it if
  /// absent, and return `true`. Cell-only: an input is settable; a derived
  /// [AsyncSlotMap] slot is not.
  bool set(K key, V value) => _guarded(() {
        final entry = _ensure(key, resolved: true, value: value);
        entry.value = value;
        entry.resolved = true;
        return true;
      });

  /// **Eager materialization**: pre-mint a resolved input cell for every entry
  /// in [values], up front.
  void materializeAll(Map<K, V> values) => _guarded(() {
        values.forEach((k, v) => set(k, v));
      });
}

/// An async **derived-slot** map: entries are minted lazily on [touch] (pending)
/// or eagerly via [materializeAll], and resolved via [drive]. No `set`.
/// `H = AsyncSlot` (elided — value cache).
class AsyncSlotMap<K, V> extends AsyncReactiveMap<K, V> {
  AsyncSlotMap(super.ctx);

  @override
  EntryKind get entryKind => EntryKind.slot;

  /// Allocate a **pending** derived slot for [key] if absent (present, but
  /// unresolved until [drive]n) — the lazy pull's first half. A warm key is a
  /// no-op.
  void touch(K key) => _guarded(() => _ensure(key, resolved: false));

  /// **Eager materialization**: pre-mint a pending derived slot for every key in
  /// [keys], up front (present but unresolved until driven).
  void materializeAll(Iterable<K> keys) => _guarded(() {
        for (final key in keys) {
          _ensure(key, resolved: false);
        }
      });

  /// Drive [key] to resolution — the analog of `AsyncContext.getAsync`: allocate
  /// if absent, resolve if pending (produce + cache the canonical value via
  /// [factory]), and return the resolved value. A warm-resolved key returns its
  /// cached value unchanged (`eventual_transparency`).
  V drive(K key, V Function(K key) factory) => _guarded(() {
        final entry = _ensure(key, resolved: false);
        if (!entry.resolved) {
          entry.value = factory(key);
          entry.resolved = true;
        }
        return entry.value as V;
      });
}
