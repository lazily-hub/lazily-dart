/// State projection / mirror — pull-model helpers.
///
/// The value-mirror contract from `lazily-spec § Lazy reconciliation`: at
/// flush, the sender resolves each invalidated allowlisted slot, so the delta
/// carries concrete `SlotValue`s; the receiver holds no compute closures.
///
/// This module ships the pure helpers: a [StateProjectionMirror] that tracks
/// dirty slots and produces the minimal flush delta, and document-hash/event
/// builders for the agent-doc state backbone.
library;

import 'ipc.dart';

/// Tracks which slots are dirty and produces a coalesced flush [Delta].
///
/// The caller marks slots dirty as the reactive graph invalidates them. At
/// flush, the mirror collects the resolved values and builds a single
/// [Delta.next] with one [DeltaOpSlotValue] per dirty slot.
class StateProjectionMirror {
  StateProjectionMirror();

  final Set<int> _dirty = {};
  final Map<int, IpcValue> _values = {};
  Epoch _baseEpoch = 0;

  /// Mark slot [node] as dirty.
  void markDirty(int node) => _dirty.add(node);

  /// Resolve a dirty slot's value (called by the graph at flush time).
  void resolve(int node, IpcValue value) {
    _values[node] = value;
    _dirty.remove(node);
  }

  /// Whether [node] is currently dirty.
  bool isDirty(int node) => _dirty.contains(node);

  /// All dirty node ids.
  List<int> get dirtyNodes => _dirty.toList()..sort();

  /// Flush: produce a [Delta] with one [DeltaOpSlotValue] per resolved slot.
  /// Slots still dirty at flush are emitted as [DeltaOpInvalidate] (the
  /// mirror-lazy path).
  Delta flush() {
    final ops = <DeltaOp>[];
    for (final node in _dirty.toList()..sort()) {
      ops.add(DeltaOp.invalidate(node));
    }
    for (final entry in _values.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key))) {
      ops.add(DeltaOp.slotValue(entry.key, entry.value));
    }
    _dirty.clear();
    _values.clear();
    final delta = Delta.next(_baseEpoch, ops);
    _baseEpoch = delta.epoch;
    return delta;
  }

  /// The current base epoch.
  Epoch get baseEpoch => _baseEpoch;
}

/// Compute the FNV-1a 64-bit document hash for a file path or string.
///
/// Cross-language stable (NOT Dart's `hashCode`). Used as the canonical
/// document key for the state backbone.
BigInt documentHash(String path) {
  final offset = BigInt.parse('cbf29ce484222325', radix: 16);
  final mask = BigInt.parse('FFFFFFFFFFFFFFFF', radix: 16);
  final prime = BigInt.parse('100000001b3', radix: 16);

  var hash = offset;
  for (final byte in path.codeUnits) {
    hash = (hash ^ BigInt.from(byte)) & mask;
    hash = (hash * prime) & mask;
  }
  return hash;
}

/// Build a state-backbone event for the agent-doc ledger.
Map<String, dynamic> buildStateEvent(
  String docHash,
  String type,
  Map<String, dynamic> fields,
  String eventSuffix,
) {
  return {
    'event_id': '$docHash:$eventSuffix',
    'fact': {
      'type': type,
      'document_hash': docHash,
      ...fields,
    },
  };
}
