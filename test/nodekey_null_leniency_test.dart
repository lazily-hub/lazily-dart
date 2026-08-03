// NodeKey null-leniency on decode (`#lzkeynullstrict`).
//
// protocol.md § NodeKey said a self-describing codec OMITS an absent `key`, and
// that a decoder seeing no `key` field treats it as absent. That settled the
// omitted form and left an explicit `key: null` undefined — and three bindings
// diverged there. The clause is now explicit: omit-when-absent binds the
// ENCODER, and a decoder MUST accept both forms as absent, refusing neither and
// constructing a key from neither.
//
// lazily-dart was already lenient — `obj.containsKey('key') && obj['key'] != null`
// tests the value, not just the presence. This runner is what holds it there,
// and pins the other half: `toWire()` must still OMIT the field, because a
// decoder that reads null as absent and writes it straight back out has a
// correct decoded value and a non-conforming encoder.
//
// THE RAW-WIRE CONTROL (`#lznullformblind`). Reading an explicit `key: null` as
// absent IS the leniency, so every key in this fixture's `expect` blocks is
// byte-identical across the `omitted` and `null` families — `decoded_key` is
// null for both, by design — and the four `null` scenarios are the four
// `omitted` ones wearing a different id as far as any POST-DECODE assertion can
// tell. A decoder that collapses the two the instant the value is in hand
// (`map['key'] ?? null`) satisfies all twelve scenarios while never once
// distinguishing them, and the manifest rung, the scenario-replay rung and both
// assertion-key rungs are all blind to it at the same time. `key_forms` used to
// be asserted against a HARDCODED literal here, which moves for neither a
// corpus edit nor a library regression.
//
// So [_wireKeyForm] classifies the `key` slot out of the RAW wire — the
// `wire_json` TEXT and the `wire_msgpack_hex` BYTES — BEFORE any decode runs,
// telling an absent map entry from an explicit null (msgpack nil is `0xc0`,
// which the schema-less view carries as a PRESENT key holding null). That
// classification is what `key_form` is asserted against per scenario, what the
// decode expectation is dispatched on, and what `key_forms` is differenced
// against after the loop. Same control as lazily-go's `nodeKeyWireForm` and
// lazily-cpp's `wire_key_form`.

// Test-only imports: the library stays pure Dart, tests may use dart:io.
import 'dart:convert';
import 'dart:io';

import 'package:lazily/ipc.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

const _fixtureName = 'codec/nodekey_null_leniency.json';

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
  expect(fixture['kind'], 'NodeKeyNullLeniency', reason: 'kind');
  return fixture;
}

List<int> _hexToBytes(String hex) {
  expect(hex.length.isEven, isTrue, reason: 'hex string has an odd length');
  return [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
}

IpcMessage _decode(
    Map<String, dynamic> scenario, Map<String, dynamic> expectBlock) {
  switch (scenario['codec'] as String) {
    case 'json':
      final raw = scenario['wire_json'] as String;
      assertKey(expectBlock, 'wire_input_fnv1a64',
          wireInputFnv1a64Hex(utf8.encode(raw)));
      return IpcMessage.decodeJson(raw);
    case 'msgpack':
      final raw = _hexToBytes(scenario['wire_msgpack_hex'] as String);
      assertKey(expectBlock, 'wire_input_fnv1a64', wireInputFnv1a64Hex(raw));
      return decodeMsgpack(raw);
    default:
      fail('unknown codec: ${scenario['codec']}');
  }
}

String _variantOf(IpcMessage message) {
  if (message is IpcMessageSnapshot) return 'Snapshot';
  if (message is IpcMessageDelta) return 'Delta';
  if (message is IpcMessageCrdtSync) return 'CrdtSync';
  throw StateError('fixture pins no runner for $message');
}

/// Navigate a schema-less frame tree to the map that carries the `key` slot.
///
/// Shared by the RAW-WIRE control and the RE-ENCODED inspection so both read
/// the same slot of the same shape, one before the decoder and one after the
/// encoder.
///
/// `node_add` is an EXPLICIT arm (`#lzscenariobodyskip`): this used to treat any
/// `field` that was not `snapshot` as a delta `NodeAdd`, so a scenario naming a
/// third field would have been read off the WRONG part of the frame and the
/// null-leniency claim would have been proven about something the fixture never
/// named.
Map<String, dynamic> _nodeKeySite(
    Map<String, dynamic> scenario, Object? frame, String what) {
  expect(frame, isA<Map<String, dynamic>>(),
      reason: '${scenario['id']}: $what should be a frame object');
  final map = frame! as Map<String, dynamic>;
  switch (scenario['field']) {
    case 'snapshot':
      final body = map['Snapshot']! as Map<String, dynamic>;
      return (body['nodes']! as List<dynamic>)[0] as Map<String, dynamic>;
    case 'node_add':
      final body = map['Delta']! as Map<String, dynamic>;
      final op = (body['ops']! as List<dynamic>)[0] as Map<String, dynamic>;
      return op['NodeAdd']! as Map<String, dynamic>;
    default:
      fail('unknown scenario field `${scenario['field']}`');
  }
}

/// msgpack `nil`, the byte an explicit `key: null` is written as.
const _msgpackNil = 0xc0;

/// `fixstr(3) "key"` — the field NAME as msgpack writes it, which is what the
/// byte-level witness scans for.
const _msgpackKeyFieldName = <int>[0xa3, 0x6b, 0x65, 0x79];

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
/// The tree-based classification below goes through [msgpackToJson], which is
/// THIS BINDING'S OWN schema-less decoder — so a defect in it corrupts the
/// control and the thing controlled together, and the control cannot see its
/// own defect. This witness bypasses that path entirely: find the field name
/// `fixstr(3) "key"` in the raw bytes, and read the tag byte immediately after
/// it. `0xc0` is nil (the `null` form), any other tag opens a value (`present`),
/// and a frame that never spells the field name at all is `omitted`.
String _msgpackKeyFormWitness(List<int> bytes, String where) {
  final at = _indexOfSequence(bytes, _msgpackKeyFieldName);
  if (at == -1) return 'omitted';
  final valueAt = at + _msgpackKeyFieldName.length;
  expect(valueAt, lessThan(bytes.length),
      reason: '$where: the frame ends on the `key` field NAME, with no value '
          'byte after it');
  return bytes[valueAt] == _msgpackNil ? 'null' : 'present';
}

/// SECOND WITNESS for the json form, read straight off the text.
///
/// Same reasoning one codec over: this looks at the characters the corpus
/// ships rather than at any parse of them.
String _jsonKeyFormWitness(String text) {
  final match = RegExp(r'"key"\s*:\s*').firstMatch(text);
  if (match == null) return 'omitted';
  return text.startsWith('null', match.end) ? 'null' : 'present';
}

/// Which of the three wire forms the scenario's OWN BYTES carry, read before
/// the decoder runs.
///
/// The json arm parses the raw `wire_json` text and the msgpack arm unpacks the
/// raw `wire_msgpack_hex` bytes; both land in the schema-less view, where an
/// absent map entry and an explicit null / msgpack nil (`0xc0`) are still two
/// different things — `containsKey` separates them, which no typed `NodeKey?`
/// and no `?? null` decode can. This is the ONLY place in the file where the
/// `omitted` and `null` families differ, so it is the only place a decoder that
/// collapsed them can redden.
///
/// TWO WITNESSES, and they must agree. The tree walk is only as trustworthy as
/// the code path it runs through — [msgpackToJson] is this package's own
/// decoder — so each arm is cross-checked against a witness that never touches
/// it: the raw bytes for msgpack, the raw characters for json. A control that
/// shares a defect with the thing it controls cannot see that defect; these two
/// disagree the moment either side moves.
String _wireKeyForm(Map<String, dynamic> scenario) {
  final Object? frame;
  final String witness;
  final where = scenario['id'] as String;
  switch (scenario['codec'] as String) {
    case 'json':
      final text = scenario['wire_json'] as String;
      witness = _jsonKeyFormWitness(text);
      frame = jsonDecode(text);
    case 'msgpack':
      final bytes = _hexToBytes(scenario['wire_msgpack_hex'] as String);
      witness = _msgpackKeyFormWitness(bytes, where);
      frame = msgpackToJson(bytes);
    default:
      // Fail closed (`#lzscenariobodyskip`): a codec this runner cannot read
      // raw would otherwise classify nothing and report the scenario covered.
      fail('unknown codec: ${scenario['codec']}');
  }
  final site = _nodeKeySite(scenario, frame, "the scenario's own wire");
  final String form;
  if (!site.containsKey('key')) {
    form = 'omitted';
  } else if (site['key'] == null) {
    form = 'null';
  } else {
    form = 'present';
  }
  expect(form, witness,
      reason: '$where: the two independent readings of the `key` slot '
          'disagree. One walks the schema-less tree this package decodes the '
          'frame into, the other reads the raw carrier without touching that '
          "decoder — so a defect in the decoder cannot hide inside its own "
          'control');
  return form;
}

/// Re-encode under the scenario's own codec and read the field set back off the
/// WIRE tree, not off the typed object — a typed object cannot distinguish
/// "field absent" from "field present and null", which is the whole distinction.
Map<String, dynamic> _reencodedNode(
    Map<String, dynamic> scenario, IpcMessage message) {
  Object? wire = message.toWire();
  if (scenario['codec'] == 'msgpack') {
    // Through the msgpack codec specifically. Both codecs derive from the same
    // `toWire()` tree, but that is worth proving rather than assuming: the
    // `#lzmsgpackparity` defect was a msgpack encoder writing `key: null` while
    // json omitted it.
    wire = msgpackToJson(encodeMsgpack(message));
  }
  return _nodeKeySite(scenario, wire, 're-encoded frame');
}

Object? _decodedKey(Map<String, dynamic> scenario, IpcMessage message) {
  switch (scenario['field']) {
    case 'snapshot':
      return message.snapshot!.nodes[0].key?.toWire();
    case 'node_add':
      final op = message.delta!.ops[0];
      expect(op, isA<DeltaOpNodeAdd>(),
          reason: 'the fixture declares a NodeAdd op');
      return (op as DeltaOpNodeAdd).key?.toWire();
    default:
      fail('unknown scenario field `${scenario['field']}`');
  }
}

void main() {
  test(
      'NodeKey null-leniency: both wire forms decode as absent, the encoder still omits',
      () {
    final fixture = _loadFixture();

    // Tracked, so the meta block is subject to the consumption guard — an
    // untracked block silently accepts a key no runner reads, which is how the
    // corpus's new `prose` declaration would have slipped past here.
    final block = assertionsOf(fixture['assertions'], 'assertions');
    assertKey(block, 'required_of_binding', 'MUST');

    // Populations the vocabularies are differenced against AFTER the loop.
    // Evidence of a replay, never a declaration: compared to the hardcoded
    // literals that stood here, every one of them was green over a runner that
    // decodes nothing — the exact vacuity `anti_vacuity` exists to name
    // (`#lznullformblind`).
    final codecsReplayed = <String>{};
    final fieldsReplayed = <String>{};
    final formsReplayed = <String>{};

    // ---- prose keys (`#lzprosekeyconvention`) -------------------------------
    proseKey(block, 'clause', dischargedBy: [
      // "a decoder MUST accept both an omitted `key` and an explicit
      // `key: null` and read both as absent". `key_form` is what proves the two
      // forms were DISTINCT going in — read off the bytes, not off the label —
      // and `decoded_key` is what proves they arrive the same, at both of the
      // optional-key sites `fields` names.
      'key_form',
      'decoded_key',
      'fields',
    ]);
    proseKey(block, 'wire_encoding', dischargedBy: [
      // Executable proof that the exact raw text / decoded-hex byte buffer
      // reaches the library decoder rather than a reconstructed proxy.
      'wire_input_fnv1a64',
    ]);
    proseKey(block, 'reencode_obligation',
        // The paragraph names its own executable form: "`expect.
        // reencoded_key_field_present` is the half a decode assertion cannot
        // reach."
        dischargedBy: ['reencoded_key_field_present']);
    proseKey(block, 'anti_vacuity', dischargedBy: [
      // "`present` forces a real key through and `omitted` forces a real
      // decode" — and which scenario is which is now counted off the RAW WIRE
      // rather than taken from the fixture's own labels, so a runner that
      // replays one family twice is red on the set difference.
      'key_form',
      'key_forms',
      'decoded_key',
      'reencoded_key_field_present',
    ]);
    excuseKey(
      block,
      'generator',
      'names the script that regenerates this fixture; a replay cannot observe '
          'which generator produced the bytes it is reading',
    );
    addTearDown(() => verifyProse(fixture));

    // Anti-vacuity in both directions. A runner that never decodes reports
    // "absent" for everything and satisfies all eight omitted/null scenarios;
    // the `present` count is what only a real decode can produce.
    var replayed = 0;
    var keysDecoded = 0;

    for (final entry in scenariosOf(fixture)) {
      // `id` and `name` are label keys: reading them books nothing
      // (`#lzscenariobodyskip`), so a body that fell through here would still
      // be reported as having replayed nothing.
      final where = entry['id'] as String;
      // The scenario map itself is tracked, not just its `expect` block: the
      // wire form, the variant and the two selectors live OUT here, and an
      // untracked scenario is where `key_form` sat unread while the runner
      // asserted a literal instead.
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
          'field',
          'a selector: it chooses which optional-key site this scenario '
              'exercises, and is differenced into `assertions.fields` after '
              'the loop rather than compared here');
      excuseKey(
          scenario,
          scenario['codec'] == 'json' ? 'wire_json' : 'wire_msgpack_hex',
          'the frame under test: this runner\'s INPUT, classified by '
          '`key_form` and proven by the decoded values asserted below');
      excuseKey(scenario, 'expect',
          'container: asserted key-by-key against the DECODED and RE-ENCODED frames below');

      final expectBlock = assertionsOf(scenario['expect'], '$where: expect');
      replayed += 1;
      codecsReplayed.add(scenario['codec'] as String);
      fieldsReplayed.add(scenario['field'] as String);

      // THE CONTROL. Not a selector: a scenario tagged `null` whose frame omits
      // the entry — or a classifier that stopped telling the two apart —
      // reddens HERE, which is the only place in this file it can.
      final wireForm = _wireKeyForm(scenario);
      formsReplayed.add(wireForm);
      assertKey(
          scenario,
          'key_form',
          wireForm,
          '$where: the scenario declares a key form its own bytes must carry; '
              'the label and the wire disagree');

      final message = _decode(scenario, expectBlock);
      assertKey(scenario, 'variant', _variantOf(message), '$where: variant');
      final key = _decodedKey(scenario, message);
      if (key != null) keysDecoded += 1;

      // The clause itself, dispatched on the RAW form rather than on the
      // fixture's `expect` — which is identical across the two absent forms and
      // therefore cannot state this. Fail closed on a form this runner has no
      // rule for.
      switch (wireForm) {
        case 'omitted':
        case 'null':
          expect(key, isNull,
              reason: '$where: the wire carries the `$wireForm` form, and BOTH '
                  'absent forms must decode to no key at all — refusing '
                  'neither and constructing a key from neither');
        case 'present':
          expect(key, isNotNull,
              reason: '$where: the wire carries a real key, so a decoder that '
                  'reports absent for everything must die here');
        default:
          fail('$where: the wire carries a `key` form this runner has no rule '
              'for: `$wireForm`');
      }

      // The decode half: omitted and explicit-null must both arrive absent.
      assertKey(expectBlock, 'decoded_key', key);

      final node = _reencodedNode(scenario, message);
      // The encode half, which no assertion over the decoded value can reach.
      assertKey(
          expectBlock, 'reencoded_key_field_present', node['key'] != null);

      assertKey(expectBlock, 'node', node['node']);
      assertKey(expectBlock, 'type_tag', node['type_tag']);
      assertKey(
          expectBlock,
          'payload',
          ((node['state']! as Map<String, dynamic>)['Payload']!
                  as List<dynamic>)
              .cast<int>());
      assertKey(expectBlock, 'epoch',
          message.snapshot?.epoch ?? message.delta!.epoch);
    }

    // ---- vocabularies, differenced against the replay ------------------------
    //
    // Each of these was a hand-written literal, and `scenario_count` was the
    // fixture's own `scenarios.length` — the fixture compared to itself. None
    // of them could move for a library regression, and `key_forms` could not
    // move for a corpus edit either (`#lznullformblind`). They are now compared
    // against what the loop really dispatched on, with `key_forms` taken off
    // the RAW WIRE rather than off the fixture's labels.
    assertKeyWith<void>(block, 'codecs', (expected) {
      expect(codecsReplayed, equals((expected as List<dynamic>).toSet()),
          reason: 'every declared codec must be replayed by this runner, and '
              'no scenario may carry a codec the vocabulary does not name');
    });
    assertKeyWith<void>(block, 'fields', (expected) {
      expect(fieldsReplayed, equals((expected as List<dynamic>).toSet()),
          reason: 'every declared optional-key site must be replayed, and no '
              'scenario may exercise a site the vocabulary does not name');
    });
    assertKeyWith<void>(block, 'key_forms', (expected) {
      expect(formsReplayed, equals((expected as List<dynamic>).toSet()),
          reason: 'every declared wire form must be replayed AS THAT FORM ON '
              'THE WIRE. A decoder that collapses `null` onto `omitted` — or a '
              'classifier that stops telling them apart — replays two forms '
              'where the corpus declares three');
    });
    assertKey(block, 'scenario_count', replayed);

    expect(replayed, 12, reason: 'two fields x three key forms x two codecs');
    expect(keysDecoded, 4,
        reason: 'only the `present` scenarios carry a key; a runner reporting '
            'absent for everything satisfies the null cases trivially');
  });
}
