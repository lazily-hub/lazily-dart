import 'dart:convert';
import 'dart:typed_data';

import 'package:lazily/ipc.dart';
import 'package:lazily/lazily.dart'
    show Block, BlockKey, blockKey, contentHash, contentHashHex;

/// Browser gate for the **IPC wire surface** (`#lzdartwebcompile`).
///
/// `tool/stdlib_browser_check.dart` has guarded the portable stdlib since
/// `#lzinteroppeerci`, and it passed the whole time the wire was unbuildable —
/// it imports `package:lazily/stdlib.dart` and nothing else, so it covered the
/// clock and the Future adapters and none of the protocol. This entry point
/// imports `package:lazily/ipc.dart`, which is the half the binding advertises a
/// browser story for.
///
/// Compiling is most of the value: until this landed, `dart compile js` against
/// the IPC surface failed outright on eight 64-bit integer literals dart2js
/// refuses, so no assertion about web behaviour could run at all. The
/// `#lzdartintwidth` guard was written against exactly that: its refuse-on-web
/// branch is compiled out on the VM, so the suite there can execute the POLICY
/// and never the platform binding. These are those assertions, on the platform.
///
/// Failures throw. The pass prints how many checks ran, and a run that examined
/// NOTHING fails: an entry point whose only evidence is exit 0 reports the same
/// thing whether it asserted seven properties or none (`#lzvacuousrun`).
void main() {
  const checks = <String, void Function()>{
    'refuses a wire integer above the exact range':
        _refusesAWireIntegerAboveTheExactRange,
    'accepts a wire integer inside the exact range':
        _acceptsAWireIntegerInsideTheExactRange,
    'msgpack refuses a wide tag carrying an unrepresentable value':
        _msgpackRefusesAWideTagCarryingAnUnrepresentableValue,
    'msgpack accepts a small value in a wide tag':
        _msgpackAcceptsASmallValueInAWideTag,
    'msgpack encodes a wide integer this target can represent':
        _msgpackEncodesAWideIntegerThisTargetCanRepresent,
    'content hashes are hex-stable across targets':
        _contentHashIsHexStableAcrossTargets,
    'contentHash refuses to pack rather than round':
        _contentHashRefusesToPackRatherThanRound,
    'the arena checksum stays in the exact range':
        _arenaChecksumStaysInTheExactRange,
  };

  const expected = 8;
  if (checks.length != expected) {
    throw StateError('ipc browser check: ${checks.length} checks registered, '
        'expected $expected — update the floor deliberately, not by accident');
  }

  var ran = 0;
  checks.forEach((name, check) {
    check();
    ran++;
  });
  if (ran != expected) {
    throw StateError('ipc browser check: ran $ran of $expected checks');
  }
  print('ipc browser check: OK — $ran/$expected checks on a JavaScript target');
}

void _expect(bool ok, String what) {
  if (!ok) throw StateError('ipc browser check: $what');
}

/// The half a VM test cannot reach: on a JS target `jsonDecode` rounds
/// 9007199254740993 to ...992 without complaint, so the frame must be REFUSED.
void _refusesAWireIntegerAboveTheExactRange() {
  _expect(intsAreDoubles,
      'this entry point must be running as a JavaScript target');

  var refused = false;
  try {
    IpcMessage.decodeJson('{"ResyncRequest":{"from_epoch":9007199254740993}}');
  } on FormatException {
    refused = true;
  }
  _expect(
      refused, 'a from_epoch above 2^53 - 1 decoded instead of being refused');
}

/// The other half: the guard is platform-based, not "refuse large numbers".
/// Everything at or below 2^53 - 1 is exact here and must still decode.
void _acceptsAWireIntegerInsideTheExactRange() {
  final frame = '{"ResyncRequest":{"from_epoch":$maxExactInt}}';
  final decoded = IpcMessage.decodeJson(frame);
  _expect(utf8.decode(decoded.encodeJson()) == frame,
      'a from_epoch at exactly 2^53 - 1 did not round-trip');
  _expect(
      utf8.decode(decodeMsgpack(encodeMsgpack(decoded)).encodeJson()) == frame,
      'the two codecs disagree at the boundary');
}

Uint8List _resyncFrame(List<int> tail) => Uint8List.fromList(<int>[
      0x81,
      0xad,
      ...'ResyncRequest'.codeUnits,
      0x81,
      0xaa,
      ...'from_epoch'.codeUnits,
      ...tail,
    ]);

void _msgpackRefusesAWideTagCarryingAnUnrepresentableValue() {
  // 0x0020000000000001 == 2^53 + 1, in a uint64 tag.
  var refused = false;
  try {
    decodeMsgpack(_resyncFrame(<int>[0xcf, 0x00, 0x20, 0, 0, 0, 0, 0, 0x01]));
  } on FormatException {
    refused = true;
  }
  _expect(refused, 'msgpack accepted a uint64 above 2^53 - 1 on a JS target');
}

/// msgpack permits non-minimal encodings, so a peer may carry a small value in
/// a uint64 tag. `ByteData.getUint64` throws `UnsupportedError` on a JS target
/// for EVERY such frame — which would refuse representable values for the wrong
/// reason. The unpacker reads the halves instead; this is the frame that proves
/// it, and it can only be proven here.
void _msgpackAcceptsASmallValueInAWideTag() {
  final message =
      decodeMsgpack(_resyncFrame(<int>[0xcf, 0, 0, 0, 0, 0, 0, 0, 7]));
  _expect(
      utf8.decode(message.encodeJson()) == '{"ResyncRequest":{"from_epoch":7}}',
      'a small value in a wide uint64 tag was not decoded');
}

/// The half that was still broken after `#lzdartintwidth` fixed the decoder:
/// `setUint64` is unimplemented on a JS target for EVERY 8-byte write, so a
/// browser peer could decode a wide frame and then throw encoding its own
/// reply. 2^40 is representable here and must survive the round trip.
void _msgpackEncodesAWideIntegerThisTargetCanRepresent() {
  const wide = 1099511627776; // 2^40 — above 2^32, far below 2^53.
  final frame = '{"ResyncRequest":{"from_epoch":$wide}}';
  final decoded = IpcMessage.decodeJson(frame);
  final packed = encodeMsgpack(decoded);
  _expect(packed[packed.length - 9] == 0xcf,
      'a value above 2^32 did not take the uint64 tag');
  _expect(utf8.decode(decodeMsgpack(packed).encodeJson()) == frame,
      'a uint64-tagged value above 2^32 did not round-trip through msgpack');
}

/// The identities the VM computes and the ones a browser computes have to be
/// the same string, or the same document aligns differently on the two and the
/// `c:` keyspace stops being an identity at all. These digests are pinned in
/// `test/u64_test.dart` on the VM against the same literals.
void _contentHashIsHexStableAcrossTargets() {
  const vectors = <String, String>{
    '': 'cbf29ce484222325',
    'a': 'af63dc4c8601ec8c',
    'hello world': '779a65e7023cd2e7',
    'the quick brown fox': '59aeb7b40bd8c122',
    'ünïcödé 😀': '2636b0bae56c1307',
  };
  vectors.forEach((text, expected) {
    _expect(contentHashHex(text) == expected,
        'contentHashHex($text) was ${contentHashHex(text)}, not $expected');
  });

  final key = blockKey(Block.text('hello   world'));
  _expect(key.asString() == 'c:779a65e7023cd2e7',
      'the c: wire key is ${key.asString()} on a JS target');
  _expect(key.equals(const BlockKey.content('779a65e7023cd2e7')),
      'content keys do not compare equal across constructions');
}

/// `contentHash` hands out the packed 64-bit digest. Nearly every digest is
/// above 2^53 - 1, so here it must refuse rather than hand back a rounded
/// number that is a DIFFERENT identity — the same rule the wire guard applies,
/// applied to the one API that still returns a full-width int.
void _contentHashRefusesToPackRatherThanRound() {
  var refused = false;
  try {
    contentHash('hello world'); // 0x779a65e7023cd2e7, far above 2^53 - 1.
  } on UnsupportedError {
    refused = true;
  }
  _expect(refused, 'contentHash rounded a 64-bit digest instead of refusing');
}

/// The arena checksum folds to 53 bits precisely so it does NOT have to refuse
/// here. If the fold ever widens again, this is where it shows.
void _arenaChecksumStaysInTheExactRange() {
  final arena = ShmBlobArena();
  final ref = arena.write(Uint8List.fromList(List<int>.generate(64, (i) => i)));
  _expect(ref.checksum >= 0 && ref.checksum <= maxExactInt,
      'the arena checksum ${ref.checksum} is outside the exact integer range');
  _expect(validateBlobRef(ref), 'a freshly written blob ref failed validation');
  _expect(
      arena.read(ref) != null, 'the arena could not read back its own blob');
}
