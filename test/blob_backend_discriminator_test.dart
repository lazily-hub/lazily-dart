// Blob-backend discriminator strictness on decode (`#lzblobbackendstrict`).
//
// protocol.md § Shared-memory payload path splits `ShmBlobRef.backend` two ways
// that look like one. An OMITTED `backend` is the forward-compatibility channel
// — every descriptor minted before the field existed has that shape — and MUST
// decode as `shm`. A PRESENT value outside `{shm, arrow, in_process}` is the
// opposite fact and gets the opposite answer: reject, naming the token, and
// never normalize to `shm`. Five of nine bindings had normalized, each with a
// written forward-compat rationale, which is what makes an audit that reads code
// rather than running it worthless here — a deliberate default and an accidental
// one look identical from outside, and so do two deliberate ones pointing in
// opposite directions.
//
// Normalizing inverts the `resolve_wrong_backend` theorem
// (lazily-spec/docs/zero-copy-transport.md). That theorem discharges
// non-resolution STRUCTURALLY, by routing on kind: an `rdma` descriptor never
// reaches an `shm` table because nothing maps it there. Rewriting the kind to
// `shm` routes it, and the guarantee degrades to a 64-bit checksum happening to
// disagree — probabilistic where the theorem was structural.
//
// lazily-dart was already conforming on every arm of the clause; this runner is
// what holds it there. `BlobBackendKind.fromWire` is a real dispatch site (a
// linear scan over `values` that throws on no match), reached from
// `ShmBlobRef.fromWire` only when the key is present — which is exactly the
// distinction the clause turns on, and exactly the one a `?? BlobBackendKind.shm`
// spelled over a failed LOOKUP would erase.
//
// The encoder half is asserted from the WIRE tree, not the typed object: a typed
// `ShmBlobRef` cannot distinguish "field omitted" from "field written as shm",
// and `reencoded_backend_field_present` is the only assertion in this file that
// a round-trip-whatever-you-received encoder fails.

// Test-only imports: the library stays pure Dart, tests may use dart:io.
import 'dart:convert';
import 'dart:io';

import 'package:lazily/ipc.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

const _fixtureName = 'codec/blob_backend_discriminator.json';

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
  expect(fixture['kind'], 'BlobBackendDiscriminator', reason: 'kind');
  return fixture;
}

List<int> _hexToBytes(String hex) {
  expect(hex.length.isEven, isTrue, reason: 'hex string has an odd length');
  return [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
}

/// Decode a scenario from its RAW wire form.
///
/// The reject frames cannot be carried as parsed JSON — `schemas/defs.json`
/// closes `backend` to an enum, so the corpus's own schema gate would refuse a
/// fixture embedding `"backend": "rdma"` structurally — and the accept frames
/// have to distinguish an ABSENT map entry from a present short string, which a
/// re-serialized parse would not preserve either. So both codecs start from the
/// bytes the fixture ships.
IpcMessage _decode(Map<String, dynamic> scenario) {
  switch (scenario['codec'] as String) {
    case 'json':
      return IpcMessage.decodeJson(scenario['wire_json'] as String);
    case 'msgpack':
      return decodeMsgpack(_hexToBytes(scenario['wire_msgpack_hex'] as String));
    default:
      throw StateError('unknown codec: ${scenario['codec']}');
  }
}

/// The `SharedBlob` descriptor as this scenario's codec RE-ENCODES it.
///
/// Read off the wire tree because the encoder half is invisible to the decoded
/// object: `backend` omitted and `backend` written as `"shm"` produce the same
/// `ShmBlobRef`. The msgpack arm goes through the msgpack encoder specifically
/// rather than reusing `toWire()` — both codecs derive from the same tree, but
/// `#lzmsgpackparity` was a msgpack encoder writing a field json omitted.
Map<String, dynamic> _reencodedBlob(
    Map<String, dynamic> scenario, IpcMessage message) {
  Object? wire = message.toWire();
  if (scenario['codec'] == 'msgpack') {
    wire = msgpackToJson(encodeMsgpack(message));
  }
  final body =
      (wire! as Map<String, dynamic>)['Delta']! as Map<String, dynamic>;
  final op = (body['ops']! as List<dynamic>)[0] as Map<String, dynamic>;
  final slot = op['SlotValue']! as Map<String, dynamic>;
  final payload = slot['payload']! as Map<String, dynamic>;
  return payload['SharedBlob']! as Map<String, dynamic>;
}

String _variantOf(IpcMessage message) {
  if (message is IpcMessageSnapshot) return 'Snapshot';
  if (message is IpcMessageDelta) return 'Delta';
  if (message is IpcMessageCrdtSync) return 'CrdtSync';
  throw StateError('fixture pins no runner for $message');
}

void main() {
  test(
      'blob-backend discriminator: omitted decodes as shm, an unknown token is '
      'rejected by name', () {
    final fixture = _loadFixture();

    final meta = assertionsOf(fixture['assertions'], 'assertions');
    assertKey(meta, 'required_of_binding', 'MUST');
    assertKey(meta, 'codecs', ['json', 'msgpack']);
    assertKey(meta, 'backends', ['shm', 'arrow', 'in_process']);
    assertKey(meta, 'outcomes', ['accept', 'reject']);
    assertKey(
        meta, 'scenario_count', (fixture['scenarios'] as List<dynamic>).length);
    // The enum the fixture names is the enum this binding implements — the one
    // fact in the meta block that is about lazily-dart rather than about the
    // fixture's own shape.
    expect(BlobBackendKind.values.map((k) => k.wire).toList(),
        meta['backends'] as List<dynamic>,
        reason: 'BlobBackendKind mirrors the closed enum the clause names');
    for (final prose in const [
      'clause',
      'wire_encoding',
      'reject_obligation',
      'anti_vacuity',
      'theorem',
      'generator',
    ]) {
      excuseKey(
        meta,
        prose,
        'prose: it states WHY the fixture is shaped this way; the behaviour it '
        'describes is asserted by the per-scenario decode, re-encode and '
        'rejection below',
      );
    }

    // Anti-vacuity counters, one per way a runner can pass while proving less
    // than it claims. `accepted`/`rejected` catch a runner that treats every
    // scenario as one outcome; `arrowsDecoded` catches a decoder that ignores
    // `backend` entirely and hardcodes `shm` — it satisfies the omitted and
    // explicit-shm scenarios and dies only here.
    var replayed = 0;
    var accepted = 0;
    var rejected = 0;
    var arrowsDecoded = 0;

    for (final scenario in scenariosOf(fixture)) {
      final where = scenario['id'] as String;
      final outcome = scenario['outcome'] as String;
      final block = assertionsOf(scenario['expect'], where);
      replayed += 1;

      if (outcome == 'reject') {
        rejected += 1;
        Object? caught;
        try {
          _decode(scenario);
        } catch (e) {
          caught = e;
        }
        // Not `expect(..., throwsA)`: the fixture's `rejected` key is the value
        // under assertion, so it has to reach a comparison.
        assertKey(
            block,
            'rejected',
            caught != null,
            '$where: a present `backend` outside the enum must be refused, '
                'never normalized to shm');
        assertKeyWith(block, 'error_names_token', (expected) {
          expect(caught, isNotNull, reason: '$where: nothing was thrown');
          expect('$caught', contains(expected as String),
              reason: '$where: the error must NAME the offending token — a '
                  'decoder that refused the frame for an unrelated reason '
                  'passes a bare is-error assertion while implementing none '
                  'of the clause');
        });
        continue;
      }

      accepted += 1;
      final message = _decode(scenario);
      expect(_variantOf(message), scenario['variant'],
          reason: '$where: fixture variant vs decoded frame');

      final op = message.delta!.ops[0];
      expect(op, isA<DeltaOpSlotValue>(),
          reason: '$where: the fixture ships a SlotValue op');
      final payload = (op as DeltaOpSlotValue).payload;
      expect(payload, isA<IpcValueSharedBlob>(),
          reason: '$where: the op payload is a SharedBlob descriptor');
      final blob = (payload as IpcValueSharedBlob).blob;
      if (blob.backend == BlobBackendKind.arrow) arrowsDecoded += 1;

      assertKey(block, 'decoded_backend', blob.backend.wire,
          '$where: decoded backend');

      // The encoder half. A conforming encoder OMITS `backend` when it is `shm`
      // so a pre-field descriptor round-trips byte-identically, and EMITS it
      // otherwise. Nothing about the decoded value can see this.
      final reencoded = _reencodedBlob(scenario, message);
      assertKey(block, 'reencoded_backend_field_present',
          reencoded.containsKey('backend'), '$where: re-encoded backend field');

      // The rest of the descriptor, so a decoder that gets the discriminator
      // right by dropping the frame's other fields cannot pass.
      assertKey(block, 'node', op.node, '$where: node');
      assertKey(block, 'offset', blob.offset, '$where: offset');
      assertKey(block, 'len', blob.len, '$where: len');
      assertKey(block, 'generation', blob.generation, '$where: generation');
      assertKey(block, 'epoch', blob.epoch, '$where: epoch');
      assertKey(block, 'checksum', blob.checksum, '$where: checksum');
    }

    expect(replayed, 8,
        reason: 'four backend forms x two codecs (omitted, shm, arrow, rdma)');
    expect(accepted, 6, reason: 'omitted, explicit shm and arrow, both codecs');
    expect(rejected, 2, reason: 'the unknown token, both codecs');
    expect(arrowsDecoded, 2,
        reason: 'a decoder that hardcodes `shm` and never reads the field '
            'passes every other assertion in this file');
  });

  // The arms the fixture carries no frame for. `in_process` is in the enum the
  // clause closes, and a non-string `backend` is a shape the fixture cannot
  // carry at all (its own schema gate would refuse it) — both are still part of
  // "reject a present value that is not one of these three".
  group('the clause beyond the fixture', () {
    ShmBlobRef decodeBlob(String backendFragment) {
      final wire = '{"Delta": {"base_epoch": 8, "epoch": 9, "ops": '
          '[{"SlotValue": {"node": 7, "payload": {"SharedBlob": '
          '{"offset": 40, "len": 17, "generation": 2, "epoch": 9, '
          '"checksum": 987654321$backendFragment}}}}]}}';
      final message = IpcMessage.decodeJson(wire);
      final op = message.delta!.ops[0] as DeltaOpSlotValue;
      return (op.payload as IpcValueSharedBlob).blob;
    }

    test('`in_process` decodes as itself and is emitted', () {
      final blob = decodeBlob(', "backend": "in_process"');
      expect(blob.backend, BlobBackendKind.inProcess);
      expect(blob.toWire().containsKey('backend'), isTrue,
          reason: 'only the `shm` default is omitted');
      expect(blob.toWire()['backend'], 'in_process');
    });

    test('a non-string `backend` is refused by TYPE, not coerced', () {
      // The failure mode this pins is `'$value'` string-interpolating a number
      // and then missing the enum: it would reject 7 with the right shape and
      // ACCEPT a hypothetical `"shm"`-stringifying value.
      expect(
          () => decodeBlob(', "backend": 7'),
          throwsA(isA<FormatException>().having(
              (e) => '$e', 'message', contains('backend must be a string'))));
    });

    test('a case variant of a member is not a member', () {
      expect(
          () => decodeBlob(', "backend": "SHM"'),
          throwsA(isA<FormatException>()
              .having((e) => '$e', 'message', contains('SHM'))));
    });

    test('the enum is closed — every member round-trips and nothing else does',
        () {
      for (final kind in BlobBackendKind.values) {
        expect(decodeBlob(', "backend": "${kind.wire}"').backend, kind,
            reason: '${kind.wire} decodes as itself');
      }
      expect(() => decodeBlob(', "backend": "rdma"'),
          throwsA(isA<FormatException>()));
    });
  });
}
