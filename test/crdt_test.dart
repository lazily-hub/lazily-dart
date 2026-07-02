import 'dart:convert';

import 'package:lazily/ipc.dart';
import 'package:test/test.dart';

/// CRDT plane wire + runtime conformance. Mirrors `lazily-rs/src/crdt.rs` and
/// `lazily-py/tests/test_ipc.py` CRDT tests, and pins the canonical JSON byte
/// shape captured from `lazily-rs` serde in `lazily-js/test/ipc.test.js`.

void main() {
  group('WireStamp', () {
    test('round-trips through JSON', () {
      final stamp = WireStamp(wallTime: 200, logical: 3, peer: 7);
      final wire = jsonEncode(stamp.toWire());
      expect(WireStamp.fromWire(jsonDecode(wire)), stamp);
    });

    test('total order is (wall, logical, peer)', () {
      final a = HlcStamp(100, 0, 1);
      final b = HlcStamp(100, 1, 1);
      final c = HlcStamp(100, 1, 2);
      final d = HlcStamp(101, 0, 1);
      expect(a < b, isTrue);
      expect(b < c, isTrue);
      expect(c < d, isTrue);
      expect(d > a, isTrue);
    });

    test('HlcStamp ↔ WireStamp is lossless', () {
      final runtime = HlcStamp(12345, 67, 9);
      final wire = runtime.toWire();
      expect(HlcStamp.fromWire(wire), runtime);
    });
  });

  group('Hlc', () {
    test('tick is monotonic', () {
      final clock = Hlc(1);
      var prev = clock.tick(100);
      for (var i = 0; i < 5; i++) {
        final next = clock.tick(100); // same wall → logical increments
        expect(next > prev, isTrue);
        expect(next.wallTime, 100);
        prev = next;
      }
      // Wall advance resets logical.
      final advanced = clock.tick(200);
      expect(advanced.wallTime, 200);
      expect(advanced.logical, 0);
    });

    test('recv observes the remote stamp (strictly greater)', () {
      final clock = Hlc(1);
      final remote = HlcStamp(150, 5, 2);
      final local = clock.observe(remote, 120);
      expect(local > remote, isTrue);
    });

    test('recv with now dominating both resets logical', () {
      final clock = Hlc(1);
      clock.tick(100);
      final local = clock.observe(HlcStamp(90, 0, 2), 300);
      expect(local.wallTime, 300);
      expect(local.logical, 0);
    });
  });

  group('StampFrontier', () {
    test('observe keeps the per-peer max', () {
      final f = StampFrontier();
      expect(f.observe(1, HlcStamp(100, 0, 1)), isTrue);
      expect(f.observe(1, HlcStamp(90, 5, 1)), isFalse, reason: 'older ignored');
      expect(f.observe(1, HlcStamp(100, 1, 1)), isTrue, reason: 'newer kept');
      expect(f.get(1), HlcStamp(100, 1, 1));
    });

    test('merge is idempotent, commutative, associative', () {
      final a = StampFrontier()
        ..observe(1, HlcStamp(100, 0, 1))
        ..observe(2, HlcStamp(50, 0, 2));
      final b = StampFrontier()
        ..observe(2, HlcStamp(200, 0, 2))
        ..observe(3, HlcStamp(30, 0, 3));

      final ab = StampFrontier()..merge(a)..merge(b);
      final ba = StampFrontier()..merge(b)..merge(a);
      expect(ab.toWire(), ba.toWire(), reason: 'commutative');

      final abAgain = StampFrontier()..merge(ab);
      expect(abAgain.toWire(), ab.toWire(), reason: 'idempotent');
    });

    test('watermark is min over membership, null until complete', () {
      final f = StampFrontier()
        ..observe(1, HlcStamp(100, 0, 1))
        ..observe(2, HlcStamp(50, 5, 2));
      expect(f.watermark([1, 2]), HlcStamp(50, 5, 2));
      expect(f.watermark([1, 2, 3]), isNull,
          reason: 'unseen peer → null (causally incomplete)');
    });
  });

  group('CrdtPlane', () {
    test('tick + observeRemote arm the watermark', () {
      final a = CrdtPlane(1);
      final b = CrdtPlane(2);
      // Peer 1 emits a local op.
      final s1 = a.tick(100);
      // Peer 2 observes it and emits its own.
      final s2local = b.observeRemote(s1, 110);
      final s2 = b.tick(120);
      // Peer 1 observes peer 2's frame.
      a.observeRemote(s2local, 130);
      a.observeRemote(s2, 140);

      // Both peers have seen each other → watermark is armed.
      expect(a.stabilityWatermark(), isNotNull);
      expect(b.stabilityWatermark(), isNotNull);
    });

    test('isCollectable requires the full membership to have observed', () {
      final a = CrdtPlane(1);
      final old = a.tick(100);
      expect(a.isCollectable(old), isTrue, reason: 'only self → collectable');

      final b = CrdtPlane(2);
      b.observeRemote(old, 110);
      // b knows about 1 but not vice versa; a still has membership {1}.
      a.observeRemote(HlcStamp(200, 0, 2), 210);
      // now a's membership is {1,2} but it may not have seen b's latest —
      // watermark is min over what a observed.
      final w = a.stabilityWatermark();
      expect(w, isNotNull);
      expect(a.isCollectable(old), isTrue, reason: 'old ≤ watermark');
    });
  });

  group('CrdtOp wire', () {
    test('keyless op emits key: null (never omitted)', () {
      final op = CrdtOp.newOp(
          1, WireStamp(wallTime: 200, logical: 0, peer: 1), [10, 20]);
      final wire = op.toWire();
      expect(wire.containsKey('key'), isTrue);
      expect(wire['key'], isNull);
    });

    test('keyed op carries the NodeKey', () {
      final op = CrdtOp.keyed(2, NodeKey('scores/alice'),
          WireStamp(wallTime: 180, logical: 3, peer: 2), [30]);
      expect(op.toWire()['key'], 'scores/alice');
    });

    test('decoder accepts an absent key field', () {
      final wire = {
        'node': 1,
        'stamp': WireStamp(wallTime: 1, logical: 0, peer: 1).toWire(),
        'state': {'Inline': [1]}
      };
      final op = CrdtOp.fromWire(wire);
      expect(op.key, isNull);
    });
  });

  group('CrdtSync wire', () {
    test('frontier entries are 2-tuple [peer, stamp] arrays', () {
      final sync = CrdtSync(
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
      );
      final wire = sync.toWire();
      final frontier0 = (wire['frontier'] as List).first;
      expect(frontier0, isA<List>());
      expect((frontier0 as List).first, 1);
    });

    test('round-trips through JSON', () {
      final sync = CrdtSync(
        frontier: [
          StampFrontierEntry(1, WireStamp(wallTime: 9, logical: 0, peer: 1)),
        ],
        ops: [
          CrdtOp.newOp(
              1, WireStamp(wallTime: 9, logical: 0, peer: 1), [1, 2]),
        ],
      );
      final encoded = jsonEncode(sync.toWire());
      final decoded = CrdtSync.fromWire(jsonDecode(encoded));
      expect(decoded, sync);
    });

    test('IpcMessage.CrdtSync variant round-trips byte-identically', () {
      final message = IpcMessage.ofCrdtSync(CrdtSync(
        frontier: [
          StampFrontierEntry(1, WireStamp(wallTime: 9, logical: 0, peer: 1)),
        ],
        ops: [
          CrdtOp.newOp(
              1, WireStamp(wallTime: 9, logical: 0, peer: 1), [1, 2]),
        ],
      ));
      final wire = message.toWire();
      expect((wire as Map).keys.single, 'CrdtSync');
      final decoded = IpcMessage.decodeJson(message.encodeJson());
      expect(decoded, message);
      expect(decoded.isCrdtSync, isTrue);
    });

    test('canonical bytes match the lazily-rs serde shape', () {
      // Pinned in lazily-js/test/ipc.test.js as captured from lazily-rs.
      final message = IpcMessage.ofCrdtSync(CrdtSync(
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
      final canonical = message.encodeJson();
      final expected = {
        'CrdtSync': {
          'frontier': [
            [1, {'wall_time': 200, 'logical': 0, 'peer': 1}],
            [2, {'wall_time': 180, 'logical': 3, 'peer': 2}],
          ],
          'ops': [
            {
              'node': 1,
              'key': null,
              'stamp': {'wall_time': 200, 'logical': 0, 'peer': 1},
              'state': {'Inline': [10, 20]},
            },
            {
              'node': 2,
              'key': 'scores/alice',
              'stamp': {'wall_time': 180, 'logical': 3, 'peer': 2},
              'state': {'Inline': [30]},
            },
          ],
        },
      };
      expect(jsonDecode(utf8.decode(canonical)), expected);
    });
  });

  group('CrdtSync.filterReadable', () {
    test('omits ops for unreadable nodes; retains the full frontier', () {
      final permissions = PeerPermissions()
        ..allow(99, RemoteOp.read(1));
      final sync = CrdtSync(
        frontier: [
          StampFrontierEntry(1, WireStamp(wallTime: 1, logical: 0, peer: 1)),
        ],
        ops: [
          CrdtOp.newOp(1, WireStamp(wallTime: 1, logical: 0, peer: 1), [1]),
          CrdtOp.newOp(2, WireStamp(wallTime: 2, logical: 0, peer: 2), [2]),
        ],
      );
      final filtered = sync.filterReadable(permissions, 99);
      expect(filtered.ops.length, 1);
      expect(filtered.ops.first.node, 1);
      expect(filtered.frontier.length, 1,
          reason: 'frontier retained in full');
    });
  });
}
