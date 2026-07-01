/// lazily-spec IPC wire types for Dart.
///
/// A pure-Dart port of the language-agnostic lazily wire protocol
/// ([protocol.md](https://github.com/lazily-hub/lazily-spec/blob/main/protocol.md)):
/// `Snapshot` / `Delta` / `DeltaOp` / `NodeState` / `IpcValue` / `IpcMessage`,
/// the permission boundary (`RemoteOp`, `PeerPermissions`), and the optional
/// wire-stable `NodeKey` keyed address.
///
/// The transition rules — epoch sequencing, fail-closed gap resync, the
/// `PartialEq` cell guard, memo equality suppression, eager Signal
/// materialization, and batch frontier coalescing — are encoded as the
/// `// lazily-lean` helpers below. Each is the runtime mirror of a theorem
/// proven in `lazily-spec/formal/lean/LazilyFormal/IPC.lean`, so this binding
/// shares the same verified invariants as the other lazily bindings.
///
/// The library is pure Dart (only `dart:convert` and `dart:typed_data`): it
/// runs on the Flutter, web, and native targets without `dart:io`.

import 'dart:convert';
import 'dart:typed_data';

/// Wire-stable node and peer identifiers (protocol.md § Shared Types).
///
/// Serialized as bare JSON numbers. JS/TS peers must keep these at or below
/// `Number.MAX_SAFE_INTEGER` (2^53); the Dart binding has no such constraint.
typedef NodeId = int;
typedef PeerId = int;
typedef Epoch = int;

/// A validated `/`-joined path addressing a keyed collection entry.
///
/// `NodeKey` is an **additive**, optional wire-stable address: unlike the
/// volatile [NodeId] (a producer may re-mint it after a resync or a
/// remove-then-readd), a key is producer-defined and stable across NodeId
/// churn, so a peer can subscribe to "entry `scores/alice`" without an
/// out-of-band key→NodeId map. Multi-segment paths address nested collections.
///
/// Bounds (protocol.md § NodeKey), enforced on construction:
/// - path ≤ 1024 bytes (UTF-8);
/// - ≤ 32 `/`-separated segments;
/// - no empty path and no empty segments (leading/trailing/double `/`
///   rejected).
///
/// Serialization is format-aware: the JSON codec **omits** the `key` field
/// when this is `null`, so pre-`key` encoders and existing conformance
/// fixtures round-trip unchanged.
class NodeKey {
  NodeKey(String path) : path = path {
    _validate(path);
  }

  /// The canonical path string.
  final String path;

  static void _validate(String path) {
    final bytes = utf8.encode(path);
    if (bytes.isEmpty) {
      throw ArgumentError('NodeKey path must be non-empty');
    }
    if (bytes.length > 1024) {
      throw ArgumentError('NodeKey path exceeds 1024 bytes (was ${bytes.length})');
    }
    final segments = path.split('/');
    if (segments.length > 32) {
      throw ArgumentError(
          'NodeKey path exceeds 32 segments (was ${segments.length})');
    }
    for (final segment in segments) {
      if (segment.isEmpty) {
        throw ArgumentError(
            'NodeKey path has an empty segment (leading/trailing/double "/")');
      }
    }
  }

  /// The `/`-separated path segments.
  List<String> get segments => path.split('/');

  /// Serialize as a bare path string (the JSON shape of a `NodeKey`).
  String toWire() => path;

  /// Parse a wire path string, re-validating the bounds.
  static NodeKey fromWire(Object? value) {
    if (value is! String) {
      throw FormatException('NodeKey must be a string, got ${value.runtimeType}');
    }
    return NodeKey(value);
  }

  @override
  bool operator ==(Object other) => other is NodeKey && other.path == path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => 'NodeKey($path)';
}

/// Descriptor into a shared-memory blob arena (protocol.md § Shared-memory IPC).
///
/// `ShmBlobArena` writes a fixed header before each payload:
/// `{ generation, epoch, length, checksum }`. Readers validate the header
/// before accepting a descriptor. This class is the wire mirror of that
/// descriptor; arena I/O itself is implementation-local.
class ShmBlobRef {
  /// Constructs a [ShmBlobRef], rejecting negative fields.
  ShmBlobRef({
    required int offset,
    required int len,
    required int generation,
    required int epoch,
    required int checksum,
  })  : offset = _nonNeg(offset, 'offset'),
        len = _nonNeg(len, 'len'),
        generation = _nonNeg(generation, 'generation'),
        epoch = _nonNeg(epoch, 'epoch'),
        checksum = _nonNeg(checksum, 'checksum');

  final int offset;
  final int len;
  final int generation;
  final int epoch;
  final int checksum;

  static int _nonNeg(int v, String name) {
    if (v.isNaN || v.isInfinite || v < 0) {
      throw ArgumentError('$name must be a non-negative integer (was $v)');
    }
    return v;
  }

  Map<String, Object> toWire() => {
        'offset': offset,
        'len': len,
        'generation': generation,
        'epoch': epoch,
        'checksum': checksum,
      };

  static ShmBlobRef fromWire(Object? value) {
    final obj = _asObject(value, 'ShmBlobRef');
    return ShmBlobRef(
      offset: _reqInt(obj, 'offset'),
      len: _reqInt(obj, 'len'),
      generation: _reqInt(obj, 'generation'),
      epoch: _reqInt(obj, 'epoch'),
      checksum: _reqInt(obj, 'checksum'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ShmBlobRef &&
      other.offset == offset &&
      other.len == len &&
      other.generation == generation &&
      other.epoch == epoch &&
      other.checksum == checksum;

  @override
  int get hashCode =>
      Object.hash(offset, len, generation, epoch, checksum);

  @override
  String toString() =>
      'ShmBlobRef(offset=$offset, len=$len, generation=$generation, '
      'epoch=$epoch, checksum=$checksum)';
}

/// The body of a `NodeSnapshot` / `NodeAdd` (protocol.md § NodeState).
///
/// Externally tagged: a single-key JSON object whose key is the PascalCase
/// variant name, except [NodeStateOpaque] which is the bare unit string
/// `"Opaque"`.
sealed class NodeState {
  const NodeState();

  /// The JSON-shaped, externally-tagged representation.
  Object toWire();

  /// Decode an externally-tagged [NodeState].
  static NodeState fromWire(Object? value) {
    if (value is String) {
      if (value == 'Opaque') return const NodeStateOpaque();
      throw FormatException('unknown NodeState unit variant: $value');
    }
    final entry = _tagged(value, 'NodeState');
    switch (entry.key) {
      case 'Payload':
        return NodeStatePayload(_bytesFromWire(entry.value));
      case 'SharedBlob':
        return NodeStateSharedBlob(ShmBlobRef.fromWire(entry.value));
      case 'Opaque':
        return const NodeStateOpaque();
      default:
        throw FormatException('unknown NodeState variant: ${entry.key}');
    }
  }

  /// Convenience constructors mirroring the other bindings.
  static NodeState payload(List<int> bytes) => NodeStatePayload(bytes);
  static NodeState sharedBlob(ShmBlobRef blob) => NodeStateSharedBlob(blob);
  static const NodeState opaque = NodeStateOpaque();
}

/// Concrete serialized value bytes (`{"Payload": [u8]}`).
final class NodeStatePayload extends NodeState {
  NodeStatePayload(List<int> bytes) : bytes = _bytesOf(bytes);

  /// The concrete value bytes (a copy of the input, validated to 0..255).
  final Uint8List bytes;

  @override
  Object toWire() => <String, Object>{'Payload': <int>[...bytes]};

  @override
  bool operator ==(Object other) =>
      other is NodeStatePayload && _listEquals(bytes, other.bytes);

  @override
  int get hashCode => Object.hash('Payload', Object.hashAll(bytes));
}

/// A concrete value stored in shared memory (`{"SharedBlob": ShmBlobRef}`).
final class NodeStateSharedBlob extends NodeState {
  const NodeStateSharedBlob(this.blob);

  final ShmBlobRef blob;

  @override
  Object toWire() => <String, Object>{'SharedBlob': blob.toWire()};

  @override
  bool operator ==(Object other) =>
      other is NodeStateSharedBlob && other.blob == blob;

  @override
  int get hashCode => Object.hash('SharedBlob', blob);
}

/// A visible node whose value cannot be serialized (the bare `"Opaque"` unit).
final class NodeStateOpaque extends NodeState {
  const NodeStateOpaque();

  @override
  Object toWire() => 'Opaque';

  @override
  bool operator ==(Object other) => other is NodeStateOpaque;

  @override
  int get hashCode => 'Opaque'.hashCode;
}

/// A `DeltaOp` cell payload (protocol.md § IpcValue).
///
/// Externally tagged: `{"Inline": [u8]}` or `{"SharedBlob": ShmBlobRef}`.
sealed class IpcValue {
  const IpcValue();

  Object toWire();

  static IpcValue fromWire(Object? value) {
    final entry = _tagged(value, 'IpcValue');
    switch (entry.key) {
      case 'Inline':
        return IpcValueInline(_bytesFromWire(entry.value));
      case 'SharedBlob':
        return IpcValueSharedBlob(ShmBlobRef.fromWire(entry.value));
      default:
        throw FormatException('unknown IpcValue variant: ${entry.key}');
    }
  }

  /// Normalize a [List<int]] / [Uint8List] / [ShmBlobRef] / [IpcValue] to an
  /// [IpcValue], matching `IpcValue.of` in the sibling bindings.
  static IpcValue of(Object value) {
    if (value is IpcValue) return value;
    if (value is ShmBlobRef) return IpcValueSharedBlob(value);
    if (value is List<int>) return IpcValueInline(value);
    throw ArgumentError(
        'cannot coerce ${value.runtimeType} into an IpcValue');
  }

  static IpcValue inline(List<int> bytes) => IpcValueInline(bytes);
  static IpcValue sharedBlob(ShmBlobRef blob) => IpcValueSharedBlob(blob);
}

/// Inline byte-array payload (`{"Inline": [u8]}`).
final class IpcValueInline extends IpcValue {
  IpcValueInline(List<int> bytes) : bytes = _bytesOf(bytes);

  final Uint8List bytes;

  @override
  Object toWire() => <String, Object>{'Inline': <int>[...bytes]};

  @override
  bool operator ==(Object other) =>
      other is IpcValueInline && _listEquals(bytes, other.bytes);

  @override
  int get hashCode => Object.hash('Inline', Object.hashAll(bytes));
}

/// A payload descriptor into shared memory (`{"SharedBlob": ShmBlobRef}`).
final class IpcValueSharedBlob extends IpcValue {
  const IpcValueSharedBlob(this.blob);

  final ShmBlobRef blob;

  @override
  Object toWire() => <String, Object>{'SharedBlob': blob.toWire()};

  @override
  bool operator ==(Object other) =>
      other is IpcValueSharedBlob && other.blob == blob;

  @override
  int get hashCode => Object.hash('SharedBlob', blob);
}

/// A serialized node in a [Snapshot] (protocol.md § NodeSnapshot).
///
/// The optional [key] is a wire-stable [NodeKey]. It is omitted from the JSON
/// output when `null`, so pre-`key` peers and the existing conformance
/// fixtures round-trip unchanged.
class NodeSnapshot {
  NodeSnapshot(
    this.node,
    this.typeTag,
    this.state, {
    this.key,
  });

  NodeSnapshot.payload(
    this.node,
    this.typeTag,
    List<int> bytes, {
    this.key,
  }) : state = NodeStatePayload(bytes);

  NodeSnapshot.sharedBlob(
    this.node,
    this.typeTag,
    ShmBlobRef blob, {
    this.key,
  }) : state = NodeStateSharedBlob(blob);

  NodeSnapshot.opaque(
    this.node,
    this.typeTag, {
    this.key,
  }) : state = const NodeStateOpaque();

  final NodeId node;
  final String typeTag;
  final NodeState state;
  final NodeKey? key;

  Map<String, Object> toWire() {
    final out = <String, Object>{
      'node': node,
      'type_tag': typeTag,
      'state': state.toWire(),
    };
    if (key != null) out['key'] = key!.toWire();
    return out;
  }

  static NodeSnapshot fromWire(Object? value) {
    final obj = _asObject(value, 'NodeSnapshot');
    return NodeSnapshot(
      _reqInt(obj, 'node'),
      _reqString(obj, 'type_tag'),
      NodeState.fromWire(obj['state']),
      key: obj.containsKey('key') && obj['key'] != null
          ? NodeKey.fromWire(obj['key'])
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NodeSnapshot &&
      other.node == node &&
      other.typeTag == typeTag &&
      other.state == state &&
      other.key == key;

  @override
  int get hashCode => Object.hash(node, typeTag, state, key);

  @override
  String toString() => 'NodeSnapshot($node, $typeTag, $state'
      '${key != null ? ', key=$key' : ''})';
}

/// A dependency edge: `dependent` reads `dependency`.
class EdgeSnapshot {
  const EdgeSnapshot(this.dependent, this.dependency);

  final NodeId dependent;
  final NodeId dependency;

  Map<String, Object> toWire() => {
        'dependent': dependent,
        'dependency': dependency,
      };

  static EdgeSnapshot fromWire(Object? value) {
    final obj = _asObject(value, 'EdgeSnapshot');
    return EdgeSnapshot(_reqInt(obj, 'dependent'), _reqInt(obj, 'dependency'));
  }

  /// Both endpoints must be readable for the edge to be observable by [peer].
  bool isReadableBy(PeerPermissions permissions, PeerId peer) =>
      permissions.canRead(peer, dependent) &&
      permissions.canRead(peer, dependency);

  @override
  bool operator ==(Object other) =>
      other is EdgeSnapshot &&
      other.dependent == dependent &&
      other.dependency == dependency;

  @override
  int get hashCode => Object.hash(dependent, dependency);

  @override
  String toString() => 'Edge($dependent -> $dependency)';
}

/// Full graph state, sent on connect and on resync (protocol.md § Snapshot).
class Snapshot {
  const Snapshot({
    required this.epoch,
    this.nodes = const [],
    this.edges = const [],
    this.roots = const [],
  });

  final Epoch epoch;
  final List<NodeSnapshot> nodes;
  final List<EdgeSnapshot> edges;
  final List<NodeId> roots;

  Map<String, Object> toWire() => {
        'epoch': epoch,
        'nodes': nodes.map((n) => n.toWire()).toList(),
        'edges': edges.map((e) => e.toWire()).toList(),
        'roots': <int>[...roots],
      };

  static Snapshot fromWire(Object? value) {
    final obj = _asObject(value, 'Snapshot');
    return Snapshot(
      epoch: _reqInt(obj, 'epoch'),
      nodes: _objList(obj, 'nodes', NodeSnapshot.fromWire),
      edges: _objList(obj, 'edges', EdgeSnapshot.fromWire),
      roots: _intList(obj, 'roots'),
    );
  }

  /// Drop non-readable nodes/edges/roots before serialization (omission, not
  /// redaction — protocol.md § Permission Boundary).
  Snapshot filterReadable(PeerPermissions permissions, PeerId peer) =>
      Snapshot(
        epoch: epoch,
        nodes:
            nodes.where((n) => permissions.canRead(peer, n.node)).toList(),
        edges: edges.where((e) => e.isReadableBy(permissions, peer)).toList(),
        roots: permissions.filterReadable(peer, roots),
      );

  @override
  bool operator ==(Object other) =>
      other is Snapshot &&
      other.epoch == epoch &&
      _listEquals(other.nodes, nodes) &&
      _listEquals(other.edges, edges) &&
      _listEquals(other.roots, roots);

  @override
  int get hashCode =>
      Object.hash(epoch, Object.hashAll(nodes), Object.hashAll(edges),
          Object.hashAll(roots));
}

/// One incremental operation in a [Delta] (protocol.md § DeltaOp variants).
///
/// All variants are externally tagged. [DeltaOpNodeAdd] carries the optional
/// wire-stable [NodeKey] (omitted from JSON when `null`).
sealed class DeltaOp {
  const DeltaOp();

  Object toWire();

  /// Whether the [peer] may read every node this op names. Ops targeting an
  /// unreadable node are omitted from a permission-filtered delta.
  bool targetReadable(PeerPermissions permissions, PeerId peer);

  static DeltaOp fromWire(Object? value) {
    final entry = _tagged(value, 'DeltaOp');
    final body = _asObject(entry.value, entry.key);
    switch (entry.key) {
      case 'CellSet':
        return DeltaOpCellSet(_reqInt(body, 'node'),
            IpcValue.fromWire(body['payload']));
      case 'SlotValue':
        return DeltaOpSlotValue(_reqInt(body, 'node'),
            IpcValue.fromWire(body['payload']));
      case 'Invalidate':
        return DeltaOpInvalidate(_reqInt(body, 'node'));
      case 'NodeAdd':
        return DeltaOpNodeAdd(
          _reqInt(body, 'node'),
          _reqString(body, 'type_tag'),
          NodeState.fromWire(body['state']),
          key: body.containsKey('key') && body['key'] != null
              ? NodeKey.fromWire(body['key'])
              : null,
        );
      case 'NodeRemove':
        return DeltaOpNodeRemove(_reqInt(body, 'node'));
      case 'EdgeAdd':
        return DeltaOpEdgeAdd(
            _reqInt(body, 'dependent'), _reqInt(body, 'dependency'));
      case 'EdgeRemove':
        return DeltaOpEdgeRemove(
            _reqInt(body, 'dependent'), _reqInt(body, 'dependency'));
      default:
        throw FormatException('unknown DeltaOp variant: ${entry.key}');
    }
  }

  // Constructors mirroring the sibling bindings' `DeltaOp` namespace.
  static DeltaOp cellSet(NodeId node, Object payload) =>
      DeltaOpCellSet(node, IpcValue.of(payload));
  static DeltaOp slotValue(NodeId node, Object payload) =>
      DeltaOpSlotValue(node, IpcValue.of(payload));
  static DeltaOp invalidate(NodeId node) => DeltaOpInvalidate(node);
  static DeltaOp nodeAdd(
          NodeId node, String typeTag, NodeState state, {NodeKey? key}) =>
      DeltaOpNodeAdd(node, typeTag, state, key: key);
  static DeltaOp nodeRemove(NodeId node) => DeltaOpNodeRemove(node);
  static DeltaOp edgeAdd(NodeId dependent, NodeId dependency) =>
      DeltaOpEdgeAdd(dependent, dependency);
  static DeltaOp edgeRemove(NodeId dependent, NodeId dependency) =>
      DeltaOpEdgeRemove(dependent, dependency);
}

/// Changed-value cell write, `PartialEq`-guarded at the source.
final class DeltaOpCellSet extends DeltaOp {
  const DeltaOpCellSet(this.node, this.payload);

  final NodeId node;
  final IpcValue payload;

  @override
  Object toWire() => {
        'CellSet': {
          'node': node,
          'payload': payload.toWire(),
        },
      };

  @override
  bool targetReadable(PeerPermissions permissions, PeerId peer) =>
      permissions.canRead(peer, node);

  @override
  bool operator ==(Object other) =>
      other is DeltaOpCellSet && other.node == node && other.payload == payload;

  @override
  int get hashCode => Object.hash('CellSet', node, payload);
}

/// A recompute published a new value.
final class DeltaOpSlotValue extends DeltaOp {
  const DeltaOpSlotValue(this.node, this.payload);

  final NodeId node;
  final IpcValue payload;

  @override
  Object toWire() => {
        'SlotValue': {
          'node': node,
          'payload': payload.toWire(),
        },
      };

  @override
  bool targetReadable(PeerPermissions permissions, PeerId peer) =>
      permissions.canRead(peer, node);

  @override
  bool operator ==(Object other) =>
      other is DeltaOpSlotValue &&
      other.node == node &&
      other.payload == payload;

  @override
  int get hashCode => Object.hash('SlotValue', node, payload);
}

/// Dirtied, not yet recomputed (lazy).
final class DeltaOpInvalidate extends DeltaOp {
  const DeltaOpInvalidate(this.node);

  final NodeId node;

  @override
  Object toWire() => {
        'Invalidate': {'node': node},
      };

  @override
  bool targetReadable(PeerPermissions permissions, PeerId peer) =>
      permissions.canRead(peer, node);

  @override
  bool operator ==(Object other) =>
      other is DeltaOpInvalidate && other.node == node;

  @override
  int get hashCode => Object.hash('Invalidate', node);
}

/// New node (optional wire-stable [key]).
final class DeltaOpNodeAdd extends DeltaOp {
  const DeltaOpNodeAdd(this.node, this.typeTag, this.state, {this.key});

  final NodeId node;
  final String typeTag;
  final NodeState state;
  final NodeKey? key;

  @override
  Object toWire() {
    final body = <String, Object>{
      'node': node,
      'type_tag': typeTag,
      'state': state.toWire(),
    };
    if (key != null) body['key'] = key!.toWire();
    return {'NodeAdd': body};
  }

  @override
  bool targetReadable(PeerPermissions permissions, PeerId peer) =>
      permissions.canRead(peer, node);

  @override
  bool operator ==(Object other) =>
      other is DeltaOpNodeAdd &&
      other.node == node &&
      other.typeTag == typeTag &&
      other.state == state &&
      other.key == key;

  @override
  int get hashCode => Object.hash('NodeAdd', node, typeTag, state, key);
}

/// Removed node (free-list reuse: Remove then Add).
final class DeltaOpNodeRemove extends DeltaOp {
  const DeltaOpNodeRemove(this.node);

  final NodeId node;

  @override
  Object toWire() => {
        'NodeRemove': {'node': node},
      };

  @override
  bool targetReadable(PeerPermissions permissions, PeerId peer) =>
      permissions.canRead(peer, node);

  @override
  bool operator ==(Object other) =>
      other is DeltaOpNodeRemove && other.node == node;

  @override
  int get hashCode => Object.hash('NodeRemove', node);
}

/// New dependency edge.
final class DeltaOpEdgeAdd extends DeltaOp {
  const DeltaOpEdgeAdd(this.dependent, this.dependency);

  final NodeId dependent;
  final NodeId dependency;

  @override
  Object toWire() => {
        'EdgeAdd': {
          'dependent': dependent,
          'dependency': dependency,
        },
      };

  @override
  bool targetReadable(PeerPermissions permissions, PeerId peer) =>
      permissions.canRead(peer, dependent) &&
      permissions.canRead(peer, dependency);

  @override
  bool operator ==(Object other) =>
      other is DeltaOpEdgeAdd &&
      other.dependent == dependent &&
      other.dependency == dependency;

  @override
  int get hashCode => Object.hash('EdgeAdd', dependent, dependency);
}

/// Removed dependency edge.
final class DeltaOpEdgeRemove extends DeltaOp {
  const DeltaOpEdgeRemove(this.dependent, this.dependency);

  final NodeId dependent;
  final NodeId dependency;

  @override
  Object toWire() => {
        'EdgeRemove': {
          'dependent': dependent,
          'dependency': dependency,
        },
      };

  @override
  bool targetReadable(PeerPermissions permissions, PeerId peer) =>
      permissions.canRead(peer, dependent) &&
      permissions.canRead(peer, dependency);

  @override
  bool operator ==(Object other) =>
      other is DeltaOpEdgeRemove &&
      other.dependent == dependent &&
      other.dependency == dependency;

  @override
  int get hashCode => Object.hash('EdgeRemove', dependent, dependency);
}

/// The outcome of attempting to apply a [Delta] (lean `ApplyDecision`).
sealed class DeltaApplyStatus {
  const DeltaApplyStatus();

  bool get isApply => this is DeltaApplyStatusApply;
  bool get isResyncRequired => this is DeltaApplyStatusResyncRequired;
}

/// The delta was sequential and may be applied; the new epoch is [newEpoch].
final class DeltaApplyStatusApply extends DeltaApplyStatus {
  const DeltaApplyStatusApply(this.newEpoch);

  final Epoch newEpoch;

  @override
  bool operator ==(Object other) =>
      other is DeltaApplyStatusApply && other.newEpoch == newEpoch;

  @override
  int get hashCode => Object.hash('Apply', newEpoch);
}

/// A gap, reorder, or sender restart was detected; request a fresh snapshot.
final class DeltaApplyStatusResyncRequired extends DeltaApplyStatus {
  const DeltaApplyStatusResyncRequired({
    required this.lastEpoch,
    required this.baseEpoch,
    required this.epoch,
  });

  final Epoch lastEpoch;
  final Epoch baseEpoch;
  final Epoch epoch;

  @override
  bool operator ==(Object other) =>
      other is DeltaApplyStatusResyncRequired &&
      other.lastEpoch == lastEpoch &&
      other.baseEpoch == baseEpoch &&
      other.epoch == epoch;

  @override
  int get hashCode => Object.hash('ResyncRequired', lastEpoch, baseEpoch, epoch);
}

/// An incremental change set (protocol.md § Delta).
class Delta {
  const Delta({required this.baseEpoch, required this.epoch, this.ops = const []});

  final Epoch baseEpoch;
  final Epoch epoch;
  final List<DeltaOp> ops;

  /// The next sequential delta after [baseEpoch] carrying [ops].
  ///
  /// lean theorem `nextDelta_epoch`: the returned [epoch] is always
  /// `baseEpoch + 1`.
  factory Delta.next(Epoch baseEpoch, [List<DeltaOp> ops = const []]) =>
      Delta(baseEpoch: baseEpoch, epoch: baseEpoch + 1, ops: List.of(ops));

  /// lean `isSequentialAfter`: true iff this delta continues immediately after
  /// [lastEpoch].
  bool isNextAfter(Epoch lastEpoch) =>
      baseEpoch == lastEpoch && epoch == baseEpoch + 1;

  /// lean `applyDelta`: apply iff sequential, otherwise fail closed.
  DeltaApplyStatus applyStatus(Epoch lastEpoch) => isNextAfter(lastEpoch)
      ? DeltaApplyStatusApply(epoch)
      : DeltaApplyStatusResyncRequired(
          lastEpoch: lastEpoch, baseEpoch: baseEpoch, epoch: epoch);

  /// Drop ops whose target node(s) are unreadable by [peer] (omission).
  Delta filterReadable(PeerPermissions permissions, PeerId peer) => Delta(
        baseEpoch: baseEpoch,
        epoch: epoch,
        ops: ops.where((op) => op.targetReadable(permissions, peer)).toList(),
      );

  Map<String, Object> toWire() => {
        'base_epoch': baseEpoch,
        'epoch': epoch,
        'ops': ops.map((op) => op.toWire()).toList(),
      };

  static Delta fromWire(Object? value) {
    final obj = _asObject(value, 'Delta');
    return Delta(
      baseEpoch: _reqInt(obj, 'base_epoch'),
      epoch: _reqInt(obj, 'epoch'),
      ops: _objList(obj, 'ops', DeltaOp.fromWire),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Delta &&
      other.baseEpoch == baseEpoch &&
      other.epoch == epoch &&
      _listEquals(other.ops, ops);

  @override
  int get hashCode => Object.hash(baseEpoch, epoch, Object.hashAll(ops));
}

/// A length-prefixed, tagged `Snapshot` or `Delta` (protocol.md § IPC).
sealed class IpcMessage {
  const IpcMessage();

  bool get isSnapshot => this is IpcMessageSnapshot;
  bool get isDelta => this is IpcMessageDelta;

  /// The [Snapshot] if this is one, otherwise `null`.
  Snapshot? get snapshot =>
      this is IpcMessageSnapshot ? (this as IpcMessageSnapshot).value : null;

  /// The [Delta] if this is one, otherwise `null`.
  Delta? get delta =>
      this is IpcMessageDelta ? (this as IpcMessageDelta).value : null;

  /// The externally-tagged wire shape.
  Object toWire();

  /// UTF-8 JSON bytes of [toWire].
  Uint8List encodeJson() => Uint8List.fromList(utf8.encode(jsonEncode(toWire())));

  static IpcMessage ofSnapshot(Snapshot snapshot) =>
      IpcMessageSnapshot(snapshot);

  static IpcMessage ofDelta(Delta delta) => IpcMessageDelta(delta);

  static IpcMessage fromWire(Object? value) {
    final entry = _tagged(value, 'IpcMessage');
    switch (entry.key) {
      case 'Snapshot':
        return IpcMessageSnapshot(Snapshot.fromWire(entry.value));
      case 'Delta':
        return IpcMessageDelta(Delta.fromWire(entry.value));
      default:
        throw FormatException('unknown IpcMessage variant: ${entry.key}');
    }
  }

  /// Decode UTF-8 JSON bytes (or a JSON string) into an [IpcMessage].
  static IpcMessage decodeJson(Object data) {
    final text = data is Uint8List
        ? utf8.decode(data)
        : data is String
            ? data
            : throw ArgumentError(
                'decodeJson expects Uint8List or String, got ${data.runtimeType}');
    return fromWire(jsonDecode(text));
  }
}

final class IpcMessageSnapshot extends IpcMessage {
  const IpcMessageSnapshot(this.value);

  final Snapshot value;

  @override
  Object toWire() => {'Snapshot': value.toWire()};

  @override
  bool operator ==(Object other) =>
      other is IpcMessageSnapshot && other.value == value;

  @override
  int get hashCode => Object.hash('Snapshot', value);
}

final class IpcMessageDelta extends IpcMessage {
  const IpcMessageDelta(this.value);

  final Delta value;

  @override
  Object toWire() => {'Delta': value.toWire()};

  @override
  bool operator ==(Object other) =>
      other is IpcMessageDelta && other.value == value;

  @override
  int get hashCode => Object.hash('Delta', value);
}

// ---------------------------------------------------------------------------
// Permission boundary (protocol.md § Permission Boundary)
// ---------------------------------------------------------------------------

/// The three independently-gated remote operation kinds.
enum OpKind {
  read('read'),
  write('write'),
  triggerEffect('trigger_effect');

  const OpKind(this.wire);
  final String wire;
}

/// `{ kind: OpKind, node: NodeId }`. A read grant never implies write or effect.
class RemoteOp {
  const RemoteOp(this.kind, this.node);

  final OpKind kind;
  final NodeId node;

  static RemoteOp read(NodeId node) => RemoteOp(OpKind.read, node);
  static RemoteOp write(NodeId node) => RemoteOp(OpKind.write, node);
  static RemoteOp triggerEffect(NodeId node) =>
      RemoteOp(OpKind.triggerEffect, node);

  @override
  bool operator ==(Object other) =>
      other is RemoteOp && other.kind == kind && other.node == node;

  @override
  int get hashCode => Object.hash(kind, node);

  @override
  String toString() => 'RemoteOp(${kind.wire}, $node)';
}

/// Thrown by [PeerPermissions.check] when [peer] lacks [op].
class PermissionDenied implements Exception {
  const PermissionDenied(this.peer, this.op);

  final PeerId peer;
  final RemoteOp op;

  @override
  String toString() =>
      'PermissionDenied: peer $peer denied ${op.kind.wire} on node ${op.node}';
}

/// Default-deny, per-peer allowlist of [RemoteOp] grants.
///
/// The three [OpKind]s are gated independently. Non-allowlisted nodes are
/// omitted entirely from a permission-filtered snapshot/delta (not redacted).
class PeerPermissions {
  final Map<PeerId, Map<OpKind, Set<NodeId>>> _peers = {};

  /// Grant [peer] the [op]; returns whether this added a new grant.
  bool allow(PeerId peer, RemoteOp op) =>
      _peers.putIfAbsent(peer, () => {}).putIfAbsent(op.kind, () => {}).add(op.node);

  /// Grant [peer] every node in [nodes] for [kind].
  void allowMany(PeerId peer, OpKind kind, Iterable<NodeId> nodes) {
    _peers.putIfAbsent(peer, () => {})[kind] ??= <NodeId>{};
    _peers[peer]![kind]!.addAll(nodes);
  }

  /// Revoke a single grant; returns whether anything was removed.
  bool revoke(PeerId peer, RemoteOp op) {
    final byKind = _peers[peer]?[op.kind];
    if (byKind == null || !byKind.remove(op.node)) return false;
    _prune(peer);
    return true;
  }

  /// Drop every grant for [peer]; returns whether the peer was present.
  bool revokePeer(PeerId peer) => _peers.remove(peer) != null;

  /// Whether [peer] holds [op].
  bool isAllowed(PeerId peer, RemoteOp op) =>
      _peers[peer]?[op.kind]?.contains(op.node) ?? false;

  /// Whether [peer] may read [node].
  bool canRead(PeerId peer, NodeId node) => isAllowed(peer, RemoteOp.read(node));

  /// Throw [PermissionDenied] unless [peer] holds [op].
  void check(PeerId peer, RemoteOp op) {
    if (!isAllowed(peer, op)) throw PermissionDenied(peer, op);
  }

  /// The readable subset of [nodes] for [peer].
  List<NodeId> filterReadable(PeerId peer, Iterable<NodeId> nodes) =>
      nodes.where((node) => canRead(peer, node)).toList();

  /// The number of peers with at least one grant.
  int get peerCount => _peers.length;

  void _prune(PeerId peer) {
    final byKind = _peers[peer];
    if (byKind == null) return;
    byKind.entries
        .where((e) => e.value.isEmpty)
        .map((e) => e.key)
        .toList()
        .forEach(byKind.remove);
    if (byKind.isEmpty) _peers.remove(peer);
  }
}

// ---------------------------------------------------------------------------
// lazily-lean transition helpers.
//
// Runtime mirrors of `lazily-spec/formal/lean/LazilyFormal/IPC.lean`. Each
// helper is annotated with the theorem it carries; the test suite pins them.
// ---------------------------------------------------------------------------

/// lean `cellSetOps` + theorem `equal_cell_set_is_silent` /
/// `changed_cell_set_emits_cell_set`: the `PartialEq` cell guard. An equal
/// write emits no op; a changed write emits exactly one [DeltaOpCellSet].
List<DeltaOp> cellSetOps(NodeId node, IpcValue oldValue, IpcValue newValue) {
  if (oldValue == newValue) return const <DeltaOp>[];
  return <DeltaOp>[DeltaOpCellSet(node, newValue)];
}

/// lean `downstreamInvalidations`: each downstream node becomes an
/// [DeltaOpInvalidate], preserving order.
List<DeltaOp> downstreamInvalidations(List<NodeId> downstream) =>
    downstream.map(DeltaOpInvalidate.new).toList();

/// lean `memoOps` + theorem `equal_memo_suppresses_downstream` /
/// `changed_memo_publishes_then_invalidates`: memo equality suppression. An
/// equal recompute is silent; a changed recompute publishes a [DeltaOpSlotValue]
/// then invalidates the downstream frontier.
List<DeltaOp> memoOps(
  NodeId node,
  IpcValue oldValue,
  IpcValue newValue,
  List<NodeId> downstream,
) {
  if (oldValue == newValue) return const <DeltaOp>[];
  return <DeltaOp>[
    DeltaOpSlotValue(node, newValue),
    ...downstreamInvalidations(downstream),
  ];
}

/// lean `signalOps` + theorem `equal_signal_is_silent` /
/// `changed_signal_materializes_slot_value` /
/// `signal_never_emits_bare_invalidate`: a changed eager Signal materializes a
/// concrete [DeltaOpSlotValue] for its backing slot — never a bare
/// [DeltaOpInvalidate].
List<DeltaOp> signalOps(NodeId node, IpcValue oldValue, IpcValue newValue) {
  if (oldValue == newValue) return const <DeltaOp>[];
  return <DeltaOp>[DeltaOpSlotValue(node, newValue)];
}

/// lean `BatchFlush` + theorems `batch_frontier_is_coalesced`,
/// `batch_flush_advances_epoch_once`, `batch_flush_ops_are_frontier_invalidations`.
///
/// One outermost batch-flush invalidation pass produces a no-duplicate frontier
/// (the `frontierNodup` field) and emits exactly one delta that advances the
/// IPC epoch once. The frontier is coalesced: a dependent reached through many
/// changed cells appears at most once.
class BatchFlush {
  BatchFlush({
    this.changedCells = const [],
    List<NodeId> frontier = const [],
  })  : frontier = _dedup(frontier),
        ops = downstreamInvalidations(_dedup(frontier));

  /// The cells that changed in this batch (informational; not serialized).
  final List<NodeId> changedCells;

  /// The coalesced, duplicate-free invalidation frontier (`frontierNodup`).
  final List<NodeId> frontier;

  /// `ops = frontier.map(DeltaOp.invalidate)` (theorem
  /// `batch_flush_ops_are_frontier_invalidations`).
  final List<DeltaOp> ops;

  /// Build the single delta this flush emits. Advances the epoch exactly once
  /// (theorem `batch_flush_advances_epoch_once`).
  Delta toDelta(Epoch baseEpoch) => Delta.next(baseEpoch, ops);

  static List<NodeId> _dedup(List<NodeId> nodes) {
    final seen = <NodeId>{};
    final out = <NodeId>[];
    for (final node in nodes) {
      if (seen.add(node)) out.add(node);
    }
    return out;
  }
}

// ---------------------------------------------------------------------------
// JSON shape helpers
// ---------------------------------------------------------------------------

Map<String, Object?> _asObject(Object? value, String name) {
  if (value is! Map) {
    throw FormatException('$name must be a JSON object, got ${value.runtimeType}');
  }
  return value.cast<String, Object?>();
}

MapEntry<String, Object?> _tagged(Object? value, String name) {
  final obj = _asObject(value, name);
  if (obj.length != 1) {
    throw FormatException('$name must be externally tagged (one key)');
  }
  final e = obj.entries.single;
  return MapEntry(e.key, e.value);
}

int _reqInt(Map<String, Object?> obj, String field) {
  final v = obj[field];
  if (v is! int || v < 0) {
    throw FormatException(
        '$field must be a non-negative integer, got ${v?.runtimeType}');
  }
  return v;
}

String _reqString(Map<String, Object?> obj, String field) {
  final v = obj[field];
  if (v is! String) {
    throw FormatException('$field must be a string, got ${v?.runtimeType}');
  }
  return v;
}

List<int> _intList(Map<String, Object?> obj, String field) {
  final v = obj[field];
  if (v is! List) {
    throw FormatException('$field must be an array, got ${v?.runtimeType}');
  }
  return v.map((e) {
    if (e is! int || e < 0) {
      throw FormatException(
          '$field entry must be a non-negative integer, got ${e.runtimeType}');
    }
    return e;
  }).toList();
}

List<T> _objList<T>(
  Map<String, Object?> obj,
  String field,
  T Function(Object?) decode,
) {
  final v = obj[field];
  if (v is! List) {
    throw FormatException('$field must be an array, got ${v?.runtimeType}');
  }
  return v.map(decode).toList();
}

Uint8List _bytesOf(List<int> bytes) {
  final out = Uint8List(bytes.length);
  for (var i = 0; i < bytes.length; i++) {
    final b = bytes[i];
    if (b < 0 || b > 255) {
      throw ArgumentError('byte payload[$i] must be in 0..255 (was $b)');
    }
    out[i] = b;
  }
  return out;
}

Uint8List _bytesFromWire(Object? value) {
  if (value is! List) {
    throw FormatException('byte payload must be an array, got ${value.runtimeType}');
  }
  return _bytesOf(value.cast<int>());
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
