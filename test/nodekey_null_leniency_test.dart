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
  final map = wire! as Map<String, dynamic>;
  if (scenario['field'] == 'snapshot') {
    final body = map['Snapshot']! as Map<String, dynamic>;
    return (body['nodes']! as List<dynamic>)[0] as Map<String, dynamic>;
  }
  final body = map['Delta']! as Map<String, dynamic>;
  final op = (body['ops']! as List<dynamic>)[0] as Map<String, dynamic>;
  return op['NodeAdd']! as Map<String, dynamic>;
}

Object? _decodedKey(Map<String, dynamic> scenario, IpcMessage message) {
  if (scenario['field'] == 'snapshot') {
    return message.snapshot!.nodes[0].key?.toWire();
  }
  final op = message.delta!.ops[0];
  expect(op, isA<DeltaOpNodeAdd>(),
      reason: 'the fixture declares a NodeAdd op');
  return (op as DeltaOpNodeAdd).key?.toWire();
}

void main() {
  test(
      'NodeKey null-leniency: both wire forms decode as absent, the encoder still omits',
      () {
    final fixture = _loadFixture();

    final block = fixture['assertions'] as Map<String, dynamic>;
    assertKey(block, 'required_of_binding', 'MUST');
    assertKey(block, 'codecs', ['json', 'msgpack']);
    assertKey(block, 'fields', ['snapshot', 'node_add']);
    assertKey(block, 'key_forms', ['omitted', 'null', 'present']);
    assertKey(block, 'scenario_count',
        (fixture['scenarios'] as List<dynamic>).length);
    for (final prose in const [
      'clause',
      'wire_encoding',
      'reencode_obligation',
      'anti_vacuity',
      'generator',
    ]) {
      excuseKey(
        block,
        prose,
        'prose: it states WHY the fixture is shaped this way; the behaviour it '
        'describes is asserted by the per-scenario decode and re-encode below',
      );
    }

    // Anti-vacuity in both directions. A runner that never decodes reports
    // "absent" for everything and satisfies all eight omitted/null scenarios;
    // the `present` count is what only a real decode can produce.
    var replayed = 0;
    var keysDecoded = 0;

    for (final scenario in scenariosOf(fixture)) {
      final expectBlock = scenario['expect'] as Map<String, dynamic>;
      replayed += 1;

      final message = _decode(scenario);
      final key = _decodedKey(scenario, message);
      if (key != null) keysDecoded += 1;

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

    expect(replayed, 12, reason: 'two fields x three key forms x two codecs');
    expect(keysDecoded, 4,
        reason: 'only the `present` scenarios carry a key; a runner reporting '
            'absent for everything satisfies the null cases trivially');
  });
}
