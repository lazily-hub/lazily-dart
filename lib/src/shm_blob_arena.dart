/// Shared-memory blob arena — byte storage with header validation and a
/// zero-copy cross-isolate transfer path.
///
/// The arena writes a fixed header before each payload: `{generation, epoch,
/// length, checksum}`. Readers validate the header before accepting a
/// descriptor.
///
/// **Cross-isolate shared-memory path.** Dart's concurrency model gives each
/// isolate a private heap — there is no `mmap`/`SharedArrayBuffer`-style shared
/// address space. Its faithful counterpart is [TransferableTypedData]
/// (`dart:isolate`): a **zero-copy MOVE** of a payload buffer to a receiving
/// isolate — the sender relinquishes the buffer, the receiver adopts it with no
/// byte copy. [ShmBlobArena.transfer] packages a validated blob as a
/// [ShmBlobTransfer] (descriptor + moved payload) that crosses a `SendPort`
/// zero-copy; the receiver calls [ShmBlobTransfer.receive] to adopt the buffer
/// and re-validate the header. This is the isolate-model realization of the
/// shared-memory blob path — the same zero-copy discipline the
/// `BlobBackend` transport (`#lzzcpy`) uses, applied to the arena.
///
/// Mirrors `lazily-spec § Shared-memory IPC` and `protocol.md § Shared-memory
/// payload path`.
library;

import 'dart:isolate';
import 'dart:typed_data';

import 'ipc.dart';

/// A blob arena entry: header + payload.
class _ArenaEntry {
  _ArenaEntry(this.generation, this.epoch, this.payload);

  int generation;
  int epoch;
  final Uint8List payload;

  int get checksum => _fnv1a(payload);

  ShmBlobRef toRef(int offset) => ShmBlobRef(
        offset: offset,
        len: payload.length,
        generation: generation,
        epoch: epoch,
        checksum: checksum,
      );
}

/// An in-process blob arena. Manages blob storage with generation/epoch
/// tracking and header validation.
class ShmBlobArena {
  ShmBlobArena({this.epoch = 0});

  int epoch;
  final List<_ArenaEntry> _entries = [];
  int _generation = 0;

  /// The number of stored blobs.
  int get length => _entries.length;

  /// Whether the arena is empty.
  bool get isEmpty => _entries.isEmpty;

  /// Allocate a blob. Returns the descriptor.
  ShmBlobRef write(List<int> bytes) {
    final entry = _ArenaEntry(++_generation, epoch, Uint8List.fromList(bytes));
    final offset = _entries.length;
    _entries.add(entry);
    return entry.toRef(offset);
  }

  /// Read a blob by descriptor. Returns null if the header validation fails
  /// (wrong generation, wrong epoch, or checksum mismatch).
  Uint8List? read(ShmBlobRef ref) {
    if (ref.offset < 0 || ref.offset >= _entries.length) return null;
    final entry = _entries[ref.offset];
    if (entry.generation != ref.generation) return null;
    if (entry.epoch != ref.epoch) return null;
    if (entry.payload.length != ref.len) return null;
    if (entry.checksum != ref.checksum) return null;
    return entry.payload;
  }

  /// Update an existing blob in place (bumps generation). Returns the new
  /// descriptor, or null if [ref] is stale.
  ShmBlobRef? update(ShmBlobRef ref, List<int> bytes) {
    if (ref.offset < 0 || ref.offset >= _entries.length) return null;
    final entry = _entries[ref.offset];
    if (entry.generation != ref.generation) return null;
    if (entry.epoch != ref.epoch) return null;
    entry
      ..generation = ++_generation
      ..payload.setRange(0, bytes.length, bytes);
    return entry.toRef(ref.offset);
  }

  /// Advance the arena epoch. All existing descriptors become stale.
  void advanceEpoch() {
    epoch++;
    for (final entry in _entries) {
      entry.epoch = epoch;
    }
  }

  /// Package blob [ref] for a **zero-copy cross-isolate move** — Dart's
  /// shared-memory blob path. Returns a [ShmBlobTransfer] (the descriptor paired
  /// with the payload wrapped in [TransferableTypedData]) to send over a
  /// [SendPort], or `null` if [ref] is stale (header validation fails). The
  /// payload buffer is MOVED, not copied: after the receiving isolate
  /// materializes it, this arena's copy of those bytes must not be used.
  ShmBlobTransfer? transfer(ShmBlobRef ref) {
    final bytes = read(ref);
    if (bytes == null) return null;
    return ShmBlobTransfer(ref, TransferableTypedData.fromList([bytes]));
  }
}

/// A zero-copy cross-isolate blob transfer: a [ShmBlobRef] descriptor paired
/// with its payload wrapped in [TransferableTypedData]. Sendable over a
/// [SendPort]; the wrapped buffer crosses to the receiving isolate with **no
/// copy** (a move). The receiver calls [receive] once to adopt the payload and
/// re-validate it against the header. Dart's isolate-model realization of the
/// shared-memory blob path (see [ShmBlobArena]).
class ShmBlobTransfer {
  ShmBlobTransfer(this.ref, this.data);

  /// The blob descriptor (header): `{offset, len, generation, epoch, checksum}`.
  final ShmBlobRef ref;

  /// The moved payload buffer (adopted zero-copy by the receiving isolate).
  final TransferableTypedData data;

  /// Adopt the moved payload (zero-copy) and validate it against [ref]'s header.
  /// Returns the bytes, or `null` on a length/checksum/header mismatch. Call at
  /// most once — [TransferableTypedData.materialize] consumes the buffer.
  Uint8List? receive() {
    if (ref.len < 0 || ref.generation < 0 || ref.epoch < 0) return null;
    final bytes = data.materialize().asUint8List();
    if (bytes.length != ref.len) return null;
    if (_fnv1a(bytes) != ref.checksum) return null;
    return bytes;
  }
}

/// Validate a [ShmBlobRef] descriptor against expected bounds.
bool validateBlobRef(ShmBlobRef ref, {int? maxLen}) {
  if (ref.offset < 0) return false;
  if (ref.len < 0) return false;
  if (ref.generation < 0) return false;
  if (ref.epoch < 0) return false;
  if (ref.checksum < 0) return false;
  if (maxLen != null && ref.len > maxLen) return false;
  return true;
}

int _fnv1a(Uint8List bytes) {
  var hash = 0xcbf29ce484222325;
  const prime = 0x100000001b3;
  for (final b in bytes) {
    hash = (hash ^ b) & 0xFFFFFFFFFFFFFFFF;
    hash = (hash * prime) & 0xFFFFFFFFFFFFFFFF;
  }
  // Dart's native `int` is signed 64-bit, so a full-width FNV-1a-64 with the
  // top bit set would be negative — which `ShmBlobRef` (and the wire schema)
  // reject, since a descriptor's fields are unsigned. Fold into the
  // non-negative 63-bit range. This is a Dart-internal arena checksum (the
  // isolate model has no cross-process shared memory — the `shared_memory:
  // partial` carve-out per lazily-spec), so it need not be byte-compatible with
  // the rs/py/zig FNV-1a-64; only self-consistent between write and read.
  return hash & 0x7FFFFFFFFFFFFFFF;
}
