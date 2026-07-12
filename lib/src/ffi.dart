/// The C-ABI FFI boundary (protocol.md § FFI Boundary,
/// `schemas/ffi.json`).
///
/// Exposes the language-agnostic FFI types and the channel contract that every
/// binding whose platform can host a native in-process boundary MUST provide.
/// Dart has `dart:ffi`, so this binding declares the `ffi = host` capability
/// (mirrors `lazily-rs/src/ffi.rs` and `lazily-zig/src/lazily/ffi.zig`); the
/// `none` carve-out is reserved for platforms with no shared in-process address
/// space (browser/Worker JS, fully-sandboxed runtimes).
///
/// The frame is **just serialized `IpcMessage` bytes** — there is no custom
/// header and no separate discriminant byte. The [LazilyFfiMessageKind] is
/// derived by *decoding* the message and matching on the variant, exactly as
/// the Rust reference does. A channel accepts a frame, decodes it as
/// [IpcMessage], and re-encodes canonical JSON bytes.
///
/// `LazilyFfiMessageKind` includes `crdtSync = 3` per the protocol's normative
/// requirement (the FFI message kind discriminant MUST include `CrdtSync = 3`).
library lazily.ffi;

import 'dart:convert';
import 'dart:typed_data';

import 'ipc.dart';

/// The FFI operation status code (`schemas/ffi.json#/$defs/LazilyFfiStatus`).
///
/// Errors return one of the non-zero codes; panics are caught before crossing
/// the C ABI and surface as [panic].
enum LazilyFfiStatus {
  /// Success.
  ok(0),

  /// No message available (e.g. an empty channel read).
  empty(1),

  /// A required pointer argument was `null`.
  nullPointer(2),

  /// The frame bytes did not decode as a valid [IpcMessage].
  invalidMessage(3),

  /// The frame decoded but could not be re-encoded as canonical bytes.
  encodeFailed(4),

  /// A panic was caught before crossing the C ABI.
  panic(5);

  const LazilyFfiStatus(this.code);

  /// The integer wire discriminant.
  final int code;

  /// Decode the integer discriminant, returning `null` for an unknown value
  /// (mirrors the Rust enum's strictness on out-of-range discriminants).
  static LazilyFfiStatus? fromCode(int code) {
    for (final v in LazilyFfiStatus.values) {
      if (v.code == code) return v;
    }
    return null;
  }

  /// Whether this status represents success.
  bool get isOk => this == LazilyFfiStatus.ok;
}

/// The IPC message kind discriminant
/// (`schemas/ffi.json#/$defs/LazilyFfiMessageKind`).
///
/// Derived by *decoding* a frame as [IpcMessage] and matching on the variant.
/// `crdtSync = 3` is normative: the FFI message kind discriminant MUST include
/// it (the multi-writer plane rides the same transport).
enum LazilyFfiMessageKind {
  /// Unknown / unset.
  unknown(0),

  /// An [IpcMessageSnapshot].
  snapshot(1),

  /// An [IpcMessageDelta].
  delta(2),

  /// An [IpcMessageCrdtSync] — the multi-writer CRDT plane.
  crdtSync(3),

  /// An [IpcMessageResyncRequest] — reliable-sync gap-recovery control frame
  /// (`#lzsync`, reverse channel).
  resyncRequest(4),

  /// An [IpcMessageOutboxAck] — reliable-sync ack/resume-cursor control frame
  /// (`#lzsync`, reverse channel).
  outboxAck(5);

  const LazilyFfiMessageKind(this.code);

  /// The integer wire discriminant.
  final int code;

  /// Decode the integer discriminant, returning [unknown] for an out-of-range
  /// value (matches the C enum's zero-default).
  static LazilyFfiMessageKind fromCode(int code) {
    for (final v in LazilyFfiMessageKind.values) {
      if (v.code == code) return v;
    }
    return LazilyFfiMessageKind.unknown;
  }
}

/// Owned byte buffer crossing the FFI boundary
/// (`schemas/ffi.json#/$defs/LazilyFfiBytes`).
///
/// On a real C ABI this is `{ uint8_t* ptr; size_t len; }` with explicit
/// allocation ownership: the caller owns input bytes; the host owns output
/// buffers until the paired free function is called. This Dart mirror carries
/// the bytes inline ([bytes]); the ownership contract is identical at the
/// `dart:ffi` boundary (a host function returns a [LazilyFfiBytes] whose
/// `ptr` is a `Pointer<Uint8>`, freed via the paired `lazily_ffi_bytes_free`).
class LazilyFfiBytes {
  LazilyFfiBytes(List<int> bytes) : bytes = _bytesOf(bytes);

  /// Construct from an already-owned [Uint8List] (no copy).
  LazilyFfiBytes.fromUint8List(this.bytes);

  /// The owned byte buffer.
  final Uint8List bytes;

  /// The buffer length in bytes.
  int get len => bytes.length;

  /// Decode UTF-8 JSON.
  String get asJson => utf8.decode(bytes);

  static Uint8List _bytesOf(List<int> bytes) {
    if (bytes is Uint8List) return bytes;
    final out = Uint8List(bytes.length);
    for (var i = 0; i < bytes.length; i++) {
      final b = bytes[i];
      if (b < 0 || b > 255) {
        throw ArgumentError('byte[$i] must be in 0..255 (was $b)');
      }
      out[i] = b;
    }
    return out;
  }

  @override
  String toString() => 'LazilyFfiBytes(len=$len)';
}

/// The result of a frame classification: the status plus (on success) the
/// decoded message kind.
class LazilyFfiClassification {
  const LazilyFfiClassification(this.status, this.kind);

  final LazilyFfiStatus status;
  final LazilyFfiMessageKind kind;

  /// Whether classification succeeded.
  bool get isOk => status.isOk;
}

/// Validate a frame: decode the bytes as [IpcMessage] and confirm the result is
/// well-formed. Returns [LazilyFfiStatus.ok] on success.
///
/// Mirrors `lazily_ffi_ipc_message_validate_json` in `lazily-rs/src/ffi.rs`.
LazilyFfiStatus lazilyFfiValidateJson(LazilyFfiBytes frame) {
  try {
    IpcMessage.decodeJson(frame.bytes);
    return LazilyFfiStatus.ok;
  } on FormatException {
    return LazilyFfiStatus.invalidMessage;
  } on ArgumentError {
    return LazilyFfiStatus.invalidMessage;
  } catch (_) {
    return LazilyFfiStatus.panic;
  }
}

/// Classify a frame: decode it and return the variant kind. Returns
/// [LazilyFfiStatus.invalidMessage] in [LazilyFfiClassification.status] if the
/// frame is not a valid [IpcMessage].
///
/// Mirrors `lazily_ffi_ipc_message_kind_json` in `lazily-rs/src/ffi.rs`.
LazilyFfiClassification lazilyFfiKindJson(LazilyFfiBytes frame) {
  try {
    final message = IpcMessage.decodeJson(frame.bytes);
    final kind = switch (message) {
      IpcMessageSnapshot() => LazilyFfiMessageKind.snapshot,
      IpcMessageDelta() => LazilyFfiMessageKind.delta,
      IpcMessageCrdtSync() => LazilyFfiMessageKind.crdtSync,
      IpcMessageResyncRequest() => LazilyFfiMessageKind.resyncRequest,
      IpcMessageOutboxAck() => LazilyFfiMessageKind.outboxAck,
    };
    return LazilyFfiClassification(LazilyFfiStatus.ok, kind);
  } on FormatException {
    return LazilyFfiClassification(
        LazilyFfiStatus.invalidMessage, LazilyFfiMessageKind.unknown);
  } on ArgumentError {
    return LazilyFfiClassification(
        LazilyFfiStatus.invalidMessage, LazilyFfiMessageKind.unknown);
  } catch (_) {
    return LazilyFfiClassification(
        LazilyFfiStatus.panic, LazilyFfiMessageKind.unknown);
  }
}

/// Clone a frame through the channel: decode the bytes as [IpcMessage], then
/// re-encode canonical JSON bytes. Returns the re-encoded bytes on success, or
/// `null` with a non-ok status if the frame is invalid.
///
/// This is the contract pin: "the channel decodes each accepted frame as
/// [IpcMessage] and re-encodes canonical JSON bytes." Mirrors
/// `lazily_ffi_ipc_message_clone_json` in `lazily-rs/src/ffi.rs`.
class LazilyFfiCloneResult {
  const LazilyFfiCloneResult(this.status, this.output);

  final LazilyFfiStatus status;

  /// The re-encoded canonical JSON bytes (set iff [status] is ok).
  final LazilyFfiBytes? output;
}

LazilyFfiCloneResult lazilyFfiCloneJson(LazilyFfiBytes frame) {
  try {
    final message = IpcMessage.decodeJson(frame.bytes);
    final reencoded = message.encodeJson();
    return LazilyFfiCloneResult(LazilyFfiStatus.ok, LazilyFfiBytes.fromUint8List(reencoded));
  } on FormatException {
    return const LazilyFfiCloneResult(LazilyFfiStatus.invalidMessage, null);
  } on ArgumentError {
    return const LazilyFfiCloneResult(LazilyFfiStatus.invalidMessage, null);
  } catch (_) {
    return const LazilyFfiCloneResult(LazilyFfiStatus.panic, null);
  }
}

/// A simple in-process FFI channel: a send → recv relay that mirrors the C ABI
/// `lazily_ffi_channel_send_json` / `lazily_ffi_channel_recv_json` pair without
/// a real C ABI. The bytes are decoded on send and re-encoded on recv, so a
/// round-trip exercises the same "decode + re-encode canonical JSON" contract.
class LazilyFfiChannel {
  final List<Uint8List> _queue = [];

  /// Encode [message] to canonical JSON and queue it.
  ///
  /// Mirrors `lazily_ffi_channel_send_json`. Returns [LazilyFfiStatus.ok] on
  /// success or [LazilyFfiStatus.encodeFailed] if encoding fails.
  LazilyFfiStatus send(IpcMessage message) {
    try {
      _queue.add(message.encodeJson());
      return LazilyFfiStatus.ok;
    } catch (_) {
      return LazilyFfiStatus.encodeFailed;
    }
  }

  /// Send raw frame bytes (decoded + re-encoded to canonical form on the way
  /// in, so the recv side sees canonical bytes regardless of codec).
  LazilyFfiStatus sendJsonFrame(LazilyFfiBytes frame) {
    try {
      final message = IpcMessage.decodeJson(frame.bytes);
      _queue.add(message.encodeJson());
      return LazilyFfiStatus.ok;
    } on FormatException {
      return LazilyFfiStatus.invalidMessage;
    } catch (_) {
      return LazilyFfiStatus.panic;
    }
  }

  /// Dequeue the next message. Returns the decoded [IpcMessage] or `null` if
  /// the queue is empty ([LazilyFfiStatus.empty]).
  ///
  /// Mirrors `lazily_ffi_channel_recv_json`.
  IpcMessage? recv() {
    if (_queue.isEmpty) return null;
    return IpcMessage.decodeJson(_queue.removeAt(0));
  }

  /// Whether the channel has a pending frame.
  bool get isEmpty => _queue.isEmpty;
}
