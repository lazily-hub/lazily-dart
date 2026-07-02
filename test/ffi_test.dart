import 'dart:convert';

import 'package:lazily/ffi.dart';
import 'package:lazily/ipc.dart';
import 'package:test/test.dart';

/// FFI boundary conformance (protocol.md § FFI Boundary, schemas/ffi.json).
/// Mirrors `lazily-rs/tests/ffi.rs`: validate / classify / clone through the
/// channel, with the `CrdtSync = 3` discriminant normative.

void main() {
  group('LazilyFfiStatus', () {
    test('codes are stable and exhaustive', () {
      expect(LazilyFfiStatus.ok.code, 0);
      expect(LazilyFfiStatus.empty.code, 1);
      expect(LazilyFfiStatus.nullPointer.code, 2);
      expect(LazilyFfiStatus.invalidMessage.code, 3);
      expect(LazilyFfiStatus.encodeFailed.code, 4);
      expect(LazilyFfiStatus.panic.code, 5);
      for (var i = 0; i <= 5; i++) {
        expect(LazilyFfiStatus.fromCode(i), isNotNull);
      }
    });
  });

  group('LazilyFfiMessageKind', () {
    test('discriminant includes CrdtSync = 3 (normative)', () {
      expect(LazilyFfiMessageKind.unknown.code, 0);
      expect(LazilyFfiMessageKind.snapshot.code, 1);
      expect(LazilyFfiMessageKind.delta.code, 2);
      expect(LazilyFfiMessageKind.crdtSync.code, 3);
    });

    test('out-of-range decodes to unknown', () {
      expect(LazilyFfiMessageKind.fromCode(99), LazilyFfiMessageKind.unknown);
    });
  });

  group('validate', () {
    test('ok for a well-formed Snapshot frame', () {
      final message = IpcMessage.ofSnapshot(const Snapshot(epoch: 1));
      final status = lazilyFfiValidateJson(LazilyFfiBytes(message.encodeJson()));
      expect(status, LazilyFfiStatus.ok);
    });

    test('invalidMessage for malformed bytes', () {
      final status = lazilyFfiValidateJson(
          LazilyFfiBytes(utf8.encode('not json at all')));
      expect(status, LazilyFfiStatus.invalidMessage);
    });
  });

  group('kindJson (classify by decoding)', () {
    test('classifies a Snapshot frame', () {
      final message = IpcMessage.ofSnapshot(const Snapshot(epoch: 7));
      final c = lazilyFfiKindJson(LazilyFfiBytes(message.encodeJson()));
      expect(c.isOk, isTrue);
      expect(c.kind, LazilyFfiMessageKind.snapshot);
    });

    test('classifies a Delta frame', () {
      final message = IpcMessage.ofDelta(const Delta(baseEpoch: 0, epoch: 1));
      final c = lazilyFfiKindJson(LazilyFfiBytes(message.encodeJson()));
      expect(c.kind, LazilyFfiMessageKind.delta);
    });

    test('classifies a CrdtSync frame (CrdtSync = 3)', () {
      final message = IpcMessage.ofCrdtSync(CrdtSync(
        frontier: [
          StampFrontierEntry(
              1, WireStamp(wallTime: 9, logical: 0, peer: 1)),
        ],
        ops: [
          CrdtOp.newOp(
              1, WireStamp(wallTime: 9, logical: 0, peer: 1), [1, 2]),
        ],
      ));
      final c = lazilyFfiKindJson(LazilyFfiBytes(message.encodeJson()));
      expect(c.isOk, isTrue);
      expect(c.kind, LazilyFfiMessageKind.crdtSync);
    });
  });

  group('cloneJson (decode + re-encode canonical)', () {
    test('round-trips a Snapshot byte-identically', () {
      final message = IpcMessage.ofSnapshot(const Snapshot(epoch: 3));
      final result = lazilyFfiCloneJson(LazilyFfiBytes(message.encodeJson()));
      expect(result.status, LazilyFfiStatus.ok);
      expect(result.output, isNotNull);
      final decoded = IpcMessage.decodeJson(result.output!.bytes);
      expect(decoded, message);
    });

    test('round-trips a CrdtSync frame', () {
      final message = IpcMessage.ofCrdtSync(CrdtSync(
        frontier: [
          StampFrontierEntry(
              2, WireStamp(wallTime: 5, logical: 1, peer: 2)),
        ],
        ops: [
          CrdtOp.keyed(7, NodeKey('docs/x'),
              WireStamp(wallTime: 5, logical: 1, peer: 2), [9]),
        ],
      ));
      final result = lazilyFfiCloneJson(LazilyFfiBytes(message.encodeJson()));
      expect(result.status, LazilyFfiStatus.ok);
      expect(IpcMessage.decodeJson(result.output!.bytes), message);
    });

    test('invalidMessage for a malformed frame', () {
      final result = lazilyFfiCloneJson(
          LazilyFfiBytes(utf8.encode('{ nope }')));
      expect(result.status, LazilyFfiStatus.invalidMessage);
      expect(result.output, isNull);
    });
  });

  group('LazilyFfiChannel', () {
    test('send + recv round-trips a message', () {
      final channel = LazilyFfiChannel();
      expect(channel.isEmpty, isTrue);
      final message = IpcMessage.ofDelta(const Delta(baseEpoch: 4, epoch: 5));
      expect(channel.send(message), LazilyFfiStatus.ok);
      expect(channel.isEmpty, isFalse);
      final recv = channel.recv();
      expect(recv, message);
      expect(channel.isEmpty, isTrue);
      expect(channel.recv(), isNull, reason: 'empty → null');
    });

    test('sendJsonFrame rejects malformed bytes', () {
      final channel = LazilyFfiChannel();
      final status = channel.sendJsonFrame(
          LazilyFfiBytes(utf8.encode('garbage')));
      expect(status, LazilyFfiStatus.invalidMessage);
      expect(channel.isEmpty, isTrue);
    });

    test('sendJsonFrame canonicalizes on the way in', () {
      final channel = LazilyFfiChannel();
      // Build bytes from a message, then pass them as a raw frame: the channel
      // decodes + re-encodes canonical JSON.
      final message = IpcMessage.ofSnapshot(const Snapshot(epoch: 1));
      final status = channel.sendJsonFrame(LazilyFfiBytes(message.encodeJson()));
      expect(status, LazilyFfiStatus.ok);
      expect(channel.recv(), message);
    });
  });
}
