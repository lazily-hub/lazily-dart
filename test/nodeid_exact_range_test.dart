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

String _fixturePath(String name) {
  final sibling = '../lazily-spec/conformance/$name';
  if (File(sibling).existsSync()) return sibling;
  final local = 'test/conformance/$name';
  if (File(local).existsSync()) return local;
  throw StateError('conformance fixture not found: $name');
}

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
IpcMessage? _decode(Map<String, dynamic> scenario) {
  try {
    switch (scenario['codec'] as String) {
      case 'json':
        // The raw TEXT through the codec's own entry point, not a pre-parsed
        // object: `jsonDecode` is where the rounding would happen on a JS
        // target, so a runner that parsed the frame itself would move the
        // defect outside the code under test.
        return IpcMessage.decodeJson(scenario['wire_json'] as String);
      case 'msgpack':
        return decodeMsgpack(
            _hexToBytes(scenario['wire_msgpack_hex'] as String));
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

    final block = fixture['assertions'] as Map<String, dynamic>;
    assertKey(block, 'required_of_binding', 'MUST');
    assertKey(block, 'codecs', ['json', 'msgpack']);
    assertKey(block, 'scenario_count',
        (fixture['scenarios'] as List<dynamic>).length);
    for (final prose in const [
      'clause',
      'wire_encoding',
      'outcomes',
      'anti_vacuity',
      'generator',
    ]) {
      excuseKey(
        block,
        prose,
        'prose: it states WHY the fixture is shaped this way; the behaviour it '
        'describes is asserted by the per-scenario decode below',
      );
    }

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
      final expectBlock = scenario['expect'] as Map<String, dynamic>;

      // `outcome` is the corpus-wide statement of what a decoder may do.
      // lazily-dart reads it as a constraint on the FIXTURE: an `exact`
      // scenario no target can represent would be a fixture bug.
      assertKeyWith<void>(expectBlock, 'outcome', (want) {
        expect(want, anyOf('exact', 'exact_or_reject'), reason: '$id outcome');
        if (want == 'exact') {
          expect(expected <= BigInt.from(maxExactInt), isTrue,
              reason: '$id: an `exact` scenario must be representable on EVERY '
                  'Dart target, including the double-backed ones');
        }
      });

      final message = _decode(scenario);

      if (message == null) {
        expect(representable, isFalse,
            reason: '$id: this runtime represents $expected exactly, so the '
                'frame must decode rather than be refused');
        refused += 1;
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
