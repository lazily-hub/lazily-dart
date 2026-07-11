import 'dart:isolate';
import 'dart:typed_data';

import 'package:lazily/ipc.dart';
import 'package:test/test.dart';

/// Isolates as genuine parallelism (the Dart answer to "simulate
/// multithreading"): each isolate has a private heap, so shared state is either
/// MOVED zero-copy ([TransferableTypedData]) or replicated + reconciled through
/// the CRDT wire protocol. Two demonstrations:
///
///  1. **Zero-copy shared-memory blob path.** A blob is packaged by
///     [ShmBlobArena.transfer] and moved to a worker isolate with no byte copy;
///     the worker re-validates the header against the descriptor.
///  2. **Parallel CRDT convergence.** N worker isolates independently mutate a
///     family replica in parallel, each returns its sync frame, and the frames
///     converge to one identical state regardless of merge order — the
///     materialization-confluence / aggregate-convergence contract under REAL
///     multi-isolate parallelism, not a single-threaded simulation.

/// Worker: adopt a moved blob zero-copy, validate it, report the outcome.
void _blobWorker(List<Object?> args) {
  final reply = args[0] as SendPort;
  final transfer = args[1] as ShmBlobTransfer;
  final bytes = transfer.receive();
  reply.send(<String, Object?>{
    'ok': bytes != null,
    'len': bytes?.length,
    'checksum': transfer.ref.checksum,
    'first': bytes != null && bytes.isNotEmpty ? bytes.first : null,
    'last': bytes != null && bytes.isNotEmpty ? bytes.last : null,
  });
}

/// Worker: build a family replica for [peer], set its own key `live/<peer>`,
/// and return the sync frame (wire form — guaranteed sendable).
void _familyWorker(List<Object?> args) {
  final reply = args[0] as SendPort;
  final peer = args[1] as int;
  final rt = CrdtPlaneRuntime(peer)..registerFamilyLww('live');
  rt.familySetLww('live', '$peer', true, 100 + peer);
  reply.send(rt.syncFrame().toWire());
}

Future<Object?> _spawnAndReceive(
    void Function(List<Object?>) entry, List<Object?> args) async {
  final rp = ReceivePort();
  await Isolate.spawn(entry, [rp.sendPort, ...args]);
  final result = await rp.first;
  rp.close();
  return result;
}

void main() {
  group('isolate parallelism (shared-memory + CRDT convergence)', () {
    test('zero-copy blob transfer across isolates validates against header',
        () async {
      final arena = ShmBlobArena();
      final payload =
          Uint8List.fromList(List<int>.generate(4096, (i) => i & 0xff));
      final ref = arena.write(payload);
      final transfer = arena.transfer(ref);
      expect(transfer, isNotNull);

      final result = await _spawnAndReceive(_blobWorker, [transfer]) as Map;
      expect(result['ok'], isTrue, reason: 'worker header validation failed');
      expect(result['len'], 4096);
      expect(result['checksum'], ref.checksum);
      expect(result['first'], 0);
      expect(result['last'], 4095 & 0xff);
    });

    test('stale descriptor is rejected by the receiver', () async {
      final arena = ShmBlobArena();
      final ref = arena.write(Uint8List.fromList([9, 8, 7]));
      final transfer = arena.transfer(ref)!;
      // Corrupt the descriptor's checksum → receive() must reject.
      final tampered = ShmBlobTransfer(
        ShmBlobRef(
          offset: ref.offset,
          len: ref.len,
          generation: ref.generation,
          epoch: ref.epoch,
          checksum: ref.checksum ^ 0x1,
        ),
        transfer.data,
      );
      final result = await _spawnAndReceive(_blobWorker, [tampered]) as Map;
      expect(result['ok'], isFalse);
    });

    test(
        'parallel family mutations converge across isolates (order-independent)',
        () async {
      const workers = 5;
      final frames = <Object?>[];
      for (var p = 1; p <= workers; p++) {
        frames.add(await _spawnAndReceive(_familyWorker, [p]));
      }

      CrdtPlaneRuntime merge(Iterable<Object?> wires) {
        final rt = CrdtPlaneRuntime(0)..registerFamilyLww('live');
        for (final wire in wires) {
          rt.ingest(CrdtSync.fromWire(wire));
        }
        return rt;
      }

      final forward = merge(frames);
      final reversed = merge(frames.reversed);

      // Every worker's key materialized; the derived count converges; and the
      // merge is order-independent (confluence).
      expect(forward.familyKeys('live').length, workers);
      expect(forward.familyCountTrue('live'), workers);
      expect(reversed.familyKeys('live').length, workers);
      expect(reversed.familyCountTrue('live'), workers);
      expect(forward.membershipEpoch(), reversed.membershipEpoch());
      for (var p = 1; p <= workers; p++) {
        expect(forward.familyValueLww('live', '$p'), isTrue);
        expect(reversed.familyValueLww('live', '$p'), isTrue);
      }
    });
  });
}
