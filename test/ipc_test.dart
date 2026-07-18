// Test-only imports: the library stays pure Dart, tests may use dart:io.
import 'dart:convert';
import 'dart:io';

import 'package:lazily/ipc.dart';
import 'package:test/test.dart';

/// Locate a conformance fixture: prefer the committed copy in
/// `test/conformance/` (self-contained, matches lazily-kt), then fall back to
/// the sibling `lazily-spec/conformance/` submodule for dev convenience (parity
/// with lazily-js).
String _fixturePath(String name) {
  final local = 'test/conformance/$name';
  if (File(local).existsSync()) return local;
  final sibling = '../lazily-spec/conformance/$name';
  if (File(sibling).existsSync()) return sibling;
  throw StateError('conformance fixture not found: $name');
}

Map<String, Object?> _loadFixture(String name) {
  final fixture =
      jsonDecode(File(_fixturePath(name)).readAsStringSync()) as Map<String, Object?>;
  expect(fixture['protocol_version'], 1, reason: '$name protocol_version');
  return fixture;
}

void assertRoundTripJson(IpcMessage message, Map<String, Object?> fixture) {
  final wire = fixture['wire'] as Map<String, Object?>;
  expect(message.toWire(), wire);
  expect(IpcMessage.decodeJson(message.encodeJson()), message);
}

String nodeStateKind(NodeState state) {
  if (state is NodeStatePayload) return 'Payload';
  if (state is NodeStateSharedBlob) return 'SharedBlob';
  if (state is NodeStateOpaque) return 'Opaque';
  throw StateError('unknown NodeState: $state');
}

String deltaOpKind(DeltaOp op) {
  return (op.toWire() as Map).keys.single as String;
}

ShmBlobRef? firstSharedBlob(Snapshot snapshot) {
  final state = snapshot.nodes.first.state;
  return state is NodeStateSharedBlob ? state.blob : null;
}

const allOpKinds = {
  'CellSet',
  'SlotValue',
  'Invalidate',
  'NodeAdd',
  'NodeRemove',
  'EdgeAdd',
  'EdgeRemove',
};

/// Cross-check every `assertions` metadata field against the parsed message so
/// silent drift between `wire` and `assertions` is caught. An unknown assertion
/// key throws, mirroring the lazily-js/lazily-kt conformance harness.
void assertFixtureAssertions(IpcMessage message, Map<String, Object?> fixture) {
  final a =
      fixture['assertions'] as Map<String, Object?>?; // ignore: unnecessary_cast
  expect(a, isNotNull,
      reason: 'fixture missing assertions: ${fixture['description']}');

  if (message.isSnapshot) {
    final snap = message.snapshot!;
    for (final entry in a!.entries) {
      final key = entry.key;
      final expected = entry.value;
      Object? actual;
      switch (key) {
        case 'epoch':
          actual = snap.epoch;
          break;
        case 'node_count':
          actual = snap.nodes.length;
          break;
        case 'edge_count':
          actual = snap.edges.length;
          break;
        case 'root_count':
          actual = snap.roots.length;
          break;
        case 'first_node_type_tag':
          actual = snap.nodes.first.typeTag;
          break;
        case 'first_node_state_kind':
          actual = nodeStateKind(snap.nodes.first.state);
          break;
        case 'has_opaque_node':
          actual = snap.nodes.any((n) => n.state is NodeStateOpaque);
          break;
        case 'opaque_node_id':
          actual = snap.nodes
              .cast<NodeSnapshot?>()
              .firstWhere((n) => n!.state is NodeStateOpaque,
                  orElse: () => null)
              ?.node;
          break;
        case 'blob_offset':
          actual = firstSharedBlob(snap)?.offset;
          break;
        case 'blob_len':
          actual = firstSharedBlob(snap)?.len;
          break;
        case 'blob_epoch':
          actual = firstSharedBlob(snap)?.epoch;
          break;
        default:
          throw StateError('unknown snapshot assertion key: $key');
      }
      expect(actual, expected, reason: 'snapshot assertion "$key"');
    }
  } else if (message.isDelta) {
    final delta = message.delta!;
    for (final entry in a!.entries) {
      final key = entry.key;
      final expected = entry.value;
      Object? actual;
      switch (key) {
        case 'base_epoch':
          actual = delta.baseEpoch;
          break;
        case 'epoch':
          actual = delta.epoch;
          break;
        case 'is_sequential':
          actual = delta.isNextAfter(delta.baseEpoch);
          break;
        case 'op_count':
          actual = delta.ops.length;
          break;
        case 'has_all_op_variants':
          actual = allOpKinds.every(delta.ops.map(deltaOpKind).toSet().contains);
          break;
        case 'resync_after_epoch_10':
          actual = delta.applyStatus(10).isResyncRequired;
          break;
        case 'first_op_kind':
          actual = deltaOpKind(delta.ops.first);
          break;
        case 'first_op_payload_kind':
          final first = delta.ops.first;
          final payload = first is DeltaOpCellSet
              ? first.payload
              : (first as DeltaOpSlotValue).payload;
          actual = (payload.toWire() as Map).keys.single;
          break;
        default:
          throw StateError('unknown delta assertion key: $key');
      }
      expect(actual, expected, reason: 'delta assertion "$key"');
    }
  } else {
    fail('unknown message kind for fixture ${fixture['description']}');
  }
}

IpcValue _inline(List<int> bytes) => IpcValueInline(bytes);

void main() {
  group('NodeKey', () {
    test('accepts a well-formed multi-segment path', () {
      final key = NodeKey('scores/alice');
      expect(key.path, 'scores/alice');
      expect(key.segments, ['scores', 'alice']);
      expect(key.toWire(), 'scores/alice');
      expect(NodeKey.fromWire('outer/k1/inner/k2').segments.length, 4);
    });

    test('round-trips through wire and is value-equal', () {
      expect(NodeKey('a/b'), NodeKey('a/b'));
      expect(NodeKey('a/b').hashCode, NodeKey('a/b').hashCode);
      expect(NodeKey('a') == NodeKey('b'), isFalse);
    });

    test('rejects empty path, empty segments, and over-bounds', () {
      expect(() => NodeKey(''), throwsArgumentError);
      expect(() => NodeKey('/a'), throwsArgumentError);
      expect(() => NodeKey('a/'), throwsArgumentError);
      expect(() => NodeKey('a//b'), throwsArgumentError);
      expect(() => NodeKey(List.filled(33, 's').join('/')),
          throwsArgumentError);
      expect(() => NodeKey('x' * 1025), throwsArgumentError);
    });
  });

  group('ShmBlobRef', () {
    test('serializes and round-trips', () {
      final blob = ShmBlobRef(
          offset: 0, len: 16, generation: 1, epoch: 9, checksum: 123);
      expect(blob.toWire(), {
        'offset': 0,
        'len': 16,
        'generation': 1,
        'epoch': 9,
        'checksum': 123,
      });
      expect(ShmBlobRef.fromWire(blob.toWire()), blob);
    });

    test('rejects negative fields', () {
      expect(
          () => ShmBlobRef(
              offset: -1, len: 1, generation: 1, epoch: 1, checksum: 1),
          throwsArgumentError);
    });
  });

  group('NodeState / IpcValue', () {
    test('payload serializes as a byte array, not base64', () {
      final state = NodeStatePayload([10, 255, 0]);
      expect(state.toWire(), {
        'Payload': [10, 255, 0]
      });
      expect(NodeState.fromWire(state.toWire()), state);
    });

    test('opaque is the bare unit string', () {
      const state = NodeStateOpaque();
      expect(state.toWire(), 'Opaque');
      expect(NodeState.fromWire('Opaque'), state);
    });

    test('shared-blob carries the descriptor', () {
      final state = NodeStateSharedBlob(ShmBlobRef(
          offset: 7, len: 4, generation: 1, epoch: 2, checksum: 9));
      expect(NodeState.fromWire(state.toWire()), state);
    });

    test('IpcValue.of normalizes inputs', () {
      expect(IpcValue.of([1, 2]), IpcValueInline([1, 2]));
      expect(
          IpcValue.of(ShmBlobRef(
              offset: 0, len: 0, generation: 0, epoch: 0, checksum: 0)),
          isA<IpcValueSharedBlob>());
      expect(IpcValue.of([1]).runtimeType, IpcValueInline([1]).runtimeType);
    });
  });

  group('Snapshot', () {
    test('round-trips through JSON bytes', () {
      final snapshot = Snapshot(
        epoch: 7,
        nodes: [
          NodeSnapshot.payload(1, 'i32', [1, 2, 3]),
          NodeSnapshot.opaque(2, 'opaque-type'),
          NodeSnapshot.sharedBlob(
            3,
            'text/plain',
            ShmBlobRef(
                offset: 0, len: 16, generation: 1, epoch: 7, checksum: 999),
          ),
        ],
        edges: [const EdgeSnapshot(2, 1), const EdgeSnapshot(3, 1)],
        roots: [1, 2],
      );

      final message = IpcMessage.ofSnapshot(snapshot);
      final decoded = IpcMessage.decodeJson(message.encodeJson());

      expect(decoded, message);
      expect(decoded.snapshot, snapshot);
    });

    test('omits the key field when null (format-aware)', () {
      final snapshot = NodeSnapshot.payload(1, 'i32', [1]);
      expect(snapshot.toWire().containsKey('key'), isFalse);
    });

    test('round-trips an optional NodeKey on a node', () {
      final snapshot = Snapshot(
        epoch: 1,
        nodes: [
          NodeSnapshot.payload(1, 'i32', [1], key: NodeKey('scores/alice')),
        ],
        roots: [1],
      );
      final wire = snapshot.nodes.first.toWire();
      expect(wire['key'], 'scores/alice');

      final decoded = NodeSnapshot.fromWire(wire);
      expect(decoded.key, NodeKey('scores/alice'));
    });

    test('permission filter omits non-readable nodes, edges, and roots', () {
      final permissions = PeerPermissions();
      permissions.allowMany(1, OpKind.read, [1, 2]);

      final snapshot = Snapshot(
        epoch: 5,
        nodes: [
          NodeSnapshot.payload(1, 'i32', [1]),
          NodeSnapshot.payload(2, 'i32', [2]),
          NodeSnapshot.payload(3, 'i32', [3]),
        ],
        edges: [const EdgeSnapshot(2, 1), const EdgeSnapshot(3, 1)],
        roots: [1, 2, 3],
      );

      final filtered = snapshot.filterReadable(permissions, 1);
      expect(filtered.nodes.map((n) => n.node), [1, 2]);
      expect(filtered.edges, [const EdgeSnapshot(2, 1)]);
      expect(filtered.roots, [1, 2]);
    });
  });

  group('Delta', () {
    test('Delta.next advances the epoch by exactly one', () {
      final delta = Delta.next(40, [DeltaOp.cellSet(1, [10])]);
      expect(delta.baseEpoch, 40);
      expect(delta.epoch, 41);
      expect(delta.isNextAfter(40), isTrue);
      expect(delta.isNextAfter(39), isFalse);
    });

    test('round-trips all seven op variants', () {
      final delta = Delta.next(40, [
        DeltaOp.cellSet(1, [10]),
        DeltaOp.slotValue(2, [20]),
        DeltaOp.invalidate(3),
        DeltaOp.nodeAdd(4, 'u64', NodeState.payload([64])),
        DeltaOp.nodeRemove(5),
        DeltaOp.edgeAdd(2, 1),
        DeltaOp.edgeRemove(3, 1),
      ]);

      final message = IpcMessage.ofDelta(delta);
      final decoded = IpcMessage.decodeJson(message.encodeJson());

      expect(decoded, message);
      expect(decoded.delta!.epoch, 41);
      expect({for (final op in decoded.delta!.ops) op.runtimeType}.length, 7);
    });

    test('NodeAdd round-trips an optional NodeKey', () {
      final op = DeltaOp.nodeAdd(4, 'u64', NodeState.payload([64]),
          key: NodeKey('outer/k1'));
      final decoded = DeltaOp.fromWire(op.toWire());
      expect(decoded, op);
      expect((decoded as DeltaOpNodeAdd).key, NodeKey('outer/k1'));
    });

    test('applyStatus requests resync on an epoch gap', () {
      final delta = Delta(baseEpoch: 12, epoch: 13);
      final status = delta.applyStatus(10);
      expect(status.isResyncRequired, isTrue);
      final resync = status as DeltaApplyStatusResyncRequired;
      expect(resync.lastEpoch, 10);
      expect(resync.baseEpoch, 12);
      expect(resync.epoch, 13);

      expect(delta.applyStatus(12), const DeltaApplyStatusApply(13));
    });

    test('permission filter omits without redaction', () {
      final permissions = PeerPermissions();
      permissions.allowMany(1, OpKind.read, [1, 2, 5]);

      final delta = Delta.next(8, [
        DeltaOp.cellSet(1, [1]),
        DeltaOp.slotValue(2, [2]),
        DeltaOp.invalidate(3),
        DeltaOp.nodeAdd(4, 'u8', NodeState.payload([4])),
        DeltaOp.nodeRemove(5),
        DeltaOp.edgeAdd(2, 1),
        DeltaOp.edgeRemove(3, 1),
      ]);

      final filtered = delta.filterReadable(permissions, 1);
      expect(filtered.ops.map((op) => op.runtimeType), [
        DeltaOpCellSet,
        DeltaOpSlotValue,
        DeltaOpNodeRemove,
        DeltaOpEdgeAdd,
      ]);
    });
  });

  group('streaming JSON (#lzdartstreamingjson)', () {
    final snapshot = IpcMessage.ofSnapshot(Snapshot(
      epoch: 7,
      nodes: [
        NodeSnapshot.payload(1, 'i32', [1, 2, 3]),
        NodeSnapshot.opaque(2, 'opaque-type'),
        NodeSnapshot.sharedBlob(
          3,
          'text/plain',
          ShmBlobRef(
              offset: 0, len: 16, generation: 1, epoch: 7, checksum: 999),
        ),
        NodeSnapshot.payload(4, 'k', [9], key: NodeKey('scores/alice')),
      ],
      edges: [const EdgeSnapshot(2, 1), const EdgeSnapshot(3, 1)],
      roots: [1, 2],
    ));

    final delta = IpcMessage.ofDelta(Delta.next(40, [
      DeltaOp.cellSet(1, [10]),
      DeltaOp.slotValue(2, [20]),
      DeltaOp.invalidate(3),
      DeltaOp.nodeAdd(4, 'u64', NodeState.payload([64]),
          key: NodeKey('outer/k1')),
      DeltaOp.nodeRemove(5),
      DeltaOp.edgeAdd(2, 1),
      DeltaOp.edgeRemove(3, 1),
    ]));

    final crdtSync = IpcMessage.ofCrdtSync(CrdtSync(
      frontier: [
        StampFrontierEntry(1, WireStamp(wallTime: 200, logical: 0, peer: 1)),
        StampFrontierEntry(2, WireStamp(wallTime: 180, logical: 3, peer: 2)),
      ],
      ops: [
        CrdtOp.newOp(
            1, WireStamp(wallTime: 200, logical: 0, peer: 1), [10, 20]),
        CrdtOp.keyed(2, NodeKey('scores/alice'),
            WireStamp(wallTime: 180, logical: 3, peer: 2), [30]),
      ],
    ));

    final resync = IpcMessage.ofResyncRequest(const ResyncRequest(fromEpoch: 9));
    final ack = IpcMessage.ofOutboxAck(const OutboxAck(throughEpoch: 12));

    final messages = {
      'Snapshot': snapshot,
      'Delta': delta,
      'CrdtSync': crdtSync,
      'ResyncRequest': resync,
      'OutboxAck': ack,
    };

    for (final entry in messages.entries) {
      test('${entry.key}.encodeJsonStreaming() matches encodeJson() byte-for-byte',
          () {
        final canonical = entry.value.encodeJson();
        final streamed = entry.value.encodeJsonStreaming();
        expect(streamed, canonical,
            reason: '${entry.key} streaming bytes must match encodeJson');
      });
    }

    test('encodeJsonStreaming round-trips through decodeJson', () {
      for (final message in messages.values) {
        final decoded = IpcMessage.decodeJson(message.encodeJsonStreaming());
        expect(decoded, message);
      }
    });

    test('writeJson produces a tag-prefixed JSON object', () {
      final buf = StringBuffer();
      crdtSync.writeJson(buf);
      expect(jsonDecode(buf.toString()), crdtSync.toWire());
    });

    test('empty Snapshot/Delta/CrdtSync still match', () {
      final emptySnap = IpcMessage.ofSnapshot(const Snapshot(epoch: 0));
      final emptyDelta = IpcMessage.ofDelta(const Delta(baseEpoch: 0, epoch: 1));
      final emptySync = IpcMessage.ofCrdtSync(const CrdtSync());
      for (final m in [emptySnap, emptyDelta, emptySync]) {
        expect(m.encodeJsonStreaming(), m.encodeJson());
      }
    });
  });

  group('lazily-lean transition rules', () {
    // lean `nextDelta_epoch` / `nextDelta_sequential` / `apply_nextDelta`
    test('nextDelta is always sequential and applies to baseEpoch+1', () {
      for (final base in [0, 1, 40, 999]) {
        final delta = Delta.next(base, const []);
        expect(delta.epoch, base + 1, reason: 'nextDelta_epoch');
        expect(delta.isNextAfter(base), isTrue, reason: 'nextDelta_sequential');
        expect(delta.applyStatus(base), DeltaApplyStatusApply(base + 1),
            reason: 'apply_nextDelta');
      }
    });

    // lean `gap_requires_resync` / `nonsequential_epoch_requires_resync`
    test('a base-epoch gap or bad epoch fails closed to resync', () {
      final gapped = Delta(baseEpoch: 12, epoch: 13);
      expect(gapped.applyStatus(10).isResyncRequired, isTrue,
          reason: 'gap_requires_resync');

      final badEpoch = Delta(baseEpoch: 10, epoch: 99);
      expect(badEpoch.applyStatus(10).isResyncRequired, isTrue,
          reason: 'nonsequential_epoch_requires_resync');
    });

    // lean `equal_cell_set_is_silent` / `changed_cell_set_emits_cell_set`
    test('PartialEq guard: equal cell write is silent, changed emits CellSet', () {
      expect(cellSetOps(1, _inline([1]), _inline([1])), const <DeltaOp>[],
          reason: 'equal_cell_set_is_silent');
      expect(cellSetOps(1, _inline([1]), _inline([2])),
          [DeltaOpCellSet(1, _inline([2]))],
          reason: 'changed_cell_set_emits_cell_set');
    });

    // lean `equal_memo_suppresses_downstream` /
    //      `changed_memo_publishes_then_invalidates`
    test('memo equality: equal recompute is silent, changed publishes+invalidates', () {
      expect(memoOps(2, _inline([1]), _inline([1]), const [3, 4]),
          const <DeltaOp>[],
          reason: 'equal_memo_suppresses_downstream');
      expect(
          memoOps(2, _inline([1]), _inline([5]), const [3, 4]),
          [
            DeltaOpSlotValue(2, _inline([5])),
            const DeltaOpInvalidate(3),
            const DeltaOpInvalidate(4),
          ],
          reason: 'changed_memo_publishes_then_invalidates');
    });

    // lean `equal_signal_is_silent` /
    //      `changed_signal_materializes_slot_value` /
    //      `signal_never_emits_bare_invalidate`
    test('eager Signal materializes SlotValue, never a bare Invalidate', () {
      expect(signalOps(7, _inline([1]), _inline([1])), const <DeltaOp>[],
          reason: 'equal_signal_is_silent');
      expect(signalOps(7, _inline([1]), _inline([2])),
          [DeltaOpSlotValue(7, _inline([2]))],
          reason: 'changed_signal_materializes_slot_value');
      for (final ops in [
        signalOps(7, _inline([1]), _inline([1])),
        signalOps(7, _inline([1]), _inline([2])),
      ]) {
        expect(ops.any((op) => op is DeltaOpInvalidate), isFalse,
            reason: 'signal_never_emits_bare_invalidate');
      }
    });

    // lean `batch_frontier_is_coalesced` /
    //      `batch_flush_advances_epoch_once` /
    //      `batch_flush_ops_are_frontier_invalidations`
    test('BatchFlush coalesces the frontier and advances the epoch once', () {
      final flush = BatchFlush(
        changedCells: const [1, 2],
        frontier: const [3, 4, 3, 5, 4],
      );
      // frontier is deduped, order-preserving (Nodup).
      expect(flush.frontier, [3, 4, 5]);
      // ops = frontier.map(invalidate).
      expect(
          flush.ops,
          [
            const DeltaOpInvalidate(3),
            const DeltaOpInvalidate(4),
            const DeltaOpInvalidate(5),
          ]);
      // one delta, epoch advances once.
      final delta = flush.toDelta(10);
      expect(delta.epoch, 11);
      expect(delta.baseEpoch, 10);
      expect(delta.ops, flush.ops);
    });
  });

  group('permissions', () {
    test('gate read/write/effect independently', () {
      final permissions = PeerPermissions();
      expect(permissions.allow(1, RemoteOp.read(10)), isTrue);
      expect(permissions.allow(1, RemoteOp.read(10)), isFalse); // idempotent
      expect(permissions.isAllowed(1, RemoteOp.read(10)), isTrue);
      expect(permissions.isAllowed(1, RemoteOp.write(10)), isFalse);
      expect(permissions.canRead(1, 10), isTrue);
    });

    test('check throws PermissionDenied on a missing grant', () {
      final permissions = PeerPermissions();
      expect(() => permissions.check(2, RemoteOp.read(1)),
          throwsA(isA<PermissionDenied>()));
    });

    test('revoke and revokePeer prune the graph', () {
      final permissions = PeerPermissions();
      permissions.allow(1, RemoteOp.read(7));
      expect(permissions.revoke(1, RemoteOp.read(7)), isTrue);
      expect(permissions.canRead(1, 7), isFalse);
      expect(permissions.peerCount, 0);

      permissions.allow(2, RemoteOp.read(8));
      expect(permissions.revokePeer(2), isTrue);
      expect(permissions.peerCount, 0);
    });

    test('allowMany does not leak a sentinel node id', () {
      final permissions = PeerPermissions();
      permissions.allowMany(1, OpKind.read, [5, 6]);
      // The internal sentinel used to materialize the peer map must not be a
      // real grant: only 5 and 6 are readable.
      expect(permissions.canRead(1, 5), isTrue);
      expect(permissions.canRead(1, 6), isTrue);
      expect(permissions.canRead(1, -1), isFalse);
    });
  });

  group('conformance fixtures', () {
    const fixtures = [
      'snapshot_minimal.json',
      'snapshot_multi_node.json',
      'snapshot_shared_blob.json',
      'delta_sequential.json',
      'delta_non_sequential.json',
      'delta_shared_blob.json',
    ];

    for (final name in fixtures) {
      test('round-trips and satisfies assertions: $name', () {
        final fixture = _loadFixture(name);
        final message = IpcMessage.fromWire(fixture['wire']);
        assertFixtureAssertions(message, fixture);
        assertRoundTripJson(message, fixture);
      });
    }

    test('assertFixtureAssertions catches wire/assertions drift', () {
      final fixture = _loadFixture('snapshot_minimal.json');
      final message = IpcMessage.fromWire(fixture['wire']);

      // Correct metadata passes.
      assertFixtureAssertions(message, fixture);

      // A drifted field fails loudly.
      final drifted = Map<String, Object?>.from(fixture);
      final driftedAssertions =
          Map<String, Object?>.from(fixture['assertions'] as Map);
      driftedAssertions['node_count'] =
          (driftedAssertions['node_count'] as int) + 999;
      drifted['assertions'] = driftedAssertions;
      expect(() => assertFixtureAssertions(message, drifted),
          throwsA(predicate((Object? e) =>
              e.toString().contains('snapshot assertion "node_count"'))));

      // An unknown assertion key is rejected (new metadata can't be ignored).
      final unknown = Map<String, Object?>.from(fixture);
      final unknownAssertions =
          Map<String, Object?>.from(fixture['assertions'] as Map);
      unknownAssertions['unexpected_field'] = true;
      unknown['assertions'] = unknownAssertions;
      expect(() => assertFixtureAssertions(message, unknown),
          throwsA(isA<StateError>()));
    });
  });
}
