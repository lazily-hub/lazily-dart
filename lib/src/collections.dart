/// Keyed cell collections — the unified `ReactiveMap<K, V, H>` primitive and
/// its `CellMap` / `SlotMap` specializations, plus `CellTree` and keyed
/// reconciliation (cell-model.md § Keyed cell collections, `#reactivemap`).
///
/// There is **one** keyed primitive, generic over the entry's handle kind `H`
/// (the *MapHandle* abstraction, supplied per specialization):
///
/// - **[CellMap]** = `ReactiveMap<K, V, Cell<V>>` — **input-cell** entries.
///   Adds cell-only [CellMap.set] plus eager value-minting ([CellMap.entry] /
///   [CellMap.entryWith]).
/// - **[SlotMap]** = `ReactiveMap<K, V, Slot<V>>` — **derived-slot** entries.
///   [ReactiveMap.getOrInsertWith] mints a slot on first access (**lazy
///   materialization**); [SlotMap.materializeAll] pre-mints the keyset
///   (**eager**). A slot's value is derived, so `SlotMap` has **no `set`**.
///   There is **no eager/lazy mode flag** — eager = pre-mint loop, lazy =
///   mint-on-access.
///
/// The shared surface — `getOrInsertWith` / `remove` / `move*` / membership /
/// order / `keys` / `len` / `containsKey` — lives on the generic [ReactiveMap];
/// `set` and eager value-minting are the [CellMap]-only specialization, and the
/// pre-mint eager helper is the [SlotMap]-only specialization.
///
/// A *keyed cell collection* is a **composition of cells**, not a new cell
/// kind. It maps keys `K` to per-entry reactive nodes and adds dedicated
/// **membership** and **order** reactive signals so the three reactivity planes
/// are independent:
///
/// - writing one entry's value invalidates only that entry's value readers;
/// - adding/removing a key invalidates membership readers (`len`/`contains`)
///   and order readers (`keys`), but **not** unrelated entry value readers;
/// - a pure reorder (atomic move) invalidates order readers only.
///
/// Required of every lazily binding by the conformance matrix; validated
/// against the canonical fixtures in `lazily-spec/conformance/collections/` and
/// `lazily-spec/conformance/materialization/`. Mirrors
/// `lazily-rs/src/cell_family.rs` (`ReactiveMap`/`CellMap`/`SlotMap`) and
/// `lazily-rs/src/reconcile.rs` (LIS), with `lazily-kt` and `lazily-js` as
/// cross-checks.

import 'core.dart';

/// Which kind of reactive node a [ReactiveMap] entry is — the handle-kind axis
/// the map abstracts over.
///
/// Mirrors `EntryKind` in `lazily-rs::cell_family` and `lazily-formal`'s
/// `Materialization` module.
enum EntryKind {
  /// An **input** cell ([Cell]) — always materialized on access.
  cell,

  /// A **derived** slot ([Slot]) — materialized eagerly (pre-mint) or lazily on
  /// first read.
  slot,
}

/// A keyed reactive collection generic over the entry handle kind `H`: a map of
/// `K -> H` with reactive membership + order and independently-tracked per-entry
/// nodes (cell-model.md § Keyed cell collections, `#reactivemap`).
///
/// Each entry is an ordinary reactive node — its single-writer / multi-write
/// classification, `merge:` mechanism, and ingress rules are exactly those of
/// the cell model; the collection adds **no new merge unit**. A dedicated
/// membership cell tracks the set of keys, and a dedicated order cell tracks the
/// ordered key list. Reads subscribe through those cells so the three planes
/// stay independent.
///
/// Reactive binding (mirrors `lazily-rs::ReactiveMap`): a [keys] reader
/// subscribes only to the order signal; a [len] / [containsKey] reader
/// subscribes only to the membership signal; a value reader subscribes only to
/// that entry's node. An atomic move ([moveTo] / [moveBefore] / [moveAfter])
/// bumps only the order signal once and keeps the moved entry's same handle,
/// dependents, and lineage (it is not a remove + re-mint).
///
/// The two specializations a binding exposes are [CellMap] (input cells) and
/// [SlotMap] (derived slots). Subclasses supply the handle-kind operations
/// ([_materializeHandle] / [_observeHandle] / [_clearHandle] / [entryKind]) —
/// the Dart form of the `MapHandle` trait.
abstract class ReactiveMap<K, V, H> {
  ReactiveMap(this.ctx)
      : _membership = Cell<int>(ctx, 0),
        _orderSignal = Cell<int>(ctx, 0);

  final Context ctx;
  final Map<K, H> _entries = {};
  final List<K> _order = [];

  /// Reactive *set-membership* signal: a monotonic version bumped only when the
  /// **set** of keys changes (add/remove).
  final Cell<int> _membership;

  /// Reactive *order* signal: bumped on add/remove **and on move/reorder**.
  final Cell<int> _orderSignal;

  int _membershipVersion = 0;
  int _orderVersion = 0;

  // --- MapHandle abstraction (supplied per specialization) ---

  /// This map's entry kind ([EntryKind.cell] for a [CellMap], [EntryKind.slot]
  /// for a [SlotMap]).
  EntryKind get entryKind;

  /// Allocate the node for one entry, with [compute] producing its canonical
  /// value. An input cell sets its value directly; a derived slot wraps
  /// [compute] as its recomputation.
  H _materializeHandle(V Function() compute);

  /// Read [handle]'s value through its owning context (subscribes the caller,
  /// as any cell/slot read does).
  V _observeHandle(H handle);

  /// Detach [handle]'s node from the graph on removal — clear its cached value
  /// and its dependents.
  void _clearHandle(H handle);

  /// Bump only the order signal (invalidates [keys] readers). A pure move
  /// bumps only this.
  void _bumpOrder() {
    _orderVersion += 1;
    _orderSignal.value = _orderVersion;
  }

  /// Bump set-membership (invalidates [len] / [containsKey] readers), then the
  /// order signal too (the key set changed, so the ordered list changed too).
  void _bumpMembership() {
    _membershipVersion += 1;
    _membership.value = _membershipVersion;
    _bumpOrder();
  }

  /// Mint the entry node for [key] on first access (via [_materializeHandle]
  /// with [compute] as its value producer), caching the handle and bumping
  /// reactive membership. Re-minting an existing key returns the cached handle.
  H _mintWith(K key, V Function() compute) {
    final existing = _entries[key];
    if (existing != null) return existing;
    final handle = _materializeHandle(compute);
    _entries[key] = handle;
    _order.add(key);
    _bumpMembership();
    return handle;
  }

  /// Get the value at [key], minting the entry via [factory] first if absent —
  /// the mint-on-access recipe. For a [SlotMap] this is the **lazy
  /// materialization** pull; for a [CellMap] it seeds an input cell.
  ///
  /// Bumps reactive membership only on insert; an existing key returns its
  /// current value without re-running [factory].
  V getOrInsertWith(K key, V Function(K key) factory) {
    final existing = _entries[key];
    if (existing != null) return _observeHandle(existing);
    return _observeHandle(_mintWith(key, () => factory(key)));
  }

  /// The existing entry handle for [key], or `null`. Non-reactive: does not
  /// subscribe the caller to membership.
  H? handle(K key) => _entries[key];

  /// Remove [key]'s entry. Bumps reactive membership and clears the removed
  /// entry's dependents. Returns whether the key was present.
  ///
  /// The orphaned node stops driving any dependents; the runtime exposes no
  /// node-recycle yet (mirrors `lazily-rs`).
  bool remove(K key) {
    final removed = _entries.remove(key);
    if (removed == null) return false;
    _order.remove(key);
    _clearHandle(removed);
    _bumpMembership();
    return true;
  }

  /// Reactive snapshot of the keys in their current order. Subscribes the
  /// caller to **order** changes (add/remove **and move/reorder**), not to
  /// per-entry value changes.
  List<K> keys() {
    // Subscribe to the order signal.
    _orderSignal.value;
    return List<K>.of(_order);
  }

  /// The currently-materialized (present) keys, in first-materialization order.
  /// Non-reactive; the present set only grows (deferral, not de-allocation).
  List<K> presentKeys() => List<K>.of(_order);

  /// Number of currently-materialized (present) entries. Non-reactive.
  int presentCount() => _order.length;

  /// Whether [key] is currently materialized (present in the allocated set).
  /// Non-reactive.
  bool isPresent(K key) => _entries.containsKey(key);

  /// Current 0-based position of [key] in the order, or `null` if absent.
  /// Non-reactive.
  int? position(K key) {
    for (var i = 0; i < _order.length; i++) {
      if (_order[i] == key) return i;
    }
    return null;
  }

  /// Atomically move [key] to [index] in the order (`#lzcellmove`).
  ///
  /// This is the *atomic, optimized* reorder: the entry keeps the **same** node,
  /// the same dependents, and its CRDT lineage — unlike the naive `remove` +
  /// re-mint which re-allocates the node and bumps membership twice. Only the
  /// order signal is bumped (once), so [keys] readers recompute but [len] /
  /// [containsKey] readers stay cached.
  ///
  /// [index] is clamped to `[0, len)`. A no-op move (already at position) bumps
  /// nothing. Returns whether [key] was present.
  bool moveTo(K key, int index) {
    final from = position(key);
    if (from == null) return false;
    final to = index.clamp(0, _order.length - 1);
    if (from == to) return true;
    _order.removeAt(from);
    _order.insert(to, key);
    _bumpOrder();
    return true;
  }

  /// Atomically move [key] to just before [anchor] (`#lzcellmove`). Returns
  /// whether the move could be expressed.
  bool moveBefore(K key, K anchor) {
    final anchorIdx = position(anchor);
    if (anchorIdx == null) return false;
    final from = position(key);
    if (from == null) return false;
    // Removing `key` first shifts `anchor` left by one when key precedes it.
    final target = from < anchorIdx ? anchorIdx - 1 : anchorIdx;
    return moveTo(key, target);
  }

  /// Atomically move [key] to just after [anchor] (`#lzcellmove`).
  bool moveAfter(K key, K anchor) {
    final anchorIdx = position(anchor);
    if (anchorIdx == null) return false;
    final from = position(key);
    if (from == null) return false;
    final target = from <= anchorIdx ? anchorIdx : anchorIdx + 1;
    return moveTo(key, target);
  }

  /// Reactive entry count. Subscribes the caller to membership changes only.
  int len() {
    _membership.value;
    return _order.length;
  }

  /// Reactive emptiness check. Subscribes the caller to membership changes.
  bool get isEmpty => len() == 0;

  /// Reactive membership test for [key]. Subscribes the caller to membership
  /// changes (add/remove of any key), not to value changes.
  bool containsKey(K key) {
    _membership.value;
    return _entries.containsKey(key);
  }

  /// Non-reactive count. Does not subscribe the caller to anything.
  int get lenUntracked => _order.length;
}

/// A keyed **input-cell** collection: every entry is a settable [Cell] (the
/// [CellMap] specialization of [ReactiveMap], `H = Cell<V>`).
///
/// Adds cell-only [set] and eager value-minting ([entry] / [entryWith]) on top
/// of the shared reactive keyed surface. Mirrors `lazily-rs::CellMap`.
class CellMap<K, V> extends ReactiveMap<K, V, Cell<V>> {
  CellMap(super.ctx);

  @override
  EntryKind get entryKind => EntryKind.cell;

  @override
  // An input has no derivation: materialize by setting its value directly.
  Cell<V> _materializeHandle(V Function() compute) => Cell<V>(ctx, compute());

  @override
  V _observeHandle(Cell<V> handle) => handle.value;

  @override
  // Invalidate the orphaned cell's dependents (mirrors lazily-rs
  // `CellHandle::clear_dependents`).
  void _clearHandle(Cell<V> handle) => handle.invalidate();

  /// Return the value cell for [key], minting it with [defaultValue] on first
  /// access. Adding a new key bumps reactive membership; re-fetching an existing
  /// key does not. Cell-only: eager value-minting has no derived-slot analog.
  Cell<V> entryWith(K key, V Function() defaultValue) =>
      _mintWith(key, defaultValue);

  /// Return the value cell for [key], minting it with [defaultValue] on first
  /// access. Convenience wrapper over [entryWith].
  Cell<V> entry(K key, V defaultValue) => entryWith(key, () => defaultValue);

  /// The existing value cell for [key], or `null`. Non-reactive: does not
  /// subscribe the caller to membership. Alias for [handle].
  Cell<V>? cell(K key) => handle(key);

  /// Read the value at [key] if present, without registering a dependency
  /// (non-reactive peek).
  V? get(K key) => handle(key)?.peek;

  /// Read the value at [key] if present, subscribing the caller to that entry's
  /// cell (reactive inside a Slot / Signal computation).
  V? read(K key) {
    final h = handle(key);
    return h == null ? null : h.value;
  }

  /// Set the value at [key], inserting a new entry (and bumping membership) if
  /// it does not exist yet. Updating an existing entry leaves membership
  /// untouched and invalidates only that entry's dependents.
  ///
  /// Cell-only: an input is settable; a derived [SlotMap] slot is not.
  void set(K key, V value) {
    final h = handle(key);
    if (h != null) {
      h.value = value;
      return;
    }
    entryWith(key, () => value);
  }

  /// Insert [key] with [value] at [index], the end, or relative to [anchor].
  /// Bumps membership + order. Returns whether the key was newly inserted
  /// (false if it already existed; in that case the value is updated in place
  /// and only the entry's value readers invalidate).
  bool insert(K key, V value, {InsertAt at = InsertAt.end, K? anchor}) {
    if (_entries.containsKey(key)) {
      set(key, value);
      return false;
    }
    entryWith(key, () => value);
    switch (at) {
      case InsertAt.end:
        break; // already at end
      case InsertAt.at:
        // move handled below if index provided via anchor-less variant
        break;
      case InsertAt.before:
        if (anchor != null) moveBefore(key, anchor);
        break;
      case InsertAt.after:
        if (anchor != null) moveAfter(key, anchor);
        break;
    }
    return true;
  }

  /// Reconcile to [targetOrder] + [targetValues]: compute the minimal diff and
  /// apply it per-cell. Stable entries (unchanged value, in the LIS) keep their
  /// cell handles and stay cached.
  void reconcile(List<K> targetOrder, Map<K, V> targetValues) {
    final prior = [
      for (final k in _order) MapEntry(k, get(k) as V),
    ];
    final target = [
      for (final k in targetOrder) MapEntry(k, targetValues[k] as V),
    ];
    final ops = reconcileDiff(prior, target);
    for (final op in ops) {
      switch (op) {
        case DiffOpInsert():
          insert(op.key, op.value);
        case DiffOpRemove():
          remove(op.key);
        case DiffOpMove():
          moveTo(op.key, op.to);
        case DiffOpUpdate():
          set(op.key, op.value);
      }
    }
  }
}

/// A keyed **derived-slot** collection: every entry is a [Slot] whose value is
/// derived (the [SlotMap] specialization of [ReactiveMap], `H = Slot<V>`).
///
/// [ReactiveMap.getOrInsertWith] mints a slot on first access (**lazy
/// materialization**); [materializeAll] pre-mints the keyset (**eager**). A
/// slot's value is derived, so `SlotMap` has **no `set`**. There is **no
/// eager/lazy mode flag** — eager is the pre-mint loop, lazy is mint-on-access.
/// Mirrors `lazily-rs::SlotMap`.
class SlotMap<K, V> extends ReactiveMap<K, V, Slot<V>> {
  SlotMap(super.ctx);

  @override
  EntryKind get entryKind => EntryKind.slot;

  @override
  // A derived node: the same node an eager pre-mint would allocate.
  Slot<V> _materializeHandle(V Function() compute) =>
      Slot<V>(ctx, (_) => compute());

  @override
  V _observeHandle(Slot<V> handle) => handle.call();

  @override
  void _clearHandle(Slot<V> handle) => handle.clearDependents();

  /// Read the value at [key] if present (a derived-slot read, subscribing the
  /// caller), or `null` if the key is not materialized.
  V? get(K key) {
    final h = handle(key);
    return h == null ? null : _observeHandle(h);
  }

  /// **Eager materialization**: pre-mint a derived slot for every key in [keys]
  /// via [factory], up front. Observationally identical to minting each key
  /// lazily on first read ([ReactiveMap.getOrInsertWith]) — it only changes
  /// *when* the nodes are allocated.
  void materializeAll(Iterable<K> keys, V Function(K key) factory) {
    for (final key in keys) {
      getOrInsertWith(key, factory);
    }
  }
}

/// Position specifier for [CellMap.insert] (mirrors `lazily-kt::InsertAt`).
enum InsertAt {
  /// Append at the end (default).
  end,
  /// At an absolute index (use [CellMap.moveTo] after insert to position).
  at,
  /// Just before [anchor].
  before,
  /// Just after [anchor].
  after;
}

/// A keyed reconciliation op (cell-model.md § Keyed reconciliation).
///
/// Diffs two keyed sequences **by stable key, not position**, emitting the
/// minimal `{insert, remove, move, update}` op set. Reordering is
/// move-minimized: keys already in relative order — the longest-increasing
/// subsequence over their prior indices — do **not** move; only the remainder
/// emit a move.
sealed class DiffOp<K, V> {
  const DiffOp();
}

/// Insert a brand-new key (not present in `prior`) at [index] (the final
/// position in the target sequence).
final class DiffOpInsert<K, V> extends DiffOp<K, V> {
  const DiffOpInsert(this.key, this.value, this.index);
  final K key;
  final V value;
  final int index;

  @override
  bool operator ==(Object other) =>
      other is DiffOpInsert<K, V> &&
      other.key == key &&
      other.value == value &&
      other.index == index;

  @override
  int get hashCode => Object.hash('Insert', key, value, index);

  @override
  String toString() => 'Insert($key @ $index)';
}

/// Remove a key present in `prior` but absent in `target`.
final class DiffOpRemove<K, V> extends DiffOp<K, V> {
  const DiffOpRemove(this.key);
  final K key;

  @override
  bool operator ==(Object other) =>
      other is DiffOpRemove<K, V> && other.key == key;

  @override
  int get hashCode => Object.hash('Remove', key);

  @override
  String toString() => 'Remove($key)';
}

/// Atomic-move a common key from its prior position to [to] (target index).
/// Keeps the entry's same cell handle, dependents, and lineage.
final class DiffOpMove<K, V> extends DiffOp<K, V> {
  const DiffOpMove(this.key, this.to);
  final K key;
  final int to;

  @override
  bool operator ==(Object other) =>
      other is DiffOpMove<K, V> && other.key == key && other.to == to;

  @override
  int get hashCode => Object.hash('Move', key, to);

  @override
  String toString() => 'Move($key -> $to)';
}

/// Update an existing key's value (PartialEq-guarded at the cell).
final class DiffOpUpdate<K, V> extends DiffOp<K, V> {
  const DiffOpUpdate(this.key, this.value);
  final K key;
  final V value;

  @override
  bool operator ==(Object other) =>
      other is DiffOpUpdate<K, V> && other.key == key && other.value == value;

  @override
  int get hashCode => Object.hash('Update', key, value);

  @override
  String toString() => 'Update($key)';
}

/// The move-minimized keyed reconciliation (cell-model.md § Keyed
/// reconciliation).
///
/// Emits removes → inserts + moves (in target order) → updates. Moves are
/// move-minimized: the longest-increasing-subsequence (LIS) over prior indices
/// of the common keys is held fixed, and only the remainder move. O(n log n)
/// via patience sorting (strictly increasing), mirroring
/// `lazily-rs/src/reconcile.rs::longest_increasing_subsequence`.
List<DiffOp<K, V>> reconcileDiff<K, V>(
  List<MapEntry<K, V>> prior,
  List<MapEntry<K, V>> target,
) {
  final priorIndex = <K, int>{};
  final priorValue = <K, V>{};
  for (var i = 0; i < prior.length; i++) {
    final k = prior[i].key;
    priorIndex[k] = i;
    priorValue[k] = prior[i].value;
  }
  final targetValue = <K, V>{};
  for (final e in target) {
    targetValue[e.key] = e.value;
  }

  // Removes: keys in prior not in target.
  final removes = <DiffOpRemove<K, V>>[];
  final removed = <K>{};
  for (final e in prior) {
    if (!targetValue.containsKey(e.key)) {
      removes.add(DiffOpRemove<K, V>(e.key));
      removed.add(e.key);
    }
  }

  // Common keys in target order, with their prior indices (for the LIS).
  final commonKeys = <K>[];
  final priorIdxSeq = <int>[];
  for (final e in target) {
    if (priorIndex.containsKey(e.key)) {
      commonKeys.add(e.key);
      priorIdxSeq.add(priorIndex[e.key]!);
    }
  }
  // Index each common key → its position in commonKeys once, so the move loop
  // below is O(1) per common key instead of O(N) `commonKeys.indexOf(k)`
  // (`#lzdartreconcileidx`; drops the move-minimization inner loop from O(N²)
  // to O(N) on top of the O(N log N) LIS).
  final commonIdxByKey = <K, int>{
    for (var i = 0; i < commonKeys.length; i++) commonKeys[i]: i,
  };
  final stableSet = <int>{}; // indices into commonKeys held fixed by the LIS
  for (final i in _longestIncreasingSubsequence(priorIdxSeq)) {
    stableSet.add(i);
  }

  // Inserts + moves: walk target left-to-right, tracking the next free final
  // position. Inserts mint new keys at their final index; common keys either
  // stay (LIS) or move to their final index.
  final insertsAndMoves = <DiffOp<K, V>>[];
  final targetPosByKey = <K, int>{};
  for (var ti = 0; ti < target.length; ti++) {
    final k = target[ti].key;
    targetPosByKey[k] = ti;
  }
  for (var ti = 0; ti < target.length; ti++) {
    final e = target[ti];
    final k = e.key;
    if (!priorIndex.containsKey(k)) {
      // Brand-new key: insert.
      insertsAndMoves.add(DiffOpInsert<K, V>(k, e.value, ti));
    } else {
      // Common key: move unless it is in the LIS (already in relative order).
      final commonIdx = commonIdxByKey[k]!;
      if (!stableSet.contains(commonIdx)) {
        insertsAndMoves.add(DiffOpMove<K, V>(k, ti));
      }
    }
  }

  // Updates: common keys whose value changed.
  final updates = <DiffOpUpdate<K, V>>[];
  for (final e in target) {
    final k = e.key;
    final pv = priorValue[k];
    if (pv != null && pv != e.value) {
      updates.add(DiffOpUpdate<K, V>(k, e.value));
    }
  }

  return <DiffOp<K, V>>[
    ...removes,
    ...insertsAndMoves,
    ...updates,
  ];
}

/// Patience-sort LIS (strictly increasing), O(n log n).
///
/// Mirrors `lazily-rs/src/reconcile.rs::longest_increasing_subsequence`.
/// Returns the indices (into [seq]) of a longest strictly-increasing
/// subsequence, in ascending order.
List<int> _longestIncreasingSubsequence(List<int> seq) {
  final n = seq.length;
  if (n == 0) return const [];
  final tails = <int>[]; // tails[k] = index into seq of smallest tail of IS len k+1
  final prev = List<int>.filled(n, -1);
  for (var i = 0; i < n; i++) {
    var lo = 0;
    var hi = tails.length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (seq[tails[mid]] < seq[i]) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo > 0) prev[i] = tails[lo - 1];
    if (lo == tails.length) {
      tails.add(i);
    } else {
      tails[lo] = i;
    }
  }
  if (tails.isEmpty) return const [];
  final res = <int>[];
  var k = tails.last;
  while (k != -1) {
    res.add(k);
    k = prev[k];
  }
  return res.reversed.toList(growable: false);
}

/// An ordered keyed tree (cell-model.md § Ordered keyed tree).
///
/// Each node is `(stable id, value cell, ordered keyed child collection)`. A
/// node's children are a [CellMap] keyed by child id, so per-level
/// membership/order reactivity and the atomic-move guarantee are inherited.
/// The tree is still a composition of cells — not a new cell kind — so per-cell
/// merge applies node-by-node.
///
/// Mirrors `lazily-rs/src/cell_tree.rs` (recursive) and `lazily-js::CellTree`
/// (path-based). This Dart port is recursive like Rust.
class CellTree<K, V> {
  CellTree(this.ctx, this.id, V initialValue)
      : value = Cell<V>(ctx, initialValue),
        children = CellMap<K, CellTree<K, V>>(ctx);

  final Context ctx;
  final K id;
  final Cell<V> value;
  final CellMap<K, CellTree<K, V>> children;

  /// Read this node's value (reactive).
  V get() => value.value;

  /// Set this node's value (PartialEq-guarded).
  void set(V next) {
    value.value = next;
  }

  /// The id of this node (stable handle).
  K get nodeId => id;

  /// Insert a fresh child [id] with [value], returning the child node. If the
  /// child already exists, its value is updated and the existing node returned.
  CellTree<K, V> insertChild(K id, V value) {
    final existing = children.cell(id);
    if (existing != null) {
      existing.peek.set(value);
      return existing.peek;
    }
    final child = CellTree<K, V>(ctx, id, value);
    children.set(id, child);
    return child;
  }

  /// The child node for [id], or `null`. Non-reactive.
  CellTree<K, V>? child(K id) => children.get(id);

  /// Remove the child [id]. Returns whether it was present.
  bool removeChild(K id) => children.remove(id);

  /// Atomically move child [id] to [index] within this node's children.
  bool moveChildTo(K id, int index) => children.moveTo(id, index);

  /// Atomically move child [id] to just before [anchor].
  bool moveChildBefore(K id, K anchor) => children.moveBefore(id, anchor);

  /// Atomically move child [id] to just after [anchor].
  bool moveChildAfter(K id, K anchor) => children.moveAfter(id, anchor);

  /// Reactive snapshot of this node's child ids in order.
  List<K> childIds() => children.keys();

  /// Reactive child count for this node.
  int childCount() => children.len();

  /// Reactive membership test for a child of this node.
  bool hasChild(K id) => children.containsKey(id);
}
