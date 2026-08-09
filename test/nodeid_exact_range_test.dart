// NodeId exact-representation bound (`#lzspecdecoderbound`).
//
// protocol.md § NodeId / PeerId stated the 2^53 bound as a PRODUCER obligation
// and said nothing about what a decoder does when it receives a violation. That
// left the receiving half undefined, which is exactly where the bindings
// diverged. The clause is now normative: a decoder that cannot represent a
// received identifier exactly MUST reject the frame rather than round it.
//
// lazily-dart is the binding whose answer DEPENDS ON THE TARGET, which is why
// it already carried the rule deliberately (`#lzdartintwidth`,
// lib/src/int_width.dart): `int` is 64-bit two's complement on the VM and an
// IEEE-754 double on every JavaScript target, so 2^53 + 1 decodes exactly on
// one and rounds silently on the other. `intsAreDoubles` is what splits them,
// and this runner is what holds the split in place from the corpus rather than
// from a hand-written unit test.
//
// The expected outcome is therefore computed from `intsAreDoubles`, not
// hardcoded: on the VM this run accepts four of the six scenarios and refuses
// the two at u64::MAX; compiled to JavaScript it would accept two and refuse
// four. Both are conforming, and deriving the count from the predicate rather
// than pinning "4" is what keeps this file honest if it ever runs elsewhere.
//
// This file runs on the VM only — it reads the corpus through `dart:io`. The
// web branch of the same guard is proven by `tool/ipc_browser_check.dart`,
// which dart2js-compiles the wire surface and asserts the refusal on the
// platform where the rounding would actually happen (`make ipc-browser-check`).
//
// The fixture carries its wire frames as raw text (json) and hex (msgpack) and
// its expected identifier as a decimal STRING for the same reason: `jsonDecode`
// on a JS target rounds a bare 9007199254740993 to 9007199254740992 while
// LOADING the file, so a fixture spelling the expectation as a number would
// agree with a rounding decoder.

// Test-only imports: the library stays pure Dart, tests may use dart:io.
import 'dart:convert';
import 'dart:io';

import 'package:lazily/ipc.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

const _fixtureName = 'codec/nodeid_exact_range.json';

/// Corpus-relative fixture ids. Root resolution — the
/// `LAZILY_SPEC_CONFORMANCE_DIR` override, the sibling-first-then-mirror
/// ordering, and the fail-closed behaviour when an explicit override cannot be
/// read — lives in `conformance_manifest.dart` (#lzoverrideallrunners).
String _fixturePath(String name) => specFixturePath(name);

Map<String, dynamic> _loadFixture() {
  final fixture = attributeFixture(
          jsonDecode(File(_fixturePath(_fixtureName)).specReadAsStringSync()))
      as Map<String, dynamic>;
  expect(fixture['protocol_version'], 1, reason: 'protocol_version');
  expect(fixture['kind'], 'NodeIdExactRange', reason: 'kind');
  return fixture;
}

List<int> _hexToBytes(String hex) {
  expect(hex.length.isEven, isTrue, reason: 'hex string has an odd length');
  return [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
}

/// Decode a scenario's wire frame with the codec it names.
///
/// Returns the message, or `null` when the decoder REFUSED it — a conforming
/// outcome for an identifier this runtime cannot represent. The caller decides
/// which of the two is correct, because that split is the whole point.
IpcMessage? _decode(
    Map<String, dynamic> scenario, Map<String, dynamic> expectBlock) {
  try {
    switch (scenario['codec'] as String) {
      case 'json':
        // The raw TEXT through the codec's own entry point, not a pre-parsed
        // object: `jsonDecode` is where the rounding would happen on a JS
        // target, so a runner that parsed the frame itself would move the
        // defect outside the code under test.
        final raw = scenario['wire_json'] as String;
        assertKey(expectBlock, 'wire_input_fnv1a64',
            wireInputFnv1a64Hex(utf8.encode(raw)));
        return IpcMessage.decodeJson(raw);
      case 'msgpack':
        final raw = _hexToBytes(scenario['wire_msgpack_hex'] as String);
        assertKey(expectBlock, 'wire_input_fnv1a64', wireInputFnv1a64Hex(raw));
        return decodeMsgpack(raw);
      default:
        throw StateError('unknown codec: ${scenario['codec']}');
    }
  } on UnsupportedError {
    // The `#lzdartintwidth` refusal: this runtime cannot carry the identifier.
    return null;
  } on FormatException {
    return null;
  }
}

void main() {
  test(
      'NodeId exact-representation bound is enforced by refusal, never rounding',
      () {
    final fixture = _loadFixture();

    // Tracked, so the meta block is subject to the consumption guard — an
    // untracked block silently accepts a key no runner reads, which is how the
    // corpus's new `prose` declaration would have slipped past here.
    final block = assertionsOf(fixture['assertions'], 'assertions');
    assertKey(block, 'required_of_binding', 'MUST');

    // Populations the vocabularies below are differenced against after the
    // loop. Evidence of a replay, never a declaration. `codecs` used to be a
    // hand-written literal and `scenario_count` the fixture's own
    // `scenarios.length` — the fixture compared to itself and to a runner-side
    // constant, neither of which moves for a library regression
    // (`#lznullformblind`).
    final outcomesReplayed = <String>{};
    final codecsReplayed = <String>{};

    // ---- prose keys (`#lzprosekeyconvention`) -------------------------------
    //
    // `outcomes` is NOT among them: it maps a vocabulary to English glosses, so
    // the assertion is its KEY SET and the parent key's own assertion discharges
    // it. It used to be excused as prose here, which is precisely the
    // binding-decides-for-itself the convention removes.
    proseKey(block, 'clause', dischargedBy: [
      // "MUST NOT round, truncate, saturate, or wrap" — the decimal rendering
      // of the decoded id, which makes a neighbouring value visible rather than
      // approximately right, under the outcome the corpus allows.
      'node_id_decimal',
      'outcome',
      'outcomes',
    ]);
    proseKey(block, 'wire_encoding', dischargedBy: [
      // Executable proof that the exact raw text / decoded-hex byte buffer
      // reaches the library decoder rather than a reconstructed proxy.
      'wire_input_fnv1a64',
    ]);
    proseKey(block, 'anti_vacuity', dischargedBy: [
      // "the two `exact` scenarios are the control": a binding must prove it
      // decodes the boundary value correctly before its refusals count, which
      // is `node_id_decimal` on an `exact` outcome.
      'outcome',
      'node_id_decimal',
      'root_id_decimal',
    ]);
    addTearDown(() => verifyProse(fixture));

    // The platform split, read from the library's own predicate rather than
    // restated here. On the VM the exact range is [0, 2^63); compiled to JS it
    // stops at 2^53 - 1. Everything below follows from this one value.
    final exactCeiling = intsAreDoubles
        ? BigInt.from(maxExactInt)
        : BigInt.two.pow(63) - BigInt.one;

    // Anti-vacuity. `exact_or_reject` is satisfied by a runner that decodes
    // nothing and calls everything refused — and lazily-dart really does refuse
    // part of this corpus, so a broken runner resembles a working one. The two
    // counters, pinned below, are what separate them.
    var accepted = 0;
    var refused = 0;

    for (final scenario in scenariosOf(fixture)) {
      final id = scenario['id'] as String;
      final expected =
          BigInt.parse(scenario['expect']['node_id_decimal'] as String);
      final representable = expected <= exactCeiling;
      final expectBlock = assertionsOf(scenario['expect'], id);

      // `outcome` is the corpus-wide statement of what a decoder may do.
      // lazily-dart reads it as a constraint on the FIXTURE: an `exact`
      // scenario no target can represent would be a fixture bug.
      assertKeyWith<void>(expectBlock, 'outcome', (want) {
        outcomesReplayed.add(want as String);
        expect(want, anyOf('exact', 'exact_or_reject'), reason: '$id outcome');
        if (want == 'exact') {
          expect(expected <= BigInt.from(maxExactInt), isTrue,
              reason: '$id: an `exact` scenario must be representable on EVERY '
                  'Dart target, including the double-backed ones');
        }
      });

      // Recorded where the decode DISPATCHES on it, so the vocabulary below is
      // differenced against the carriers this run really read.
      codecsReplayed.add(scenario['codec'] as String);
      final message = _decode(scenario, expectBlock);

      if (message == null) {
        expect(representable, isFalse,
            reason: '$id: this runtime represents $expected exactly, so the '
                'frame must decode rather than be refused');
        refused += 1;
        // There is no decoded frame, so the rest of the block has nothing to be
        // compared against. That is the CONFORMING outcome here — `outcome` is
        // `exact_or_reject` and the refusal is the other arm — but the excuse
        // has to be recorded rather than skipped, or a runner that refused
        // every scenario would leave the block silently unconsumed.
        for (final key in const [
          'epoch',
          'node_count',
          'node_id_decimal',
          'type_tag',
          'payload',
          'root_id_decimal',
        ]) {
          excuseKey(
              expectBlock,
              key,
              'this runtime cannot represent $expected exactly, so the frame '
              'was REFUSED (the `exact_or_reject` arm the clause permits). '
              'There is no decoded frame to compare against; the refusal '
              'itself is pinned by the refused counter below');
        }
        continue;
      }

      expect(representable, isTrue,
          reason: '$id: this runtime cannot represent $expected exactly, so '
              'decoding it means the identifier was ROUNDED to a neighbouring '
              'node id — the silent corruption this clause exists to prevent');
      accepted += 1;

      final snapshot = message.snapshot;
      expect(snapshot, isNotNull, reason: '$id: fixture declares Snapshot');
      expect(scenario['variant'], 'Snapshot');

      assertKey(expectBlock, 'epoch', snapshot!.epoch);
      assertKey(expectBlock, 'node_count', snapshot.nodes.length);

      final node = snapshot.nodes[0];
      // The discriminating assertion: the decimal rendering, so a decoder that
      // returned a neighbour is visible rather than approximately right.
      assertKey(expectBlock, 'node_id_decimal', node.node.toString());
      assertKey(expectBlock, 'type_tag', node.typeTag);
      final state = node.state;
      expect(state, isA<NodeStatePayload>(),
          reason: '$id: the fixture carries a Payload node state');
      assertKey(
          expectBlock, 'payload', (state as NodeStatePayload).bytes.toList());
      expect(snapshot.roots.length, 1, reason: '$id: one root');
      assertKey(
          expectBlock, 'root_id_decimal', snapshot.roots.first.toString());
    }

    // The vocabulary the corpus declares, differenced against the outcomes this
    // run actually replayed. `outcomes` maps a vocabulary to English glosses,
    // so the assertion is the KEY SET — the gloss text itself is prose nested
    // inside a data key, which is not a prose key. Spelled through
    // [assertKeySet] (`#lzsubblockkeyset`) so the tracker KNOWS the key set was
    // compared: an object-valued key routed through the plain assertKeyWith
    // entry point is now a finish-time failure, whatever the callback does.
    assertKeySet(block, 'outcomes', outcomesReplayed,
        reason: 'every outcome the clause declares must be replayed, and no '
            'scenario may carry an outcome the vocabulary does not name');

    // The same shape for the two keys that used to be compared to a literal and
    // to the fixture's own shape (`#lznullformblind`). Every scenario ends in
    // exactly one of the two arms, so `accepted + refused` is the count of
    // scenarios whose BODY ran — which a `continue` past the payload, or a
    // dispatch chain that matches no arm, cannot inflate.
    assertKeyWith<void>(block, 'codecs', (expected) {
      expect(codecsReplayed, equals((expected as List<dynamic>).toSet()),
          reason: 'every declared codec must be replayed by this runner, and '
              'no scenario may carry a codec the vocabulary does not name');
    });
    assertKey(block, 'scenario_count', accepted + refused);

    // Two scenarios sit at 2^53 - 1 and two at 2^53 + 1; two are at u64::MAX,
    // which no Dart target represents. Pinning the split BOTH ways is what makes
    // `intsAreDoubles` executable: a guard that stopped refusing, and a decoder
    // that stopped decoding, are each a failure here.
    expect(accepted, intsAreDoubles ? 2 : 4,
        reason: 'accepted count must follow the runtime integer width');
    expect(refused, intsAreDoubles ? 4 : 2,
        reason: 'refused count must follow the runtime integer width');
  });
}
