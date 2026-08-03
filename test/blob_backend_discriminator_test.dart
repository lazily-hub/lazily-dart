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

/// Navigate a schema-less frame tree to the `SharedBlob` descriptor.
///
/// Shared by the RAW-WIRE control and the RE-ENCODED inspection so both read
/// the same slot of the same shape, one before the decoder and one after the
/// encoder.
Map<String, dynamic> _blobSite(Object? frame, String what) {
  final body =
      (frame! as Map<String, dynamic>)['Delta']! as Map<String, dynamic>;
  final op = (body['ops']! as List<dynamic>)[0] as Map<String, dynamic>;
  final slot = op['SlotValue']! as Map<String, dynamic>;
  final payload = slot['payload']! as Map<String, dynamic>;
  final blob = payload['SharedBlob'];
  expect(blob, isA<Map<String, dynamic>>(),
      reason: '$what should carry a SharedBlob descriptor');
  return blob! as Map<String, dynamic>;
}

/// msgpack `nil`, the byte an explicit `backend: null` is written as.
const _msgpackNil = 0xc0;

/// The lowest and highest `fixstr` tags: `0b101xxxxx`, five bits of length.
const _msgpackFixstrLow = 0xa0;
const _msgpackFixstrHigh = 0xbf;

/// `fixstr(7) "backend"` — the field NAME as msgpack writes it.
const _msgpackBackendFieldName = <int>[
  0xa7, 0x62, 0x61, 0x63, 0x6b, 0x65, 0x6e, 0x64, //
];

int _indexOfSequence(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var hit = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return i;
  }
  return -1;
}

/// SECOND WITNESS for the msgpack form, read straight off the bytes.
///
/// The tree walk in [_wireBackendForm] goes through [msgpackToJson], which is
/// THIS BINDING'S OWN schema-less decoder, so a defect in it would corrupt the
/// control and the thing controlled together and stay invisible. This witness
/// never touches that path: find `fixstr(7) "backend"` in the raw bytes and
/// read the tag immediately after it — `0xc0` is nil, a `fixstr` tag opens the
/// token itself (whose ASCII follows inline), anything else is a value that is
/// not a string, and a frame that never spells the field name is `omitted`.
String _msgpackBackendFormWitness(List<int> bytes, String where) {
  final at = _indexOfSequence(bytes, _msgpackBackendFieldName);
  if (at == -1) return 'omitted';
  final valueAt = at + _msgpackBackendFieldName.length;
  expect(valueAt, lessThan(bytes.length),
      reason: '$where: the frame ends on the `backend` field NAME, with no '
          'value byte after it');
  final tag = bytes[valueAt];
  if (tag == _msgpackNil) return 'null';
  if (tag < _msgpackFixstrLow || tag > _msgpackFixstrHigh) return 'non_string';
  final length = tag & 0x1f;
  expect(valueAt + 1 + length, lessThanOrEqualTo(bytes.length),
      reason: '$where: the `backend` fixstr runs past the end of the frame');
  return String.fromCharCodes(bytes.sublist(valueAt + 1, valueAt + 1 + length));
}

/// SECOND WITNESS for the json form, read straight off the text.
String _jsonBackendFormWitness(String text) {
  final match = RegExp(r'"backend"\s*:\s*').firstMatch(text);
  if (match == null) return 'omitted';
  final rest = text.substring(match.end);
  if (rest.startsWith('null')) return 'null';
  if (!rest.startsWith('"')) return 'non_string';
  return rest.substring(1, rest.indexOf('"', 1));
}

/// Which wire form the scenario's OWN BYTES carry for `backend`, read BEFORE
/// the decoder runs (`#lznullformblind`).
///
/// The `omitted` and `null` families have byte-identical `expect` blocks —
/// both decode to `shm` and both re-encode with the field absent, because
/// reading an explicit null as absent IS the leniency — so no post-decode
/// assertion can tell the two apart, and `backend_forms` used to be
/// differenced against the fixture's own LABELS, which agree with themselves
/// whatever the bytes say. Only the raw slot sees the difference: in the
/// schema-less view an absent map entry and an explicit null / msgpack nil
/// (`0xc0`) are still two different things, separated by `containsKey`.
/// TWO WITNESSES, and they must agree: the tree walk is only as trustworthy as
/// the code path it runs through, so each arm is cross-checked against a
/// reading that never touches this package's decoders.
String _wireBackendForm(Map<String, dynamic> scenario) {
  final Object? frame;
  final String witness;
  final where = scenario['id'] as String;
  switch (scenario['codec'] as String) {
    case 'json':
      final text = scenario['wire_json'] as String;
      witness = _jsonBackendFormWitness(text);
      frame = jsonDecode(text);
    case 'msgpack':
      final bytes = _hexToBytes(scenario['wire_msgpack_hex'] as String);
      witness = _msgpackBackendFormWitness(bytes, where);
      frame = msgpackToJson(bytes);
    default:
      // Fail closed (`#lzscenariobodyskip`).
      fail('unknown codec: ${scenario['codec']}');
  }
  final blob = _blobSite(frame, "$where: the scenario's own wire");
  final String form;
  if (!blob.containsKey('backend')) {
    form = 'omitted';
  } else {
    final value = blob['backend'];
    // A present token names ITSELF as the form — `shm`, `arrow`, `in_process`,
    // `rdma` — and anything that is not a string is the non-string form, which
    // is the one the fixture cannot spell as a token.
    form = value == null
        ? 'null'
        : value is String
            ? value
            : 'non_string';
  }
  expect(form, witness,
      reason: '$where: the two independent readings of the `backend` slot '
          'disagree. One walks the schema-less tree this package decodes the '
          'frame into, the other reads the raw carrier without touching that '
          'decoder — so a defect in the decoder cannot hide inside its own '
          'control');
  return form;
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
  return _blobSite(wire, '${scenario['id']}: re-encoded frame');
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

    // ---- prose keys (`#lzprosekeyconvention`) -------------------------------
    //
    // The nine keys the corpus declares in `assertions.prose` state obligations
    // in English and carry nothing to compare. Each is DISCHARGED by naming the
    // executable keys this run really asserts — the previous free-text excuses
    // named the same assertions in a sentence nothing could check, which is the
    // shape this convention removes. `verifyProse` below refutes a name the run
    // never asserted.
    proseKey(meta, 'clause', dischargedBy: [
      // omitted/null decode as shm and arrow/in_process do not,
      'decoded_backend',
      // a present non-member is refused,
      'rejected',
      // through the documented decode-error family,
      'rejection_is_decode_error',
      // naming the token.
      'error_names_token',
    ]);
    proseKey(meta, 'wire_encoding', dischargedBy: [
      // Both codecs are replayed, and the forms an ABSENT map entry, an
      // explicit nil and a present short string produce are each replayed as a
      // distinct member of the vocabulary — which is only possible because the
      // fixture carries raw text / hex rather than a parsed object. The
      // three-way split is now read OFF THOSE BYTES by `backend_form`, before
      // the decoder runs: if the carriage had collapsed absent-entry and
      // explicit-nil the split could not survive into this runner at all
      // (`#lznullformblind`).
      'backend_form',
      'codecs',
      'backend_forms',
    ]);
    proseKey(meta, 'backend_form_vocabulary', dischargedBy: [
      // The runner obligation this paragraph states — every backend in
      // `assertions.backends` appears as some accept scenario's
      // `decoded_backend` — is the set difference after the loop, over the list
      // `backends` carries out and the values `decoded_backend` asserts.
      'backends',
      'decoded_backend',
      'backend_forms',
    ]);
    proseKey(meta, 'reject_obligation', dischargedBy: [
      // "the frame was refused FOR THE STATED REASON": the paragraph names
      // `error_names_token` as the assertion that separates the two.
      'error_names_token',
      'rejection_is_decode_error',
    ]);
    proseKey(meta, 'null_form', dischargedBy: [
      // The frames really carry an explicit nil rather than an absent entry —
      // the one fact the two families' identical `expect` blocks cannot state,
      'backend_form',
      // the null frames are accept scenarios decoding as shm,
      'decoded_backend',
      // and the null does not survive the round trip as a null.
      'reencoded_backend_field_present',
    ]);
    proseKey(meta, 'non_string_form', dischargedBy: [
      // Refused through the same family the unknown-token refusal uses,
      'rejection_is_decode_error',
      // and told apart from it by which door it came through.
      'rejection_kind',
    ]);
    proseKey(meta, 'epoch_disambiguation',
        // Two epochs from two objects, given different values by the fixture so
        // a runner reading either one twice is red. Asserted per accept
        // scenario, long after this block is finished — which is why the ledger
        // is fixture-scoped.
        dischargedBy: ['frame_epoch', 'blob_epoch']);
    proseKey(meta, 'anti_vacuity', dischargedBy: [
      // (1) omitted forces a real decode and (2) arrow forces the field to be
      // READ — both land on `decoded_backend`;
      'decoded_backend',
      // (3) explicit shm forces the ENCODER half;
      'reencoded_backend_field_present',
      // (4) in_process forces the VOCABULARY to be complete, which is the
      // difference between the declared list and the forms replayed.
      'backends',
      'backend_forms',
    ]);
    proseKey(meta, 'theorem', dischargedBy: [
      // resolve_wrong_backend: an unknown kind is REFUSED rather than
      // normalized to shm and routed,
      'rejected',
      // and each known kind decodes as itself rather than collapsing.
      'decoded_backend',
    ]);
    // `generator` is NOT declared prose: it names a file, and there is nothing
    // in a replay that could observe which script wrote the fixture.
    excuseKey(
      meta,
      'generator',
      'names the script that regenerates this fixture; a replay cannot observe '
          'which generator produced the bytes it is reading',
    );
    addTearDown(() => verifyProse(fixture));

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
    // the loop. Each is EVIDENCE of a replay, never a declaration —
    // `formsReplayed` off the RAW WIRE rather than off the fixture's own
    // labels, `outcomesReplayed` off what the decoder really did
    // (`#lznullformblind`).
    final codecsReplayed = <String>{};
    final outcomesReplayed = <String>{};
    final formsReplayed = <String>{};
    final rejectionKindsReplayed = <String>{};
    final backendsDecoded = <String>{};

    for (final entry in scenariosOf(fixture)) {
      // `id` and `name` are label keys: reading them books nothing
      // (`#lzscenariobodyskip`).
      final where = entry['id'] as String;
      // The scenario map itself is tracked, not just its `expect` block: the
      // wire form, the outcome, the variant and the codec selector live OUT
      // here, and an untracked scenario is where `backend_form` sat read but
      // never asserted against anything the run produced.
      final scenario = assertionsOf(entry, where);
      excuseKey(scenario, 'id',
          'the ledger key this loop records; it names the scenario rather than asserting it');
      assertKey(scenario, 'name', where, '$where: name');
      excuseKey(
          scenario,
          'codec',
          'a selector: it chooses which raw carrier the wire-form control and '
              'the decoder read, and is differenced into `assertions.codecs` '
              'after the loop rather than compared here');
      excuseKey(
          scenario,
          entry['codec'] == 'json' ? 'wire_json' : 'wire_msgpack_hex',
          'the frame under test: this runner\'s INPUT, classified by '
          '`backend_form` and proven by the decoded values asserted below');
      excuseKey(scenario, 'expect',
          'container: asserted key-by-key against the DECODED and RE-ENCODED frames below');
      final block = assertionsOf(scenario['expect'], where);
      replayed += 1;
      codecsReplayed.add(scenario['codec'] as String);

      // THE CONTROL, read off the RAW frame before the decoder runs. A scenario
      // tagged `null` whose frame omits the entry — or a classifier that
      // stopped telling the two apart — reddens HERE, which is the only place
      // it can (`#lznullformblind`).
      final wireForm = _wireBackendForm(scenario);
      formsReplayed.add(wireForm);
      assertKey(
          scenario,
          'backend_form',
          wireForm,
          '$where: the scenario declares a backend form its own bytes must '
              'carry; the label and the wire disagree');

      // ONE decode attempt per scenario, so `outcome` is asserted against the
      // decoder's real answer instead of being used as a selector: a reject
      // frame this binding accepted, or an accept frame it refused, is caught
      // by this assertion rather than by the shape of the branch it took.
      Object? caught;
      IpcMessage? decoded;
      try {
        decoded = _decode(scenario);
      } catch (e) {
        caught = e;
      }
      final outcome = caught == null ? 'accept' : 'reject';
      outcomesReplayed.add(outcome);
      assertKey(scenario, 'outcome', outcome,
          '$where: what the decoder really did with this frame');

      if (outcome == 'reject') {
        rejected += 1;
        excuseKey(
            scenario,
            'variant',
            'the frame was REFUSED, so there is no decoded message whose '
                'variant could be read; the refusal itself is asserted below');
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
      final message = decoded!;
      assertKey(scenario, 'variant', _variantOf(message),
          '$where: fixture variant vs decoded frame');

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
      // Off the WIRE form, not the label: `nullsDecodedAsShm` is the counter
      // that separates the explicit-nil family from the omitted one, so taking
      // its membership from the fixture's own tag would be the same blindness
      // one level down (`#lznullformblind`).
      if (wireForm == 'null' && blob.backend == BlobBackendKind.shm) {
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
    // replayed, and no scenario carried a form the vocabulary omits. The
    // population is read off the BYTES, so a corpus whose `null` frames stopped
    // carrying an explicit nil replays two forms where three are declared.
    assertKeyWith(meta, 'backend_forms', (expected) {
      expect(formsReplayed, equals((expected as List<dynamic>).toSet()),
          reason: 'every declared wire shape must be replayed by this runner, '
              'and no scenario may carry a form the vocabulary does not name');
    });
    // The two vocabularies and the count that used to be hand-written literals
    // and the fixture's own `scenarios.length` — none of which could move for a
    // library regression (`#lznullformblind`).
    assertKeyWith(meta, 'codecs', (expected) {
      expect(codecsReplayed, equals((expected as List<dynamic>).toSet()),
          reason: 'every declared codec must be replayed by this runner, and '
              'no scenario may carry a codec the vocabulary does not name');
    });
    assertKeyWith(meta, 'outcomes', (expected) {
      expect(outcomesReplayed, equals((expected as List<dynamic>).toSet()),
          reason: 'both outcomes must be REACHED — the population is what the '
              'decoder really did, so a binding that accepted everything '
              'replays one outcome where the corpus declares two');
    });
    assertKey(meta, 'scenario_count', replayed);
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
