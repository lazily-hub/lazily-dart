/// The present set plus its authoritative key order, with the atomic-move
/// algebra (`#lzcellmove`).
///
/// This is the **graph-agnostic** half of every `ReactiveMap` flavor. It holds
/// no context, no factory, and no closure: only `K -> handle` bookkeeping and
/// the key list. That is exactly why ordering and atomic move bind the
/// single-threaded, thread-safe, and async flavors alike — a move touches no
/// entry handle and awaits nothing, so it is neither thread- nor
/// async-coloured.
///
/// What is deliberately **not** here is reactivity. Membership and order
/// *invalidation* is a graph write, and each flavor must mint its own version
/// cells on its own graph; a shared core cannot supply them. Each flavor keeps a
/// thin shell holding this core, its own guard, its own signals, and its own
/// materialize/observe.
///
/// `_entries` and `_order` stay in lockstep: every key in one appears exactly
/// once in the other, including on every failure path. Reordering cannot fail —
/// it is a removeAt + insert with both ends clamped — so there is no error path
/// to desync on.
///
/// Rust reference: `lazily-rs/src/keyed_order.rs`.
library;

/// What a present-set mutation did, so the caller knows what to bump.
///
/// A no-op must bump nothing: bumping on a warm insert would invalidate every
/// `len` / `containsKey` reader on a pure cache hit.
enum MapMutation {
  none,
  inserted,
  removed;

  /// Whether anything changed.
  bool get changed => this != MapMutation.none;
}

/// What an ordering move did.
///
/// [missing] and [unchanged] are distinct because the public `move*` methods
/// report `false` for a missing key but `true` for a no-op move — while neither
/// may bump the order signal.
enum MapMove {
  missing,
  unchanged,
  reordered;

  /// Whether the move applied at all (the `bool` the public API returns).
  bool get applied => this != MapMove.missing;

  /// Whether the order actually changed, i.e. whether to bump.
  bool get changed => this == MapMove.reordered;
}

/// The present set + key order + the move algebra. Closure-free.
class KeyedOrder<K, H> {
  final Map<K, H> _entries = {};
  final List<K> _order = [];

  // --- reads (no graph involvement) ---

  H? get(K key) => _entries[key];

  bool contains(K key) => _entries.containsKey(key);

  /// A copy of the authoritative key list; the internal list never escapes.
  List<K> keys() => List<K>.of(_order);

  int get length => _order.length;

  int? position(K key) {
    final at = _order.indexOf(key);
    return at == -1 ? null : at;
  }

  // --- present-set mutations ---

  /// Insert [handle] under [key], appending to the order.
  ///
  /// A warm key keeps its existing handle (cell-identity: a key's node is stable
  /// for its lifetime) and reports [MapMutation.none] so the caller bumps
  /// nothing.
  (H, MapMutation) insert(K key, H handle) {
    final existing = _entries[key];
    if (existing != null) return (existing, MapMutation.none);
    _entries[key] = handle;
    _order.add(key);
    return (handle, MapMutation.inserted);
  }

  /// Remove [key], returning its handle so the caller can dispose the node on
  /// its own graph. The core never touches a handle.
  (H?, MapMutation) remove(K key) {
    final handle = _entries.remove(key);
    if (handle == null) return (null, MapMutation.none);
    _order.remove(key);
    return (handle, MapMutation.removed);
  }

  // --- the move algebra ---

  /// Move [key] to [index], clamped to `[0, len)`.
  ///
  /// The entry keeps the same handle, its dependents, and its CRDT lineage —
  /// that is what separates a reorder from a remove + re-mint. Both ends are
  /// clamped: an unclamped negative index is the defect lazily-js shipped.
  MapMove moveTo(K key, int index) {
    final from = _order.indexOf(key);
    if (from == -1) return MapMove.missing;
    var to = index;
    if (to < 0) to = 0;
    if (to > _order.length - 1) to = _order.length - 1;
    if (from == to) return MapMove.unchanged;
    _order.removeAt(from);
    _order.insert(to, key);
    return MapMove.reordered;
  }

  /// Move [key] to just before [anchor].
  ///
  /// The target is computed on the **pre-removal** list: when [key] currently
  /// precedes [anchor], lifting it out shifts [anchor] one slot left, so the
  /// insertion point is `anchor - 1`. Getting this wrong lands the key on the
  /// far side of its anchor — the defect found in lazily-zig, where
  /// `moveBefore("a", "d")` on `[a,b,c,d]` produced `[b,c,d,a]`.
  MapMove moveBefore(K key, K anchor) {
    final anchorIdx = position(anchor);
    final from = position(key);
    if (anchorIdx == null || from == null) return MapMove.missing;
    return moveTo(key, from < anchorIdx ? anchorIdx - 1 : anchorIdx);
  }

  /// Move [key] to just after [anchor]. Same pre-removal reasoning.
  MapMove moveAfter(K key, K anchor) {
    final anchorIdx = position(anchor);
    final from = position(key);
    if (anchorIdx == null || from == null) return MapMove.missing;
    return moveTo(key, from <= anchorIdx ? anchorIdx : anchorIdx + 1);
  }
}
