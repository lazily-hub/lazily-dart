/// Fugue/RGA-style free-text character CRDT.
///
/// Each character is an element with a unique [OpId] (counter, peer) and a
/// left-origin. Deletes are sticky tombstones carrying the delete op's own id.
/// Order is a pure deterministic function of the element set: pre-order DFS of
/// the origin tree, siblings sorted **descending** by [OpId] (most-recent
/// first). Merge is commutative, associative, idempotent; concurrent same-point
/// inserts keep both, ordered by peer tiebreak.
///
/// Mirrors `lazily-js/src/text-crdt.js` and `lazily-rs` `TextCrdt`. Conforms
/// to `lazily-spec` `conformance/collections/textcrdt_convergence.json` and
/// `textcrdt_delta_sync.json` (`#lztextsync`).
library;

import 'crdt_tree.dart';

/// A globally-unique operation identifier for a character CRDT op.
///
/// Ordered ascending by `(counter, peer)` so that later ops sort after earlier
/// ones from the same peer, and ties between peers break deterministically.
class OpId implements Comparable<OpId> {
  const OpId(this.counter, this.peer);

  final int counter;
  final int peer;

  @override
  @pragma('vm:prefer-inline')
  int compareTo(OpId other) {
    final c = counter.compareTo(other.counter);
    if (c != 0) return c;
    return peer.compareTo(other.peer);
  }

  /// Descending comparator (most-recent first).
  static int desc(OpId a, OpId b) => b.compareTo(a);

  @override
  bool operator ==(Object other) =>
      other is OpId && counter == other.counter && peer == other.peer;

  @override
  int get hashCode => Object.hash(counter, peer);

  @override
  String toString() => 'OpId($counter,$peer)';

  Map<String, dynamic> toWire() => {'counter': counter, 'peer': peer};

  static OpId fromWire(Object? v) {
    final m = v as Map<String, dynamic>;
    return OpId(m['counter'] as int, m['peer'] as int);
  }
}

class _TextElem {
  _TextElem(this.id, this.ch, this.origin, this.deleted);
  // `id` stored on the elem so iteration over map values recovers the OpId
  // without re-parsing a string key (#lzopidkeytuple).
  final OpId id;
  final String ch; // single code point
  final OpId? origin; // null = document start
  OpId? deleted; // the delete op id; null = live

  _TextElem copy() => _TextElem(id, ch, origin, deleted);
}

/// A single text-CRDT operation in delta-sync wire form.
class TextOp {
  TextOp({required this.id, required this.ch, this.origin, this.deleted});

  final OpId id;
  final String ch;
  final OpId? origin;
  final OpId? deleted;

  Map<String, dynamic> toWire() => <String, dynamic>{
        'id': id.toWire(),
        'ch': ch,
        'origin': origin?.toWire(),
        'deleted': deleted?.toWire(),
      };

  static TextOp fromWire(Object? v) {
    final m = v as Map<String, dynamic>;
    return TextOp(
      id: OpId.fromWire(m['id']),
      ch: m['ch'] as String,
      origin: m['origin'] != null ? OpId.fromWire(m['origin']) : null,
      deleted: m['deleted'] != null ? OpId.fromWire(m['deleted']) : null,
    );
  }
}

/// A Fugue/RGA-style free-text character CRDT.
class TextCrdt implements CrdtTree<Map<int, int>, List<TextOp>, String> {
  TextCrdt(this._peer);
  final int _peer;
  int _counter = 0;

  // Element map keyed by the Dart 3 record `(counter, peer)` — value semantics
  // gives correct `==`/`hashCode` for free, eliminating the per-lookup string
  // allocation + per-traversal string parse the previous `Map<String, _TextElem>`
  // paid (#lzopidkeytuple).
  final Map<(int, int), _TextElem> _elems = {};

  // Cached visible orderings (#lztextordcache). Both null after every mutation;
  // populated lazily on the next read. Repeated text() / len() between
  // mutations drops O(N log N) -> O(1) (after the first rebuild) instead of
  // rebuilding per call.
  List<OpId>? _orderedLiveCache;
  List<OpId>? _orderedAllCache;

  /// The peer id of this replica.
  int get peer => _peer;

  /// Seed a new CRDT from [str] as if a single peer typed it sequentially.
  static TextCrdt fromStr(int peer, String str) {
    final crdt = TextCrdt(peer);
    crdt.insertStr(0, str);
    return crdt;
  }

  OpId _nextId() {
    _counter++;
    return OpId(_counter, _peer);
  }

  void _invalidateOrdered() {
    _orderedLiveCache = null;
    _orderedAllCache = null;
  }

  /// Visible ordering (pre-order DFS of the origin tree, siblings descending
  /// by OpId).
  List<OpId> _orderedIds({bool includeDeleted = false}) {
    // Cache hit (#lztextordcache).
    if (includeDeleted) {
      if (_orderedAllCache != null) return _orderedAllCache!;
    } else {
      if (_orderedLiveCache != null) return _orderedLiveCache!;
    }

    final byOrigin = <(int, int)?, List<OpId>>{};
    for (final elem in _elems.values) {
      final originKey = elem.origin == null
          ? null
          : (elem.origin!.counter, elem.origin!.peer);
      (byOrigin[originKey] ??= <OpId>[]).add(elem.id);
    }
    for (final list in byOrigin.values) {
      list.sort(OpId.desc);
    }

    final out = <OpId>[];
    void dfs((int, int)? originKey) {
      final kids = byOrigin[originKey];
      if (kids == null) return;
      for (final id in kids) {
        final elem = _elems[(id.counter, id.peer)]!;
        if (includeDeleted || elem.deleted == null) {
          out.add(id);
        }
        dfs((id.counter, id.peer));
      }
    }

    dfs(null);
    if (includeDeleted) {
      _orderedAllCache = out;
    } else {
      _orderedLiveCache = out;
    }
    return out;
  }

  /// Insert a single character [ch] at the visible [index].
  void insert(int index, String ch) {
    final visible = _orderedIds();
    final OpId? origin = index == 0
        ? null
        : (index - 1 < visible.length ? visible[index - 1] : null);
    final id = _nextId();
    _invalidateOrdered();
    _elems[(id.counter, id.peer)] = _TextElem(id, ch, origin, null);
  }

  /// Insert a multi-character [str] at the visible [index] with origin chaining
  /// (#lztextinsertchain): one `_orderedIds()` pass + N chain appends instead
  /// of N full-tree rebuilds. Sequential chars chain naturally — char i+1's
  /// left-origin is char i's just-minted OpId — so DFS visits them in chain
  /// order (counter strictly increases under one peer). Concurrent inserts at
  /// the same point still sort by peer tiebreak (standard CRDT convergence).
  void insertStr(int index, String str) {
    final visible = _orderedIds();
    OpId? origin = index == 0
        ? null
        : (index - 1 < visible.length ? visible[index - 1] : null);
    _invalidateOrdered();
    for (final ch in str.runes) {
      final id = _nextId();
      _elems[(id.counter, id.peer)] = _TextElem(id, String.fromCharCode(ch), origin, null);
      origin = id; // chain: next char's left-origin is this id
    }
  }

  /// Delete the visible character at [index]. No-op if out of range.
  void delete(int index) {
    final visible = _orderedIds();
    if (index < 0 || index >= visible.length) return;
    final id = visible[index];
    final elem = _elems[(id.counter, id.peer)]!;
    final del = _nextId();
    if (elem.deleted == null) {
      elem.deleted = del;
      // Tombstone flip changes the live (filtered) ordering but not the full
      // DFS — only invalidate the live cache.
      _orderedLiveCache = null;
    }
  }

  /// The visible text.
  @override
  String text() {
    final sb = StringBuffer();
    for (final id in _orderedIds()) {
      sb.write(_elems[(id.counter, id.peer)]!.ch);
    }
    return sb.toString();
  }

  /// Count of live (non-deleted) elements — O(N) fold, no list allocation
  /// (#lzcrdtlenfold).
  int len() {
    var n = 0;
    for (final elem in _elems.values) {
      if (elem.deleted == null) n++;
    }
    return n;
  }

  /// Whether there are no live elements (snake_case to match lazily-rs).
  bool get is_empty => len() == 0;

  /// Idiomatic Dart alias for [is_empty].
  bool get isEmpty => is_empty;

  /// Count of tombstoned (deleted) elements — O(N) fold (#lzcrdtlenfold).
  int tombstoneCount() {
    var n = 0;
    for (final elem in _elems.values) {
      if (elem.deleted != null) n++;
    }
    return n;
  }

  /// The current clock position.
  OpId clock() => OpId(_counter, _peer);

  /// Deep-copy this replica with a new [peer], adopting the same element set
  /// and copying the counter so future ops don't collide with prior ones.
  TextCrdt fork(int peer) {
    final copy = TextCrdt(peer);
    copy._counter = _counter;
    for (final elem in _elems.values) {
      copy._elems[(elem.id.counter, elem.id.peer)] = elem.copy();
    }
    return copy;
  }

  /// Deep-copy with the same peer.
  TextCrdt clone() => fork(_peer);

  /// State-based merge. Returns whether the visible text changed.
  bool merge(TextCrdt other) {
    final before = text();
    var anyChange = false;
    for (final oe in other._elems.values) {
      if (_mergeElem(oe.id, oe)) anyChange = true;
    }
    if (anyChange) _invalidateOrdered();
    return text() != before;
  }

  /// The visible lossless-tree value.
  @override
  String value() => text();

  /// Join [other] through the identity-preserving delta path.
  @override
  bool mergeFrom(CrdtTree<Map<int, int>, List<TextOp>, String> other) =>
      applyDelta(other.deltaSince(versionVector()));

  bool _mergeElem(OpId id, _TextElem oe) {
    // Inline max (avoids `[a, b, c].reduce(...)` alloc — audit Q2).
    final observedMax = id.counter > (oe.deleted?.counter ?? 0)
        ? id.counter
        : (oe.deleted?.counter ?? 0);
    _counter = _counter > observedMax ? _counter : observedMax;
    final key = (id.counter, id.peer);
    final existing = _elems[key];
    if (existing != null) {
      if (existing.deleted != null && oe.deleted != null) {
        // Concurrent deletes → smaller delete id wins (sticky on both).
        if (oe.deleted!.compareTo(existing.deleted!) < 0) {
          existing.deleted = oe.deleted;
          return true;
        }
        return false;
      } else if (oe.deleted != null && existing.deleted == null) {
        existing.deleted = oe.deleted;
        return true;
      }
      return false;
    } else {
      _elems[key] = _TextElem(id, oe.ch, oe.origin, oe.deleted);
      return true;
    }
  }

  /// GC stable tombstones. An element is collectable when it is deleted, the
  /// caller confirms its delete is stable, AND nothing references it as a
  /// left-origin. Returns the number removed.
  int gcWith(bool Function(OpId deleteOpId) isStable) {
    var removed = 0;
    while (true) {
      final referenced = <(int, int)>{};
      for (final e in _elems.values) {
        if (e.origin != null) referenced.add((e.origin!.counter, e.origin!.peer));
      }
      final collectable = <(int, int)>[];
      for (final entry in _elems.entries) {
        final e = entry.value;
        if (e.deleted != null &&
            isStable(e.deleted!) &&
            !referenced.contains(entry.key)) {
          collectable.add(entry.key);
        }
      }
      if (collectable.isEmpty) break;
      for (final k in collectable) {
        _elems.remove(k);
        removed++;
      }
    }
    if (removed > 0) _invalidateOrdered();
    return removed;
  }

  // --- Delta sync (#lztextsync) ---

  /// Version vector: `{peer → max counter}` over both insert ids and tombstone
  /// delete ids. Absent peer = 0.
  @override
  Map<int, int> versionVector() {
    final vv = <int, int>{};
    void bump(OpId id) => vv[id.peer] =
        (vv[id.peer] ?? 0) > id.counter ? vv[id.peer]! : id.counter;

    for (final elem in _elems.values) {
      bump(elem.id);
      final del = elem.deleted;
      if (del != null) bump(del);
    }
    return vv;
  }

  /// Elements whose insert id or tombstone delete id is newer than [theirVv].
  /// A whole-state snapshot is `deltaSince({})`.
  @override
  List<TextOp> deltaSince(Map<int, int> theirVv) {
    bool seen(OpId id) => id.counter <= (theirVv[id.peer] ?? 0);
    final out = <TextOp>[];
    for (final elem in _elems.values) {
      final id = elem.id;
      final insertNew = !seen(id);
      final deleteNew = elem.deleted != null && !seen(elem.deleted!);
      if (insertNew || deleteNew) {
        out.add(TextOp(id: id, ch: elem.ch, origin: elem.origin, deleted: elem.deleted));
      }
    }
    return out;
  }

  /// Apply a delta. Same commutative/associative/idempotent algebra as [merge].
  /// Returns whether the visible text changed.
  @override
  bool applyDelta(List<TextOp> ops) {
    final before = text();
    var anyChange = false;
    for (final op in ops) {
      if (_mergeElem(op.id, _TextElem(op.id, op.ch, op.origin, op.deleted))) {
        anyChange = true;
      }
    }
    if (anyChange) _invalidateOrdered();
    return text() != before;
  }
}
