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

/// A globally-unique operation identifier for a character CRDT op.
///
/// Ordered ascending by `(counter, peer)` so that later ops sort after earlier
/// ones from the same peer, and ties between peers break deterministically.
class OpId implements Comparable<OpId> {
  const OpId(this.counter, this.peer);

  final int counter;
  final int peer;

  @override
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

  String get _key => '$counter:$peer';

  static OpId _fromKey(String k) {
    final i = k.indexOf(':');
    return OpId(int.parse(k.substring(0, i)), int.parse(k.substring(i + 1)));
  }
}

class _TextElem {
  _TextElem(this.ch, this.origin, this.deleted);
  final String ch; // single code point
  final OpId? origin; // null = document start
  OpId? deleted; // the delete op id; null = live

  _TextElem copy() => _TextElem(ch, origin, deleted);
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
class TextCrdt {
  TextCrdt(this._peer);
  final int _peer;
  int _counter = 0;

  final Map<String, _TextElem> _elems = {};

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

  /// Visible ordering (pre-order DFS of the origin tree, siblings descending
  /// by OpId).
  List<OpId> _orderedIds({bool includeDeleted = false}) {
    final byOrigin = <String, List<OpId>>{};
    for (final entry in _elems.entries) {
      final id = OpId._fromKey(entry.key);
      final ok = entry.value.origin?._key ?? '<root>';
      (byOrigin[ok] ??= <OpId>[]).add(id);
    }
    for (final list in byOrigin.values) {
      list.sort(OpId.desc);
    }

    final out = <OpId>[];
    void dfs(String originKey) {
      final kids = byOrigin[originKey];
      if (kids == null) return;
      for (final id in kids) {
        final elem = _elems[id._key]!;
        if (includeDeleted || elem.deleted == null) {
          out.add(id);
        }
        dfs(id._key);
      }
    }

    dfs('<root>');
    return out;
  }

  /// Insert a single character [ch] at the visible [index].
  void insert(int index, String ch) {
    final visible = _orderedIds();
    final OpId? origin =
        index == 0 ? null : (index - 1 < visible.length ? visible[index - 1] : null);
    final id = _nextId();
    _elems[id._key] = _TextElem(ch, origin, null);
  }

  /// Insert a multi-character [str] at the visible [index], iterating code points.
  void insertStr(int index, String str) {
    var i = index;
    for (final ch in str.runes) {
      insert(i, String.fromCharCode(ch));
      i++;
    }
  }

  /// Delete the visible character at [index]. No-op if out of range.
  void delete(int index) {
    final visible = _orderedIds();
    if (index < 0 || index >= visible.length) return;
    final id = visible[index];
    final elem = _elems[id._key]!;
    final del = _nextId();
    if (elem.deleted == null) {
      elem.deleted = del;
    }
  }

  /// The visible text.
  String text() {
    final sb = StringBuffer();
    for (final id in _orderedIds()) {
      sb.write(_elems[id._key]!.ch);
    }
    return sb.toString();
  }

  /// Count of live (non-deleted) elements.
  int len() => _orderedIds().length;

  /// Whether there are no live elements (snake_case to match lazily-rs).
  bool get is_empty => len() == 0;

  /// Idiomatic Dart alias for [is_empty].
  bool get isEmpty => is_empty;

  /// Count of tombstoned (deleted) elements.
  int tombstoneCount() => _elems.length - len();

  /// The current clock position.
  OpId clock() => OpId(_counter, _peer);

  /// Deep-copy this replica with a new [peer], adopting the same element set
  /// and copying the counter so future ops don't collide with prior ones.
  TextCrdt fork(int peer) {
    final copy = TextCrdt(peer);
    copy._counter = _counter;
    for (final entry in _elems.entries) {
      final e = entry.value;
      copy._elems[entry.key] = _TextElem(e.ch, e.origin, e.deleted);
    }
    return copy;
  }

  /// Deep-copy with the same peer.
  TextCrdt clone() => fork(_peer);

  /// State-based merge. Returns whether the visible text changed.
  bool merge(TextCrdt other) {
    final before = text();
    for (final entry in other._elems.entries) {
      _mergeElem(OpId._fromKey(entry.key), entry.value);
    }
    return text() != before;
  }

  void _mergeElem(OpId id, _TextElem oe) {
    _counter = [
      _counter,
      id.counter,
      oe.deleted?.counter ?? 0,
    ].reduce((a, b) => a > b ? a : b);
    final existing = _elems[id._key];
    if (existing != null) {
      if (existing.deleted != null && oe.deleted != null) {
        // Concurrent deletes → smaller delete id wins (sticky on both).
        if (oe.deleted!.compareTo(existing.deleted!) < 0) {
          existing.deleted = oe.deleted;
        }
      } else if (oe.deleted != null) {
        existing.deleted = oe.deleted;
      }
    } else {
      _elems[id._key] = _TextElem(oe.ch, oe.origin, oe.deleted);
    }
  }

  /// GC stable tombstones. An element is collectable when it is deleted, the
  /// caller confirms its delete is stable, AND nothing references it as a
  /// left-origin. Returns the number removed.
  int gcWith(bool Function(OpId deleteOpId) isStable) {
    var removed = 0;
    while (true) {
      final referenced = <String>{};
      for (final e in _elems.values) {
        if (e.origin != null) referenced.add(e.origin!._key);
      }
      final collectable = <String>[];
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
    return removed;
  }

  // --- Delta sync (#lztextsync) ---

  /// Version vector: `{peer → max counter}` over both insert ids and tombstone
  /// delete ids. Absent peer = 0.
  Map<int, int> versionVector() {
    final vv = <int, int>{};
    void bump(OpId id) =>
        vv[id.peer] = (vv[id.peer] ?? 0) > id.counter ? vv[id.peer]! : id.counter;

    for (final entry in _elems.entries) {
      final id = OpId._fromKey(entry.key);
      bump(id);
      final del = entry.value.deleted;
      if (del != null) bump(del);
    }
    return vv;
  }

  /// Elements whose insert id or tombstone delete id is newer than [theirVv].
  /// A whole-state snapshot is `deltaSince({})`.
  List<TextOp> deltaSince(Map<int, int> theirVv) {
    bool seen(OpId id) => id.counter <= (theirVv[id.peer] ?? 0);
    final out = <TextOp>[];
    for (final entry in _elems.entries) {
      final id = OpId._fromKey(entry.key);
      final e = entry.value;
      final insertNew = !seen(id);
      final deleteNew = e.deleted != null && !seen(e.deleted!);
      if (insertNew || deleteNew) {
        out.add(TextOp(id: id, ch: e.ch, origin: e.origin, deleted: e.deleted));
      }
    }
    return out;
  }

  /// Apply a delta. Same commutative/associative/idempotent algebra as [merge].
  /// Returns whether the visible text changed.
  bool applyDelta(List<TextOp> ops) {
    final before = text();
    for (final op in ops) {
      _mergeElem(op.id, _TextElem(op.ch, op.origin, op.deleted));
    }
    return text() != before;
  }
}
