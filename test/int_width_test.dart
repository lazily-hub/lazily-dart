import 'dart:convert';
import 'dart:typed_data';

import 'package:lazily/ipc.dart';
import 'package:test/test.dart';

/// The IPC wire's integer range (`#lzdartintwidth`).
///
/// protocol.md § NodeId / PeerId makes `NodeId`/`PeerId` `u64` "serialized as
/// bare JSON numbers", so a conforming peer may send a value above 2^53. On the
/// Dart VM that is lossless and must keep working. Compiled to JavaScript `int`
/// is a double, `jsonDecode` rounds 9007199254740993 to 9007199254740992
/// without error, and a corrupted node id that decodes cleanly is undetectable
/// downstream — so there the frame has to be refused.
///
/// The guard is therefore platform-based, not magnitude-based: a magnitude
/// guard either corrupts on web or rejects frames the VM handles correctly.
///
/// These tests run on the VM, where the guarded branch is compiled out. That is
/// why the policy is a parameterized predicate: the RULE is executable here
/// even though the platform binding is not. End-to-end proof on a JavaScript
/// target is currently impossible for a reason unrelated to this guard — the
/// IPC surface does not compile to JS at all (see `#lzdartwebcompile`).
void main() {
  group('exact-integer-range policy', () {
    test('on a double-int runtime, the boundary is 2^53 - 1', () {
      expect(exceedsExactIntRange(maxExactInt, intsAreDoubles: true), isFalse);
      expect(
        exceedsExactIntRange(maxExactInt + 1, intsAreDoubles: true),
        isTrue,
      );
      expect(exceedsExactIntRange(0, intsAreDoubles: true), isFalse);
    });

    test('on a 64-bit-int runtime, nothing is out of range', () {
      // The half that keeps the VM lossless. A magnitude-only guard would fail
      // this and quietly remove a capability that works today.
      expect(
        exceedsExactIntRange(maxExactInt + 1, intsAreDoubles: false),
        isFalse,
      );
      expect(
        exceedsExactIntRange(0x7FFFFFFFFFFFFFF, intsAreDoubles: false),
        isFalse,
      );
    });

    test('this runtime is the VM, so decoding stays lossless', () {
      expect(intsAreDoubles, isFalse,
          reason: 'the VM test suite must not be running as a JS target');

      const big = 9007199254740993; // 2^53 + 1
      final frame = '{"ResyncRequest":{"from_epoch":$big}}';
      final decoded = IpcMessage.decodeJson(frame);
      expect(utf8.decode(decoded.encodeJson()), frame,
          reason: 'the VM represents this exactly and must not refuse it');

      // Both codecs agree on the VM too.
      expect(utf8.decode(decodeMsgpack(encodeMsgpack(decoded)).encodeJson()),
          frame);
    });
  });

  group('msgpack wide integer tags', () {
    // msgpack permits non-minimal encodings, so a peer may carry a small value
    // in a uint64 tag. `ByteData.getUint64` throws UnsupportedError on a JS
    // target for EVERY such frame, which would have refused representable
    // values for the wrong reason; the decoder reads the halves instead.
    Uint8List resyncFrame(List<int> tail) => Uint8List.fromList(<int>[
          0x81,
          0xad,
          ...'ResyncRequest'.codeUnits,
          0x81,
          0xaa,
          ...'from_epoch'.codeUnits,
          ...tail,
        ]);

    test('a small value in a wide uint64 tag decodes', () {
      final message = decodeMsgpack(
        resyncFrame(<int>[0xcf, 0, 0, 0, 0, 0, 0, 0, 7]),
      );
      expect(utf8.decode(message.encodeJson()),
          '{"ResyncRequest":{"from_epoch":7}}');
    });

    test('a value above 2^32 ENCODES into a wide uint64 tag', () {
      // The half `#lzdartintwidth` left open: it taught the DECODER to read a
      // wide tag as halves and left the encoder on `setUint64`, which dart2js
      // does not implement — so a browser peer could read a wide frame and then
      // throw producing its own reply. The tag and the payload bytes are pinned
      // here, on the VM, against the accessor the encoder no longer calls
      // (`#lzdartwebcompile`).
      const wide = 1099511627776; // 2^40.
      final packed = encodeMsgpack(
        IpcMessage.decodeJson('{"ResyncRequest":{"from_epoch":$wide}}'),
      );
      final tail = packed.sublist(packed.length - 9);
      expect(tail[0], 0xcf, reason: 'a value above 2^32 needs the uint64 tag');

      final native = ByteData(8)..setUint64(0, wide);
      expect(tail.sublist(1), native.buffer.asUint8List());

      expect(
        utf8.decode(decodeMsgpack(packed).encodeJson()),
        '{"ResyncRequest":{"from_epoch":$wide}}',
      );
    });

    test('a value above 2^53 in a wide uint64 tag decodes on the VM', () {
      // 0x0020000000000001 == 2^53 + 1.
      final message = decodeMsgpack(
        resyncFrame(<int>[0xcf, 0x00, 0x20, 0, 0, 0, 0, 0, 0x01]),
      );
      expect(
        utf8.decode(message.encodeJson()),
        '{"ResyncRequest":{"from_epoch":9007199254740993}}',
      );
    });
  });
}
