/// Reliable sync protocol (`#lzsync`) for Dart.
///
/// Delivery-reliability over the `Snapshot` / `Delta` / `CrdtSync` planes
/// (`lazily-spec` § Reliable Sync): gap recovery, at-least-once outbox, and
/// OR-set / LWW liveness cells. The correctness backstop is `lazily-formal`
/// `ReliableSync.lean`; the cross-language pins are
/// `lazily-spec/conformance/reliable-sync/`. A pure-Dart port of
/// `lazily-rs/src/reliable_sync.rs`; the wire is shared with lazily-rs /
/// lazily-kt / lazily-js / lazily-cpp.
///
/// Three pure-protocol pieces (identical logic in every binding, no I/O / clock
/// / storage engine baked in):
///
/// - [ResyncCoordinator] — receiver-side decision function over the inbound
///   frame stream ([ResyncActionApply] / [ResyncActionRequestSnapshot] /
///   [ResyncActionIgnore]), multi-epoch-span aware.
/// - [DurableOutbox] — sender-side at-least-once contract (append-before-send,
///   ack-through, replay-from-cursor). Ships [InMemoryOutbox] as the default.
/// - [OrSet] / [WireLwwRegister] — the liveness cells that ride the CrdtSync
///   plane.
///
/// The reverse-channel control frames are [IpcMessageResyncRequest] and
/// [IpcMessageOutboxAck] (see `ipc.dart`) — variants on the same framed,
/// codec-negotiated, bidirectional message plane as `Snapshot` / `Delta` /
/// `CrdtSync`, so they share one encode/decode path, one demux point, one FFI
/// kind, and one in-band order.
library lazily.reliable_sync;

import 'dart:collection';

import 'ipc.dart';

// ---------------------------------------------------------------------------
// ResyncCoordinator (receiver side)
// ---------------------------------------------------------------------------

/// Receiver decision for an inbound frame (spec § ResyncCoordinator).
///
/// Externally the three cases mirror the Rust `ResyncAction` enum:
/// [ResyncActionApply], [ResyncActionRequestSnapshot], [ResyncActionIgnore].
sealed class ResyncAction {
  const ResyncAction();

  /// Apply the frame and advance the receiver epoch.
  static const ResyncAction apply = ResyncActionApply();

  /// Drop the frame (re-delivery / malformed / suppressed / control frame).
  static const ResyncAction ignore = ResyncActionIgnore();

  bool get isApply => this is ResyncActionApply;
  bool get isRequestSnapshot => this is ResyncActionRequestSnapshot;
  bool get isIgnore => this is ResyncActionIgnore;
}

/// Apply the frame and advance the receiver epoch.
final class ResyncActionApply extends ResyncAction {
  const ResyncActionApply();

  @override
  bool operator ==(Object other) => other is ResyncActionApply;

  @override
  int get hashCode => 'ResyncActionApply'.hashCode;

  @override
  String toString() => 'ResyncAction.Apply';
}

/// A gap was detected; request a fresh [Snapshot] covering [fromEpoch].
final class ResyncActionRequestSnapshot extends ResyncAction {
  const ResyncActionRequestSnapshot(this.fromEpoch);

  /// The receiver's current `last_epoch`.
  final Epoch fromEpoch;

  @override
  bool operator ==(Object other) =>
      other is ResyncActionRequestSnapshot && other.fromEpoch == fromEpoch;

  @override
  int get hashCode => Object.hash('ResyncActionRequestSnapshot', fromEpoch);

  @override
  String toString() => 'ResyncAction.RequestSnapshot(from=$fromEpoch)';
}

/// Drop the frame (already-applied re-delivery, malformed, a duplicate request
/// suppressed while resyncing, or a reverse-channel control frame arriving at a
/// data receiver).
final class ResyncActionIgnore extends ResyncAction {
  const ResyncActionIgnore();

  @override
  bool operator ==(Object other) => other is ResyncActionIgnore;

  @override
  int get hashCode => 'ResyncActionIgnore'.hashCode;

  @override
  String toString() => 'ResyncAction.Ignore';
}

/// Receiver-side reliable-sync coordinator.
///
/// Holds `lastEpoch` (the highest epoch fully applied) and a `resyncing` flag
/// (a [ResyncActionRequestSnapshot] is outstanding until a covering [Snapshot]
/// lands, so further ahead-of-cursor deltas are ignored instead of
/// re-requesting).
///
/// [ingest] advances [lastEpoch] on Apply — the caller MUST fold the frame's
/// ops into its projection on Apply. Mirrors the `ReliableSync.step` Lean model.
class ResyncCoordinator {
  /// A coordinator that has already applied through [lastEpoch] (0 = fresh; a
  /// [Snapshot] seeds the first real epoch).
  ResyncCoordinator([this._lastEpoch = 0]);

  Epoch _lastEpoch;
  bool _resyncing = false;

  /// The highest epoch fully applied.
  Epoch get lastEpoch => _lastEpoch;

  /// Whether a resync request is outstanding (awaiting a covering snapshot).
  bool get isResyncing => _resyncing;

  /// Classify + fold an inbound [Delta]. On Apply this advances [lastEpoch] to
  /// `delta.epoch` (multi-epoch-span aware) and clears the resyncing flag.
  ResyncAction ingestDelta(Delta delta) {
    if (delta.baseEpoch == _lastEpoch) {
      // Contiguous. Accept any span >= 1; reject an empty/backward epoch.
      if (delta.epoch >= delta.baseEpoch + 1) {
        _lastEpoch = delta.epoch;
        _resyncing = false;
        return ResyncAction.apply;
      }
      return ResyncAction.ignore;
    } else if (delta.baseEpoch < _lastEpoch) {
      // Already applied — a re-delivery (outbox replay / retry). Idempotent.
      return ResyncAction.ignore;
    } else {
      // Gap: baseEpoch > lastEpoch. Request a covering snapshot once.
      if (_resyncing) return ResyncAction.ignore;
      _resyncing = true;
      return ResyncActionRequestSnapshot(_lastEpoch);
    }
  }

  /// Adopt a [Snapshot] at [snapshotEpoch] — a full-state frame always applies,
  /// setting [lastEpoch] and clearing the resyncing flag.
  ResyncAction ingestSnapshot(Epoch snapshotEpoch) {
    _lastEpoch = snapshotEpoch;
    _resyncing = false;
    return ResyncAction.apply;
  }

  /// Classify an inbound [IpcMessage]. `CrdtSync` is handled by the CRDT plane,
  /// and the reverse-channel control frames ([IpcMessageResyncRequest] /
  /// [IpcMessageOutboxAck]) are for the *sender*'s driver, not this data
  /// receiver, so both are ignored here.
  ResyncAction ingest(IpcMessage msg) {
    return switch (msg) {
      IpcMessageSnapshot() => ingestSnapshot(msg.value.epoch),
      IpcMessageDelta() => ingestDelta(msg.value),
      IpcMessageCrdtSync() ||
      IpcMessageResyncRequest() ||
      IpcMessageOutboxAck() =>
        ResyncAction.ignore,
    };
  }

  /// The [IpcMessageOutboxAck] control frame to advertise this receiver's resume
  /// cursor on reconnect (and for periodic retention advance).
  IpcMessage ack() =>
      IpcMessage.ofOutboxAck(OutboxAck(throughEpoch: _lastEpoch));
}

// ---------------------------------------------------------------------------
// DurableOutbox (sender side)
// ---------------------------------------------------------------------------

/// One retained outbox frame: its epoch retention key and the message.
typedef OutboxFrame = (Epoch epoch, IpcMessage message);

/// Sender-side at-least-once outbox contract (spec § DurableOutbox).
///
/// Every frame is durably [append]ed **before** it is sent, retained until the
/// peer proves receipt ([ackThrough]), and [replayFrom] a reconnect cursor
/// re-sends everything the peer has not yet acked. Combined with the receiver's
/// idempotent ignore of already-applied deltas, this is at-least-once delivery
/// with exactly-once effect.
abstract interface class DurableOutbox {
  /// Persist [msg] at [epoch] before it is handed to the transport.
  void append(Epoch epoch, IpcMessage msg);

  /// The peer proved receipt through [epoch]; retained frames `<= epoch` MAY be
  /// pruned.
  void ackThrough(Epoch epoch);

  /// Retained frames with `epoch > cursor`, in ascending epoch order.
  List<OutboxFrame> replayFrom(Epoch cursor);

  /// Epochs still retained (not yet acked), ascending — for diagnostics/tests.
  List<Epoch> retainedEpochs();
}

/// In-memory [DurableOutbox] — correct within a process lifetime; the default.
class InMemoryOutbox implements DurableOutbox {
  /// An empty outbox.
  InMemoryOutbox();

  final List<OutboxFrame> _entries = [];
  Epoch _ackedThrough = 0;

  /// The highest acked epoch (retention cursor).
  Epoch get ackedThrough => _ackedThrough;

  @override
  void append(Epoch epoch, IpcMessage msg) {
    _entries.add((epoch, msg));
  }

  @override
  void ackThrough(Epoch epoch) {
    if (epoch > _ackedThrough) _ackedThrough = epoch;
    _entries.removeWhere((e) => e.$1 <= _ackedThrough);
  }

  @override
  List<OutboxFrame> replayFrom(Epoch cursor) {
    final out = _entries.where((e) => e.$1 > cursor).toList();
    out.sort((a, b) => a.$1.compareTo(b.$1));
    return out;
  }

  @override
  List<Epoch> retainedEpochs() {
    final es = _entries.map((e) => e.$1).toList();
    es.sort();
    return es;
  }
}

// ---------------------------------------------------------------------------
// Liveness cells: OrSet + WireLwwRegister
// ---------------------------------------------------------------------------

/// An observed-remove set (OR-set) liveness cell.
///
/// Models one entry's presence via add/remove tags: a `(doc, pid)` is *present*
/// iff some add-tag is not shadowed by a remove that observed it. This gives the
/// add-wins-over-stale-remove bias liveness needs (a re-open concurrent with a
/// lagging close keeps the doc open). The [join] is the union of both tag sets,
/// so it is a semilattice — out-of-order and duplicate delivery converge.
class OrSet {
  /// An empty OR-set.
  OrSet();

  final Set<String> _adds = {};
  final Set<String> _removes = {};

  /// Add a presence tag (an editor open / attach event mints a fresh tag).
  void add(String tag) {
    _adds.add(tag);
  }

  /// Remove, observing [tags] — only the add-tags this remove saw are shadowed.
  void removeObserved(Iterable<String> tags) {
    _removes.addAll(tags);
  }

  /// Whether the entry is currently present (some add-tag not shadowed).
  bool present() => _adds.difference(_removes).isNotEmpty;

  /// Join another replica's OR-set (union of adds and of removes).
  void join(OrSet other) {
    _adds.addAll(other._adds);
    _removes.addAll(other._removes);
  }

  @override
  bool operator ==(Object other) =>
      other is OrSet &&
      _setEquals(_adds, other._adds) &&
      _setEquals(_removes, other._removes);

  @override
  int get hashCode => Object.hash(
        Object.hashAllUnordered(_adds),
        Object.hashAllUnordered(_removes),
      );

  @override
  String toString() => 'OrSet(adds=$_adds, removes=$_removes)';
}

/// A last-writer-wins register liveness cell (per-pid `alive`, owner lease).
///
/// Keyed by [WireStamp] (`(wallTime, logical, peer)` total order): the highest
/// stamp wins, so an OS process-exit write (`alive = false` at a fresh stamp)
/// dominates a stale re-assert. [join] is the stamp-max, a semilattice.
class WireLwwRegister<V> {
  /// A register holding [value] written at [stamp].
  WireLwwRegister(this._stamp, this._value);

  WireStamp _stamp;
  V _value;

  /// The current value.
  V get value => _value;

  /// The current decisive stamp.
  WireStamp get stamp => _stamp;

  /// Write [value] at [stamp] iff it dominates the current stamp.
  void set(WireStamp stamp, V value) {
    if (_dominates(stamp, _stamp)) {
      _stamp = stamp;
      _value = value;
    }
  }

  /// Join another replica's register (keep the higher stamp).
  void join(WireLwwRegister<V> other) {
    if (_dominates(other._stamp, _stamp)) {
      _stamp = other._stamp;
      _value = other._value;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is WireLwwRegister<V> &&
      other._stamp == _stamp &&
      other._value == _value;

  @override
  int get hashCode => Object.hash(_stamp, _value);

  @override
  String toString() => 'WireLwwRegister(stamp=$_stamp, value=$_value)';
}

/// `(wallTime, logical, peer)` total order: whether [a] dominates [b].
bool _dominates(WireStamp a, WireStamp b) {
  if (a.wallTime != b.wallTime) return a.wallTime > b.wallTime;
  if (a.logical != b.logical) return a.logical > b.logical;
  return a.peer > b.peer;
}

bool _setEquals(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);

// ---------------------------------------------------------------------------
// SyncDriver seams (host-injected policy)
// ---------------------------------------------------------------------------

/// Monotonic clock seam (spec § SyncDriver — policy injected, no runtime in
/// core). The driver never *schedules* itself; the host calls [SyncDriver.tick]
/// on its own cadence and supplies wall-free monotonic millis.
abstract interface class Clock {
  /// Milliseconds from an arbitrary fixed origin; monotonic, non-decreasing.
  int nowMillis();
}

/// Sender-side answer to a peer's [IpcMessageResyncRequest] (spec § SyncDriver).
///
/// When a receiver detects a gap it can no longer close from retained deltas, it
/// asks for a covering [Snapshot]; the host plugs its projection in here to
/// produce one at `epoch >= fromEpoch`.
abstract interface class SnapshotProvider {
  /// A full-state [IpcMessageSnapshot] covering [fromEpoch] (its `epoch` MUST be
  /// `>= fromEpoch`).
  IpcMessage snapshot(Epoch fromEpoch);
}

/// Transport sink for IPC messages. [send] returns `true` on success; a `false`
/// return is a transient send failure the driver retains-and-stalls on (it is
/// never fatal). Mirrors the `IpcSink` trait in `lazily-rs/src/ipc.rs`.
abstract interface class IpcSink {
  /// Send one IPC protocol message; `true` on success, `false` on a transient
  /// transport failure.
  bool send(IpcMessage message);
}

/// Transport source for IPC messages. [recv] returns the next message, or `null`
/// when the source is currently exhausted or closed. A read failure is signalled
/// by *throwing* (the driver surfaces it as [DriverError]). Mirrors the
/// `IpcSource` trait in `lazily-rs/src/ipc.rs`.
abstract interface class IpcSource {
  /// Receive the next IPC message, or `null` if the source is exhausted.
  IpcMessage? recv();
}

// ---------------------------------------------------------------------------
// SyncDriver
// ---------------------------------------------------------------------------

/// What one [SyncDriver.tick] accomplished (spec § SyncDriver).
///
/// [applied] are the inbound `Snapshot` / `Delta` / `CrdtSync` frames the host
/// MUST fold into its projection this tick — the driver has already advanced the
/// receiver cursor for them, so folding is the caller's remaining obligation.
class Progress {
  Progress({
    this.sent = 0,
    List<IpcMessage>? applied,
    this.resyncRequested = false,
    this.snapshotsServed = 0,
    this.peerAckedThrough = 0,
    this.retained = 0,
  }) : applied = applied ?? [];

  /// Data frames pushed to the sink this tick (fresh enqueues + reconnect
  /// replays).
  int sent;

  /// Inbound frames the host must fold into its projection (applied).
  final List<IpcMessage> applied;

  /// A gap was detected inbound and a [IpcMessageResyncRequest] was emitted.
  bool resyncRequested;

  /// Inbound [IpcMessageResyncRequest]s answered with a provider snapshot.
  int snapshotsServed;

  /// The peer's ack cursor after this tick (our outbox retention / resume
  /// point).
  int peerAckedThrough;

  /// Outbox frames still unacked (retained for reconnect replay).
  int retained;

  @override
  String toString() => 'Progress(sent=$sent, applied=${applied.length}, '
      'resyncRequested=$resyncRequested, snapshotsServed=$snapshotsServed, '
      'peerAckedThrough=$peerAckedThrough, retained=$retained)';
}

/// A transport error surfaced by [SyncDriver.tick].
///
/// A *sink* failure is not fatal — the frame is retained in the outbox and
/// replayed on the next [SyncDriver.onReconnect], per the spec's
/// retain-on-fail / resync-on-reconnect loop shape — so it is reported as a
/// stall, not an error. Only a *source* read failure is thrown as a
/// [DriverError], signalling the host to re-establish the transport and call
/// [SyncDriver.onReconnect].
class DriverError implements Exception {
  /// The inbound source failed to read; the host should reconnect.
  const DriverError.source(this.cause) : kind = 'Source';

  /// The failure kind discriminant (currently always `'Source'`).
  final String kind;

  /// The underlying error thrown by the [IpcSource].
  final Object cause;

  @override
  bool operator ==(Object other) =>
      other is DriverError && other.kind == kind && other.cause == cause;

  @override
  int get hashCode => Object.hash(kind, cause);

  @override
  String toString() => 'DriverError.$kind($cause)';
}

/// Full-duplex reliable-sync loop driver (spec § SyncDriver).
///
/// One driver drives one peer connection over a caller-supplied [IpcSink] /
/// [IpcSource] pair. It composes the three pure-protocol pieces into the loop
/// shape the spec pins:
///
/// 1. **resync-on-reconnect** — [onReconnect] arms a replay of the unacked
///    outbox suffix from the peer's ack cursor and re-advertises our receiver
///    cursor, so a dropped-frame gap converges;
/// 2. **drain** — pop host-enqueued outbound data frames, [DurableOutbox.append]
///    each *before* sending (at-least-once durability), send via the sink;
/// 3. **retain-on-fail** — a send error leaves the frame in the outbox (unacked)
///    and stops the drain; it is re-sent on the next reconnect;
/// 4. **receive** — read inbound frames, route control frames ([OutboxAck] →
///    advance retention; [ResyncRequest] → answer with a provider snapshot) and
///    feed data frames through the [ResyncCoordinator].
///
/// The driver owns no threads, no clock source, and no storage engine — the host
/// injects all three ([Clock], the transport pair, the outbox) and decides the
/// tick cadence.
class SyncDriver {
  /// A driver whose receiver has already applied through [lastEpoch] (0 = fresh;
  /// a [Snapshot] seeds the first epoch — resume otherwise).
  SyncDriver({
    required IpcSink sink,
    required IpcSource source,
    required DurableOutbox outbox,
    required Clock clock,
    required SnapshotProvider provider,
    Epoch lastEpoch = 0,
  })  : _sink = sink,
        _source = source,
        _outbox = outbox,
        _clock = clock,
        _provider = provider,
        _coordinator = ResyncCoordinator(lastEpoch);

  final IpcSink _sink;
  final IpcSource _source;
  final DurableOutbox _outbox;
  final Clock _clock;
  final SnapshotProvider _provider;
  final ResyncCoordinator _coordinator;

  /// Host-enqueued outbound data frames staged before append-then-send.
  final Queue<OutboxFrame> _pending = Queue();

  /// Highest epoch the peer has acked — our outbox retention + reconnect resume
  /// cursor.
  Epoch _peerAckedThrough = 0;

  /// We applied an inbound frame and owe the peer an [OutboxAck] (retried until
  /// sent).
  bool _ackOwed = false;

  /// A reconnect happened; the next tick replays the unacked outbox suffix.
  bool _replayPending = false;

  /// Millis since the last sink send failure; `null` when the sink is healthy.
  int? _stalledSince;

  /// The underlying outbox (diagnostics / durable-store flush).
  DurableOutbox get outbox => _outbox;

  /// Stage an outbound data frame at [epoch] for the next tick's drain. [epoch]
  /// is the frame's accepted-event count (`Delta.epoch` / `Snapshot.epoch`); it
  /// becomes the outbox retention key.
  void enqueue(Epoch epoch, IpcMessage msg) {
    _pending.add((epoch, msg));
  }

  /// Signal that the transport was re-established; the next [tick] replays the
  /// unacked outbox suffix and re-advertises our receiver cursor.
  void onReconnect() {
    _replayPending = true;
    _ackOwed = true;
    _stalledSince = null;
  }

  /// The receiver's current applied epoch.
  Epoch lastEpoch() => _coordinator.lastEpoch;

  /// Whether the sink is currently stalled (last send failed, awaiting
  /// reconnect).
  bool isStalled() => _stalledSince != null;

  /// Millis the sink has been stalled as of [now], or `0` when healthy — a
  /// backoff signal for the host scheduler (which owns cadence/backoff policy).
  int stalledFor(int now) {
    final since = _stalledSince;
    if (since == null) return 0;
    final d = now - since;
    return d > 0 ? d : 0;
  }

  /// Run one loop pass. See the class docs for the resync → drain → retain →
  /// receive shape. Sink failures retain-and-stall (not an error); only an
  /// inbound source read failure throws [DriverError].
  Progress tick() {
    final now = _clock.nowMillis();
    final progress = Progress();

    // 1. resync-on-reconnect: replay the unacked outbox suffix, oldest first.
    if (_replayPending) {
      _replayPending = false;
      for (final (_, msg) in _outbox.replayFrom(_peerAckedThrough)) {
        if (_sink.send(msg)) {
          progress.sent += 1;
        } else {
          _stalledSince = now;
          _replayPending = true; // finish the replay after the next reconnect
          break;
        }
      }
    }

    // 2. drain fresh enqueues: append-before-send, retain-and-stop on failure.
    //    A pre-existing stall (a prior failed send, no reconnect yet) skips the
    //    drain entirely — do not push into a sink already known to be down.
    while (_stalledSince == null) {
      if (_pending.isEmpty) break;
      final (epoch, msg) = _pending.first;
      _outbox.append(epoch, msg);
      _pending.removeFirst();
      if (_sink.send(msg)) {
        progress.sent += 1;
        _stalledSince = null;
      } else {
        // Retained in the outbox (unacked) → replayed on reconnect.
        _stalledSince = now;
        break;
      }
    }

    // 3. receive: route control frames + feed data frames through the
    //    coordinator.
    while (true) {
      IpcMessage? msg;
      try {
        msg = _source.recv();
      } on DriverError {
        rethrow;
      } catch (e) {
        throw DriverError.source(e);
      }
      if (msg == null) break;
      switch (msg) {
        case IpcMessageOutboxAck(:final value):
          if (value.throughEpoch > _peerAckedThrough) {
            _peerAckedThrough = value.throughEpoch;
          }
          _outbox.ackThrough(value.throughEpoch);
        case IpcMessageResyncRequest(:final value):
          final snap = _provider.snapshot(value.fromEpoch);
          if (_sink.send(snap)) {
            progress.snapshotsServed += 1;
          } else {
            _stalledSince = now;
          }
        case IpcMessageCrdtSync():
          // Idempotent anti-entropy plane — the host folds it directly.
          progress.applied.add(msg);
        case IpcMessageSnapshot() || IpcMessageDelta():
          final action = _coordinator.ingest(msg);
          switch (action) {
            case ResyncActionApply():
              _ackOwed = true;
              progress.applied.add(msg);
            case ResyncActionRequestSnapshot(:final fromEpoch):
              final req =
                  IpcMessage.ofResyncRequest(ResyncRequest(fromEpoch: fromEpoch));
              if (_sink.send(req)) {
                progress.resyncRequested = true;
              } else {
                _stalledSince = now;
              }
            case ResyncActionIgnore():
              break;
          }
      }
    }

    // 4. advertise our receiver cursor if we applied anything (retry until
    //    sent).
    if (_ackOwed && _sink.send(_coordinator.ack())) {
      _ackOwed = false;
    }

    progress.peerAckedThrough = _peerAckedThrough;
    progress.retained = _outbox.retainedEpochs().length;
    return progress;
  }
}
