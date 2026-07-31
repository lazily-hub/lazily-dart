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
// lazily-dart implements the `json` half. `msgpack` is an explicit carve-out
// (declared in bin/interop_peer.dart and now in
// scripts/check-conformance-coverage.sh), so codec/frame_roundtrip_msgpack.json
// is listed as known-uncovered rather than silently ignored.
//
// The runner decodes `wire`, RE-ENCODES the decoded message, decodes again, and
// checks every `expect` key against that second decode. Asserting against the
// fixture literal would prove nothing: the literal never passed through an
// encoder.

// Test-only imports: the library stays pure Dart, tests may use dart:io.
import 'dart:convert';
import 'dart:io';

import 'package:lazily/ipc.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

const _jsonFixture = 'codec/frame_roundtrip_json.json';

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
    excuseKey(meta, 'note',
        'prose: documents the reference-vs-byte-canonical distinction, states nothing the replay observes');

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
}
