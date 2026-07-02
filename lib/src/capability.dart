/// Capability negotiation (protocol.md § Capability Negotiation).
///
/// Each non-local session starts with a compatibility handshake. If the peers
/// disagree on `protocol_major_version`, `codec`, `ordered_reliable`, or
/// required features, they fail closed before applying any [Snapshot] or
/// [Delta] (or [CrdtSync]). The handshake is a **standalone frame**, not an
/// [IpcMessage] variant.
///
/// Mirrors `lazily-rs::CapabilityHandshake` (struct + 5-conjunct
/// `is_compatible_with`) and `lazily-js::SessionHandshake.checkCompatible`
/// (structured `{ok, field, reason}` diagnostics). The constants
/// [kProtocolId] / [kProtocolMajorVersion] are the canonical wire values every
/// peer must advertise.

import 'dart:convert';

import 'ipc.dart';

export 'ipc.dart' show PeerId;

/// The protocol identifier every `lazily-ipc` peer must advertise.
const String kProtocolId = 'lazily-ipc';

/// The current protocol major version.
const int kProtocolMajorVersion = 1;

/// The default codec negotiation token.
const String kDefaultCodec = 'json';

/// The default maximum frame size (1 MiB).
const int kDefaultMaxFrameSize = 1 << 20;

/// The lazily-dart binding's conformance declaration
/// (protocol.md § Binding Conformance Matrix). This binding implements every
/// MUST layer.
class BindingCapabilities {
  const BindingCapabilities();

  /// This binding's name.
  static const String binding = 'lazily-dart';

  /// The `ffi` capability. `host` because Dart has `dart:ffi`; never `none`
  /// (the `none` carve-out is reserved for platforms with no shared in-process
  /// address space, e.g. browser/Worker JS).
  static const FfiCapability ffi = FfiCapability.host;

  static const bool reactiveCore = true;
  static const bool collections = true;
  static const bool stateMachine = true;
  static const bool stateCharts = true;
  static const bool ipc = true;
  static const bool crdt = true;
  static const bool permissions = true;
  static const bool capabilityNegotiation = true;
  static const bool asyncContext = true;

  /// Serialize as the JSON object a peer introspects at build/link time.
  Map<String, Object> toWire() => {
        'binding': binding,
        'ffi': ffi.wire,
        'reactive_core': reactiveCore,
        'collections': collections,
        'state_machine': stateMachine,
        'state_charts': stateCharts,
        'ipc': ipc,
        'crdt': crdt,
        'permissions': permissions,
        'capability_negotiation': capabilityNegotiation,
        'async': asyncContext,
      };
}

/// The `ffi` capability declaration (protocol.md § C-ABI FFI is required).
enum FfiCapability {
  /// This binding hosts a native C ABI and may be loaded in-process.
  host('host'),

  /// This binding's runtime cannot host a native C ABI (e.g. browser/Worker
  /// JS). It conforms to the interop contract but NOT the in-process embedding
  /// contract, and MUST NOT advertise itself as embeddable.
  none('none');

  const FfiCapability(this.wire);

  /// The wire token.
  final String wire;
}

/// The compatibility handshake exchanged before any graph state flows
/// (protocol.md § Capability Negotiation).
///
/// Serialized as a plain JSON object (NOT externally tagged — this is a
/// standalone frame, not an [IpcMessage] variant):
///
/// ```json
/// {
///   "protocol_id": "lazily-ipc",
///   "protocol_major_version": 1,
///   "codec": "json",
///   "max_frame_size": 1048576,
///   "fragmentation_supported": false,
///   "ordered_reliable": true,
///   "peer_id": 1,
///   "session_id": "abc-123",
///   "features": ["shared-blob", "signaling-relay"]
/// }
/// ```
class CapabilityHandshake {
  CapabilityHandshake({
    required this.peerId,
    required this.sessionId,
    String? protocolId,
    int? protocolMajorVersion,
    String? codec,
    int? maxFrameSize,
    this.fragmentationSupported = false,
    this.orderedReliable = true,
    List<String>? features,
  })  : protocolId = protocolId ?? kProtocolId,
        protocolMajorVersion = protocolMajorVersion ?? kProtocolMajorVersion,
        codec = codec ?? kDefaultCodec,
        maxFrameSize = maxFrameSize ?? kDefaultMaxFrameSize,
        features = features ?? const [];

  /// Create a handshake with protocol defaults (JSON codec, 1 MiB frame,
  /// ordered-reliable, no features).
  factory CapabilityHandshake.defaults(PeerId peerId, String sessionId) =>
      CapabilityHandshake(peerId: peerId, sessionId: sessionId);

  final String protocolId;
  final int protocolMajorVersion;
  final String codec;
  final int maxFrameSize;
  final bool fragmentationSupported;
  final bool orderedReliable;
  final PeerId peerId;
  final String sessionId;
  final List<String> features;

  /// Builder: set the codec negotiation token.
  CapabilityHandshake withCodec(String codec) => _copy(codec: codec);

  /// Builder: set the max frame size.
  CapabilityHandshake withMaxFrameSize(int maxFrameSize) =>
      _copy(maxFrameSize: maxFrameSize);

  /// Builder: set the features list.
  CapabilityHandshake withFeatures(Iterable<String> features) =>
      _copy(features: features.toList());

  /// Builder: set fragmentation support.
  CapabilityHandshake withFragmentation(bool supported) =>
      _copy(fragmentationSupported: supported);

  /// Builder: set ordered-reliable.
  CapabilityHandshake withOrderedReliable(bool orderedReliable) =>
      _copy(orderedReliable: orderedReliable);

  CapabilityHandshake _copy({
    String? codec,
    int? maxFrameSize,
    bool? fragmentationSupported,
    bool? orderedReliable,
    List<String>? features,
  }) =>
      CapabilityHandshake(
        peerId: peerId,
        sessionId: sessionId,
        protocolId: protocolId,
        protocolMajorVersion: protocolMajorVersion,
        codec: codec ?? this.codec,
        maxFrameSize: maxFrameSize ?? this.maxFrameSize,
        fragmentationSupported:
            fragmentationSupported ?? this.fragmentationSupported,
        orderedReliable: orderedReliable ?? this.orderedReliable,
        features: features ?? this.features,
      );

  /// Whether this peer advertises [feature].
  bool hasFeature(String feature) => features.contains(feature);

  /// Whether this handshake is mutually compatible with [other].
  ///
  /// Peers are compatible when both advertise [kProtocolId], both advertise
  /// [kProtocolMajorVersion], their major versions and codecs agree, and both
  /// require ordered-reliable delivery. Feature negotiation is caller-driven
  /// via [hasFeature] / [checkCompatible]'s `requiredFeatures` argument.
  bool isCompatibleWith(CapabilityHandshake other) =>
      checkCompatible(other).isOk;

  /// Structured compatibility check. Returns the offending field (and reason)
  /// on mismatch so a caller can produce a clean fail-closed diagnostic —
  /// mirrors `lazily-js::SessionHandshake.checkCompatible`.
  ///
  /// [requiredFeatures] are checked against the *other* peer's offered set: if
  /// this peer requires a feature the other does not offer, the handshake fails
  /// closed on `features`.
  CapabilityCheck checkCompatible(
    CapabilityHandshake other, {
    Iterable<String> requiredFeatures = const [],
  }) {
    if (protocolId != kProtocolId) {
      return const CapabilityCheck.fail(
          'protocol_id', 'local protocol_id != lazily-ipc');
    }
    if (other.protocolId != kProtocolId) {
      return const CapabilityCheck.fail(
          'protocol_id', 'remote protocol_id != lazily-ipc');
    }
    if (protocolMajorVersion != kProtocolMajorVersion) {
      return CapabilityCheck.fail('protocol_major_version',
          'local major != $kProtocolMajorVersion');
    }
    if (other.protocolMajorVersion != kProtocolMajorVersion) {
      return CapabilityCheck.fail('protocol_major_version',
          'remote major != $kProtocolMajorVersion');
    }
    if (protocolMajorVersion != other.protocolMajorVersion) {
      return const CapabilityCheck.fail(
          'protocol_major_version', 'major version mismatch');
    }
    if (codec != other.codec) {
      return CapabilityCheck.fail(
          'codec', 'codec mismatch ($codec vs ${other.codec})');
    }
    if (!orderedReliable || !other.orderedReliable) {
      return const CapabilityCheck.fail('ordered_reliable',
          'both peers must require ordered-reliable delivery');
    }
    final offered = other.features.toSet();
    for (final required in requiredFeatures) {
      if (!offered.contains(required)) {
        return CapabilityCheck.fail(
            'features', 'required feature "$required" not offered by peer');
      }
    }
    return const CapabilityCheck.ok();
  }

  /// The plain-JSON wire shape (a standalone frame, NOT externally tagged).
  Map<String, Object> toWire() => {
        'protocol_id': protocolId,
        'protocol_major_version': protocolMajorVersion,
        'codec': codec,
        'max_frame_size': maxFrameSize,
        'fragmentation_supported': fragmentationSupported,
        'ordered_reliable': orderedReliable,
        'peer_id': peerId,
        'session_id': sessionId,
        'features': List<String>.of(features),
      };

  /// Decode a plain-JSON wire object. Defaults `fragmentation_supported =
  /// false`, `ordered_reliable = true`, `features = []` when absent (mirrors
  /// the `lazily-rs` serde defaults).
  static CapabilityHandshake fromWire(Object? value) {
    final obj = value is Map ? value.cast<String, Object?>() : <String, Object?>{};
    int field(Object? v, String name) {
      if (v is! int || v < 0) {
        throw FormatException(
            '$name must be a non-negative integer, got ${v?.runtimeType}');
      }
      return v;
    }

    return CapabilityHandshake(
      peerId: field(obj['peer_id'], 'peer_id'),
      sessionId: (obj['session_id'] ?? '') as String,
      protocolId: (obj['protocol_id'] ?? kProtocolId) as String,
      protocolMajorVersion:
          (obj['protocol_major_version'] ?? kProtocolMajorVersion) as int,
      codec: (obj['codec'] ?? kDefaultCodec) as String,
      maxFrameSize:
          field(obj['max_frame_size'] ?? kDefaultMaxFrameSize, 'max_frame_size'),
      fragmentationSupported: (obj['fragmentation_supported'] ?? false) as bool,
      orderedReliable: (obj['ordered_reliable'] ?? true) as bool,
      features: obj['features'] is List
          ? (obj['features'] as List).map((e) => e.toString()).toList()
          : const [],
    );
  }

  /// UTF-8 JSON bytes of [toWire].
  String encodeJson() => jsonEncode(toWire());

  /// Decode UTF-8 JSON bytes (or a JSON string) into a handshake.
  static CapabilityHandshake decodeJson(Object data) {
    final text = data is String
        ? data
        : data is List<int>
            ? utf8.decode(data)
            : throw ArgumentError(
                'decodeJson expects String or List<int>, got ${data.runtimeType}');
    return fromWire(jsonDecode(text));
  }

  @override
  String toString() =>
      'CapabilityHandshake(peer=$peerId, session=$sessionId, codec=$codec, '
      'v$protocolMajorVersion, features=$features)';
}

/// The result of [CapabilityHandshake.checkCompatible].
class CapabilityCheck {
  const CapabilityCheck._(this.ok, this.field, this.reason);

  /// Successful handshake.
  const CapabilityCheck.ok() : this._(true, null, null);

  /// Failed handshake — [field] is the offending handshake field and [reason]
  /// the human-readable fail-closed cause.
  const CapabilityCheck.fail(String field, String reason)
      : this._(false, field, reason);

  /// Whether the handshake is compatible.
  final bool ok;

  /// The offending field name on failure, or `null` on success.
  final String? field;

  /// The human-readable fail-closed reason on failure.
  final String? reason;

  bool get isOk => ok;

  @override
  String toString() =>
      ok ? 'CapabilityCheck.ok' : 'CapabilityCheck.fail($field: $reason)';
}
