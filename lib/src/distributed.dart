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

  // -- Reactive family sync (#lzfamilysync) --------------------------------- //
  //
  // A keyed family registered under a namespace syncs as a unit: an inbound keyed
  // op whose first key segment names a registered family MATERIALIZES the entry
  // on ingest (instead of being dropped/mis-addressed), so membership propagates,
  // values are adopted, LWW updates converge, re-ingest is idempotent, and a
  // derived aggregate over the family (e.g. `count_true`) converges. Mirrors
  // `lazily-js/src/distributed.js` family-sync + Go `familysync_conformance_test`
  // and the FamilySync.lean laws (applyOp_absent_adopts, present_merge,
  // applyOp_idem, aggregate_converges). The membership epoch is the reactive
  // signal a derived aggregate reads so a remote-added key forces a recompute.

  /// Registered family namespaces (materialize-on-ingest is armed for these).
  final Set<String> _families = {};

  /// Per-namespace materialized member keys, in first-materialization order.
  final Map<String, List<String>> _familyMembers = {};

  /// Monotone membership signal — bumped whenever a family entry materializes.
  int _familyEpoch = 0;

  /// Base node id for entries a family mints locally (`familySetLww`); high
  /// enough to avoid colliding with application-assigned node ids. Family entry
  /// nodes are resolved by wire key, never by raw id.
  static const int _familyNodeBase = 0x1000000000000; // 2^48
  int _nextFamilyNode = _familyNodeBase;

  // Local HLC-lite stamp generator (for locally-produced family ops).
  int _hlcWall = 0;
  int _hlcLogical = 0;

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
      _resolveNodeForFamily(op);

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

  /// A full anti-entropy sync frame (this runtime's frontier + op log) to hand
  /// to a peer's [ingest]. The Dart analog of the Zig `syncFrame`.
  CrdtSync syncFrame() => CrdtSync(
        frontier: [
          for (final e in frontierEntries()) StampFrontierEntry(e.key, e.value),
        ],
        ops: List<CrdtOp>.of(_ops),
      );

  // -- Reactive family sync (#lzfamilysync) --------------------------------- //

  /// Register a last-writer-wins family under [namespace]. Arms
  /// materialize-on-ingest: an inbound keyed op whose first key segment is
  /// [namespace] materializes a fresh entry on [ingest] instead of being
  /// dropped, so membership propagates and a derived aggregate over the family
  /// converges. Returns `this` for chaining.
  CrdtPlaneRuntime registerFamilyLww(String namespace) {
    _families.add(namespace);
    _familyMembers.putIfAbsent(namespace, () => <String>[]);
    return this;
  }

  /// The membership signal (`#lzfamilysync`): a monotone counter bumped whenever
  /// a family entry materializes. A derived aggregate over the family reads it,
  /// so a remote-added key forces a recompute.
  int membershipEpoch() => _familyEpoch;

  /// The materialized member keys of family [namespace] (full `ns/suffix`
  /// paths), in first-materialization order.
  List<String> familyKeys(String namespace) =>
      List<String>.of(_familyMembers[namespace] ?? const []);

  /// The current converged boolean value of family entry `namespace/keySuffix`,
  /// or `null` if the entry is not present. Each entry is a one-byte inline LWW
  /// register (`[0]`/`[1]`).
  bool? familyValueLww(String namespace, String keySuffix) {
    final node = _keyToNode['$namespace/$keySuffix'];
    if (node == null) return null;
    final state = _winning[node]?.state;
    if (state is! IpcValueInline) return null;
    return state.bytes.isNotEmpty && state.bytes[0] != 0;
  }

  /// A derived aggregate over family [namespace]: the count of member entries
  /// whose value is `true`. Models a reactive derived count (e.g. a live-editor
  /// open-document count); converges across replicas (aggregate_converges).
  int familyCountTrue(String namespace) {
    var count = 0;
    for (final key in _familyMembers[namespace] ?? const <String>[]) {
      final node = _keyToNode[key];
      final state = node == null ? null : _winning[node]?.state;
      if (state is IpcValueInline &&
          state.bytes.isNotEmpty &&
          state.bytes[0] != 0) {
        count++;
      }
    }
    return count;
  }

  /// Insert or update the local LWW family entry `namespace/keySuffix` to the
  /// boolean [value] at [nowMicros], returning the [CrdtOp] to broadcast (or
  /// `null` for a value-preserving update). Materializes the entry (minting a
  /// local node + bumping the membership epoch) on first insert.
  CrdtOp? familySetLww(
      String namespace, String keySuffix, bool value, int nowMicros) {
    final keyStr = '$namespace/$keySuffix';
    var node = _keyToNode[keyStr];
    if (node == null) {
      node = _mintFamilyNode();
      _keyToNode[keyStr] = node;
      _nodeToKey[node] = keyStr;
      _recordFamilyMember(namespace, keyStr);
      _bumpFamilyEpoch();
    }
    final stamp = _nextStamp(nowMicros);
    final op = CrdtOp(
      node: node,
      key: NodeKey(keyStr),
      stamp: stamp,
      state: IpcValue.inline(<int>[value ? 1 : 0]),
    );
    final dk = _dedupKey(node, stamp);
    if (_log.contains(dk)) return null;
    _log.add(dk);
    _ops.add(op);
    _observeStamp(stamp);
    final existing = _winning[node];
    if (existing == null || _compareStamp(stamp, existing.stamp) > 0) {
      _winning[node] = op;
    }
    return op;
  }

  int _mintFamilyNode() {
    while (_winning.containsKey(_nextFamilyNode) ||
        _nodeToKey.containsKey(_nextFamilyNode)) {
      _nextFamilyNode++;
    }
    return _nextFamilyNode++;
  }

  void _recordFamilyMember(String namespace, String key) {
    final members = _familyMembers.putIfAbsent(namespace, () => <String>[]);
    if (!members.contains(key)) members.add(key);
  }

  void _bumpFamilyEpoch() => _familyEpoch++;

  WireStamp _nextStamp(int nowMicros) {
    if (nowMicros > _hlcWall) {
      _hlcWall = nowMicros;
      _hlcLogical = 0;
    } else {
      _hlcLogical++;
    }
    return WireStamp(wallTime: _hlcWall, logical: _hlcLogical, peer: _peer);
  }

  /// Family-aware node resolution for [ingestOps]: a keyed op for a registered
  /// family whose entry is not yet known materializes it (records membership +
  /// bumps the epoch) instead of being dropped. Otherwise falls back to the
  /// plain key→node registration.
  void _resolveNodeForFamily(CrdtOp op) {
    final key = op.key;
    if (key != null) {
      final keyStr = key.toWire();
      if (!_keyToNode.containsKey(keyStr)) {
        final namespace = keyStr.split('/').first;
        if (_families.contains(namespace)) {
          _keyToNode[keyStr] = op.node;
          _nodeToKey[op.node] = keyStr;
          _recordFamilyMember(namespace, keyStr);
          _bumpFamilyEpoch();
          return;
        }
      }
    }
    _resolveNode(op);
  }

  int _compareStamp(WireStamp a, WireStamp b) {
    final w = a.wallTime.compareTo(b.wallTime);
    if (w != 0) return w;
    final l = a.logical.compareTo(b.logical);
    if (l != 0) return l;
    return a.peer.compareTo(b.peer);
  }
}
