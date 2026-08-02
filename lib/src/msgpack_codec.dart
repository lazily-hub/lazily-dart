/// lazily IPC wire codec — `msgpack`, the CROSS-LANGUAGE BINARY DEFAULT
/// (`#lzmsgpackseven`).
///
/// protocol.md § Frame codecs makes `msgpack` MUST-level for every binding, and
/// spells out that shipping *a* MessagePack codec is not implementing it: the
/// codec token names ONE wire — the externally tagged frame (`{"Snapshot": …}`,
/// never an integer discriminator and never an internally tagged
/// `{"type": 0, "value": …}`) over named-field maps whose keys are the `json`
/// field names, with the same omit-when-absent rule for optional fields.
///
/// This library is built ON the `json` codec's value tree rather than beside
/// it, and that is the point: the two codecs differ only in how a value tree is
/// serialized, never in the SHAPE of that tree. Deriving the msgpack frame from
/// `IpcMessage.toWire()` makes the external tags, the field names, and both
/// `NodeKey` rules identical by construction —
///
///  * `NodeSnapshot` / `DeltaOp.NodeAdd` OMIT an absent `key` (the
///    self-describing-codec rule, § NodeKey, which is what lets a pre-`key`
///    decoder read a post-`key` frame);
///  * `CrdtOp` ALWAYS writes `key`, `null` when unset, because an anti-entropy
///    op's addressing is part of its merge identity, and the decoder reads that
///    null back as absent.
///
/// A second hand-written transcription of the same shape is exactly the drift
/// that produces a private framing wearing the `msgpack` token.
///
/// Byte payloads are ARRAYS OF INTEGERS, not MessagePack `bin`. That is what
/// the reference encoder produces (`rmp_serde` serializes `Vec<u8>` through
/// serde's default seq impl) and what its decoder accepts, so emitting or
/// accepting `bin` would put lazily-dart outside the wire it claims to speak.
/// [msgpackToJson] therefore REJECTS `bin` rather than helpfully widening.
///
/// NOT byte-canonical (§ Frame codecs): a MessagePack map's key order is
/// encoder-defined, so conformance is `decode(encode(m)) == m` plus a decode of
/// a peer's frame, never a golden byte string. This encoder happens to be
/// deterministic — allowed, but not a property any peer may rely on.
///
/// Dependency-free, like the rest of this package: the packer and unpacker
/// below are ~200 lines of pure Dart, and a msgpack package would have to be
/// driven against its own struct-mapping opinions (positional encoding,
/// `Uint8List` as `bin`, `null` for absent fields) to produce this wire anyway.
///
/// Failure mode matches the `json` codec: [FormatException].
library;

import 'dart:convert';
import 'dart:typed_data';

import 'ipc.dart';

Never _fail(String what) => throw FormatException('msgpack codec: $what');

// -- encoding -----------------------------------------------------------------

/// Pack a `json`-shaped value tree (null / bool / int / String / List / Map)
/// into MessagePack bytes.
class _Packer {
  final BytesBuilder _out = BytesBuilder(copy: false);
  final ByteData _scratch = ByteData(9);

  Uint8List take() => _out.takeBytes();

  void _byte(int b) => _out.addByte(b);

  void _prefixed(int tag, int width, int value) {
    _scratch.setUint8(0, tag);
    switch (width) {
      case 1:
        _scratch.setUint8(1, value);
        break;
      case 2:
        _scratch.setUint16(1, value);
        break;
      case 4:
        _scratch.setUint32(1, value);
        break;
      default:
        _scratch.setUint64(1, value);
        break;
    }
    _out.add(Uint8List.sublistView(_scratch, 0, 1 + width));
  }

  void _int(int value) {
    if (value >= 0) {
      if (value < 0x80) return _byte(value);
      if (value <= 0xff) return _prefixed(0xcc, 1, value);
      if (value <= 0xffff) return _prefixed(0xcd, 2, value);
      if (value <= 0xffffffff) return _prefixed(0xce, 4, value);
      return _prefixed(0xcf, 8, value);
    }
    if (value >= -0x20) return _byte(0xe0 | (value + 0x20));
    if (value >= -0x80) {
      _scratch.setUint8(0, 0xd0);
      _scratch.setInt8(1, value);
      return _out.add(Uint8List.sublistView(_scratch, 0, 2));
    }
    if (value >= -0x8000) {
      _scratch.setUint8(0, 0xd1);
      _scratch.setInt16(1, value);
      return _out.add(Uint8List.sublistView(_scratch, 0, 3));
    }
    if (value >= -0x80000000) {
      _scratch.setUint8(0, 0xd2);
      _scratch.setInt32(1, value);
      return _out.add(Uint8List.sublistView(_scratch, 0, 5));
    }
    _scratch.setUint8(0, 0xd3);
    _scratch.setInt64(1, value);
    _out.add(Uint8List.sublistView(_scratch, 0, 9));
  }

  void _str(String value) {
    // `str`, never `bin`: field names and NodeKey paths are text on this wire.
    final bytes = utf8.encode(value);
    final len = bytes.length;
    if (len < 0x20) {
      _byte(0xa0 | len);
    } else if (len <= 0xff) {
      _prefixed(0xd9, 1, len);
    } else if (len <= 0xffff) {
      _prefixed(0xda, 2, len);
    } else {
      _prefixed(0xdb, 4, len);
    }
    _out.add(bytes);
  }

  void _arrayHeader(int len) {
    if (len < 0x10) return _byte(0x90 | len);
    if (len <= 0xffff) return _prefixed(0xdc, 2, len);
    _prefixed(0xdd, 4, len);
  }

  void _mapHeader(int len) {
    if (len < 0x10) return _byte(0x80 | len);
    if (len <= 0xffff) return _prefixed(0xde, 2, len);
    _prefixed(0xdf, 4, len);
  }

  void pack(Object? value) {
    if (value == null) return _byte(0xc0);
    if (value is bool) return _byte(value ? 0xc3 : 0xc2);
    if (value is int) return _int(value);
    if (value is double) {
      // No `IpcMessage` field is floating point (§ IpcMessage: every field is
      // an integer, string, or byte sequence). Refusing here keeps a future
      // double-valued field from silently acquiring a wire form nothing agreed
      // on, rather than encoding one no peer expects.
      _fail('frames carry no floating-point fields');
    }
    if (value is String) return _str(value);
    if (value is List) {
      // A `Uint8List` IS a `List<int>` here, so byte payloads take this path
      // and encode as an array of integers — the wire the reference encoder
      // produces. Nothing routes them to `bin`.
      _arrayHeader(value.length);
      for (final element in value) {
        pack(element);
      }
      return;
    }
    if (value is Map) {
      _mapHeader(value.length);
      value.forEach((key, element) {
        if (key is! String) {
          _fail('named-field maps require string keys, got ${key.runtimeType}');
        }
        _str(key);
        pack(element);
      });
      return;
    }
    _fail('cannot encode ${value.runtimeType} in a frame');
  }
}

// -- decoding -----------------------------------------------------------------

class _Unpacker {
  _Unpacker(this._bytes) : _view = ByteData.sublistView(_bytes);

  final Uint8List _bytes;
  final ByteData _view;
  int _at = 0;

  bool get eof => _at >= _bytes.length;

  int _u8() {
    if (_at >= _bytes.length) _fail('truncated frame');
    return _bytes[_at++];
  }

  int _uint(int width) {
    if (_at + width > _bytes.length) _fail('truncated frame');
    final at = _at;
    _at += width;
    switch (width) {
      case 1:
        return _view.getUint8(at);
      case 2:
        return _view.getUint16(at);
      case 4:
        return _view.getUint32(at);
      default:
        return _view.getUint64(at);
    }
  }

  int _sint(int width) {
    if (_at + width > _bytes.length) _fail('truncated frame');
    final at = _at;
    _at += width;
    switch (width) {
      case 1:
        return _view.getInt8(at);
      case 2:
        return _view.getInt16(at);
      case 4:
        return _view.getInt32(at);
      default:
        return _view.getInt64(at);
    }
  }

  String _str(int len) {
    if (_at + len > _bytes.length) _fail('truncated frame');
    final text = utf8.decode(_bytes.sublist(_at, _at + len));
    _at += len;
    return text;
  }

  List<Object?> _array(int len) {
    final out = <Object?>[];
    for (var i = 0; i < len; i++) {
      out.add(read());
    }
    return out;
  }

  Map<String, Object?> _map(int len) {
    // A LinkedHashMap, so the ENCODER's key order survives into the
    // schema-less view. Order is not a conformance property (§ Frame codecs
    // — map key order is encoder-defined), but the envelope's single key has
    // to be readable, and a runner that sorts can only sort what it sees.
    final out = <String, Object?>{};
    for (var i = 0; i < len; i++) {
      final key = read();
      if (key is! String) {
        _fail('named-field maps require string keys, got ${key.runtimeType}');
      }
      out[key] = read();
    }
    return out;
  }

  Object? read() {
    final tag = _u8();
    if (tag <= 0x7f) return tag;
    if (tag >= 0xe0) return tag - 0x100;
    if (tag >= 0x80 && tag <= 0x8f) return _map(tag & 0x0f);
    if (tag >= 0x90 && tag <= 0x9f) return _array(tag & 0x0f);
    if (tag >= 0xa0 && tag <= 0xbf) return _str(tag & 0x1f);
    switch (tag) {
      case 0xc0:
        return null;
      case 0xc2:
        return false;
      case 0xc3:
        return true;
      case 0xc4:
      case 0xc5:
      case 0xc6:
        // A byte payload arrives as an array of integers on this wire. The
        // reference decoder rejects `bin` in the same position, so accepting
        // it here would make lazily-dart read frames no conforming peer can
        // produce and no conforming peer can read — a private extension
        // wearing the `msgpack` token.
        _fail('byte payloads are arrays of integers on this wire, '
            'not msgpack `bin`');
      case 0xca:
      case 0xcb:
        _fail('frames carry no floating-point fields');
      case 0xcc:
        return _uint(1);
      case 0xcd:
        return _uint(2);
      case 0xce:
        return _uint(4);
      case 0xcf:
        return _uint(8);
      case 0xd0:
        return _sint(1);
      case 0xd1:
        return _sint(2);
      case 0xd2:
        return _sint(4);
      case 0xd3:
        return _sint(8);
      case 0xd9:
        return _str(_uint(1));
      case 0xda:
        return _str(_uint(2));
      case 0xdb:
        return _str(_uint(4));
      case 0xdc:
        return _array(_uint(2));
      case 0xdd:
        return _array(_uint(4));
      case 0xde:
        return _map(_uint(2));
      case 0xdf:
        return _map(_uint(4));
    }
    _fail('unsupported MessagePack tag 0x${tag.toRadixString(16)} in a frame');
  }
}

// -- public API ---------------------------------------------------------------

/// MessagePack bytes for [message], on the `msgpack` wire protocol.md names.
///
/// Externally tagged envelope, named-field maps keyed by the `json` field
/// names, byte payloads as arrays of integers.
Uint8List encodeMsgpack(IpcMessage message) {
  final packer = _Packer();
  packer.pack(message.toWire());
  return packer.take();
}

/// Decode a `msgpack` frame into an [IpcMessage].
IpcMessage decodeMsgpack(List<int> bytes) => IpcMessage.fromWire(
      msgpackToJson(bytes),
    );

/// Schema-less view of a frame's bytes, as the `json` codec's value tree.
///
/// The named-field rule is a property of the ENCODING, so it is invisible to
/// any assertion over a decoded [IpcMessage]: a positional encoder round-trips
/// every value correctly and is still non-conforming. Conformance runners
/// introspect through this.
Object? msgpackToJson(List<int> bytes) {
  final unpacker = _Unpacker(
    bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
  );
  final value = unpacker.read();
  if (!unpacker.eof) _fail('trailing bytes after frame');
  return value;
}
