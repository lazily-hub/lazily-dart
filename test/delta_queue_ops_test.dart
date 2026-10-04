import 'package:lazily/ipc.dart';
import 'package:test/test.dart';

/// QueueCell op-log `DeltaOp` variants (`#lzdeltaqueueops`, protocol.md §
/// QueueCell op-log delta form): `QueuePush` / `QueuePop` / `QueueClose` are
/// ordinary `Delta` ops in every codec, permission-filtered by node like
/// `CellSet` / `Invalidate`, and `QueuePush`'s payload spills like `CellSet`'s.

final _queueOps = <DeltaOp>[
  DeltaOp.queuePush(6, [97]),
  DeltaOp.queuePop(6),
  DeltaOp.queueClose(6),
];

IpcMessage _deltaOf(List<DeltaOp> ops) =>
    IpcMessage.ofDelta(Delta.next(4, ops));

void main() {
  group('codecs', () {
    test('each queue op has the spec wire shape', () {
      expect(_queueOps.map((op) => op.toWire()).toList(), [
        {
          'QueuePush': {
            'node': 6,
            'payload': {
              'Inline': [97]
            }
          }
        },
        {
          'QueuePop': {'node': 6}
        },
        {
          'QueueClose': {'node': 6}
        },
      ]);
    });

    for (final op in _queueOps) {
      final tag = (op.toWire() as Map).keys.single;
      test('$tag round-trips through json', () {
        final msg = _deltaOf([op]);
        final decoded = IpcMessage.decodeJson(msg.encodeJson());
        expect(decoded, msg);
        expect((decoded as IpcMessageDelta).value.ops.single, op);
      });
      test('$tag round-trips through msgpack', () {
        final msg = _deltaOf([op]);
        final decoded = decodeMsgpack(encodeMsgpack(msg));
        expect(decoded, msg);
        expect((decoded as IpcMessageDelta).value.ops.single.runtimeType,
            op.runtimeType);
      });
    }

    test('a peer-authored json delta carrying all three decodes', () {
      const frame = '{"Delta":{"base_epoch":1,"epoch":2,"ops":['
          '{"QueuePush":{"node":6,"payload":{"Inline":[97]}}},'
          '{"QueuePop":{"node":6}},{"QueueClose":{"node":6}}]}}';
      final delta = (IpcMessage.decodeJson(frame) as IpcMessageDelta).value;
      expect(delta.ops, _queueOps);
    });

    test('QueuePush carries a SharedBlob payload descriptor', () {
      final backend = InProcessBackend();
      final desc = backend.write(List<int>.filled(100, 1));
      final op = DeltaOpQueuePush(6, IpcValue.sharedBlob(desc));
      final msg = _deltaOf([op]);
      expect(IpcMessage.decodeJson(msg.encodeJson()), msg);
      expect(decodeMsgpack(encodeMsgpack(msg)), msg);
    });
  });

  group('strict decode', () {
    for (final tag in ['QueuePush', 'QueuePop', 'QueueClose']) {
      test('$tag without `node` is rejected', () {
        final body = tag == 'QueuePush'
            ? <String, Object?>{
                'payload': {
                  'Inline': [97]
                }
              }
            : <String, Object?>{};
        expect(() => DeltaOp.fromWire({tag: body}), throwsFormatException);
      });
      test('$tag with a non-object body is rejected', () {
        expect(() => DeltaOp.fromWire({tag: 6}), throwsFormatException);
      });
    }
    test('QueuePush without a valid payload is rejected', () {
      expect(
          () => DeltaOp.fromWire({
                'QueuePush': {'node': 6}
              }),
          throwsFormatException);
    });
    test('an unknown op tag is still rejected', () {
      expect(
          () => DeltaOp.fromWire({
                'QueuePeek': {'node': 6}
              }),
          throwsFormatException);
    });
  });

  group('permissions', () {
    test('queue ops are filtered by a node-scoped read check', () {
      final permissions = PeerPermissions()..allowMany(1, OpKind.read, [6]);
      final delta = Delta.next(4, [
        DeltaOp.queuePush(6, [1]),
        DeltaOp.queuePush(7, [2]),
        DeltaOp.queuePop(6),
        DeltaOp.queuePop(7),
        DeltaOp.queueClose(6),
        DeltaOp.queueClose(7),
      ]);
      final filtered = delta.filterReadable(permissions, 1);
      expect(filtered.ops, _queueOpsFor(6));
      expect(delta.filterReadable(permissions, 2).ops, isEmpty);
    });
  });

  group('blob spill / resolve', () {
    test('an over-threshold QueuePush payload spills and resolves', () {
      final backend = InProcessBackend();
      final big = List<int>.filled(500, 0x5A);
      final msg = _deltaOf([
        DeltaOp.queuePush(6, big),
        DeltaOp.queuePop(6),
        DeltaOp.queueClose(6),
      ]);
      final result = spillMessage(msg, backend, 64);
      expect(result.spilledBytes, big.length);
      final ops = (result.message as IpcMessageDelta).value.ops;
      final push = ops[0] as DeltaOpQueuePush;
      expect(push.node, 6);
      expect(push.payload, isA<IpcValueSharedBlob>());
      final view = (BlobRouter()..register(backend)).resolve(push.payload);
      expect(view?.toList(), big);
      expect(ops.sublist(1), [DeltaOp.queuePop(6), DeltaOp.queueClose(6)]);
      // The spilled frame still round-trips on the wire.
      expect(
          IpcMessage.decodeJson(result.message.encodeJson()), result.message);
    });

    test('a sub-threshold QueuePush payload stays inline', () {
      final backend = InProcessBackend();
      final result = spillMessage(
          _deltaOf([
            DeltaOp.queuePush(6, [1, 2])
          ]),
          backend,
          64);
      expect(result.spilledBytes, 0);
      final push = (result.message as IpcMessageDelta).value.ops.single
          as DeltaOpQueuePush;
      expect(push.payload, IpcValue.inline([1, 2]));
    });
  });
}

List<DeltaOp> _queueOpsFor(NodeId node) => [
      DeltaOp.queuePush(node, [1]),
      DeltaOp.queuePop(node),
      DeltaOp.queueClose(node),
    ];
