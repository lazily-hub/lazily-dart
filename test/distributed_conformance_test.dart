import 'dart:convert';
import 'package:test/test.dart';
import 'package:lazily/ipc.dart';

import 'conformance_manifest.dart';

/// Replay the distributed + receipts + signaling conformance fixtures.

/// Corpus-relative fixture ids. Root resolution — the
/// `LAZILY_SPEC_CONFORMANCE_DIR` override, the sibling-first-then-mirror
/// ordering, and the fail-closed behaviour when an explicit override cannot be
/// read — lives in `conformance_manifest.dart` (#lzoverrideallrunners).
Map<String, dynamic> _loadFixture(List<String> segments) =>
    attributeFixture(jsonDecode(specReadFixture(segments.join('/'))))
        as Map<String, dynamic>;

void main() {
  group('Distributed anti-entropy', () {
    final fixture = _loadFixture(['distributed', 'anti_entropy_converge.json']);
    for (final scenario in scenariosOf(fixture)) {
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
      // `server` is an EXPLICIT arm (`#lzscenariobodyskip`). Both dispatches
      // below were ternaries on `direction`, so anything that was not the
      // string `client` — a typo, a third direction the corpus later adds —
      // silently ran the SERVER codec. A positive frame would then round-trip
      // through the wrong message type, and a reject entry would "reject" for
      // a reason the fixture never named.
      for (final entry
          in (frames['frames'] as List).cast<Map<String, dynamic>>()) {
        final wire =
            (entry['wire'] as Map<String, dynamic>).cast<String, dynamic>();
        final actual = switch (entry['direction']) {
          'client' => ClientMessage.fromWire(wire).toWire(),
          'server' => ServerMessage.fromWire(wire).toWire(),
          final other => fail('unknown signaling direction `$other`'),
        };
        expect(actual, wire, reason: entry['label'] as String);
      }
      for (final entry
          in (frames['rejects'] as List).cast<Map<String, dynamic>>()) {
        final wire =
            (entry['wire'] as Map<String, dynamic>).cast<String, dynamic>();
        final direction = entry['direction'];
        expect(direction, anyOf('client', 'server'),
            reason: 'unknown signaling direction `$direction`');
        expect(
          () => direction == 'client'
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

  assertKey(expect_, 'applied_count', applied);

  if (scenario['redeliver'] == true) {
    final reapplied = runtime.ingestOps(ops);
    assertKey(expect_, 'redeliver_applied_count', reapplied);
  }

  if (scenario['reverse_order_equivalent'] == true) {
    final runtime2 = CrdtPlaneRuntime(1);
    runtime2.ingestOps(ops.reversed.toList());
    final reversedWire = runtime2.converged().map((e) => e.toWire()).toList();
    final forwardWire = runtime.converged().map((e) => e.toWire()).toList();
    expect(reversedWire, forwardWire, reason: 'reverse_order_equivalent');
  }
  assertKeyIfPresent(expect_, 'order_independent', (v) {
    final runtime2 = CrdtPlaneRuntime(1);
    runtime2.ingestOps(ops.reversed.toList());
    final reversedWire = runtime2.converged().map((e) => e.toWire()).toList();
    final forwardWire = runtime.converged().map((e) => e.toWire()).toList();
    expect(reversedWire.toString() == forwardWire.toString(), v,
        reason: 'order_independent');
  });

  final actual = runtime.converged();
  assertKeyWith(expect_, 'converged', (v) {
    final convergedExpected = (v as List).cast<Map<String, dynamic>>();
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
  });

  // `resolution` names the conflict rule the plane applies. Assert the RULE,
  // not the label: every converged entry must carry the state of the
  // highest-stamped op for its (node, key). Comparing the label alone would
  // pass against a plane that resolved by arrival order and happened to agree.
  assertKey(expect_, 'resolution', 'max_stamp',
      'this runner models max-stamp resolution only');
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

  assertKey(assertions, 'receipt_count', cr.receipts.length);

  // The generation each receipt is observed AT comes from the receipt's own wire
  // field, never from the assertion block (#lznullformblind). Reading
  // `current_generation` out of the fixture and feeding it into `observe` made
  // the assertion below a tautology: the projection's generation is the max of
  // whatever was passed in, so the fixture's value was compared against itself
  // and flipping it in the corpus moved BOTH sides. The corpus perturbation pass
  // found it — the one key of 107 whose flip left this suite green.
  final projection = ReceiptProjection();
  for (final receipt in cr.receipts) {
    projection.observe(receipt.generation, receipt);
  }

  assertKey(assertions, 'current_generation', projection.currentGeneration);

  final terminal = assertKeyWith(assertions, 'causation_id', (v) {
    final t = projection.terminalFor(v as String);
    expect(t, isNotNull, reason: 'terminal exists for causation_id $v');
    return t!;
  });
  assertKey(assertions, 'terminal_outcome', terminal.outcome.wire);

  assertKeyWith(assertions, 'stale_receipt_ids', (v) {
    for (final id in (v as List).cast<String>()) {
      expect(projection.containsReceipt(id), isTrue,
          reason: 'stale receipt $id is known');
    }
  });

  assertKeyWith(assertions, 'nonterminal_outcomes', (v) {
    for (final outcome in (v as List).cast<String>()) {
      expect(ReceiptOutcome.fromWire(outcome).isTerminal, isFalse,
          reason: '$outcome is non-terminal');
    }
  });
}

// ---------------------------------------------------------------------------
// Signaling session
// ---------------------------------------------------------------------------

void _playSignalingSession(Map<String, dynamic> fixture) {
  final room = SignalingRoom();

  // The fixture-level block, which this runner never bound at all: three
  // load-bearing properties sat unread beside the transcript, and an UNTRACKED
  // block reports nothing when it goes unconsumed (`#lznullformblind`,
  // `#lzassertunknownkeys`). Each is computed from the frames the room really
  // produced — never from the fixture's own `expect` entries, which is the
  // fixture agreeing with itself.
  final block = assertionsOf(fixture['assertions'], 'assertions');
  // conn -> the peer id the SERVER registered for it, read off the `welcome`
  // frame the server sent, not off the client's `join` input.
  final registered = <Object, Object?>{};
  var rosterExcludesSelf = true;
  var rosterSortedAscending = true;
  var forwardedFromIsServerRegistered = true;
  // Anti-vacuity: each property above is trivially true over a transcript that
  // never produces the frame it is about.
  var rostersSeen = 0;
  var forwardsSeen = 0;

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

      // The three fixture-level properties, observed off the PRODUCED frame.
      switch (actualWire['type']) {
        case 'welcome':
          // The server's own answer to "who are you here": everything after
          // this reads the registration from the room, not from the client.
          registered[frames[i].connId] = actualWire['peer'];
          final roster = (actualWire['peers']! as List).cast<int>();
          if (roster.isNotEmpty) rostersSeen += 1;
          if (roster.contains(actualWire['peer'])) rosterExcludesSelf = false;
          for (var p = 1; p < roster.length; p++) {
            if (roster[p - 1] >= roster[p]) rosterSortedAscending = false;
          }
        case 'offer':
        case 'answer':
        case 'ice':
          // Anti-spoof: `from` is the SENDING connection's server-registered
          // peer id. The sender is `input.conn` — the frame goes OUT to someone
          // else — and a client-supplied `from` must never reach it.
          forwardsSeen += 1;
          if (actualWire['from'] != registered[connId]) {
            forwardedFromIsServerRegistered = false;
          }
      }
    }
  }

  // Polarity kept honest: the observation is compared against whatever the
  // corpus declares, so a fixture that flips a claim to `false` requires the
  // property to be ABSENT rather than silently passing.
  assertKey(block, 'roster_excludes_self', rosterExcludesSelf,
      'the `welcome` roster must not carry the joining peer itself');
  assertKey(block, 'roster_sorted_ascending', rosterSortedAscending,
      'the `welcome` roster is in ascending peer order');
  assertKey(
      block,
      'forwarded_from_is_server_registered',
      forwardedFromIsServerRegistered,
      'a forwarded frame carries the SENDER\'s server-registered peer id');
  expect(rostersSeen, greaterThan(0),
      reason: 'a transcript whose rosters are all empty satisfies both roster '
          'properties without exercising either');
  expect(forwardsSeen, greaterThan(0),
      reason: 'a transcript that forwards nothing satisfies the anti-spoof '
          'property without exercising it');

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
