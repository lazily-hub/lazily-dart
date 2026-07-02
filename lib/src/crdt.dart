/// Distributed CRDT plane runtime (protocol.md § Distributed: CRDT Cell Plane).
///
/// This module carries the runtime side of the CRDT plane: the hybrid logical
/// clock ([Hlc] / [HlcStamp]), the per-peer stamp frontier ([StampFrontier])
/// with its commutative/associative/idempotent [StampFrontier.merge] and the
/// causal-stability watermark (the `min` over membership), and the
/// [CrdtPlane] that wires both to a live membership set. The wire mirror of
/// these runtime types is [WireStamp] / [CrdtOp] / [CrdtSync] in
/// `package:lazily/src/ipc.dart`; the two layers never depend on each other's
/// representation, only on the shared `(wall_time, logical, peer)` total order.
///
/// Mirrors `lazily-rs/src/crdt.rs` (`Hlc`, `StampFrontier`, `CrdtPlane`) and
/// the formally-proven invariants in
/// `lazily-spec/formal/lean/LazilyFormal/CRDT.lean`
/// (`stampJoin_{comm,assoc,idem}`,
/// `collectable_implies_observed_everywhere`).

import 'ipc.dart';

/// Runtime HLC stamp — a total order `(wall_time, logical, peer)`.
///
/// The runtime sibling of [WireStamp]; the two are isomorphic and converted
/// losslessly at the boundary. Order is lexicographic on
/// `(wallTime, logical, peer)`, so equal `(wall, logical)` from different
/// peers is still totally ordered by [peer].
class HlcStamp implements Comparable<HlcStamp> {
  const HlcStamp(this.wallTime, this.logical, this.peer);

  final int wallTime;
  final int logical;
  final PeerId peer;

  /// Convert to the wire mirror.
  WireStamp toWire() =>
      WireStamp(wallTime: wallTime, logical: logical, peer: peer);

  /// Convert from the wire mirror.
  factory HlcStamp.fromWire(WireStamp stamp) =>
      HlcStamp(stamp.wallTime, stamp.logical, stamp.peer);

  @override
  int compareTo(HlcStamp other) {
    var c = wallTime.compareTo(other.wallTime);
    if (c != 0) return c;
    c = logical.compareTo(other.logical);
    if (c != 0) return c;
    return peer.compareTo(other.peer);
  }

  /// Lexicographic total order.
  bool operator <(HlcStamp other) => compareTo(other) < 0;
  bool operator <=(HlcStamp other) => compareTo(other) <= 0;
  bool operator >(HlcStamp other) => compareTo(other) > 0;
  bool operator >=(HlcStamp other) => compareTo(other) >= 0;

  /// The component-wise minimum (used by the stability watermark).
  static HlcStamp min(HlcStamp a, HlcStamp b) => a <= b ? a : b;

  @override
  bool operator ==(Object other) =>
      other is HlcStamp &&
      other.wallTime == wallTime &&
      other.logical == logical &&
      other.peer == peer;

  @override
  int get hashCode => Object.hash(wallTime, logical, peer);

  @override
  String toString() =>
      'HlcStamp(wall=$wallTime, logical=$logical, peer=$peer)';
}

/// A hybrid logical clock (Karger-Shrinkman-Levine).
///
/// Wall time is supplied by the caller ([tick]/[observe] take `nowMicros`) so
/// the clock is deterministic and never reads the system clock. The invariant:
/// every stamp a peer produces is strictly greater than the previous one, and
/// [observe] always produces a stamp strictly greater than the remote one
/// (theorem `hlc_send_is_monotonic_and_recv_observes_remote`).
class Hlc {
  Hlc(this._peer) : _lastWall = 0, _lastLogical = 0;

  final PeerId _peer;
  int _lastWall;
  int _lastLogical;

  /// This peer's id (the final tiebreak component).
  PeerId get peer => _peer;

  /// Local event. Advances the clock and returns the new stamp.
  ///
  /// If [nowMicros] is greater than the last wall, the wall advances and the
  /// logical counter resets; otherwise the logical counter increments (wall
  /// held back to preserve monotonicity under same-millisecond events).
  HlcStamp tick(int nowMicros) {
    if (nowMicros > _lastWall) {
      _lastWall = nowMicros;
      _lastLogical = 0;
    } else {
      _lastLogical += 1;
    }
    return HlcStamp(_lastWall, _lastLogical, _peer);
  }

  /// Observe a remote [remote] stamp. The returned local stamp is strictly
  /// greater than [remote] (the standard HLC recv rule).
  HlcStamp observe(HlcStamp remote, int nowMicros) {
    final wall = _max3(_lastWall, remote.wallTime, nowMicros);
    if (wall == _lastWall && wall == remote.wallTime) {
      _lastLogical = _max2(_lastLogical, remote.logical) + 1;
    } else if (wall == _lastWall) {
      _lastLogical += 1;
    } else if (wall == remote.wallTime) {
      _lastLogical = remote.logical + 1;
    } else {
      _lastLogical = 0;
    }
    _lastWall = wall;
    return HlcStamp(_lastWall, _lastLogical, _peer);
  }

  static int _max2(int a, int b) => a >= b ? a : b;
  static int _max3(int a, int b, int c) => _max2(_max2(a, b), c);
}

/// Per-peer stamp frontier: the highest [HlcStamp] observed from each peer.
///
/// Mirrors `lazily-rs/src/crdt.rs::StampFrontier` (a `BTreeMap<PeerId,
/// HlcStamp>`). The merge laws (commutative, associative, idempotent) are
/// formally proven (`stampJoin_{comm,assoc,idem}`): fold [observe] over an
/// incoming frontier in any order and the result is identical.
class StampFrontier {
  final Map<PeerId, HlcStamp> _stamps = {};

  StampFrontier();

  /// Build a frontier from `(peer, stamp)` pairs (the [WireStamp] wire form).
  factory StampFrontier.fromWire(Iterable<StampFrontierEntry> entries) {
    final f = StampFrontier();
    for (final e in entries) {
      f.observe(e.peer, HlcStamp.fromWire(e.stamp));
    }
    return f;
  }

  /// The set of peers this frontier has observed.
  Iterable<PeerId> get peers => _stamps.keys;

  /// Whether [peer] has been observed.
  bool knows(PeerId peer) => _stamps.containsKey(peer);

  /// The highest stamp observed for [peer], or `null` if unseen.
  HlcStamp? get(PeerId peer) => _stamps[peer];

  /// Fold one observation: keep the per-peer max. Idempotent — older/equal
  /// stamps are ignored. Returns whether the frontier changed.
  bool observe(PeerId peer, HlcStamp stamp) {
    final cur = _stamps[peer];
    if (cur != null && cur >= stamp) return false;
    _stamps[peer] = stamp;
    return true;
  }

  /// Merge [other] in: fold [observe] over it. Commutative, associative,
  /// idempotent. Returns whether anything changed.
  bool merge(StampFrontier other) {
    var changed = false;
    other._stamps.forEach((peer, stamp) {
      if (observe(peer, stamp)) changed = true;
    });
    return changed;
  }

  /// The causal-stability watermark: the `min` over the given membership's
  /// observed stamps. Returns `null` until *every* member has been observed —
  /// a single unseen member means the frontier is not yet causally complete
  /// (formally: `collectable_implies_observed_everywhere`).
  HlcStamp? watermark(Iterable<PeerId> membership) {
    HlcStamp? min;
    for (final peer in membership) {
      final stamp = _stamps[peer];
      if (stamp == null) return null;
      min = min == null ? stamp : HlcStamp.min(min, stamp);
    }
    return min;
  }

  /// Emit the wire form (a list of `(peer, WireStamp)` entries, one per
  /// observed peer, sorted by peer id for deterministic output).
  List<StampFrontierEntry> toWire() {
    final peers = _stamps.keys.toList()..sort();
    return peers.map((p) => StampFrontierEntry(p, _stamps[p]!.toWire())).toList();
  }
}

/// The CRDT plane: an [Hlc] + a [StampFrontier] + the live membership set.
///
/// This is the runtime hub a `merge: crdt` root cell drives. Local edits
/// ([tick]) and remote observations ([observeRemote]) both fold into the
/// frontier; the [stabilityWatermark] is what the tombstone-GC contract
/// consumes. Wires to live `ReplicatedCell`s and `BridgeHub` fan-out are the
/// runtime-integration slice (`#lzcrdtplane5b`); the wire format, codec
/// round-trips, and frontier exchange implemented here are the conformance
/// surface (`#lzcrdtplane5a`).
class CrdtPlane {
  CrdtPlane(this._self) : _clock = Hlc(_self);

  final PeerId _self;
  final Hlc _clock;
  final StampFrontier _frontier = StampFrontier();
  final Set<PeerId> _membership = {};

  /// This peer's id.
  PeerId get self => _self;

  /// The HLC (wall time is caller-supplied via [tick]/[observeRemote]).
  Hlc get clock => _clock;

  /// The stamp frontier (highest observed stamp per peer).
  StampFrontier get frontier => _frontier;

  /// The live membership set (peers this plane has observed, including self).
  Set<PeerId> get membership => Set.unmodifiable(_membership);

  /// A local event: tick the clock and fold the result into the frontier.
  /// Self is added to the membership on first use.
  HlcStamp tick(int nowMicros) {
    _membership.add(_self);
    final stamp = _clock.tick(nowMicros);
    _frontier.observe(_self, stamp);
    return stamp;
  }

  /// Observe a remote stamp: expand membership, fold into the frontier, and
  /// advance the HLC. Returns the new local stamp.
  HlcStamp observeRemote(HlcStamp remote, int nowMicros) {
    _membership.add(remote.peer);
    _frontier.observe(remote.peer, remote);
    return _clock.observe(remote, nowMicros);
  }

  /// The causal-stability watermark: `min` over membership of the frontier, or
  /// `null` until every member has been observed.
  HlcStamp? stabilityWatermark() => _frontier.watermark(_membership);

  /// Whether [stamp] is collectable: its delete stamp is `<=` the stability
  /// watermark (so every replica has provably observed it).
  bool isCollectable(HlcStamp stamp) {
    final w = stabilityWatermark();
    return w != null && stamp <= w;
  }
}
