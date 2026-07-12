import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:lazily/ipc.dart';
import 'package:test/test.dart';

/// Reliable-sync conformance (`#lzsync`, lazily-spec/conformance/reliable-sync/).
///
/// Replays the canonical fixtures against the native [ResyncCoordinator] /
/// [InMemoryOutbox] / [OrSet] / [WireLwwRegister], round-trips the two control
/// frames ([ResyncRequest] / [OutboxAck]) through JSON, and pins the
/// [SyncDriver] loop shape over a scripted transport seam. Cross-language pin
/// with lazily-rs / lazily-kt / lazily-js / lazily-cpp; backstop lazily-formal
/// ReliableSync.lean.

final _localDir = Directory('test/conformance/reliable-sync');
final _specDir = Directory('../lazily-spec/conformance/reliable-sync');

String _fixturePath(String name) {
  final local = '${_localDir.path}/$name';
  if (File(local).existsSync()) return local;
  final sibling = '${_specDir.path}/$name';
  if (File(sibling).existsSync()) return sibling;
  throw StateError('fixture not found: $name (looked in $local, $sibling)');
}

Map<String, dynamic> _load(String name) =>
    jsonDecode(File(_fixturePath(name)).readAsStringSync())
        as Map<String, dynamic>;

Map<String, dynamic> _scenario(Map<String, dynamic> fx, String name) =>
    (fx['scenarios'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((s) => s['name'] == name);

IpcMessage _msg(Object? wire) => IpcMessage.fromWire(wire);

List<OutboxFrame> _framesOf(Map<String, dynamic> sc, String key) =>
    (sc[key] as List)
        .cast<Map<String, dynamic>>()
        .map((e) => (e['epoch'] as int, IpcMessage.fromWire(e['frame'])))
        .toList();

WireStamp _stamp(Map<String, dynamic> o) => WireStamp(
      wallTime: o['wall_time'] as int,
      logical: o['logical'] as int,
      peer: o['peer'] as int,
    );

/// A reference file-backed [DurableOutbox] (crash-replay test helper): one
/// `[epoch, wire]` JSON row per line, reopened from disk to model a crash.
class _FileOutbox implements DurableOutbox {
  _FileOutbox(this.path) {
    if (!File(path).existsSync()) File(path).writeAsStringSync('');
  }

  final String path;
  int _ackedThrough = 0;

  List<OutboxFrame> _readAll() => File(path)
      .readAsStringSync()
      .split('\n')
      .where((l) => l.trim().isNotEmpty)
      .map((l) {
        final row = jsonDecode(l) as List;
        return (row[0] as int, IpcMessage.fromWire(row[1]));
      })
      .toList();

  @override
  void append(int epoch, IpcMessage msg) {
    File(path).writeAsStringSync('${jsonEncode([epoch, msg.toWire()])}\n',
        mode: FileMode.append);
  }

  @override
  void ackThrough(int epoch) {
    if (epoch > _ackedThrough) _ackedThrough = epoch;
    final retained = _readAll().where((e) => e.$1 > _ackedThrough);
    File(path).writeAsStringSync(
        retained.map((e) => '${jsonEncode([e.$1, e.$2.toWire()])}\n').join());
  }

  @override
  List<OutboxFrame> replayFrom(int cursor) {
    final out = _readAll().where((e) => e.$1 > cursor).toList();
    out.sort((a, b) => a.$1.compareTo(b.$1));
    return out;
  }

  @override
  List<int> retainedEpochs() {
    final es = _readAll().map((e) => e.$1).toList()..sort();
    return es;
  }
}

// -- SyncDriver scripted transport seam (mirrors lazily-rs / lazily-js) --------

class _Wire {
  final List<IpcMessage> sent = [];
  final Queue<IpcMessage> inbound = Queue();
  bool up = true;
  bool sourceErr = false;
}

class _TestSink implements IpcSink {
  _TestSink(this.wire);
  final _Wire wire;

  @override
  bool send(IpcMessage message) {
    if (!wire.up) return false;
    wire.sent.add(message);
    return true;
  }
}

class _TestSource implements IpcSource {
  _TestSource(this.wire);
  final _Wire wire;

  @override
  IpcMessage? recv() {
    if (wire.sourceErr) {
      wire.sourceErr = false;
      throw StateError('scripted source read failure');
    }
    return wire.inbound.isEmpty ? null : wire.inbound.removeFirst();
  }
}

class _ZeroClock implements Clock {
  @override
  int nowMillis() => 0;
}

/// SnapshotProvider that answers a ResyncRequest{from} with a snapshot at
/// from + 5.
class _SnapAhead implements SnapshotProvider {
  @override
  IpcMessage snapshot(int fromEpoch) =>
      IpcMessage.ofSnapshot(Snapshot(epoch: fromEpoch + 5));
}

SyncDriver _driverAt(_Wire wire, int lastEpoch) => SyncDriver(
      sink: _TestSink(wire),
      source: _TestSource(wire),
      outbox: InMemoryOutbox(),
      clock: _ZeroClock(),
      provider: _SnapAhead(),
      lastEpoch: lastEpoch,
    );

IpcMessage _dframe(int base, int epoch) =>
    IpcMessage.ofDelta(Delta(baseEpoch: base, epoch: epoch));

void main() {
  group('reliable-sync control-frame serde', () {
    test('ResyncRequest round-trips JSON', () {
      final m = IpcMessage.ofResyncRequest(const ResyncRequest(fromEpoch: 2));
      final text = jsonEncode(m.toWire());
      expect(text, '{"ResyncRequest":{"from_epoch":2}}');
      expect(IpcMessage.decodeJson(text).toWire(), m.toWire());
      expect(IpcMessage.decodeJson(text), m);
    });

    test('OutboxAck round-trips JSON', () {
      final m = IpcMessage.ofOutboxAck(const OutboxAck(throughEpoch: 41));
      final text = jsonEncode(m.toWire());
      expect(text, '{"OutboxAck":{"through_epoch":41}}');
      expect(IpcMessage.decodeJson(text).toWire(), m.toWire());
      expect(IpcMessage.decodeJson(text), m);
    });
  });

  group('reliable-sync conformance fixtures (#lzsync)', () {
    test('multi_epoch_delta.json', () {
      final fx = _load('multi_epoch_delta.json');
      expect(fx['kind'], 'ReliableSync');

      final sc = _scenario(fx, 'span_3_applies_equal_to_unit_fold');
      final d = sc['delta'] as Map<String, dynamic>;
      final base = d['base_epoch'] as int;
      final epoch = d['epoch'] as int;
      expect(epoch > base + 1, isTrue, reason: 'fixture pins a multi-epoch span');
      final delta = Delta(baseEpoch: base, epoch: epoch);
      expect(delta.span, epoch - base);
      final coord = ResyncCoordinator(sc['receiver_last_epoch'] as int);
      expect(coord.ingestDelta(delta).isApply, isTrue);
      expect(coord.lastEpoch,
          (sc['expect'] as Map)['receiver_last_epoch_after']);

      final gap = _scenario(fx, 'gap_rule_unchanged_under_span');
      final gc = ResyncCoordinator(gap['receiver_last_epoch'] as int);
      final gd = gap['delta'] as Map<String, dynamic>;
      final res = gc.ingestDelta(
          Delta(baseEpoch: gd['base_epoch'] as int, epoch: gd['epoch'] as int));
      expect(res, isA<ResyncActionRequestSnapshot>());
      expect((res as ResyncActionRequestSnapshot).fromEpoch,
          (gap['expect'] as Map)['request_from']);
      expect(gc.lastEpoch, gap['receiver_last_epoch']);
    });

    test('resync_gap_converge.json', () {
      final fx = _load('resync_gap_converge.json');

      final sc = _scenario(fx, 'drop_suffix_then_resync_converges');
      final coord = ResyncCoordinator(sc['start_last_epoch'] as int);
      var requests = 0;
      for (final frame in (sc['inbound'] as List).cast<Map<String, dynamic>>()) {
        if (frame['dropped'] == true) continue;
        final res = coord.ingest(_msg(frame['frame']));
        switch (frame['expect_action']) {
          case 'Apply':
            expect(res.isApply, isTrue);
          case 'RequestSnapshot':
            requests++;
            expect(res, isA<ResyncActionRequestSnapshot>());
            expect((res as ResyncActionRequestSnapshot).fromEpoch,
                frame['request_from']);
          default:
            expect(res.isIgnore, isTrue);
        }
        expect(coord.lastEpoch, frame['last_epoch_after']);
      }
      expect(coord.lastEpoch, (sc['expect'] as Map)['final_last_epoch']);
      expect(requests, (sc['expect'] as Map)['resync_requests_emitted']);

      final single = _scenario(fx, 'single_request_per_gap');
      final c2 = ResyncCoordinator(single['start_last_epoch'] as int);
      var req2 = 0;
      for (final frame
          in (single['inbound'] as List).cast<Map<String, dynamic>>()) {
        if (c2.ingest(_msg(frame['frame'])).isRequestSnapshot) req2++;
      }
      expect(req2, (single['expect'] as Map)['resync_requests_emitted']);
    });

    test('idempotent_redelivery.json', () {
      final fx = _load('idempotent_redelivery.json');
      for (final name in const [
        'replayed_delta_is_ignored',
        'duplicate_current_head_is_ignored'
      ]) {
        final sc = _scenario(fx, name);
        final coord = ResyncCoordinator(sc['start_last_epoch'] as int);
        for (final frame
            in (sc['inbound'] as List).cast<Map<String, dynamic>>()) {
          expect(coord.ingest(_msg(frame['frame'])).isIgnore, isTrue,
              reason: name);
          expect(coord.lastEpoch, frame['last_epoch_after']);
        }
        expect(coord.lastEpoch, (sc['expect'] as Map)['final_last_epoch']);
      }
    });

    test('outbox_replay_after_crash.json', () {
      final fx = _load('outbox_replay_after_crash.json');
      final sc = _scenario(fx, 'crash_between_append_and_ack_replays_on_reconnect');
      final appended = _framesOf(sc, 'appended');
      final ack = sc['ack_through'] as int;
      final cursor = sc['reconnect_cursor'] as int;
      final expect_ = sc['expect'] as Map<String, dynamic>;

      final dir = Directory.systemTemp.createTempSync('lz_outbox_dart_');
      final path = '${dir.path}/outbox.jsonl';

      try {
        final mem = InMemoryOutbox();
        var file = _FileOutbox(path);
        for (final (e, m) in appended) {
          mem.append(e, m);
          file.append(e, m);
        }
        mem.ackThrough(ack);
        file.ackThrough(ack);

        final retainedAfterAck =
            (expect_['retained_after_ack'] as List).cast<int>();
        expect(mem.retainedEpochs(), retainedAfterAck);
        expect(file.retainedEpochs(), retainedAfterAck);

        // "crash": reopen the durable file outbox from disk.
        file = _FileOutbox(path);
        final replay = file.replayFrom(cursor);
        expect(replay.map((e) => e.$1).toList(),
            (expect_['replayed_from_cursor'] as List).cast<int>());

        final coord = ResyncCoordinator(cursor);
        final applied = <int>[];
        for (final (_, m) in replay) {
          if (coord.ingest(m).isApply) applied.add(coord.lastEpoch);
        }
        expect(applied, (expect_['receiver_applies'] as List).cast<int>());
        expect(coord.lastEpoch, expect_['receiver_last_epoch_after']);
      } finally {
        dir.deleteSync(recursive: true);
      }

      // send_failure_retains_frame_for_next_tick
      final sc2 = _scenario(fx, 'send_failure_retains_frame_for_next_tick');
      final ex2 = sc2['expect'] as Map<String, dynamic>;
      final retained = (ex2['retained'] as List).cast<int>();
      final mem2 = InMemoryOutbox();
      for (final (e, m) in _framesOf(sc2, 'appended')) {
        mem2.append(e, m);
      }
      expect(mem2.retainedEpochs(), retained);
      expect(mem2.replayFrom(retained[0] - 1).map((e) => e.$1).toList(),
          retained);
    });

    test('liveness_orset_lww.json', () {
      final fx = _load('liveness_orset_lww.json');

      final add = _scenario(fx, 'open_set_add_wins_over_stale_remove');
      final set = OrSet();
      for (final op in (add['ops'] as List).cast<Map<String, dynamic>>()) {
        if (op['op'] == 'add') {
          set.add(op['tag'] as String);
        } else if (op['op'] == 'remove') {
          set.removeObserved((op['observed_tags'] as List).cast<String>());
        }
      }
      expect(set.present(), (add['expect'] as Map)['present']);

      final lww = _scenario(fx, 'lww_alive_highest_stamp_wins');
      final ops = (lww['ops'] as List).cast<Map<String, dynamic>>();
      final reg = WireLwwRegister<bool>(
          _stamp(ops[0]['stamp'] as Map<String, dynamic>),
          ops[0]['value'] as bool);
      for (final op in ops.skip(1)) {
        reg.set(_stamp(op['stamp'] as Map<String, dynamic>),
            op['value'] as bool);
      }
      expect(reg.value, (lww['expect'] as Map)['value']);

      final death = _scenario(fx, 'whole_editor_death_cascades');
      final open = (death['open_set'] as List)
          .cast<Map<String, dynamic>>()
          .where((e) => e['present'] == true)
          .map((e) {
        final parts = (e['key'] as String).split('/');
        return (parts[0], int.parse(parts[1].replaceFirst('pid', '')));
      }).toList();
      final alive = <int, WireLwwRegister<bool>>{};
      (death['alive_before'] as Map).forEach((pid, v) {
        alive[int.parse(pid as String)] = WireLwwRegister<bool>(
            const WireStamp(wallTime: 1, logical: 0, peer: 1), v as bool);
      });
      final op = death['op'] as Map<String, dynamic>;
      final pid = int.parse((op['key'] as String).replaceFirst('alive/pid', ''));
      alive[pid]!.set(_stamp(op['stamp'] as Map<String, dynamic>),
          op['value'] as bool);
      final live = <String>{
        for (final (doc, p) in open)
          if (alive[p]?.value == true) doc
      }.toList()
        ..sort();
      expect(live,
          (death['expect'] as Map)['live_docs_after'].cast<String>().toList()
            ..sort());
    });
  });

  group('liveness cell laws', () {
    WireStamp st(int w) => WireStamp(wallTime: w, logical: 0, peer: 1);

    test('OrSet join is commutative and add wins over stale remove', () {
      final a = OrSet()..add('t1');
      final b = OrSet()
        ..removeObserved(['t1'])
        ..add('t3'); // re-open with a tag the close never observed
      final ab = OrSet()
        ..join(a)
        ..join(b);
      final ba = OrSet()
        ..join(b)
        ..join(a);
      expect(ab, ba, reason: 'join is commutative');
      expect(ab.present(), isTrue, reason: 'add tag t3 not shadowed → present');
    });

    test('WireLwwRegister join keeps the higher stamp', () {
      final a = WireLwwRegister<bool>(st(10), true);
      a.join(WireLwwRegister<bool>(st(20), false));
      expect(a.value, isFalse);
      // re-joining a stale lower stamp is a no-op (idempotent under retry)
      a.join(WireLwwRegister<bool>(st(5), true));
      expect(a.value, isFalse);
    });
  });

  // -- SyncDriver loop-shape unit tests (mirror lazily-rs / lazily-js) --------

  group('sync-driver loop shape (#sync-driver)', () {
    test('drains append-before-send and retains until acked', () {
      final wire = _Wire();
      final d = _driverAt(wire, 0);
      d.enqueue(1, _dframe(0, 1));
      d.enqueue(2, _dframe(1, 2));
      var p = d.tick();
      expect(p.sent, 2, reason: 'both fresh frames pushed to the sink');
      expect(wire.sent.length, 2);
      expect(p.retained, 2, reason: 'appended-before-send, retained until acked');
      expect(d.isStalled(), isFalse);

      // Peer proves receipt → the outbox prunes and the resume cursor advances.
      wire.inbound.add(IpcMessage.ofOutboxAck(const OutboxAck(throughEpoch: 2)));
      p = d.tick();
      expect(p.peerAckedThrough, 2);
      expect(p.retained, 0, reason: 'acked frames pruned');
    });

    test('retains on send failure and replays on reconnect', () {
      final wire = _Wire();
      final d = _driverAt(wire, 0);
      wire.up = false; // sink down before the first send
      d.enqueue(1, _dframe(0, 1));
      var p = d.tick();
      expect(p.sent, 0);
      expect(d.isStalled(), isTrue, reason: 'a failed send stalls the driver');
      expect(p.retained, 1,
          reason: 'frame retained in the outbox despite the failure');
      expect(wire.sent, isEmpty);
      expect(d.stalledFor(250), 250,
          reason: 'stall duration is a host backoff signal');

      // Transport recovers → the unacked suffix replays from the ack cursor.
      wire.up = true;
      d.onReconnect();
      p = d.tick();
      expect(d.isStalled(), isFalse);
      expect(p.sent, 1, reason: 'the retained frame is replayed');
      expect(
          wire.sent.any((m) => m.isDelta && m.delta!.epoch == 1), isTrue,
          reason: 'the replayed delta reached the sink');
    });

    test('applies inbound delta and advertises receiver cursor', () {
      final wire = _Wire();
      final d = _driverAt(wire, 0);
      wire.inbound.add(_dframe(0, 1));
      final p = d.tick();
      expect(p.applied.length, 1,
          reason: 'the applied frame is handed to the host');
      expect(d.lastEpoch(), 1);
      expect(
          wire.sent.any((m) => m.isOutboxAck && m.outboxAck!.throughEpoch == 1),
          isTrue,
          reason: 'an OutboxAck advertising the new cursor was sent');
    });

    test('re-delivery is an idempotent no-op', () {
      final wire = _Wire();
      final d = _driverAt(wire, 0);
      wire.inbound.add(_dframe(0, 1));
      expect(d.tick().applied.length, 1);
      // Re-deliver the exact same frame (an outbox replay from the peer).
      wire.inbound.add(_dframe(0, 1));
      final p = d.tick();
      expect(p.applied.length, 0,
          reason: 'already-applied re-delivery is ignored');
      expect(d.lastEpoch(), 1, reason: 'cursor does not double-advance');
    });

    test('requests a snapshot on an inbound gap', () {
      final wire = _Wire();
      final d = _driverAt(wire, 2);
      wire.inbound.add(_dframe(3, 4)); // base 3 > last 2 → gap
      final p = d.tick();
      expect(p.resyncRequested, isTrue);
      expect(p.applied.length, 0, reason: 'the gapped delta is not applied');
      expect(
          wire.sent.any(
              (m) => m.isResyncRequest && m.resyncRequest!.fromEpoch == 2),
          isTrue,
          reason: 'a ResyncRequest at the current cursor was emitted');
    });

    test('answers a ResyncRequest with a provider snapshot', () {
      final wire = _Wire();
      final d = _driverAt(wire, 0);
      wire.inbound
          .add(IpcMessage.ofResyncRequest(const ResyncRequest(fromEpoch: 2)));
      final p = d.tick();
      expect(p.snapshotsServed, 1);
      expect(wire.sent.any((m) => m.isSnapshot && m.snapshot!.epoch == 7),
          isTrue,
          reason: 'a covering snapshot (from + 5) was sent');
    });

    test('surfaces a source read error as DriverError', () {
      final wire = _Wire();
      final d = _driverAt(wire, 0);
      wire.sourceErr = true;
      expect(
          () => d.tick(),
          throwsA(isA<DriverError>()
              .having((e) => e.kind, 'kind', 'Source')));
    });

    test('gap then covering snapshot converges', () {
      final wire = _Wire();
      final d = _driverAt(wire, 2);
      wire.inbound.add(_dframe(4, 5)); // gap
      d.tick();
      expect(d.lastEpoch(), 2, reason: 'still stuck at the pre-gap cursor');
      wire.inbound.add(IpcMessage.ofSnapshot(const Snapshot(epoch: 5)));
      final p = d.tick();
      expect(p.applied.length, 1);
      expect(d.lastEpoch(), 5, reason: 'snapshot restored convergence');
    });
  });
}
