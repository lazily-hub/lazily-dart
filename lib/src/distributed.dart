/// Distributed CRDT plane runtime — state-based anti-entropy.
///
/// The runtime manages a set of per-node LWW cells. Each cell holds the
/// winning [CrdtOp] (greatest [WireStamp] under lex `(wallTime, logical,
/// peer)`). Op-log dedup is keyed by `(node, stamp)`, so re-ingesting a frame
/// applies zero new ops.
///
/// Mirrors `lazily-js/src/distributed.js` (`CrdtPlaneRuntime`). Conforms to
/// `lazily-spec` `conformance/distributed/anti_entropy_converge.json`.
library;

import 'ipc.dart';

/// The result of a converged node.
class ConvergedEntry {
  ConvergedEntry({required this.node, this.key, required this.state});

  final int node;
  final String? key;
  final Object state; // IpcValue.toWire() result

  Map<String, dynamic> toWire() {
    final m = <String, dynamic>{
      'node': node,
      'state': state,
    };
    if (key != null) m['key'] = key;
    return m;
  }

  @override
  String toString() => 'ConvergedEntry(node=$node, key=$key, state=$state)';
}

/// A state-based CRDT plane runtime with anti-entropy.
class CrdtPlaneRuntime {
  CrdtPlaneRuntime(this._peer);

  final int _peer;

  /// Per-node winning op (greatest stamp).
  final Map<int, CrdtOp> _winning = {};

  /// Op-log dedup keys: `"$node|$wallTime|$logical|$peer"`.
  final Set<String> _log = {};

  /// All ops in insertion order (for delta sync).
  final List<CrdtOp> _ops = [];

  /// Node key → node id mapping.
  final Map<String, int> _keyToNode = {};
  final Map<int, String?> _nodeToKey = {};

  /// Per-peer frontier (greatest stamp seen).
  final Map<int, WireStamp> _frontier = {};

  /// Known membership.
  final Set<int> _membership = {};

  int get peer => _peer;
  int get size => _winning.length;
  bool get isEmpty => _winning.isEmpty;

  String _dedupKey(int node, WireStamp stamp) =>
      '$node|${stamp.wallTime}|${stamp.logical}|${stamp.peer}';

  int _resolveNode(CrdtOp op) {
    final key = op.key;
    if (key != null) {
      final keyStr = key.toWire();
      final existing = _keyToNode[keyStr];
      if (existing != null) return existing;
      _keyToNode[keyStr] = op.node;
      _nodeToKey[op.node] = keyStr;
    } else {
      _nodeToKey.putIfAbsent(op.node, () => null);
    }
    return op.node;
  }

  void _observeStamp(WireStamp stamp) {
    _membership.add(stamp.peer);
    final current = _frontier[stamp.peer];
    if (current == null || _compareStamp(stamp, current) > 0) {
      _frontier[stamp.peer] = stamp;
    }
  }

  /// Ingest a list of ops (from a [CrdtSync] frame). Returns the number of
  /// newly applied ops (0 = idempotent re-delivery).
  int ingestOps(List<CrdtOp> ops, [int nowMicros = 0]) {
    var applied = 0;
    for (final op in ops) {
      final dk = _dedupKey(op.node, op.stamp);
      if (_log.contains(dk)) continue;
      _log.add(dk);
      _ops.add(op);
      applied++;

      _observeStamp(op.stamp);
      _resolveNode(op);

      final existing = _winning[op.node];
      if (existing == null || _compareStamp(op.stamp, existing.stamp) > 0) {
        _winning[op.node] = op;
      }
    }
    return applied;
  }

  /// Ingest a [CrdtSync] frame. Returns the number of newly applied ops.
  int ingest(CrdtSync sync, [int nowMicros = 0]) {
    // Observe frontier stamps.
    for (final entry in sync.frontier) {
      _observeStamp(entry.stamp);
    }
    return ingestOps(sync.ops, nowMicros);
  }

  /// The winning op for [node], or null.
  CrdtOp? winningOp(int node) => _winning[node];

  /// The winning state (as wire) for [node], or null.
  Object? value(int node) => _winning[node]?.state.toWire();

  /// All node ids (ascending).
  List<int> nodes() => _winning.keys.toList()..sort();

  /// The converged state: one entry per node (ascending), with the winning
  /// op's key and state wire form.
  List<ConvergedEntry> converged() {
    final sorted = nodes();
    return [
      for (final node in sorted)
        ConvergedEntry(
          node: node,
          key: _nodeToKey[node],
          state: _winning[node]!.state.toWire(),
        ),
    ];
  }

  /// Known peer ids (ascending).
  List<int> membership() => _membership.toList()..sort();

  /// Frontier entries (ascending by peer).
  List<MapEntry<int, WireStamp>> frontierEntries() {
    final entries = _frontier.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return entries.map((e) => MapEntry(e.key, e.value)).toList();
  }

  /// The full op log.
  List<CrdtOp> get ops => List.unmodifiable(_ops);

  int _compareStamp(WireStamp a, WireStamp b) {
    final w = a.wallTime.compareTo(b.wallTime);
    if (w != 0) return w;
    final l = a.logical.compareTo(b.logical);
    if (l != 0) return l;
    return a.peer.compareTo(b.peer);
  }
}
