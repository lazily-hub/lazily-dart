/// Membership + failure detection (`#lzmemb`) — the Dart port.
///
/// See `lazily-spec/docs/membership.md` and the formal model
/// `lazily-formal/LazilyFormal/Membership.lean`. A [MembershipCell] is a
/// reactive view of the live peer set backed by SWIM-style heartbeats + a
/// **Phi-accrual** failure detector; the derived [MembershipCell.peerSet] is the
/// `Alive` peers. Per-peer state is `Alive | Suspect | Dead | Left`.
///
/// The pure compute **core** ([MembershipCore] + [PhiAccrual]) is the Phi-accrual
/// math + SWIM state machine over plain state (bytes-eligible), split from a thin
/// reactive **cell** that projects the alive set onto a [Context] [Cell] so
/// `peerSet` invalidates *only when the set changes* (the backend-portability
/// rule). The peer id is generic (`P extends Comparable`); the distributed plane
/// plugs in its `PeerId`. Below the CRDT plane.
library;

import 'dart:math';

import 'core.dart';

// ---------------------------------------------------------------------------
// State + events
// ---------------------------------------------------------------------------

/// Per-peer liveness state (SWIM).
enum PeerState {
  /// Heartbeats current; a valid CRDT sync target.
  alive('Alive'),

  /// Phi crossed the threshold; awaiting a refuting heartbeat or the timeout.
  suspect('Suspect'),

  /// Suspect long enough to declare failed.
  dead('Dead'),

  /// Gracefully departed.
  left('Left');

  const PeerState(this.label);

  /// The cross-language wire label (`"Alive"`, `"Suspect"`, ...).
  final String label;
}

/// The kind of a [PeerChangeEvent].
enum PeerChangeType { joined, left, stateChanged }

/// A diff event over the membership cell: a peer joined, gracefully left, or
/// transitioned between two [PeerState]s. Value-equal so it composes with the
/// `!=` guards downstream.
class PeerChangeEvent<P> {
  /// A newly-known peer arrived (`Alive`).
  const PeerChangeEvent.joined(this.peer)
      : type = PeerChangeType.joined,
        from = null,
        to = null;

  /// A known peer gracefully departed.
  const PeerChangeEvent.left(this.peer)
      : type = PeerChangeType.left,
        from = null,
        to = null;

  /// A known peer transitioned from [from] to [to].
  const PeerChangeEvent.stateChanged(this.peer, this.from, this.to)
      : type = PeerChangeType.stateChanged;

  final PeerChangeType type;
  final P peer;
  final PeerState? from;
  final PeerState? to;

  @override
  bool operator ==(Object other) =>
      other is PeerChangeEvent<P> &&
      other.type == type &&
      other.peer == peer &&
      other.from == from &&
      other.to == to;

  @override
  int get hashCode => Object.hash(type, peer, from, to);

  @override
  String toString() {
    switch (type) {
      case PeerChangeType.joined:
        return 'Joined($peer)';
      case PeerChangeType.left:
        return 'Left($peer)';
      case PeerChangeType.stateChanged:
        return 'StateChanged($peer, ${from!.label} -> ${to!.label})';
    }
  }
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

/// Tunables for the failure detector + SWIM state machine.
class MembershipConfig {
  const MembershipConfig({
    this.phiThreshold = 8.0,
    this.suspectTimeout = 5,
    this.maxSamples = 100,
    this.minStd = 0.1,
  });

  /// `phi > phiThreshold` marks a peer `Suspect`.
  final double phiThreshold;

  /// Ticks a peer stays `Suspect` before being declared `Dead`.
  final int suspectTimeout;

  /// Sliding window size for heartbeat inter-arrival samples.
  final int maxSamples;

  /// Floor on the sample standard deviation (avoids div-by-zero).
  final double minStd;
}

// ---------------------------------------------------------------------------
// Phi-accrual failure detector
// ---------------------------------------------------------------------------

/// Phi-accrual failure detector over a sliding window of heartbeat inter-arrival
/// times. `phi` uses the bit-portable Akka-style logistic approximation of the
/// normal CDF so every binding agrees.
class PhiAccrual {
  PhiAccrual(int maxSamples, this.minStd)
      : maxSamples = maxSamples < 1 ? 1 : maxSamples;

  final int maxSamples;
  final double minStd;
  final List<double> _window = [];
  int? _lastHeartbeat;

  /// Record a heartbeat arrival, appending its inter-arrival sample.
  void heartbeat(int now) {
    final last = _lastHeartbeat;
    if (last != null) {
      _window.add((now - last).toDouble());
      while (_window.length > maxSamples) {
        _window.removeAt(0);
      }
    }
    _lastHeartbeat = now;
  }

  double _mean() {
    var sum = 0.0;
    for (final x in _window) {
      sum += x;
    }
    return sum / _window.length;
  }

  double _std(double mean) {
    var v = 0.0;
    for (final x in _window) {
      v += (x - mean) * (x - mean);
    }
    v /= _window.length;
    final s = sqrt(v);
    return s > minStd ? s : minStd;
  }

  /// The suspicion level at [now]. `0.0` when there is no estimate yet.
  double phi(int now) {
    final last = _lastHeartbeat;
    if (last == null || _window.isEmpty) return 0.0;
    final elapsed = (now - last).toDouble();
    final mean = _mean();
    final std = _std(mean);
    final y = (elapsed - mean) / std;
    final e = exp(-y * (1.5976 + 0.070566 * y * y));
    if (elapsed > mean) {
      return -(log(e / (1.0 + e)) / ln10);
    } else {
      return -(log(1.0 - 1.0 / (1.0 + e)) / ln10);
    }
  }
}

// ---------------------------------------------------------------------------
// SWIM compute core
// ---------------------------------------------------------------------------

class _PeerRecord {
  _PeerRecord(this.state, this.detector, this.suspectSince);

  PeerState state;
  PhiAccrual detector;
  int? suspectSince;
}

/// The pure membership compute core: the SWIM state machine over a keyed peer
/// map, driven by heartbeats and a logical clock. Emits [PeerChangeEvent]s.
class MembershipCore<P extends Comparable> {
  MembershipCore([this.config = const MembershipConfig()]);

  final MembershipConfig config;
  final Map<P, _PeerRecord> _peers = {};

  PhiAccrual _newDetector() =>
      PhiAccrual(config.maxSamples, config.minStd);

  /// The current alive peer set, sorted ascending (the reactive `PeerSet`).
  List<P> aliveSet() {
    final alive = <P>[];
    _peers.forEach((peer, record) {
      if (record.state == PeerState.alive) alive.add(peer);
    });
    alive.sort(Comparable.compare);
    return alive;
  }

  /// The state of a known peer, or `null` if unknown.
  PeerState? state(P peer) => _peers[peer]?.state;

  /// Join a peer (or refresh a re-joining one): `Alive` with a fresh detector.
  List<PeerChangeEvent<P>> join(P peer, int now) {
    final detector = _newDetector();
    detector.heartbeat(now);
    final prev = _peers[peer]?.state;
    _peers[peer] = _PeerRecord(PeerState.alive, detector, null);
    if (prev == null) return [PeerChangeEvent.joined(peer)];
    if (prev == PeerState.alive) return [];
    return [PeerChangeEvent.stateChanged(peer, prev, PeerState.alive)];
  }

  /// Record a heartbeat. An unknown peer is a join; a `Suspect`/`Dead` peer
  /// returns to `Alive` (SWIM refutation).
  List<PeerChangeEvent<P>> heartbeat(P peer, int now) {
    final record = _peers[peer];
    if (record == null) return join(peer, now);
    record.detector.heartbeat(now);
    final from = record.state;
    if (from != PeerState.alive && from != PeerState.left) {
      record.state = PeerState.alive;
      record.suspectSince = null;
      return [PeerChangeEvent.stateChanged(peer, from, PeerState.alive)];
    }
    return [];
  }

  /// Graceful departure.
  List<PeerChangeEvent<P>> leave(P peer, int now) {
    final record = _peers[peer];
    if (record == null || record.state == PeerState.left) return [];
    record.state = PeerState.left;
    record.suspectSince = null;
    return [PeerChangeEvent.left(peer)];
  }

  /// Advance the clock: escalate `Alive -> Suspect` (phi crossed) and
  /// `Suspect -> Dead` (timeout elapsed).
  List<PeerChangeEvent<P>> tick(int now) {
    final events = <PeerChangeEvent<P>>[];
    _peers.forEach((peer, record) {
      if (record.state == PeerState.alive) {
        if (record.detector.phi(now) > config.phiThreshold) {
          record.state = PeerState.suspect;
          record.suspectSince = now;
          events.add(PeerChangeEvent.stateChanged(
              peer, PeerState.alive, PeerState.suspect));
        }
      } else if (record.state == PeerState.suspect) {
        final since = record.suspectSince;
        if (since != null && now - since >= config.suspectTimeout) {
          record.state = PeerState.dead;
          events.add(PeerChangeEvent.stateChanged(
              peer, PeerState.suspect, PeerState.dead));
        }
      }
    });
    return events;
  }
}

// ---------------------------------------------------------------------------
// Reactive membership cell
// ---------------------------------------------------------------------------

/// Compare two sorted alive-set lists for value equality (the reactive guard).
bool _listEquals<P>(List<P> a, List<P> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The derived reactive alive-peer set — a `Cell<List<P>>` projected by
/// [MembershipCell].
typedef PeerSet<P extends Comparable> = Source<List<P>>;

/// Reactive membership: drives a [MembershipCore] and projects the alive set
/// onto a [Context] [Cell] so [peerSet] invalidates only on a set change.
class MembershipCell<P extends Comparable> {
  MembershipCell(this.ctx, [MembershipConfig config = const MembershipConfig()])
      : core = MembershipCore<P>(config),
        peerSetCell = Source<List<P>>(ctx, <P>[]);

  final Context ctx;
  final MembershipCore<P> core;

  /// The backing `PeerSet` cell, for direct subscription.
  final Source<List<P>> peerSetCell;

  void _refresh() {
    final next = core.aliveSet();
    // Only write when the set changed, so the reader's `!=` guard holds even
    // though a fresh list identity is produced each call.
    if (!_listEquals(peerSetCell.peek, next)) {
      peerSetCell.value = next;
    }
  }

  List<PeerChangeEvent<P>> join(P peer, int now) {
    final events = core.join(peer, now);
    _refresh();
    return events;
  }

  List<PeerChangeEvent<P>> heartbeat(P peer, int now) {
    final events = core.heartbeat(peer, now);
    _refresh();
    return events;
  }

  List<PeerChangeEvent<P>> leave(P peer, int now) {
    final events = core.leave(peer, now);
    _refresh();
    return events;
  }

  List<PeerChangeEvent<P>> tick(int now) {
    final events = core.tick(now);
    _refresh();
    return events;
  }

  /// The reactive alive peer set (`PeerSet`).
  List<P> peerSet() => peerSetCell.value;

  /// The state of a known peer, or `null` if unknown.
  PeerState? state(P peer) => core.state(peer);
}
