/// Move-aware sequence CRDT, HLC, and LWW register.
///
/// Each element is **three independent LWW registers** — `value`, `position`
/// (fractional-index byte key + peer), `deleted` — each stamped by an [HlcStamp].
/// A move is a single LWW reassignment of the `position` register (not delete +
/// reinsert), so concurrent moves converge to the later stamp without
/// duplication. Order is the lexicographic total order on `(frac, peer)`.
///
/// Mirrors `lazily-js/src/seq-crdt.js` and `lazily-rs`. Conforms to
/// `lazily-spec` `conformance/collections/seqcrdt_convergence.json`.
library;

import 'dart:typed_data' show BytesBuilder, Uint8List;

/// A hybrid logical clock timestamp: `(wallTime, logical, peer)` total order.
class HlcStamp implements Comparable<HlcStamp> {
  const HlcStamp(this.wallTime, this.logical, this.peer);

  final int wallTime; // microseconds
  final int logical;
  final int peer;

  @override
  int compareTo(HlcStamp other) {
    final w = wallTime.compareTo(other.wallTime);
    if (w != 0) return w;
    final l = logical.compareTo(other.logical);
    if (l != 0) return l;
    return peer.compareTo(other.peer);
  }

  static HlcStamp max(HlcStamp a, HlcStamp b) => a.compareTo(b) >= 0 ? a : b;

  @override
  bool operator ==(Object other) =>
      other is HlcStamp &&
      wallTime == other.wallTime &&
      logical == other.logical &&
      peer == other.peer;

  @override
  int get hashCode => Object.hash(wallTime, logical, peer);

  @override
  String toString() => 'HlcStamp($wallTime,$logical,$peer)';
}

/// A hybrid logical clock. Callers supply `nowMicros` for wall time.
class Hlc {
  Hlc(int peer) : _peer = peer;
  int _peer;
  int _lastWall = 0;
  int _lastLogical = 0;

  int get peer => _peer;

  /// Local event: strictly increasing on this peer.
  HlcStamp tick(int nowMicros) {
    if (nowMicros > _lastWall) {
      _lastWall = nowMicros;
      _lastLogical = 0;
    } else {
      _lastLogical++;
    }
    return HlcStamp(_lastWall, _lastLogical, _peer);
  }

  /// Observe a remote stamp: advance past it.
  HlcStamp observe(HlcStamp remote, int nowMicros) {
    final wall = [
      _lastWall,
      remote.wallTime,
      nowMicros,
    ].reduce((a, b) => a > b ? a : b);
    if (wall == _lastWall && wall == remote.wallTime) {
      _lastLogical = [
        _lastLogical,
        remote.logical,
      ].reduce((a, b) => a > b ? a : b) +
          1;
    } else if (wall == _lastWall) {
      _lastLogical++;
    } else if (wall == remote.wallTime) {
      _lastLogical = remote.logical + 1;
    } else {
      _lastLogical = 0;
    }
    _lastWall = wall;
    return HlcStamp(_lastWall, _lastLogical, _peer);
  }
}

/// A last-writer-wins register. Ties broken in favor of the incumbent.
class LwwRegister<V> {
  LwwRegister(this.value, this.stamp);
  V value;
  HlcStamp stamp;

  /// Set if [newStamp] is strictly greater than the current stamp.
  /// Returns whether the value was updated.
  bool set(V newValue, HlcStamp newStamp) {
    if (newStamp.compareTo(stamp) > 0) {
      value = newValue;
      stamp = newStamp;
      return true;
    }
    return false;
  }

  /// Merge from another register. Returns whether the value changed.
  bool mergeFrom(LwwRegister<V> other) => set(other.value, other.stamp);

  LwwRegister<V> copy() => LwwRegister<V>(value, stamp);
}

/// A fractional-index position: `(frac bytes, peer)` for lexicographic order.
class Position implements Comparable<Position> {
  const Position(this.frac, this.peer);

  /// Bytes in `0..255`. A compact [Uint8List] (`#lzdartuint8list`) — faster
  /// element indexing and tighter allocation than a growable `List<int>`.
  final Uint8List frac;
  final int peer;

  @override
  @pragma('vm:prefer-inline')
  int compareTo(Position other) {
    final a = frac;
    final b = other.frac;
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      final c = a[i].compareTo(b[i]);
      if (c != 0) return c;
    }
    final lenCmp = a.length.compareTo(b.length);
    if (lenCmp != 0) return lenCmp;
    return peer.compareTo(other.peer);
  }

  @override
  String toString() => 'Position(${frac.join(',')},$peer)';
}

/// Compute a fractional-index byte key strictly between [lo] (exclusive) and
/// [hi] (exclusive). `null` for [lo] means -∞; `null` for [hi] means +∞.
///
/// Returns a compact [Uint8List] (`#lzdartuint8list`), written through a
/// [BytesBuilder] so each emit is an `addByte` into a pre-sized byte buffer
/// instead of boxing into a growable `List<int>`.
Uint8List keyBetween(Uint8List? lo, Uint8List? hi) {
  final out = BytesBuilder();
  final cap = (lo?.length ?? 0) + (hi?.length ?? 0) + 2;
  var i = 0;
  while (i <= cap) {
    final a = (lo != null && i < lo.length) ? lo[i] : 0;
    final b = hi == null ? 256 : (i < hi.length ? hi[i] : 0);
    if (a + 1 < b) {
      out.addByte((a + b) ~/ 2);
      return out.toBytes();
    }
    out.addByte(a);
    i++;
    if (a < b) {
      // dropped below hi; append midpoint to +inf
      final tail = keyBetween(
          lo == null ? null : (i < lo.length ? lo.sublist(i) : Uint8List(0)),
          null);
      out.add(tail);
      return out.toBytes();
    }
    // a === b: shared prefix, continue
  }
  out.addByte(128);
  return out.toBytes();
}

class _SeqEntry<V> {
  _SeqEntry(this.value, this.position, this.deleted, HlcStamp stamp)
      : valueStamp = stamp,
        posStamp = stamp,
        delStamp = stamp;

  LwwRegister<V> value;
  LwwRegister<Position> position;
  LwwRegister<bool> deleted;
  HlcStamp valueStamp;
  HlcStamp posStamp;
  HlcStamp delStamp;

  HlcStamp maxStamp() =>
      HlcStamp.max(value.stamp, HlcStamp.max(position.stamp, deleted.stamp));

  _SeqEntry<V> copy() {
    final e = _SeqEntry<V>(value.copy(), position.copy(), deleted.copy(), value.stamp);
    e.valueStamp = valueStamp;
    e.posStamp = posStamp;
    e.delStamp = delStamp;
    return e;
  }

  bool mergeFrom(_SeqEntry<V> other) {
    var changed = false;
    if (value.mergeFrom(other.value)) changed = true;
    if (position.mergeFrom(other.position)) changed = true;
    if (deleted.mergeFrom(other.deleted)) changed = true;
    return changed;
  }
}

/// A move-aware sequence CRDT. IDs are caller-supplied.
class SeqCrdt<Id, V> {
  SeqCrdt(this._peer) : _hlc = Hlc(_peer);
  final int _peer;
  final Hlc _hlc;
  final Map<Id, _SeqEntry<V>> _entries = {};

  int get peer => _peer;

  /// Insert a new element between [left] and [right] (either may be null =
  /// -∞/+∞). No-op if [id] already exists.
  void insertBetween(Id id, V value, Id? left, Id? right, int nowMicros) {
    if (_entries.containsKey(id)) return;
    final lo = left != null ? _entries[left]?.position.value.frac : null;
    final hi = right != null ? _entries[right]?.position.value.frac : null;
    final frac = keyBetween(lo, hi);
    final pos = Position(frac, _peer);
    final stamp = _stamp(nowMicros);
    _entries[id] = _SeqEntry<V>(
      LwwRegister<V>(value, stamp),
      LwwRegister<Position>(pos, stamp),
      LwwRegister<bool>(false, stamp),
      stamp,
    );
  }

  HlcStamp _stamp(int nowMicros) => _hlc.tick(nowMicros);

  /// Insert at the back (+∞).
  void insertBack(Id id, V value, int nowMicros) =>
      insertBetween(id, value, _lastId(), null, nowMicros);

  /// Insert at the front (-∞).
  void insertFront(Id id, V value, int nowMicros) =>
      insertBetween(id, value, null, _firstId(), nowMicros);

  Id? _firstId() {
    Id? best;
    Position? bestPos;
    for (final entry in _entries.entries) {
      if (entry.value.deleted.value) continue;
      final p = entry.value.position.value;
      if (bestPos == null || p.compareTo(bestPos) < 0) {
        bestPos = p;
        best = entry.key;
      }
    }
    return best;
  }

  Id? _lastId() {
    Id? best;
    Position? bestPos;
    for (final entry in _entries.entries) {
      if (entry.value.deleted.value) continue;
      final p = entry.value.position.value;
      if (bestPos == null || p.compareTo(bestPos) > 0) {
        bestPos = p;
        best = entry.key;
      }
    }
    return best;
  }

  /// Update the value of [id]. Returns whether it changed.
  bool setValue(Id id, V value, int nowMicros) {
    final e = _entries[id];
    if (e == null) return false;
    return e.value.set(value, _stamp(nowMicros));
  }

  /// Move [id] between [left] and [right]. Returns whether the move applied.
  bool moveBetween(Id id, Id? left, Id? right, int nowMicros) {
    final e = _entries[id];
    if (e == null) return false;
    final lo = left != null ? _entries[left]?.position.value.frac : null;
    final hi = right != null ? _entries[right]?.position.value.frac : null;
    final frac = keyBetween(lo, hi);
    final pos = Position(frac, _peer);
    return e.position.set(pos, _stamp(nowMicros));
  }

  /// Move [id] to just after [anchor].
  bool moveAfter(Id id, Id anchor, int nowMicros) {
    final order = _orderedIds();
    final ai = order.indexOf(anchor);
    if (ai < 0) return false;
    final right = ai + 1 < order.length ? order[ai + 1] : null;
    return moveBetween(id, anchor, right, nowMicros);
  }

  /// Move [id] to just before [anchor].
  bool moveBefore(Id id, Id anchor, int nowMicros) {
    final order = _orderedIds();
    final ai = order.indexOf(anchor);
    if (ai < 0) return false;
    final left = ai > 0 ? order[ai - 1] : null;
    return moveBetween(id, left, anchor, nowMicros);
  }

  /// Tombstone [id]. Returns whether the removal applied.
  bool remove(Id id, int nowMicros) {
    final e = _entries[id];
    if (e == null) return false;
    return e.deleted.set(true, _stamp(nowMicros));
  }

  /// Whether [id] exists and is not tombstoned.
  bool contains(Id id) {
    final e = _entries[id];
    return e != null && !e.deleted.value;
  }

  /// The value for [id], or null if absent/deleted.
  V? get(Id id) {
    final e = _entries[id];
    if (e == null || e.deleted.value) return null;
    return e.value.value;
  }

  List<Id> _orderedIds() {
    final live = <MapEntry<Id, Position>>[];
    for (final entry in _entries.entries) {
      if (!entry.value.deleted.value) {
        live.add(MapEntry(entry.key, entry.value.position.value));
      }
    }
    live.sort((a, b) => a.value.compareTo(b.value));
    return live.map((e) => e.key).toList();
  }

  /// The live element ids in position order.
  List<Id> order() => _orderedIds();

  /// The live `(id, value)` pairs in position order.
  List<MapEntry<Id, V>> values() {
    return [for (final id in order()) MapEntry(id, get(id) as V)];
  }

  /// Count of tombstoned elements.
  int tombstoneCount() =>
      _entries.values.where((e) => e.deleted.value).length;

  /// Total entry count including tombstones.
  int entryCount() => _entries.length;

  /// Count of live elements.
  int len() => _orderedIds().length;

  /// Deep-copy with a new [peer].
  SeqCrdt<Id, V> fork(int peer) {
    final copy = SeqCrdt<Id, V>(peer);
    copy._hlc._lastWall = _hlc._lastWall;
    copy._hlc._lastLogical = _hlc._lastLogical;
    for (final entry in _entries.entries) {
      copy._entries[entry.key] = entry.value.copy();
    }
    return copy;
  }

  /// Deep-copy with the same peer.
  SeqCrdt<Id, V> clone() => fork(_peer);

  /// State-based merge. Returns whether anything changed.
  bool merge(SeqCrdt<Id, V> other, int nowMicros) {
    // Advance clock past every remote stamp.
    for (final e in other._entries.values) {
      _hlc.observe(e.maxStamp(), nowMicros);
    }
    var changed = false;
    for (final entry in other._entries.entries) {
      final existing = _entries[entry.key];
      if (existing != null) {
        if (existing.mergeFrom(entry.value)) changed = true;
      } else {
        _entries[entry.key] = entry.value.copy();
        changed = true;
      }
    }
    return changed;
  }

  /// GC entries whose tombstone is stable per [isStable]. Returns removed count.
  int gcWith(bool Function(HlcStamp stamp) isStable) {
    var removed = 0;
    final toRemove = <Id>[];
    for (final entry in _entries.entries) {
      if (entry.value.deleted.value && isStable(entry.value.deleted.stamp)) {
        toRemove.add(entry.key);
      }
    }
    for (final id in toRemove) {
      _entries.remove(id);
      removed++;
    }
    return removed;
  }

  /// GC entries tombstoned at or before [watermark].
  int gc(HlcStamp watermark) =>
      gcWith((s) => s.compareTo(watermark) <= 0);
}
