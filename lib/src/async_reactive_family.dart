/// Async keyed reactive map ([AsyncReactiveMap]) — the async flavor of
/// [ReactiveMap] (`#reactivemap`, async).
///
/// Spec:   `lazily-spec/cell-model.md` § Keyed cell collections (async).
/// Formal: `lazily-formal/LazilyFormal/AsyncMaterialization.lean`
///   (`eventual_transparency`, `async_resolved_matches_sync`,
///    `observe_pending_is_none`, `cell_resolved_at_build`, `resolve_monotone`,
///    `resolve_preserves_observe`).
/// Rust reference: `lazily-rs/src/async_reactive_family.rs`
///   (`AsyncReactiveMap` / `AsyncSourceMap` / `AsyncComputedMap`).
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
/// is driven to resolution ([AsyncComputedMap.drive], the analog of
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
import 'keyed_order.dart';

/// One allocated (present) async map entry: [resolved] tracks the async
/// resolution axis, [value] caches its canonical value once resolved. A pending
/// entry's [value] is `null` and unspecified.
class _AsyncEntry<V> {
  _AsyncEntry(this.resolved, this.cell);

  bool resolved;

  /// The entry's node on the owning graph. Entries used to be plain cached
  /// values, so a per-entry read registered no edge and a write invalidated
  /// nobody. The resolution axis is orthogonal: [resolved] still tracks
  /// pending-vs-resolved, while the cell carries the value and its dependents.
  final Source<V?> cell;

  V? get value => cell.value;
}

/// The async keyed reactive map (`#reactivemap`): keys `K` map to per-entry
/// async reactive nodes, each carrying a resolution flag.
///
/// The two specializations are [AsyncSourceMap] (input cells — resolved at
/// allocation, adds [AsyncSourceMap.set]) and [AsyncComputedMap] (derived slots —
/// pending until [AsyncComputedMap.drive]n). The shared surface — [observe] /
/// [isResolved] / membership / present-set — lives here. See the library doc
/// for the eventual-transparency law.
abstract class AsyncReactiveMap<K, V> {
  AsyncReactiveMap(this._ctx)
      : _membership = Source<int>(_ctx, 0),
        _orderSignal = Source<int>(_ctx, 0);

  final Context _ctx;

  /// Reactive *set-membership* signal, minted on THIS flavor's graph. A shared
  /// graph-agnostic core cannot supply reactivity.
  final Source<int> _membership;

  /// Reactive *order* signal: bumped on add/remove **and on move/reorder**.
  final Source<int> _orderSignal;

  int _membershipVersion = 0;
  int _orderVersion = 0;

  /// Reentrancy depth of the run-to-completion guard.
  int _depth = 0;

  /// Current reentrancy depth (`> 0` while inside a guarded section).
  int get depth => _depth;

  /// Present set + key order + the move algebra, shared with the other two
  /// flavors. Graph-agnostic; the reactivity above is this flavor's own.
  /// Resolution only ever flips `false → true` (`resolve_monotone`).
  final KeyedOrder<K, _AsyncEntry<V>> _keyed = KeyedOrder<K, _AsyncEntry<V>>();

  /// This map's entry kind ([EntryKind.source] for an [AsyncSourceMap],
  /// [EntryKind.computed] for an [AsyncComputedMap]).
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
    final existing = _keyed.get(key);
    if (existing != null) return existing;
    final entry = _AsyncEntry<V>(resolved, Source<V?>(_ctx, value));
    final (stored, mutation) = _keyed.insert(key, entry);
    if (mutation.changed) _bumpMembership();
    return stored;
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

  /// A non-blocking read: `(value, true)` once resolved, `(null, false)` while
  /// pending or absent (`observe_pending_is_none`). Non-minting.
  (V?, bool) observe(K key, [Compute? cx]) => _guarded(() {
        final entry = _keyed.get(key);
        if (entry != null && entry.resolved) {
          return (cx == null ? entry.value : cx.get(entry.cell), true);
        }
        return (null, false);
      });

  /// The existing entry node for [key], or `null`. Non-minting.
  Source<V?>? handle(K key) => _guarded(() => _keyed.get(key)?.cell);

  /// Whether [key] is currently allocated (present). Non-reactive.
  bool isPresent(K key) => _guarded(() => _keyed.contains(key));

  /// Whether [key] is allocated AND resolved (a non-blocking [observe] would
  /// return a value).
  bool isResolved(K key) => _guarded(() {
        final entry = _keyed.get(key);
        return entry != null && entry.resolved;
      });

  /// A stable snapshot of the currently-allocated keys, in first-materialization
  /// order (a copy).
  List<K> presentKeys() => _guarded(() => _keyed.keys());

  /// The number of currently-allocated entries.
  int presentCount() => _guarded(() => _keyed.length);

  // --- Core surface: ordering, atomic move, reactive membership ---
  //
  // Ordering is not async-coloured: the move algebra touches no entry handle and
  // awaits nothing, so the async map carries the same Core surface as the other
  // two flavors.

  /// Reactive snapshot of the keys in their current order. Subscribes the caller
  /// to **order** changes (add/remove **and move/reorder**).
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

  /// Reactive membership test for [key].
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

  /// Atomically move [key] to [index] (`#lzcellmove`). The entry keeps its node,
  /// its dependents, and its resolution state; only the order signal is bumped.
  bool moveTo(K key, int index) =>
      _applyMove(_guarded(() => _keyed.moveTo(key, index)));

  /// Atomically move [key] to just before [anchor] (`#lzcellmove`).
  bool moveBefore(K key, K anchor) =>
      _applyMove(_guarded(() => _keyed.moveBefore(key, anchor)));

  /// Atomically move [key] to just after [anchor] (`#lzcellmove`).
  bool moveAfter(K key, K anchor) =>
      _applyMove(_guarded(() => _keyed.moveAfter(key, anchor)));

  /// Remove [key]'s entry, clearing the removed node's dependents so no reader
  /// is left on a stale resolution, and bump reactive membership.
  bool remove(K key) {
    final (removed, mutation) = _guarded(() => _keyed.remove(key));
    if (!mutation.changed) return false;
    removed!.cell.invalidate();
    _bumpMembership();
    return true;
  }
}

/// An async **input-cell** map: every entry is an always-resolved input. Adds
/// cell-only [set]. `H = AsyncCell` (elided — value cache).
class AsyncSourceMap<K, V> extends AsyncReactiveMap<K, V> {
  AsyncSourceMap(super.ctx);

  @override
  EntryKind get entryKind => EntryKind.source;

  /// Set [key]'s value (an input cell — always resolved), allocating it if
  /// absent, and return `true`. Cell-only: an input is settable; a derived
  /// [AsyncComputedMap] slot is not.
  bool set(K key, V value) => _guarded(() {
        final entry = _ensure(key, resolved: true, value: value);
        // Overwrite in place: the entry keeps its node, membership and order are
        // untouched, and only this entry's readers see a change.
        entry.cell.value = value;
        entry.resolved = true;
        return true;
      });

  /// **Eager materialization**: pre-mint a resolved input cell for every entry
  /// in [values], up front.
  void materializeAll(Map<K, V> values) => _guarded(() {
        values.forEach((k, v) => set(k, v));
      });
}

/// Async-flavor exact-key dependency publication.
class AsyncDependencyMap<K, V>
    extends AsyncSourceMap<K, DependencyAvailability<V>> {
  AsyncDependencyMap(super.ctx);

  DependencyAvailability<V> observeDependency(K key, [Compute? cx]) {
    if (handle(key) == null) {
      set(key, DependencyAvailability<V>.unavailable());
    }
    return observe(key, cx).$1 as DependencyAvailability<V>;
  }

  void publish(K key, V value) =>
      set(key, DependencyAvailability<V>.available(value));

  void unpublish(K key) => set(key, DependencyAvailability<V>.unavailable());
}

/// An async **derived-slot** map: entries are minted lazily on [touch] (pending)
/// or eagerly via [materializeAll], and resolved via [drive]. No `set`.
/// `H = AsyncSlot` (elided — value cache).
class AsyncComputedMap<K, V> extends AsyncReactiveMap<K, V> {
  AsyncComputedMap(super.ctx);

  @override
  EntryKind get entryKind => EntryKind.computed;

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
          // Resolution keeps the entry's node: driving a pending slot is not a
          // re-mint, so its dependents survive.
          entry.cell.value = factory(key);
          entry.resolved = true;
        }
        return entry.value as V;
      });
}

/// Former name of [AsyncSourceMap], kept so existing callers still compile.
@Deprecated('renamed to AsyncSourceMap')
typedef AsyncCellMap<K, V> = AsyncSourceMap<K, V>;

/// Former name of [AsyncComputedMap], kept so existing callers still compile.
@Deprecated('renamed to AsyncComputedMap')
typedef AsyncSlotMap<K, V> = AsyncComputedMap<K, V>;
