import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:lazily/ipc.dart';

import 'conformance_manifest.dart';

/// Replay the distributed + receipts + signaling conformance fixtures.

Map<String, dynamic> _loadFixture(List<String> segments) {
  final candidates = [
    '../lazily-spec/conformance/${segments.join('/')}',
    'test/conformance/${segments.join('/')}',
  ];
  for (final path in candidates) {
    final f = File(path);
    if (f.existsSync()) {
      return attributeFixture(jsonDecode(f.specReadAsStringSync())) as Map<String, dynamic>;
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

  group('Signaling frame rejection', () {
    final frames = _loadFixture(['signaling', 'frames.json']);
    test('round trip positives and reject malformed frames', () {
      for (final entry
          in (frames['frames'] as List).cast<Map<String, dynamic>>()) {
        final wire =
            (entry['wire'] as Map<String, dynamic>).cast<String, dynamic>();
        final Map<String, dynamic> actual = entry['direction'] == 'client'
            ? ClientMessage.fromWire(wire).toWire()
            : ServerMessage.fromWire(wire).toWire();
        expect(actual, wire, reason: entry['label'] as String);
      }
      for (final entry
          in (frames['rejects'] as List).cast<Map<String, dynamic>>()) {
        final wire =
            (entry['wire'] as Map<String, dynamic>).cast<String, dynamic>();
        expect(
          () => entry['direction'] == 'client'
              ? ClientMessage.fromWire(wire)
              : ServerMessage.fromWire(wire),
          throwsA(anything),
          reason: entry['label'] as String,
        );
      }
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
    final stampMap =
        (m['stamp'] as Map<String, dynamic>).cast<String, dynamic>();
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
  final expect_ = assertionsOf(scenario['expect']);

  expect(applied, expect_['applied_count'] as int, reason: 'applied_count');

  if (scenario['redeliver'] == true) {
    final reapplied = runtime.ingestOps(ops);
    expect(reapplied, expect_['redeliver_applied_count'] as int,
        reason: 'redeliver_applied_count');
  }

  final orderIndependent = expect_['order_independent'];
  if (orderIndependent != null || scenario['reverse_order_equivalent'] == true) {
    final runtime2 = CrdtPlaneRuntime(1);
    runtime2.ingestOps(ops.reversed.toList());
    final reversedWire = runtime2.converged().map((e) => e.toWire()).toList();
    final forwardWire = runtime.converged().map((e) => e.toWire()).toList();
    if (orderIndependent != null) {
      expect(reversedWire.toString() == forwardWire.toString(),
          orderIndependent, reason: 'order_independent');
    } else {
      expect(reversedWire, forwardWire, reason: 'order_independent');
    }
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

  // `resolution` names the conflict rule the plane applies. Assert the RULE,
  // not the label: every converged entry must carry the state of the
  // highest-stamped op for its (node, key). Comparing the label alone would
  // pass against a plane that resolved by arrival order and happened to agree.
  expect(expect_['resolution'], 'max_stamp',
      reason: 'this runner models max-stamp resolution only');
  for (final entry in actual) {
    final rivals = ops.where((o) => o.node == entry.node).toList();
    expect(rivals, isNotEmpty, reason: 'converged entry with no source op');
    final winner =
        rivals.reduce((a, b) => _higherStamp(b.stamp, a.stamp) ? b : a);
    expect(entry.state, winner.state.toWire(),
        reason: 'max_stamp resolution for node ${entry.node}');
  }
}

/// Stamp order is (wall_time, logical, peer), lexicographically.
bool _higherStamp(WireStamp a, WireStamp b) {
  if (a.wallTime != b.wallTime) return a.wallTime > b.wallTime;
  if (a.logical != b.logical) return a.logical > b.logical;
  return a.peer > b.peer;
}

// ---------------------------------------------------------------------------
// Causal receipts
// ---------------------------------------------------------------------------

void _playCausalReceipts(Map<String, dynamic> fixture) {
  final assertions = assertionsOf(fixture['assertions']);
  final wireReceipts = (fixture['wire']
      as Map<String, dynamic>)['CausalReceipts'] as Map<String, dynamic>;
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

  expect(projection.currentGeneration, assertions['current_generation'] as int,
      reason: 'current_generation');

  final terminal = projection.terminalFor(assertions['causation_id'] as String);
  expect(terminal, isNotNull, reason: 'terminal exists');
  expect(terminal!.outcome.wire, assertions['terminal_outcome'] as String,
      reason: 'terminal_outcome');

  final staleIds = (assertions['stale_receipt_ids'] as List).cast<String>();
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
    final input =
        (step['input'] as Map<String, dynamic>).cast<String, dynamic>();
    final connId = input['conn'] as String;
    final recv =
        (input['recv'] as Map<String, dynamic>).cast<String, dynamic>();
    final type = recv['type'] as String;

    final msg = ClientMessage.fromWire(recv);

    final frames = room.receive(connId, msg);
    final expected = (step['expect'] as List).cast<Map<String, dynamic>>();

    expect(frames.length, expected.length,
        reason: 'frame count for step $type');

    for (var i = 0; i < expected.length; i++) {
      final exp = expected[i];
      final targetConn = exp['to'] as String;
      final expFrame =
          (exp['frame'] as Map<String, dynamic>).cast<String, dynamic>();

      expect(i < frames.length, isTrue, reason: 'frame $i exists');
      expect(frames[i].connId, targetConn, reason: 'frame[$i] target');

      final actualWire = frames[i].message.toWire();
      for (final entry in expFrame.entries) {
        expect(actualWire[entry.key], entry.value,
            reason: 'frame[$i].${entry.key}');
      }
    }
  }

  for (final reject
      in (fixture['rejects'] as List).cast<Map<String, dynamic>>()) {
    final input =
        (reject['input'] as Map<String, dynamic>).cast<String, dynamic>();
    final recv =
        (input['recv'] as Map<String, dynamic>).cast<String, dynamic>();
    expect(
      () => ClientMessage.fromWire(recv),
      throwsA(anything),
      reason: reject['label'] as String,
    );
  }
}
