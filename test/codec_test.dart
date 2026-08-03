// Frame-codec round-trip conformance (`#lzmsgpackparity`).
//
// protocol.md § Frame codecs makes `json` (the reference codec) and `msgpack`
// (the cross-language binary default) MUST-level for every binding, and
// requires every frame to round-trip through both for all three IpcMessage
// variants. That requirement lived only in prose. The four conformance rungs —
// was the fixture OPENED, were its keys CONSUMED, were they ASSERTED, was every
// SCENARIO replayed — all reason about fixture *content*, and content replay
// never exercises a codec, so a binding could carve out a MUST-level codec and
// stay green on every rung.
//
// lazily-dart now implements BOTH halves (`#lzmsgpackseven`): the `json`
// reference codec in lib/src/ipc.dart, and the `msgpack` cross-language binary
// default in lib/src/msgpack_codec.dart. Neither is a carve-out any more, so
// codec/frame_roundtrip_msgpack.json left `KNOWN_UNCOVERED` in
// scripts/check-conformance-coverage.sh and `carve_outs` in
// bin/interop_peer.dart.
//
// The runner decodes `wire`, RE-ENCODES the decoded message, decodes again, and
// checks every `expect` key against that second decode. Asserting against the
// fixture literal would prove nothing: the literal never passed through an
// encoder.
//
// The msgpack half additionally introspects the ENCODED BYTES through
// `msgpackToJson`. The named-field rule is a property of the ENCODING, so it is
// invisible to every assertion over a decoded IpcMessage: a positional encoder
// round-trips every value correctly and is still outside the wire the `msgpack`
// token names. `encoded_envelope_key` / `encoded_body_field_names` /
// `first_node_encoded_field_names` are the executable form of that rule.

// Test-only imports: the library stays pure Dart, tests may use dart:io.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:lazily/ipc.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

const _jsonFixture = 'codec/frame_roundtrip_json.json';
const _msgpackFixture = 'codec/frame_roundtrip_msgpack.json';

String _fixturePath(String name) {
  final sibling = '../lazily-spec/conformance/$name';
  if (File(sibling).existsSync()) return sibling;
  final local = 'test/conformance/$name';
  if (File(local).existsSync()) return local;
  throw StateError('conformance fixture not found: $name');
}

Map<String, dynamic> _loadFixture(String name) {
  final fixture = attributeFixture(
          jsonDecode(File(_fixturePath(name)).specReadAsStringSync()))
      as Map<String, dynamic>;
  expect(fixture['protocol_version'], 1, reason: '$name protocol_version');
  expect(fixture['kind'], 'FrameCodecRoundTrip', reason: '$name kind');
  return fixture;
}

String _deltaOpVariant(DeltaOp op) {
  if (op is DeltaOpCellSet) return 'CellSet';
  if (op is DeltaOpSlotValue) return 'SlotValue';
  if (op is DeltaOpInvalidate) return 'Invalidate';
  if (op is DeltaOpNodeAdd) return 'NodeAdd';
  if (op is DeltaOpNodeRemove) return 'NodeRemove';
  if (op is DeltaOpEdgeAdd) return 'EdgeAdd';
  if (op is DeltaOpEdgeRemove) return 'EdgeRemove';
  throw StateError('unknown DeltaOp: $op');
}

void _assertSnapshot(Map<String, dynamic> block, Snapshot snap) {
  assertKey(block, 'epoch', snap.epoch);
  assertKey(block, 'node_count', snap.nodes.length);
  assertKey(block, 'edge_count', snap.edges.length);
  assertKey(block, 'root_count', snap.roots.length);
  assertKey(block, 'first_node_type_tag', snap.nodes[0].typeTag);
  final state = snap.nodes[0].state;
  expect(state, isA<NodeStatePayload>(),
      reason: 'first node carries Payload bytes');
  assertKey(
      block, 'first_node_payload', (state as NodeStatePayload).bytes.toList());

  final opaque = snap.nodes.firstWhere((n) => n.state is NodeStateOpaque,
      orElse: () => throw StateError('fixture pins an Opaque node'));
  assertKey(block, 'opaque_node_id', opaque.node);
  // The externally-tagged UNIT variant is the shape most likely to decay into
  // `{"Opaque": null}` under a re-encode, so name it rather than infer it.
  assertKey(block, 'opaque_node_state_tag', opaque.state.toWire());

  assertKey(block, 'first_edge',
      <int>[snap.edges[0].dependent, snap.edges[0].dependency]);
  assertKey(block, 'roots', snap.roots.toList());
}

void _assertDelta(Map<String, dynamic> block, Delta delta) {
  assertKey(block, 'base_epoch', delta.baseEpoch);
  assertKey(block, 'epoch', delta.epoch);
  assertKey(block, 'op_count', delta.ops.length);
  assertKey(block, 'op_variants', delta.ops.map(_deltaOpVariant).toList());

  final first = delta.ops[0];
  expect(first, isA<DeltaOpCellSet>(), reason: 'first op is a CellSet');
  final payload = (first as DeltaOpCellSet).payload;
  expect(payload, isA<IpcValueInline>(), reason: 'first op payload is Inline');
  assertKey(
      block, 'first_op_payload', (payload as IpcValueInline).bytes.toList());

  final nodeAdd = delta.ops.whereType<DeltaOpNodeAdd>().first;
  assertKey(block, 'node_add_type_tag', nodeAdd.typeTag);
}

void _assertCrdtSync(Map<String, dynamic> block, CrdtSync sync) {
  assertKey(block, 'frontier_len', sync.frontier.length);
  assertKey(block, 'frontier_first_peer', sync.frontier[0].peer);
  assertKey(
      block, 'frontier_first_stamp_wall_time', sync.frontier[0].stamp.wallTime);
  assertKey(block, 'op_count', sync.ops.length);
  assertKey(block, 'first_op_node', sync.ops[0].node);
  // Decoded-value assertion, not an encoding one: both self-describing codecs
  // WRITE `key` for a CrdtOp (null when unset — an anti-entropy op's addressing
  // is part of its merge identity). What must survive the round trip is that
  // the decoder reads that null back as absent.
  assertKey(block, 'first_op_key_absent', sync.ops[0].key == null);
  assertKey(block, 'second_op_node', sync.ops[1].node);
  assertKey(block, 'second_op_key', sync.ops[1].key!.path);
  assertKey(block, 'second_op_stamp_peer', sync.ops[1].stamp.peer);
}

void _assertValues(Map<String, dynamic> block, IpcMessage message) {
  if (message is IpcMessageSnapshot)
    return _assertSnapshot(block, message.snapshot!);
  if (message is IpcMessageDelta) return _assertDelta(block, message.delta!);
  if (message is IpcMessageCrdtSync) {
    return _assertCrdtSync(block, message.crdtSync!);
  }
  throw StateError('codec fixture pins no runner for $message');
}

/// Field names of one encoded msgpack map, SORTED.
///
/// A MessagePack map's key order is encoder-defined (§ Frame codecs), so order
/// is not a conformance property; MEMBERSHIP is. The `isA<Map>` guard is the
/// positional-encoder trap: an encoder that writes structs as arrays satisfies
/// every value assertion in this file and dies here.
List<String> _sortedFieldNames(Object? value, String what) {
  expect(value, isA<Map<String, Object?>>(),
      reason: '$what should encode as a named-field map, not a positional '
          'array');
  return (value as Map<String, Object?>).keys.toList()..sort();
}

Object? _encodedMember(Object? body, String key) {
  final map = body as Map<String, Object?>;
  expect(map.containsKey(key), isTrue,
      reason: 'the encoded frame body should carry `$key`');
  return map[key];
}

Object? _encodedElement(Object? value, int index, String what) {
  expect(value, isA<List<Object?>>(),
      reason: '$what should encode as an array');
  final list = value as List<Object?>;
  expect(list.length, greaterThan(index),
      reason: '$what should carry the pinned element');
  return list[index];
}

String _variantOf(IpcMessage message) {
  if (message is IpcMessageSnapshot) return 'Snapshot';
  if (message is IpcMessageDelta) return 'Delta';
  if (message is IpcMessageCrdtSync) return 'CrdtSync';
  throw StateError('codec fixture pins no runner for $message');
}

void main() {
  test('json frames round-trip through the reference codec', () {
    final fixture = _loadFixture(_jsonFixture);
    expect(fixture['codec'], 'json');

    // The fixture-level block pins the codec's identity and the two distinct
    // senses of "canonical" protocol.md keeps apart (`role` = the required
    // interop floor, `byte_canonical` = one deterministic byte form per
    // message).
    final meta = assertionsOf(fixture['assertions'], 'assertions');
    assertKey(meta, 'codec', 'json');
    assertKey(meta, 'self_describing', true);
    assertKey(meta, 'byte_canonical', true);
    assertKey(meta, 'required_of_binding', 'MUST');
    assertKey(meta, 'role', 'reference');
    assertKey(meta, 'scenario_count', (fixture['scenarios'] as List).length);
    // `note` is declared prose by the corpus (`#lzprosekeyconvention`), so it
    // is DISCHARGED rather than excused: the paragraph's whole claim is that
    // `role` and `byte_canonical` are two senses a runner must not conflate,
    // and the two assertions above are what keep them apart.
    proseKey(meta, 'note', dischargedBy: ['role', 'byte_canonical']);
    addTearDown(() => verifyProse(fixture));

    var replayed = 0;
    for (final scenario in scenariosOf(fixture)) {
      final where = scenario['id'] as String;
      final source = IpcMessage.fromWire(scenario['wire']);
      expect(_variantOf(source), scenario['variant'],
          reason: '$where: fixture variant vs decoded frame');

      // Encode the DECODED message and decode the result. The fixture literal
      // is never re-asserted, so a codec that silently drops a field cannot be
      // masked by reading the input back.
      final roundTripped = IpcMessage.decodeJson(source.encodeJson());

      final block = assertionsOf(scenario['expect'], where);
      assertKey(block, 'round_trip_equals_source', roundTripped == source);
      _assertValues(block, roundTripped);
      replayed += 1;
    }
    expect(replayed, 3, reason: 'one scenario per IpcMessage variant');
  });

  test('msgpack frames round-trip on the cross-language binary wire', () {
    final fixture = _loadFixture(_msgpackFixture);
    expect(fixture['codec'], 'msgpack');

    // The distinction protocol.md keeps apart: `msgpack` is self-describing AND
    // NOT byte-canonical, which is why every assertion below reads a decoded
    // value or a field-name SET rather than a golden byte string.
    final meta = assertionsOf(fixture['assertions'], 'assertions');
    assertKey(meta, 'codec', 'msgpack');
    assertKey(meta, 'self_describing', true);
    assertKey(meta, 'byte_canonical', false);
    assertKey(meta, 'required_of_binding', 'MUST');
    assertKey(meta, 'role', 'cross_language_binary_default');
    assertKey(meta, 'scenario_count', (fixture['scenarios'] as List).length);
    // The paragraph states two things: `byte_canonical: false` is why this
    // fixture pins decoded values instead of golden bytes, and msgpack frames
    // encode each struct as a MAP KEYED BY THE JSON FIELD NAME — which it names
    // `encoded_body_field_names` as the executable form of. A positional
    // encoder passes a naive value round trip and fails those keys.
    proseKey(meta, 'note', dischargedBy: [
      'byte_canonical',
      'encoded_envelope_key',
      'encoded_body_field_names',
      'first_node_encoded_field_names',
    ]);
    addTearDown(() => verifyProse(fixture));

    var replayed = 0;
    for (final scenario in scenariosOf(fixture)) {
      final where = scenario['id'] as String;
      // `wire` is written in the reference json form in BOTH codec fixtures, so
      // the msgpack half starts from the same value and differs only in the
      // encoder under test.
      final source = IpcMessage.fromWire(scenario['wire']);
      expect(_variantOf(source), scenario['variant'],
          reason: '$where: fixture variant vs decoded frame');

      final bytes = encodeMsgpack(source);
      final block = assertionsOf(scenario['expect'], where);

      // Schema-less view of the bytes actually produced, asserted BEFORE the
      // decode: a positional encoder decodes back to nothing at all, and the
      // named-field assertions are the ones that should name the defect.
      final generic = msgpackToJson(bytes);
      expect(generic, isA<Map<String, Object?>>(),
          reason: '$where: IpcMessage is externally tagged — a map, never a '
              'positional pair or an integer discriminator');
      final envelope = generic as Map<String, Object?>;
      expect(envelope.length, 1,
          reason: '$where: the external tag is a ONE-entry map, not an '
              'internally tagged `{"type": …, "value": …}`');
      final tag = envelope.keys.first;
      final body = envelope.values.first;

      assertKey(block, 'encoded_envelope_key', tag, '$where: envelope key');
      assertKey(block, 'encoded_body_field_names',
          _sortedFieldNames(body, '$where: a frame body'));

      if (tag == 'Snapshot') {
        // `NodeSnapshot.key` is optional and OMITTED when absent in a
        // self-describing codec (§ NodeKey) — the rule that lets a pre-`key`
        // decoder read a post-`key` frame. It has to hold under msgpack
        // exactly as under json, and the pinned list carries no `key`.
        assertKey(
            block,
            'first_node_encoded_field_names',
            _sortedFieldNames(
                _encodedElement(_encodedMember(body, 'nodes'), 0, '`nodes`'),
                '$where: a node'));
      } else if (tag == 'CrdtSync') {
        // A `CrdtOp` ALWAYS carries `key` (null when unset), so BOTH lists do —
        // the deliberate difference from `NodeSnapshot`.
        final ops = _encodedMember(body, 'ops');
        assertKey(
            block,
            'first_op_encoded_field_names',
            _sortedFieldNames(
                _encodedElement(ops, 0, '`ops`'), '$where: an op'));
        assertKey(
            block,
            'second_op_encoded_field_names',
            _sortedFieldNames(
                _encodedElement(ops, 1, '`ops`'), '$where: an op'));
      }

      final roundTripped = decodeMsgpack(bytes);
      assertKey(block, 'round_trip_equals_source', roundTripped == source);
      _assertValues(block, roundTripped);
      replayed += 1;
    }
    expect(replayed, 3, reason: 'one scenario per IpcMessage variant');
  });

  // The variants and shapes the fixture carries no frame for. `msgpack` is a
  // DISTINCT wire from `json`, so none of these rules is inherited from the
  // json suite above.
  group('msgpack covers what the fixture does not', () {
    test('the reliable-sync control frames round-trip', () {
      final request =
          IpcMessage.ofResyncRequest(const ResyncRequest(fromEpoch: 12));
      expect(decodeMsgpack(encodeMsgpack(request)), request);
      expect((msgpackToJson(encodeMsgpack(request))! as Map).keys.single,
          'ResyncRequest');

      final ack = IpcMessage.ofOutboxAck(const OutboxAck(throughEpoch: 41));
      expect(decodeMsgpack(encodeMsgpack(ack)), ack);
      expect(
          (msgpackToJson(encodeMsgpack(ack))! as Map).keys.single, 'OutboxAck');
    });

    test('a present NodeKey and a SharedBlob descriptor keep their names', () {
      final message = IpcMessage.ofSnapshot(Snapshot(
        epoch: 3,
        nodes: [
          NodeSnapshot(
            1,
            'blob',
            NodeStateSharedBlob(ShmBlobRef(
              offset: 8,
              len: 16,
              generation: 2,
              epoch: 3,
              checksum: 99,
            )),
            key: NodeKey('docs/a'),
          ),
        ],
        edges: const [],
        roots: const [1],
      ));
      expect(decodeMsgpack(encodeMsgpack(message)), message);

      final body = (msgpackToJson(encodeMsgpack(message))! as Map)['Snapshot'];
      final node = _encodedElement(_encodedMember(body, 'nodes'), 0, '`nodes`');
      // The other half of the omit-when-absent rule: a PRESENT key is written,
      // under the same field name the json codec uses.
      expect(_sortedFieldNames(node, 'a keyed node'),
          <String>['key', 'node', 'state', 'type_tag']);
      final state = (node as Map<String, Object?>)['state'];
      expect((state! as Map).keys.single, 'SharedBlob',
          reason: 'NodeState stays externally tagged under msgpack');
      expect(
          _sortedFieldNames(
              (state as Map<String, Object?>)['SharedBlob'], 'a blob ref'),
          <String>['checksum', 'epoch', 'generation', 'len', 'offset']);
    });

    test('byte payloads are integer arrays, and msgpack `bin` is rejected', () {
      final message = IpcMessage.ofSnapshot(Snapshot(
        epoch: 1,
        nodes: [
          NodeSnapshot.payload(1, 'i32', const [1, 2, 3])
        ],
        edges: const [],
        roots: const [1],
      ));
      final node = _encodedElement(
          _encodedMember(
              (msgpackToJson(encodeMsgpack(message))! as Map)['Snapshot'],
              'nodes'),
          0,
          '`nodes`');
      final payload =
          ((node as Map<String, Object?>)['state']! as Map)['Payload'];
      // NOT msgpack `bin`. That is what `rmp_serde` produces for a `Vec<u8>`
      // (serde's default seq impl) and what its decoder accepts; emitting
      // `bin` would put this binding outside the wire it advertises.
      expect(payload, isA<List<Object?>>());
      expect(payload, <int>[1, 2, 3]);

      // `bin 8` carrying the same three bytes, in the payload position.
      final withBin = Uint8List.fromList(<int>[
        0x81, 0xa8, ...utf8.encode('Snapshot'), // {"Snapshot":
        0x81, 0xa5, ...utf8.encode('nodes'), // {"nodes":
        0x91, 0x81, 0xa5, ...utf8.encode('state'), // [{"state":
        0x81, 0xa7, ...utf8.encode('Payload'), // {"Payload":
        0xc4, 0x03, 1, 2, 3, // bin 8 [1,2,3]
      ]);
      expect(
          () => msgpackToJson(withBin),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('not msgpack `bin`'))));
    });

    test('a frame with no trailing garbage is required', () {
      final bytes = encodeMsgpack(
          IpcMessage.ofOutboxAck(const OutboxAck(throughEpoch: 1)));
      expect(
          () => msgpackToJson(Uint8List.fromList(<int>[...bytes, 0xc0])),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('trailing bytes'))));
    });
  });
}
