import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:lazily/ipc.dart';

/// Replay the distributed + receipts + signaling conformance fixtures.

Map<String, dynamic> _loadFixture(List<String> segments) {
  final candidates = [
    '../lazily-spec/conformance/${segments.join('/')}',
    'test/conformance/${segments.join('/')}',
  ];
  for (final path in candidates) {
    final f = File(path);
    if (f.existsSync()) {
      return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    }
  }
  throw StateError('fixture not found: ${segments.join('/')}');
}

void main() {
  group('Distributed anti-entropy', () {
    final fixture = _loadFixture(['distributed', 'anti_entropy_converge.json']);
    for (final scenario
        in (fixture['scenarios'] as List).cast<Map<String, dynamic>>()) {
      test(scenario['name'] as String, () {
        _playAntiEntropy(scenario);
      });
    }
  });

  group('Causal receipts', () {
    final fixture = _loadFixture(['receipts', 'causal_receipts.json']);
    test('replay assertions', () {
      _playCausalReceipts(fixture);
    });
  });

  group('Signaling anti-spoof session', () {
    final fixture = _loadFixture(['signaling', 'anti_spoof_session.json']);
    test('replay transcript', () {
      _playSignalingSession(fixture);
    });
  });
}

// ---------------------------------------------------------------------------
// Anti-entropy
// ---------------------------------------------------------------------------

void _playAntiEntropy(Map<String, dynamic> scenario) {
  final runtime = CrdtPlaneRuntime(1);
  final opsData = (scenario['ops'] as List).cast<Map<String, dynamic>>();
  final ops = opsData.map((m) {
    final stampMap = (m['stamp'] as Map<String, dynamic>).cast<String, dynamic>();
    return CrdtOp(
      node: m['node'] as int,
      key: m['key'] != null ? NodeKey.fromWire(m['key']) : null,
      stamp: WireStamp(
        wallTime: stampMap['wall_time'] as int,
        logical: stampMap['logical'] as int,
        peer: stampMap['peer'] as int,
      ),
      state: IpcValue.fromWire(m['state']),
    );
  }).toList();

  final applied = runtime.ingestOps(ops);
  final expect_ = scenario['expect'] as Map<String, dynamic>;

  expect(applied, expect_['applied_count'] as int, reason: 'applied_count');

  if (scenario['redeliver'] == true) {
    final reapplied = runtime.ingestOps(ops);
    expect(reapplied, expect_['redeliver_applied_count'] as int,
        reason: 'redeliver_applied_count');
  }

  if (scenario['reverse_order_equivalent'] == true) {
    final runtime2 = CrdtPlaneRuntime(1);
    runtime2.ingestOps(ops.reversed.toList());
    expect(runtime2.converged().map((e) => e.toWire()).toList(),
        runtime.converged().map((e) => e.toWire()).toList(),
        reason: 'order_independent');
  }

  final convergedExpected =
      (expect_['converged'] as List).cast<Map<String, dynamic>>();
  final actual = runtime.converged();
  expect(actual.length, convergedExpected.length, reason: 'converged length');
  for (var i = 0; i < actual.length; i++) {
    final aw = actual[i].toWire();
    final ew = convergedExpected[i];
    expect(aw['node'], ew['node'], reason: 'converged[$i].node');
    expect(aw['state'], ew['state'], reason: 'converged[$i].state');
    if (ew['key'] != null) {
      expect(aw['key'], ew['key'], reason: 'converged[$i].key');
    }
  }
}

// ---------------------------------------------------------------------------
// Causal receipts
// ---------------------------------------------------------------------------

void _playCausalReceipts(Map<String, dynamic> fixture) {
  final assertions = fixture['assertions'] as Map<String, dynamic>;
  final wireReceipts =
      (fixture['wire'] as Map<String, dynamic>)['CausalReceipts'] as Map<String, dynamic>;
  final receiptsList =
      (wireReceipts['receipts'] as List).cast<Map<String, dynamic>>();

  final cr = CausalReceipts.fromWire({
    'receipts': receiptsList,
  });

  expect(cr.receipts.length, assertions['receipt_count'] as int,
      reason: 'receipt_count');

  final projection = ReceiptProjection();
  for (final receipt in cr.receipts) {
    projection.observe(assertions['current_generation'] as int, receipt);
  }

  expect(projection.currentGeneration,
      assertions['current_generation'] as int,
      reason: 'current_generation');

  final terminal = projection.terminalFor(assertions['causation_id'] as String);
  expect(terminal, isNotNull, reason: 'terminal exists');
  expect(terminal!.outcome.wire, assertions['terminal_outcome'] as String,
      reason: 'terminal_outcome');

  final staleIds =
      (assertions['stale_receipt_ids'] as List).cast<String>();
  for (final id in staleIds) {
    expect(projection.containsReceipt(id), isTrue,
        reason: 'stale receipt $id is known');
  }

  final nonTerminal =
      (assertions['nonterminal_outcomes'] as List).cast<String>();
  for (final outcome in nonTerminal) {
    expect(ReceiptOutcome.fromWire(outcome).isTerminal, isFalse,
        reason: '$outcome is non-terminal');
  }
}

// ---------------------------------------------------------------------------
// Signaling session
// ---------------------------------------------------------------------------

void _playSignalingSession(Map<String, dynamic> fixture) {
  final room = SignalingRoom();

  for (final step in (fixture['steps'] as List).cast<Map<String, dynamic>>()) {
    final input = (step['input'] as Map<String, dynamic>).cast<String, dynamic>();
    final connId = input['conn'] as String;
    final recv = (input['recv'] as Map<String, dynamic>).cast<String, dynamic>();
    final type = recv['type'] as String;

    ClientMessage msg;
    switch (type) {
      case 'join':
        msg = ClientJoin(recv['peer'] as int);
      case 'leave':
        msg = ClientLeave();
      case 'offer':
        msg = ClientOffer(recv['to'] as int, recv['sdp'] as String);
      case 'answer':
        msg = ClientAnswer(recv['to'] as int, recv['sdp'] as String);
      case 'ice':
        msg = ClientIce(recv['to'] as int, recv['candidate'] as String);
      default:
        throw StateError('unknown client type $type');
    }

    final frames = room.receive(connId, msg);
    final expected =
        (step['expect'] as List).cast<Map<String, dynamic>>();

    expect(frames.length, expected.length,
        reason: 'frame count for step $type');

    for (var i = 0; i < expected.length; i++) {
      final exp = expected[i];
      final targetConn = exp['to'] as String;
      final expFrame = (exp['frame'] as Map<String, dynamic>).cast<String, dynamic>();

      expect(i < frames.length, isTrue, reason: 'frame $i exists');
      expect(frames[i].connId, targetConn, reason: 'frame[$i] target');

      final actualWire = frames[i].message.toWire();
      for (final entry in expFrame.entries) {
        expect(actualWire[entry.key], entry.value,
            reason: 'frame[$i].${entry.key}');
      }
    }
  }
}
