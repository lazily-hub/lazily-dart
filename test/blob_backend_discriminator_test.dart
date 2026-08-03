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
// FIXTURE v2 (14 scenarios, seven wire shapes x two codecs) adds the four facts
// v1 declared or implied without carrying, and lazily-dart was ALREADY
// conforming on every one of them — no library change was needed to turn this
// runner green, only a runner that reaches them:
//
//  * `in_process`, the third member of the enum v1 declared and carried no frame
//    for. A binding knowing only {shm, arrow} refused it, conformingly by the
//    letter of the clause, and passed all eight v1 scenarios while implementing
//    a smaller enum than the clause declares. `BlobBackendKind` has carried all
//    three members since the zero-copy transport landed, and the
//    vocabulary-completeness assertion below is what now holds it there — a SET
//    DIFFERENCE against `assertions.backends`, which no scenario count can
//    substitute for.
//  * An explicit `backend: null`, which is the ABSENT form (§ NodeKey,
//    `#lzkeynullstrict`) and not a present-unknown one: a serde-style peer that
//    skipped `skip_serializing_if` emits null where a conforming encoder omits,
//    so refusing it is stricter than the reference implementation on a frame the
//    reference implementation produces. `ShmBlobRef.fromWire` branches on
//    `backendWire == null` BEFORE reaching the lookup, so null takes the default
//    path and never the enum scan.
//  * A non-string `backend`, refused by `BlobBackendKind.fromWire`'s type guard
//    rather than coerced. Dart makes the coercion easy — `obj['backend']` is
//    `Object?` and `'$value'` would stringify `7` — and the guard runs first.
//    Both refusals arrive as `FormatException`, the documented decode-error
//    family for BOTH codecs (msgpack_codec.dart: "Failure mode matches the
//    `json` codec: [FormatException]"), so one catch around a decode handles
//    both. That is what `rejection_is_decode_error` asserts: a refusal raised
//    outside that family still refuses the frame, but it fails PAST the handler
//    every caller already wraps a decode in.
//  * A Delta frame epoch (9) distinct from the descriptor epoch (5). v1 carried
//    9 in both, so `expect.epoch` could not tell a runner reading the frame from
//    one reading the blob. The key was REMOVED rather than redefined; this
//    runner asserts `frame_epoch` off `Delta.epoch` and `blob_epoch` off
//    `ShmBlobRef.epoch`, which are different facts (delta ordering vs the arena
//    incarnation the bytes were written into).
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
/// have to distinguish an ABSENT map entry from a present short string (and,
/// since v2, from an explicit nil), which a re-serialized parse would not
/// preserve either. So both codecs start from the bytes the fixture ships.
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
/// object: `backend` omitted, `backend` written as `"shm"` and `backend` written
/// as an explicit null all produce the same `ShmBlobRef`. The msgpack arm goes
/// through the msgpack encoder specifically rather than reusing `toWire()` —
/// both codecs derive from the same tree, but `#lzmsgpackparity` was a msgpack
/// encoder writing a field json omitted.
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
      'blob-backend discriminator: omitted and null decode as shm, the enum is '
      'complete, an unknown token and a non-string are refused as decode errors',
      () {
    final fixture = _loadFixture();

    final meta = assertionsOf(fixture['assertions'], 'assertions');
    assertKey(meta, 'required_of_binding', 'MUST');
    assertKey(meta, 'codecs', ['json', 'msgpack']);
    assertKey(meta, 'outcomes', ['accept', 'reject']);
    assertKey(
        meta, 'scenario_count', (fixture['scenarios'] as List<dynamic>).length);

    // The enum the fixture names is the enum this binding implements — the one
    // fact in the meta block that is about lazily-dart rather than about the
    // fixture's own shape. The list is also carried out of the block so the
    // VOCABULARY-COMPLETENESS check after the loop can difference it against
    // the backends actually decoded; a `BlobBackendKind` that mirrors the enum
    // and a decoder that reaches every member of it are separate facts.
    final declaredBackends = assertKeyWith(meta, 'backends', (expected) {
      final declared = (expected as List<dynamic>).cast<String>();
      expect(BlobBackendKind.values.map((k) => k.wire).toList(), declared,
          reason: 'BlobBackendKind mirrors the closed enum the clause names');
      return declared;
    });

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
    excuseKey(
      meta,
      'backend_form_vocabulary',
      'prose: it names the seven wire shapes and states the runner obligation '
          'that every backend in `assertions.backends` appear as some accept '
          "scenario's `decoded_backend`. `backend_forms` is asserted as a set "
          'against the forms this run replayed, and the obligation itself is the '
          'vocabulary-completeness difference after the loop',
    );
    excuseKey(
      meta,
      'null_form',
      'prose: it argues WHY an explicit null is the absent form rather than a '
          'present-unknown one. The behaviour is asserted by the backend_null_* '
          'scenarios — decoded_backend shm, and no `backend` entry re-encoded',
    );
    excuseKey(
      meta,
      'non_string_form',
      'prose: it argues why a non-string refusal must arrive through the '
          "codec's documented decode-error family. The behaviour is asserted by "
          'the backend_non_string_* scenarios via `rejection_is_decode_error`, '
          'checked against `caught is FormatException`',
    );
    excuseKey(
      meta,
      'epoch_disambiguation',
      'prose: it explains why `expect.epoch` was removed. The behaviour is '
          'asserted per accept scenario — `frame_epoch` against `Delta.epoch` and '
          '`blob_epoch` against `ShmBlobRef.epoch`, which the fixture now gives '
          'different values so a runner reading the wrong one is red',
    );

    // Anti-vacuity counters, one per way a runner can pass while proving less
    // than it claims. `accepted`/`rejected` catch a runner that treats every
    // scenario as one outcome; `arrowsDecoded` catches a decoder that ignores
    // `backend` entirely and hardcodes `shm` — it satisfies the omitted,
    // explicit-shm and null scenarios and dies only there.
    var replayed = 0;
    var accepted = 0;
    var rejected = 0;
    var arrowsDecoded = 0;
    var inProcessDecoded = 0;
    var nullsDecodedAsShm = 0;
    var decodeErrorRefusals = 0;

    // Populations the meta block's vocabularies are differenced against after
    // the loop. Each is EVIDENCE of a replay, never a declaration.
    final formsReplayed = <String>{};
    final rejectionKindsReplayed = <String>{};
    final backendsDecoded = <String>{};

    for (final scenario in scenariosOf(fixture)) {
      final where = scenario['id'] as String;
      final outcome = scenario['outcome'] as String;
      final block = assertionsOf(scenario['expect'], where);
      formsReplayed.add(scenario['backend_form'] as String);
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
            '$where: a present `backend` that is not a member of the enum must '
                'be refused, never normalized to shm');

        // The refusal has to arrive through the family a caller already guards
        // a decode with. Both codecs document `FormatException` and nothing
        // else; a `TypeError` out of downstream string handling refuses the
        // frame and fails past every handler, which is invisible to a bare
        // is-error assertion.
        assertKey(
            block,
            'rejection_is_decode_error',
            caught is FormatException,
            '$where: the refusal must be a FormatException — the documented '
                'decode-error family for BOTH codecs — not a stray runtime '
                'type error that fails past the handler');
        if (caught is FormatException) decodeErrorRefusals += 1;

        // WHICH refusal this is. The two arms reach the same family through
        // different doors — an enum miss in `BlobBackendKind.fromWire`'s scan
        // versus its type guard — and a runner that never distinguishes them
        // cannot tell a decoder that type-guards everything from one that
        // enum-checks everything.
        assertKeyWith(block, 'rejection_kind', (expected) {
          final kind = expected as String;
          rejectionKindsReplayed.add(kind);
          switch (kind) {
            case 'unknown_token':
              expect('$caught', contains('unknown blob backend kind'),
                  reason: '$where: a present token outside the enum must miss '
                      'the lookup, not the type guard');
            case 'non_string':
              expect('$caught', contains('backend must be a string'),
                  reason: '$where: a non-string must be refused BY TYPE. Dart '
                      "makes `'\$value'` a one-character coercion away, and a "
                      'stringified 7 would then miss the enum and produce a '
                      'correctly shaped refusal for the wrong reason — while '
                      'accepting a hypothetical value that stringifies to shm');
            default:
              fail('$where: fixture names an unknown rejection_kind: $kind');
          }
        });

        // Only the unknown-token arm names a token; there is no token in `7`,
        // and requiring the field name would pin a message format no codec's
        // native type error carries.
        assertKeyIfPresent(block, 'error_names_token', (expected) {
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

      final delta = message.delta!;
      final op = delta.ops[0];
      expect(op, isA<DeltaOpSlotValue>(),
          reason: '$where: the fixture ships a SlotValue op');
      final payload = (op as DeltaOpSlotValue).payload;
      expect(payload, isA<IpcValueSharedBlob>(),
          reason: '$where: the op payload is a SharedBlob descriptor');
      final blob = (payload as IpcValueSharedBlob).blob;
      if (blob.backend == BlobBackendKind.arrow) arrowsDecoded += 1;
      if (blob.backend == BlobBackendKind.inProcess) inProcessDecoded += 1;
      if (scenario['backend_form'] == 'null' &&
          blob.backend == BlobBackendKind.shm) {
        nullsDecodedAsShm += 1;
      }
      backendsDecoded.add(blob.backend.wire);

      assertKey(block, 'decoded_backend', blob.backend.wire,
          '$where: decoded backend');

      // The encoder half. A conforming encoder OMITS `backend` when it is `shm`
      // so a pre-field descriptor round-trips byte-identically, and EMITS it
      // otherwise. Nothing about the decoded value can see this — and for the
      // null form it is the assertion that the null does not survive the round
      // trip as a null.
      final reencoded = _reencodedBlob(scenario, message);
      assertKey(block, 'reencoded_backend_field_present',
          reencoded.containsKey('backend'), '$where: re-encoded backend field');

      // The rest of the descriptor, so a decoder that gets the discriminator
      // right by dropping the frame's other fields cannot pass.
      assertKey(block, 'node', op.node, '$where: node');
      assertKey(block, 'offset', blob.offset, '$where: offset');
      assertKey(block, 'len', blob.len, '$where: len');
      assertKey(block, 'generation', blob.generation, '$where: generation');

      // TWO epochs, from two different objects. The fixture gives them
      // different values precisely so this pair cannot be satisfied by reading
      // either one twice: the frame epoch orders deltas, the descriptor epoch
      // is the arena incarnation the blob was written into.
      assertKey(block, 'frame_epoch', delta.epoch,
          '$where: the Delta frame epoch (delta ordering)');
      assertKey(
          block,
          'blob_epoch',
          blob.epoch,
          '$where: the ShmBlobRef epoch (arena incarnation) — a DIFFERENT '
              'number from frame_epoch since fixture v2');

      assertKey(block, 'checksum', blob.checksum, '$where: checksum');
    }

    // ---- vocabulary completeness -------------------------------------------
    //
    // The assertion a scenario COUNT cannot reach, and the one that would have
    // caught v1's missing `in_process`: a set difference between the enum the
    // clause declares and the backends this run actually decoded. A binding
    // implementing {shm, arrow} refuses `in_process` while naming the token,
    // which is conforming by the letter of the reject clause and wrong.
    expect(backendsDecoded, containsAll(declaredBackends),
        reason: 'every backend in assertions.backends MUST appear as the '
            'decoded_backend of some accept scenario. Missing: '
            '${declaredBackends.toSet().difference(backendsDecoded)}');
    expect(declaredBackends.toSet(), containsAll(backendsDecoded),
        reason: 'and nothing decodes to a backend the clause does not declare');

    // The same shape one level out: every wire FORM the fixture declares was
    // replayed, and no scenario carried a form the vocabulary omits.
    assertKeyWith(meta, 'backend_forms', (expected) {
      expect(formsReplayed, equals((expected as List<dynamic>).toSet()),
          reason: 'every declared wire shape must be replayed by this runner, '
              'and no scenario may carry a form the vocabulary does not name');
    });
    assertKeyWith(meta, 'rejection_kinds', (expected) {
      expect(
          rejectionKindsReplayed, equals((expected as List<dynamic>).toSet()),
          reason: 'both refusal doors — the enum lookup and the type guard — '
              'must be exercised; a runner that only reaches one cannot tell a '
              'decoder that type-guards everything from one that enum-checks '
              'everything');
    });

    expect(replayed, 14,
        reason: 'seven backend forms x two codecs (omitted, shm, arrow, '
            'in_process, null, non_string, rdma)');
    expect(accepted, 10,
        reason:
            'omitted, explicit shm, arrow, in_process and null, both codecs');
    expect(rejected, 4,
        reason: 'the unknown token and the non-string, both codecs');
    expect(decodeErrorRefusals, 4,
        reason: 'every refusal arrives as a FormatException, so one catch '
            'around a decode handles both doors');
    expect(arrowsDecoded, 2,
        reason: 'a decoder that hardcodes `shm` and never reads the field '
            'passes every other accept assertion in this file');
    expect(inProcessDecoded, 2,
        reason: 'the third enum member, which v1 declared and never carried');
    expect(nullsDecodedAsShm, 2,
        reason: 'an explicit null is the ABSENT form, not a present-unknown '
            'one (#lzkeynullstrict)');
  });

  // Finer-grained arms of the same clause. The fixture now carries `in_process`,
  // an explicit null and a non-string value (v2), so these are no longer the
  // only place those shapes are proven — what they still add is the part the
  // fixture cannot express: the VALUE the encoder emits (the fixture asserts
  // only that a `backend` entry is present), the exact refusal message, and the
  // closed-enum round trip driven off `BlobBackendKind.values` rather than a
  // transcription of it.
  group('the clause at ShmBlobRef granularity', () {
    ShmBlobRef decodeBlob(String backendFragment) {
      final wire = '{"Delta": {"base_epoch": 8, "epoch": 9, "ops": '
          '[{"SlotValue": {"node": 7, "payload": {"SharedBlob": '
          '{"offset": 40, "len": 17, "generation": 2, "epoch": 5, '
          '"checksum": 987654321$backendFragment}}}}]}}';
      final message = IpcMessage.decodeJson(wire);
      final op = message.delta!.ops[0] as DeltaOpSlotValue;
      return (op.payload as IpcValueSharedBlob).blob;
    }

    test('`in_process` decodes as itself and is emitted BY NAME', () {
      final blob = decodeBlob(', "backend": "in_process"');
      expect(blob.backend, BlobBackendKind.inProcess);
      expect(blob.toWire().containsKey('backend'), isTrue,
          reason: 'only the `shm` default is omitted');
      expect(blob.toWire()['backend'], 'in_process',
          reason: 'the fixture asserts the field is PRESENT; the token it '
              'carries is only checked here');
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

    test('an explicit null takes the DEFAULT path, not the enum scan', () {
      // `ShmBlobRef.fromWire` branches on `backendWire == null` before the
      // lookup, so null never reaches `BlobBackendKind.fromWire`'s type guard —
      // which is what separates accept-as-shm from the ExpectedString error two
      // sibling bindings raised on this shape while implementing v1.
      final blob = decodeBlob(', "backend": null');
      expect(blob.backend, BlobBackendKind.shm);
      expect(blob.toWire().containsKey('backend'), isFalse,
          reason: 'the null does not survive a round trip');
      expect(decodeBlob('').backend, BlobBackendKind.shm,
          reason: 'and it agrees with the omitted form it stands in for');
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
