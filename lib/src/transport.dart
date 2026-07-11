/// Cross-process zero-copy transport — pluggable blob backends (`#lzzcpy`).
///
/// Spec: `lazily-spec/docs/zero-copy-transport.md`.
/// Formal: `lazily-formal/LazilyFormal/ZeroCopyTransport.lean`.
/// Rust reference: `lazily-rs/src/transport.rs`.
///
/// A large payload is not copied through the wire codec. The producer **spills**
/// it to a blob backend (the backend mints a [ShmBlobRef] descriptor) and ships
/// only the descriptor; the receiver **resolves** the descriptor against the
/// same backend and reads the bytes in place — zero copy. The [BlobBackend]
/// interface is the adapter seam:
///
/// - [InProcessBackend] wraps [ShmBlobArena] — single address space (the FFI
///   host / an in-process binding loaded in the same isolate).
/// - [ArrowBackend] holds Apache Arrow IPC stream bytes — the descriptor's bytes
///   are an Arrow IPC stream a columnar consumer imports as an `Array` /
///   `RecordBatch` with no copy (bring your own Arrow reader around the resolved
///   `Uint8List`).
///
/// Because the formal laws (spill-then-resolve identity, backend isolation, ABA
/// generation safety, checksum integrity) are stated only over a backend's
/// issued-blob table, they hold uniformly for every backend that maintains the
/// [BlobBackend] contract.
///
/// Dart runs on the isolate model — no shared address space across OS processes
/// — so the shipped backends are in-process (`in_process` / `arrow`). A real
/// POSIX `shm` region would require `dart:ffi` `shm_open` + `mmap`; a descriptor
/// tagged [BlobBackendKind.shm] therefore has no in-isolate backend to resolve
/// it here (the `shared_memory: partial` carve-out per `lazily-spec`). The
/// backend-agnostic contract and the spill/resolve/route policy are complete.
library;

import 'dart:typed_data';

import 'ipc.dart';
import 'shm_blob_arena.dart';

/// A zero-copy view into a backend's resolved bytes.
///
/// `null` (not an empty list) when the descriptor did not resolve
/// (unknown / stale-generation / corrupt-checksum / wrong-backend). An empty
/// payload that resolves correctly is a zero-length [Uint8List].
typedef BlobView = Uint8List?;

/// The adapter seam: a backend mints descriptors via [write] and resolves them
/// zero-copy via [readView].
///
/// Entries are immutable + stable-addressed for any descriptor's lifetime. The
/// formal laws (resolve_write identity, backend isolation, ABA generation
/// safety, checksum rejection) hold for every backend by construction.
abstract interface class BlobBackend {
  /// Which backend discriminator this adapter serves.
  BlobBackendKind get kind;

  /// Mint a fresh descriptor for [bytes]: allocate a stable-addressed slot,
  /// store the bytes immutably, and return a descriptor whose checksum is the
  /// bytes' FNV-1a-64, tagged with this backend's [kind].
  ShmBlobRef write(List<int> bytes);

  /// Resolve [descriptor] zero-copy — return the stored bytes iff
  /// `generation + epoch + len + checksum` all match; `null` otherwise. **No
  /// copy, no checksum recompute.**
  BlobView readView(ShmBlobRef descriptor);

  /// Advance the validity epoch. Descriptors minted before an epoch advance no
  /// longer resolve (models compaction / restart).
  void advanceEpoch();
}

/// Shared arena-backed implementation for the in-process backends. Wraps a
/// [ShmBlobArena] and tags every minted descriptor with a fixed [kind].
abstract class _ArenaBackend implements BlobBackend {
  _ArenaBackend(this._arena);

  final ShmBlobArena _arena;

  /// The backing arena (for inspection / composition).
  ShmBlobArena get arena => _arena;

  /// The backend's current validity epoch.
  int get epoch => _arena.epoch;

  @override
  ShmBlobRef write(List<int> bytes) => _arena.write(bytes).withBackend(kind);

  @override
  BlobView readView(ShmBlobRef descriptor) => _arena.read(descriptor);

  @override
  void advanceEpoch() => _arena.advanceEpoch();
}

/// Default in-process backend: wraps [ShmBlobArena] for the single-address-space
/// case (the FFI host ↔ a binding loaded in the same isolate).
///
/// Descriptors carry [BlobBackendKind.inProcess].
class InProcessBackend extends _ArenaBackend {
  /// Create an in-process backend backed by a fresh arena at [epoch] 0.
  InProcessBackend() : super(ShmBlobArena());

  /// Wrap an existing [arena].
  InProcessBackend.fromArena(super.arena);

  @override
  BlobBackendKind get kind => BlobBackendKind.inProcess;
}

/// Apache Arrow blob backend: holds spilled payloads as Arrow IPC stream bytes
/// and resolves a descriptor to the buffer's raw bytes with no copy.
///
/// The descriptor's bytes **are** an Arrow IPC stream — a columnar consumer
/// imports them as an `Array` / `RecordBatch` zero-copy (the Arrow IPC format is
/// itself zero-copy across a shared buffer). This adapter stores the raw stream
/// bytes and tags the descriptor [BlobBackendKind.arrow]; bring your own Arrow
/// reader to wrap the resolved [Uint8List] into typed Arrow.
class ArrowBackend extends _ArenaBackend {
  /// Create an Arrow backend backed by a fresh arena at [epoch] 0.
  ArrowBackend() : super(ShmBlobArena());

  /// Wrap an existing [arena].
  ArrowBackend.fromArena(super.arena);

  @override
  BlobBackendKind get kind => BlobBackendKind.arrow;
}

/// Receiver-side multi-backend resolver. Holds backends by [BlobBackendKind] and
/// resolves any descriptor by its `backend` discriminator — a `shm` descriptor
/// routes to the shm backend, an `arrow` descriptor to the arrow backend, etc.
/// (the `resolve_wrong_backend` law: a descriptor never resolves against a
/// backend of the wrong kind).
class BlobRouter {
  final Map<BlobBackendKind, BlobBackend> _backends = {};

  /// Register [backend] for its [BlobBackend.kind]. Replaces any
  /// previously-registered backend of the same kind. Returns `this` for
  /// chaining.
  BlobRouter register(BlobBackend backend) {
    _backends[backend.kind] = backend;
    return this;
  }

  /// Resolve a descriptor by routing to its `backend` kind. Returns `null` if no
  /// backend is registered for this kind, or the descriptor did not resolve.
  BlobView readView(ShmBlobRef descriptor) =>
      _backends[descriptor.backend]?.readView(descriptor);

  /// Resolve an [IpcValue]: inline bytes returned directly, [IpcValueSharedBlob]
  /// routed by the descriptor's `backend` discriminator.
  BlobView resolve(IpcValue value) {
    if (value is IpcValueInline) return value.bytes;
    if (value is IpcValueSharedBlob) return readView(value.blob);
    return null;
  }
}

/// The outcome of spilling: the (possibly rewritten) [message] and the total
/// [spilledBytes] moved off the wire into backends.
class SpillResult {
  const SpillResult(this.message, this.spilledBytes);

  /// The message with large inline payloads replaced by descriptors.
  final IpcMessage message;

  /// Total bytes spilled to backends (`0` if nothing exceeded the threshold).
  final int spilledBytes;
}

/// If [value] is an [IpcValueInline] of `>= threshold` bytes, write it to
/// [backend] and return a [IpcValueSharedBlob] descriptor; otherwise return
/// [value] unchanged. The second field is the number of bytes spilled (`0` if
/// not spilled).
///
/// Payloads below the threshold stay inline — cheaper than a backend round-trip
/// for tiny values. The threshold is a session/deployment knob.
(IpcValue, int) spillValue(IpcValue value, BlobBackend backend, int threshold) {
  if (value is IpcValueInline && value.bytes.length >= threshold) {
    final descriptor = backend.write(value.bytes);
    return (IpcValueSharedBlob(descriptor), value.bytes.length);
  }
  return (value, 0);
}

/// Spill a [NodeStatePayload] above [threshold] to a [NodeStateSharedBlob]
/// descriptor; otherwise return [state] unchanged.
(NodeState, int) _spillState(
    NodeState state, BlobBackend backend, int threshold) {
  if (state is NodeStatePayload && state.bytes.length >= threshold) {
    final descriptor = backend.write(state.bytes);
    return (NodeStateSharedBlob(descriptor), state.bytes.length);
  }
  return (state, 0);
}

/// Spill large payloads across an [IpcMessage]'s value/state sites: Snapshot node
/// states, Delta `CellSet`/`SlotValue` payloads + `NodeAdd` states, and
/// `CrdtSync` op states. Returns a [SpillResult] with the rewritten message and
/// the total bytes spilled.
///
/// Each inline payload above [threshold] is written to [backend] and replaced
/// with a descriptor — the message stays small on the wire. Sites already
/// carrying a descriptor are left untouched.
SpillResult spillMessage(
    IpcMessage message, BlobBackend backend, int threshold) {
  var total = 0;

  if (message is IpcMessageSnapshot) {
    final snap = message.value;
    final nodes = <NodeSnapshot>[];
    for (final node in snap.nodes) {
      final (state, spilled) = _spillState(node.state, backend, threshold);
      total += spilled;
      nodes.add(NodeSnapshot(node.node, node.typeTag, state, key: node.key));
    }
    return SpillResult(
      IpcMessageSnapshot(Snapshot(
        epoch: snap.epoch,
        nodes: nodes,
        edges: snap.edges,
        roots: snap.roots,
      )),
      total,
    );
  }

  if (message is IpcMessageDelta) {
    final delta = message.value;
    final ops = <DeltaOp>[];
    for (final op in delta.ops) {
      if (op is DeltaOpCellSet) {
        final (payload, spilled) = spillValue(op.payload, backend, threshold);
        total += spilled;
        ops.add(DeltaOpCellSet(op.node, payload));
      } else if (op is DeltaOpSlotValue) {
        final (payload, spilled) = spillValue(op.payload, backend, threshold);
        total += spilled;
        ops.add(DeltaOpSlotValue(op.node, payload));
      } else if (op is DeltaOpNodeAdd) {
        final (state, spilled) = _spillState(op.state, backend, threshold);
        total += spilled;
        ops.add(DeltaOpNodeAdd(op.node, op.typeTag, state, key: op.key));
      } else {
        ops.add(op);
      }
    }
    return SpillResult(
      IpcMessageDelta(
          Delta(baseEpoch: delta.baseEpoch, epoch: delta.epoch, ops: ops)),
      total,
    );
  }

  if (message is IpcMessageCrdtSync) {
    final sync = message.value;
    final ops = <CrdtOp>[];
    for (final op in sync.ops) {
      final (state, spilled) = spillValue(op.state, backend, threshold);
      total += spilled;
      ops.add(CrdtOp(node: op.node, stamp: op.stamp, state: state, key: op.key));
    }
    return SpillResult(
      IpcMessageCrdtSync(CrdtSync(frontier: sync.frontier, ops: ops)),
      total,
    );
  }

  return SpillResult(message, 0);
}

/// Resolve an [IpcValue] against a single [backend]: inline bytes returned
/// directly, [IpcValueSharedBlob] resolved zero-copy. Returns `null` if a
/// SharedBlob fails to resolve (unknown / stale / corrupt).
BlobView resolveValue(IpcValue value, BlobBackend backend) {
  if (value is IpcValueInline) return value.bytes;
  if (value is IpcValueSharedBlob) return backend.readView(value.blob);
  return null;
}
