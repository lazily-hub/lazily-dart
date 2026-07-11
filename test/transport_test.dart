import 'dart:convert';
import 'dart:io';

import 'package:lazily/ipc.dart';
import 'package:test/test.dart';

/// Cross-process zero-copy transport (`#lzzcpy`) — pluggable blob backends.
/// Mirrors the Rust tests in `lazily-rs/src/transport.rs` and pins the
/// `lazily-formal/LazilyFormal/ZeroCopyTransport.lean` laws (resolve_write,
/// resolve_wrong_backend, resolve_stale_generation, resolve_corrupt_checksum,
/// transport_roundtrip). Fixture: lazily-spec/conformance/delta_zero_copy_arrow.json.

bool _bytesEq(BlobView view, List<int> expected) {
  if (view == null) return false;
  if (view.length != expected.length) return false;
  for (var i = 0; i < view.length; i++) {
    if (view[i] != expected[i]) return false;
  }
  return true;
}

void main() {
  group('BlobBackend resolve_write identity', () {
    test('InProcessBackend mints and resolves zero-copy', () {
      final backend = InProcessBackend();
      final payload = [1, 2, 3, 4, 5, 6, 7, 8];
      final desc = backend.write(payload);
      expect(desc.backend, BlobBackendKind.inProcess);
      expect(_bytesEq(backend.readView(desc), payload), isTrue);
    });

    test('ArrowBackend mints and resolves zero-copy', () {
      final backend = ArrowBackend();
      final payload = [10, 20, 30, 40];
      final desc = backend.write(payload);
      expect(desc.backend, BlobBackendKind.arrow);
      expect(_bytesEq(backend.readView(desc), payload), isTrue);
    });

    test('an empty payload resolves to a zero-length view (not null)', () {
      final backend = InProcessBackend();
      final desc = backend.write(const <int>[]);
      final view = backend.readView(desc);
      expect(view, isNotNull);
      expect(view!.length, 0);
    });
  });

  group('backend-agnostic laws', () {
    test('backend isolation (resolve_wrong_backend)', () {
      final inproc = InProcessBackend();
      final desc = inproc.write([9, 9, 9]);

      // No backend registered → does not resolve.
      final empty = BlobRouter();
      expect(empty.readView(desc), isNull);

      // Registered in_process backend resolves it.
      final router = BlobRouter()..register(inproc);
      expect(router.readView(desc), isNotNull);

      // A shm-kind descriptor with no shm backend registered → null.
      final shmDesc = desc.withBackend(BlobBackendKind.shm);
      expect(router.readView(shmDesc), isNull);
    });

    test('ABA generation safety (resolve_stale_generation)', () {
      final backend = InProcessBackend();
      final desc = backend.write([1, 2, 3]);
      final stale = ShmBlobRef(
        offset: desc.offset,
        len: desc.len,
        generation: desc.generation + 1,
        epoch: desc.epoch,
        checksum: desc.checksum,
        backend: desc.backend,
      );
      expect(backend.readView(stale), isNull);
    });

    test('checksum integrity (resolve_corrupt_checksum)', () {
      final backend = InProcessBackend();
      final desc = backend.write([4, 5, 6]);
      final corrupt = ShmBlobRef(
        offset: desc.offset,
        len: desc.len,
        generation: desc.generation,
        epoch: desc.epoch,
        checksum: desc.checksum + 1,
        backend: desc.backend,
      );
      expect(backend.readView(corrupt), isNull);
    });

    test('epoch advance invalidates prior descriptors', () {
      final backend = InProcessBackend();
      final desc = backend.write([7, 8]);
      expect(backend.readView(desc), isNotNull);
      backend.advanceEpoch();
      expect(backend.readView(desc), isNull);
    });

    test('multi-backend routing by descriptor kind', () {
      final inproc = InProcessBackend();
      final arrow = ArrowBackend();
      final inprocDesc = inproc.write('inproc bytes'.codeUnits);
      final arrowDesc = arrow.write('arrow bytes'.codeUnits);

      final router = BlobRouter()
        ..register(inproc)
        ..register(arrow);

      expect(_bytesEq(router.readView(inprocDesc), 'inproc bytes'.codeUnits),
          isTrue);
      expect(
          _bytesEq(router.readView(arrowDesc), 'arrow bytes'.codeUnits), isTrue);
    });

    test('Arrow IPC stream bytes resolve verbatim', () {
      final arrow = ArrowBackend();
      // A stand-in Arrow IPC stream ("ARROW1\0\0"); the backend resolves it to
      // the raw bytes a columnar consumer wraps.
      final ipcStream = [0x41, 0x52, 0x52, 0x4f, 0x57, 0x31, 0x00, 0x00];
      final desc = arrow.write(ipcStream);
      expect(desc.backend, BlobBackendKind.arrow);
      expect(_bytesEq(arrow.readView(desc), ipcStream), isTrue);
    });
  });

  group('spill / resolve policy', () {
    test('spill_resolve round trip (transport_roundtrip)', () {
      final backend = InProcessBackend();
      final big = List<int>.filled(500, 0x5A);
      final msg = IpcMessageDelta(
          Delta.next(1, [DeltaOp.slotValue(7, big)]));

      final result = spillMessage(msg, backend, 64);
      expect(result.spilledBytes, big.length);

      final router = BlobRouter()..register(backend);
      final delta = (result.message as IpcMessageDelta).value;
      final op = delta.ops[0] as DeltaOpSlotValue;
      expect(op.payload, isA<IpcValueSharedBlob>());
      expect(_bytesEq(router.resolve(op.payload), big), isTrue);
    });

    test('spill across Snapshot NodeState and CrdtSync op state', () {
      final backend = InProcessBackend();
      final big = List<int>.filled(300, 0xAB);

      final snap = IpcMessageSnapshot(Snapshot(
        epoch: 1,
        nodes: [NodeSnapshot.payload(1, 'blob', big)],
        roots: [1],
      ));
      expect(spillMessage(snap, backend, 64).spilledBytes, big.length);

      const stamp = WireStamp(wallTime: 1, logical: 0, peer: 1);
      final crdt = IpcMessageCrdtSync(CrdtSync(
        frontier: [const StampFrontierEntry(1, stamp)],
        ops: [CrdtOp.newOp(1, stamp, big)],
      ));
      expect(spillMessage(crdt, backend, 64).spilledBytes, big.length);
    });

    test('sub-threshold payloads stay inline', () {
      final backend = InProcessBackend();
      final msg =
          IpcMessageDelta(Delta.next(1, [DeltaOp.slotValue(1, [1, 2, 3])]));
      final result = spillMessage(msg, backend, 64);
      expect(result.spilledBytes, 0);
      final delta = (result.message as IpcMessageDelta).value;
      final op = delta.ops[0] as DeltaOpSlotValue;
      expect(op.payload, isA<IpcValueInline>());
    });

    test('resolveValue returns inline bytes directly', () {
      final backend = InProcessBackend();
      final inline = IpcValue.inline([1, 2, 3]);
      expect(_bytesEq(resolveValue(inline, backend), [1, 2, 3]), isTrue);
    });
  });

  group('wire descriptor backend discriminator', () {
    test('default shm backend is omitted from the wire (backward compat)', () {
      final ref = ShmBlobRef(
          offset: 40, len: 17, generation: 2, epoch: 9, checksum: 987654321);
      expect(ref.backend, BlobBackendKind.shm);
      expect(ref.toWire().containsKey('backend'), isFalse);
      // A backend-absent descriptor decodes to shm.
      expect(ShmBlobRef.fromWire(ref.toWire()).backend, BlobBackendKind.shm);
    });

    test('non-default backend round-trips on the wire', () {
      final ref = ShmBlobRef(
        offset: 40,
        len: 17,
        generation: 2,
        epoch: 9,
        checksum: 987654321,
        backend: BlobBackendKind.arrow,
      );
      final wire = ref.toWire();
      expect(wire['backend'], 'arrow');
      expect(ShmBlobRef.fromWire(wire), ref);
    });

    test('conformance delta_zero_copy_arrow.json round-trips', () {
      final path = [
        'test/conformance/delta_zero_copy_arrow.json',
        '../lazily-spec/conformance/delta_zero_copy_arrow.json',
      ].firstWhere((p) => File(p).existsSync(),
          orElse: () => throw StateError('fixture not found'));
      final fixture =
          jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
      final wire = fixture['wire'] as Map<String, dynamic>;
      final msg = IpcMessage.fromWire(wire);

      final assertions = fixture['assertions'] as Map<String, dynamic>;
      final delta = (msg as IpcMessageDelta).value;
      expect(delta.baseEpoch, assertions['base_epoch']);
      expect(delta.epoch, assertions['epoch']);
      expect(delta.ops.length, assertions['op_count']);
      final op = delta.ops[0] as DeltaOpSlotValue;
      final blob = (op.payload as IpcValueSharedBlob).blob;
      expect(blob.backend, BlobBackendKind.arrow);

      // Re-encode must reproduce the fixture wire exactly (backend='arrow'
      // preserved).
      expect(jsonDecode(jsonEncode(msg.toWire())), wire);
    });
  });
}
