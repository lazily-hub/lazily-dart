/// Shared-memory blob arena — in-process blob storage with header validation.
///
/// The arena writes a fixed header before each payload: `{generation, epoch,
/// length, checksum}`. Readers validate the header before accepting a
/// descriptor. On Dart (isolate model — no shared address space across
/// processes), this is an in-process byte arena: the descriptors and validation
/// are conformant, but cross-process shared memory is carried `Inline` over IPC
/// (the `shared_memory: partial` carve-out per `lazily-spec`).
///
/// Mirrors `lazily-spec § Shared-memory IPC` and `protocol.md § Shared-memory
/// payload path`.
library;

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
  return hash;
}
