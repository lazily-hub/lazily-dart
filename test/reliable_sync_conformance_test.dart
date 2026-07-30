import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:lazily/ipc.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

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

// Fixture resolution is SIBLING-FIRST (`#lzspecconf`): the canonical
// lazily-spec checkout wins whenever it is present, and the mirrored copy under
// `test/conformance/` is a fallback for a checkout without the sibling — never
// an authority. The reverse order silently shadowed the canonical fixture with
// a stale mirror, so CI cloned lazily-spec and then tested the local copy and
// still reported green. `conformance_fixture_drift_test.dart` byte-compares the
// two whenever both exist, so a stale mirror fails loudly instead of hiding.
String _fixturePath(String name) {
  final sibling = '${_specDir.path}/$name';
  if (File(sibling).existsSync()) return sibling;
  final local = '${_localDir.path}/$name';
  if (File(local).existsSync()) return local;
  throw StateError('fixture not found: $name (looked in $local, $sibling)');
}

Map<String, dynamic> _load(String name) =>
    attributeFixture(jsonDecode(File(_fixturePath(name)).specReadAsStringSync()))
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

/// The corpus's name for a [ResyncAction] variant.
String _actionName(ResyncAction action) => switch (action) {
      ResyncActionApply() => 'Apply',
      ResyncActionRequestSnapshot() => 'RequestSnapshot',
      ResyncActionIgnore() => 'Ignore',
    };

/// Fold one inbound frame into a `node -> bytes` projection, the way a receiver
/// materializes the graph.
///
/// A Snapshot REPLACES the projection — it is the sender's whole state at its
/// epoch, which is exactly why gap recovery is state-equivalent rather than
/// lossy. A Delta folds its cell writes in.
void _fold(Map<NodeId, List<int>> state, IpcMessage m) {
  if (m is IpcMessageSnapshot) {
    state.clear();
    for (final node in m.value.nodes) {
      final s = node.state;
      if (s is NodeStatePayload) state[node.node] = s.bytes.toList();
    }
    return;
  }
  if (m is! IpcMessageDelta) return;
  for (final op in m.value.ops) {
    final NodeId node;
    final IpcValue payload;
    if (op is DeltaOpCellSet) {
      node = op.node;
      payload = op.payload;
    } else if (op is DeltaOpSlotValue) {
      node = op.node;
      payload = op.payload;
    } else {
      continue;
    }
    if (payload is IpcValueInline) state[node] = payload.bytes.toList();
  }
}

/// A fixture's `{"<node>": [bytes]}` projection in this runner's shape.
Map<NodeId, List<int>> _stateOf(Object? declared) => {
      for (final e in (declared as Map).entries)
        int.parse(e.key as String): (e.value as List).cast<int>(),
    };

bool _sameState(Map<NodeId, List<int>> a, Map<NodeId, List<int>> b) =>
    a.length == b.length &&
    a.keys.every((k) {
      final x = a[k]!, y = b[k];
      return y != null &&
          x.length == y.length &&
          List.generate(x.length, (i) => x[i] == y[i]).every((v) => v);
    });

// A boolean property the fixture DECLARES is now checked through
// `assertKey(block, key, observed, what)`, which both marks the key asserted
// and keeps the original polarity rule: deliberately not
// `expect(observed, isTrue)` guarded by the declared value, because a fixture
// that flips the claim to `false` must then require the property to be ABSENT,
// or the assertion only ever tests one polarity.

/// A reference file-backed [DurableOutbox] (crash-replay test helper): one
/// `[epoch, wire]` JSON row per line, reopened from disk to model a crash.
class _FileOutbox implements DurableOutbox {
  _FileOutbox(this.path) {
    if (!File(path).existsSync()) File(path).writeAsStringSync('');
  }

  final String path;
  int _ackedThrough = 0;

  List<OutboxFrame> _readAll() => File(path)
      .specReadAsStringSync()
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
      final ex = assertionsOf(sc['expect']);
      final d = sc['delta'] as Map<String, dynamic>;
      final base = d['base_epoch'] as int;
      final epoch = d['epoch'] as int;
      expect(epoch > base + 1, isTrue, reason: 'fixture pins a multi-epoch span');
      final delta = Delta(baseEpoch: base, epoch: epoch);
      expect(delta.span, epoch - base);
      final start = sc['receiver_last_epoch'] as int;
      final coord = ResyncCoordinator(start);
      final action = coord.ingestDelta(delta);
      assertKey(ex, 'action', _actionName(action));
      assertKey(ex, 'applied', action.isApply, 'delta applied');
      assertKey(ex, 'receiver_last_epoch_after', coord.lastEpoch);
      // `atomic_advance`: the whole span lands in ONE ingest — the cursor never
      // rests on an intermediate epoch.
      assertKey(ex, 'atomic_advance', coord.lastEpoch - start == delta.span,
          'span advanced the cursor atomically, not epoch by epoch');
      // `fold_equivalent`: folding the same span as unit deltas leaves the
      // receiver on the same cursor, so a span is an optimization and not a
      // different protocol.
      final unit = ResyncCoordinator(start);
      for (var e = base; e < epoch; e++) {
        expect(unit.ingestDelta(Delta(baseEpoch: e, epoch: e + 1)).isApply,
            isTrue);
      }
      assertKey(ex, 'fold_equivalent', unit.lastEpoch == coord.lastEpoch,
          'span fold equals the unit fold');

      final gap = _scenario(fx, 'gap_rule_unchanged_under_span');
      final gapEx = assertionsOf(gap['expect']);
      final gc = ResyncCoordinator(gap['receiver_last_epoch'] as int);
      final gd = gap['delta'] as Map<String, dynamic>;
      final res = gc.ingestDelta(
          Delta(baseEpoch: gd['base_epoch'] as int, epoch: gd['epoch'] as int));
      expect(res, isA<ResyncActionRequestSnapshot>());
      assertKey(gapEx, 'action', _actionName(res));
      assertKey(gapEx, 'applied', res.isApply, 'gap delta is not applied');
      assertKey(gapEx, 'request_from',
          (res as ResyncActionRequestSnapshot).fromEpoch);
      assertKey(gapEx, 'receiver_last_epoch_after', gc.lastEpoch);
      expect(gc.lastEpoch, gap['receiver_last_epoch']);
    });

    test('resync_gap_converge.json', () {
      final fx = _load('resync_gap_converge.json');

      final sc = _scenario(fx, 'drop_suffix_then_resync_converges');
      final ex = assertionsOf(sc['expect']);
      final coord = ResyncCoordinator(sc['start_last_epoch'] as int);
      // What the dropping receiver actually materializes, and — separately —
      // what it would hold from the deltas ALONE. The second is what gives
      // `equals_no_drop_receiver` teeth below.
      final state = <NodeId, List<int>>{};
      final deltasOnly = <NodeId, List<int>>{};
      final sender = <NodeId, List<int>>{};
      var requests = 0;
      for (final frame in (sc['inbound'] as List).cast<Map<String, dynamic>>()) {
        if (frame['dropped'] == true) continue;
        final m = _msg(frame['frame']);
        final res = coord.ingest(m);
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
        if (res.isApply) _fold(state, m);
        if (m.isDelta) _fold(deltasOnly, m);
        // The covering Snapshot IS the sender's whole state at the final epoch,
        // and therefore what a receiver that dropped nothing holds.
        if (m.isSnapshot) _fold(sender, m);
        expect(coord.lastEpoch, frame['last_epoch_after']);
      }
      assertKey(ex, 'final_last_epoch', coord.lastEpoch);
      assertKey(ex, 'resync_requests_emitted', requests);
      assertKeyWith(ex, 'converged_nodes',
          (v) => expect(state, _stateOf(v)));
      assertKey(ex, 'equals_no_drop_receiver', _sameState(state, sender),
          'gap recovery is state-equivalent, not lossy');
      expect(_sameState(deltasOnly, sender), isFalse,
          reason: 'the deltas this receiver saw are MISSING the dropped '
              "suffix's writes — without that the equality above would hold "
              'trivially and prove nothing about recovery');

      final single = _scenario(fx, 'single_request_per_gap');
      final singleEx = assertionsOf(single['expect']);
      final c2 = ResyncCoordinator(single['start_last_epoch'] as int);
      var req2 = 0;
      for (final frame
          in (single['inbound'] as List).cast<Map<String, dynamic>>()) {
        if (c2.ingest(_msg(frame['frame'])).isRequestSnapshot) req2++;
      }
      assertKey(singleEx, 'resync_requests_emitted', req2);
      assertKey(singleEx, 'final_last_epoch', c2.lastEpoch);
    });

    test('idempotent_redelivery.json', () {
      final fx = _load('idempotent_redelivery.json');
      for (final name in const [
        'replayed_delta_is_ignored',
        'duplicate_current_head_is_ignored'
      ]) {
        final sc = _scenario(fx, name);
        final ex = assertionsOf(sc['expect']);
        final coord = ResyncCoordinator(sc['start_last_epoch'] as int);
        final state = _stateOf(sc['state_before']);
        final before = {
          for (final e in state.entries) e.key: List<int>.of(e.value),
        };
        for (final frame
            in (sc['inbound'] as List).cast<Map<String, dynamic>>()) {
          final m = _msg(frame['frame']);
          final res = coord.ingest(m);
          expect(res.isIgnore, isTrue, reason: name);
          // Fold only what the coordinator ACCEPTED. The re-delivered frame
          // carries a different value for the same node, so a receiver that
          // folded regardless of the decision would visibly diverge here —
          // which is what makes `state_after` a real assertion and not a
          // restatement of `state_before`.
          if (res.isApply) _fold(state, m);
          expect(coord.lastEpoch, frame['last_epoch_after']);
        }
        assertKey(ex, 'final_last_epoch', coord.lastEpoch);
        assertKeyWith(ex, 'state_after', (v) => expect(state, _stateOf(v)));
        assertKey(ex, 'net_effect_unchanged', _sameState(state, before),
            'at-least-once delivery, exactly-once effect ($name)');
      }
    });

    test('outbox_replay_after_crash.json', () {
      final fx = _load('outbox_replay_after_crash.json');
      final sc = _scenario(fx, 'crash_between_append_and_ack_replays_on_reconnect');
      final appended = _framesOf(sc, 'appended');
      final ack = sc['ack_through'] as int;
      final cursor = sc['reconnect_cursor'] as int;
      final expect_ = assertionsOf(sc['expect']);

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

        final retainedAfterAck = assertKeyWith(expect_, 'retained_after_ack',
            (v) => (v as List).cast<int>());
        expect(mem.retainedEpochs(), retainedAfterAck);
        expect(file.retainedEpochs(), retainedAfterAck);

        // "crash": reopen the durable file outbox from disk.
        file = _FileOutbox(path);
        final replay = file.replayFrom(cursor);
        final replayed = replay.map((e) => e.$1).toList();
        assertKeyWith(expect_, 'replayed_from_cursor',
            (v) => expect(replayed, (v as List).cast<int>()));
        // `replay_order` is not a duplicate of `replayed_from_cursor`: the set
        // can be right while the ORDER is wrong, and a receiver that folds a
        // later epoch first sees a gap it can never close.
        assertKeyWith(expect_, 'replay_order',
            (v) => expect(replayed, (v as List).cast<int>()));

        final coord = ResyncCoordinator(cursor);
        final applied = <int>[];
        for (final (_, m) in replay) {
          if (coord.ingest(m).isApply) applied.add(coord.lastEpoch);
        }
        assertKeyWith(expect_, 'receiver_applies',
            (v) => expect(applied, (v as List).cast<int>()));
        assertKey(expect_, 'receiver_last_epoch_after', coord.lastEpoch);

        // At-least-once on the wire, exactly-once in effect: every frame the
        // sender still owed lands, and none lands twice.
        final owed = [
          for (final (e, _) in appended)
            if (e > ack) e,
        ];
        final lost = owed.where((e) => !applied.contains(e)).length;
        final doubled = applied.length - applied.toSet().length;
        assertKey(expect_, 'ops_lost', lost);
        assertKey(expect_, 'ops_doubled', doubled);
        assertKey(expect_, 'exactly_once_effect', lost == 0 && doubled == 0,
            'crash replay is at-least-once delivery with exactly-once effect');
      } finally {
        dir.deleteSync(recursive: true);
      }

      // send_failure_retains_frame_for_next_tick
      final sc2 = _scenario(fx, 'send_failure_retains_frame_for_next_tick');
      final ex2 = assertionsOf(sc2['expect']);
      final retained =
          assertKeyWith(ex2, 'retained', (v) => (v as List).cast<int>());
      final mem2 = InMemoryOutbox();
      for (final (e, m) in _framesOf(sc2, 'appended')) {
        mem2.append(e, m);
      }
      expect(mem2.retainedEpochs(), retained);
      // The send failed and nothing was acked, so the frame is still owed.
      assertKey(
          ex2,
          'frame_retained_after_failed_send',
          sc2['send_fails_first_attempt'] == true &&
              sc2['ack_through'] == null &&
              mem2.retainedEpochs().isNotEmpty,
          'a failed send retains the frame');
      final resent = mem2.replayFrom(retained[0] - 1).map((e) => e.$1).toList();
      assertKeyWith(ex2, 'resent_on_next_tick',
          (v) => expect(resent, (v as List).cast<int>()));
      // A retained frame is a DELAY, not a hole: the next tick replays it, so
      // the receiver never sees an epoch it can no longer obtain.
      assertKey(ex2, 'permanent_gap', resent.isEmpty,
          'a retained frame is redeliverable, so there is no permanent gap');
    });

    test('liveness_orset_lww.json', () {
      final fx = _load('liveness_orset_lww.json');

      final add = _scenario(fx, 'open_set_add_wins_over_stale_remove');
      final addEx = assertionsOf(add['expect']);
      final addOps = (add['ops'] as List).cast<Map<String, dynamic>>();
      OrSet replayOrSet(Iterable<Map<String, dynamic>> ops) {
        final s = OrSet();
        for (final op in ops) {
          if (op['op'] == 'add') {
            s.add(op['tag'] as String);
          } else if (op['op'] == 'remove') {
            s.removeObserved((op['observed_tags'] as List).cast<String>());
          }
        }
        return s;
      }

      final set = replayOrSet(addOps);
      assertKey(addEx, 'present', set.present());

      // `reason` is the corpus's prose for WHY the set stays present. Holding
      // it to the tag the replay actually computes stops the explanation from
      // drifting away from the data it explains.
      final addedTags = {
        for (final op in addOps)
          if (op['op'] == 'add') op['tag'] as String,
      };
      final observedTags = {
        for (final op in addOps)
          if (op['op'] == 'remove') ...(op['observed_tags'] as List).cast<String>(),
      };
      final unobserved = addedTags.difference(observedTags);
      expect(set.present(), unobserved.isNotEmpty,
          reason: 'present iff some added tag outlived every remove');
      assertKeyWith(addEx, 'reason', (v) {
        for (final tag in unobserved) {
          expect(v, contains(tag),
              reason: 'the fixture explains presence by a tag no remove '
                  'observed; the replay computed $unobserved');
        }
      });
      // `order_independent`: an OrSet join is commutative, so the reversed
      // transcript must reach the same verdict.
      assertKey(addEx, 'order_independent',
          replayOrSet(addOps.reversed).present() == set.present(),
          'OrSet outcome is order-independent');
      // `redeliver_applied_count`: re-delivering the whole transcript applies
      // nothing new.
      final redelivered = replayOrSet(addOps)..join(set);
      assertKeyWith(addEx, 'redeliver_applied_count', (v) {
        expect(redelivered.present() == set.present() && redelivered == set,
            v == 0,
            reason: 'a re-delivered transcript is a no-op');
      });

      final lww = _scenario(fx, 'lww_alive_highest_stamp_wins');
      final lwwEx = assertionsOf(lww['expect']);
      final ops = (lww['ops'] as List).cast<Map<String, dynamic>>();
      WireLwwRegister<bool> replayLww(List<Map<String, dynamic>> os) {
        final r = WireLwwRegister<bool>(
            _stamp(os[0]['stamp'] as Map<String, dynamic>),
            os[0]['value'] as bool);
        for (final op in os.skip(1)) {
          r.set(_stamp(op['stamp'] as Map<String, dynamic>),
              op['value'] as bool);
        }
        return r;
      }

      final reg = replayLww(ops);
      assertKey(lwwEx, 'value', reg.value);
      // `resolution`: the corpus names the conflict rule. Assert the rule, not
      // the label — the surviving value must be the one carried by the op with
      // the maximum stamp. The label is still compared against the fixture's
      // own value, so a corpus that switches rules reddens here rather than
      // replaying against a runner that models only this one.
      assertKey(lwwEx, 'resolution', 'max_stamp',
          'this runner models max-stamp resolution only');
      // Stamp order is (wall_time, logical, peer) lexicographically — the same
      // total order the register uses to break ties.
      List<int> stampKey(Map<String, dynamic> op) {
        final s = _stamp(op['stamp'] as Map<String, dynamic>);
        return [s.wallTime, s.logical, s.peer];
      }

      bool higher(List<int> a, List<int> b) {
        for (var i = 0; i < a.length; i++) {
          if (a[i] != b[i]) return a[i] > b[i];
        }
        return false;
      }

      final maxStamped = ops.reduce(
          (a, b) => higher(stampKey(b), stampKey(a)) ? b : a);
      expect(reg.value, maxStamped['value'],
          reason: 'max_stamp resolution: the highest-stamp write survives');
      assertKey(lwwEx, 'order_independent',
          replayLww(ops.reversed.toList()).value == reg.value,
          'LWW outcome is order-independent');

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
      final deathEx = assertionsOf(death['expect']);
      assertKeyWith(deathEx, 'live_docs_after',
          (v) => expect(live, (v as List).cast<String>().toList()..sort()));
      // `live_docs_before` is the aggregate this replay started from — assert it
      // rather than assume it, or the "after" set could be right for the wrong
      // reason (a doc that was never live cannot demonstrate a cascade).
      final liveBefore = <String>{for (final (doc, _) in open) doc}.toList()
        ..sort();
      assertKeyWith(
          deathEx,
          'live_docs_before',
          (v) => expect(
              liveBefore, (v as List).cast<String>().toList()..sort()));
      // `cascade`: ONE pid death dropped MORE THAN ONE doc, and left the docs
      // of every other pid alone. That pair is the cascade; either half on its
      // own is satisfied by an unrelated single drop.
      final dropped = liveBefore.where((d) => !live.contains(d)).toList();
      final otherPidDocs = [
        for (final (doc, p) in open)
          if (p != pid) doc,
      ];
      assertKey(
          deathEx,
          'cascade',
          dropped.length > 1 && otherPidDocs.every(live.contains),
          'one pid death cascades across its docs and isolates the others');
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
