import 'dart:convert';
import 'dart:io';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

/// Replays the canonical `lazily-spec/conformance/lossless-tree/` compute
/// fixtures against the native [LosslessTreeCrdt] — the same
/// `{scenarios: [{seed, steps, expect}]}` shape and the same `label`→id
/// addressing every binding uses. Each scenario builds `seed.tree` on replica
/// `a`, replays the schedule of ops / forks / anti-entropy syncs across named
/// replicas, and asserts exact rendered text, live-node counts, and convergence
/// across delivery orders. The lossless invariant `render(tree) == source_text`
/// is what every assertion checks.
///
/// Mirrors `lazily-kt/.../LosslessTreeCrdtConformanceTest.kt`.

final _localDir = Directory('test/conformance/lossless-tree');
final _specDir = Directory('../lazily-spec/conformance/lossless-tree');

String _fixturePath(String name) {
  if (_localDir.existsSync()) {
    final local = _localDir.resolveSymbolicLinksSync() + '/$name';
    if (File(local).existsSync()) return local;
  }
  final sibling = _specDir.resolveSymbolicLinksSync() + '/$name';
  if (File(sibling).existsSync()) return sibling;
  throw StateError('lossless-tree fixture not found: $name');
}

Map<String, dynamic> _loadFixture(String name) =>
    jsonDecode(File(_fixturePath(name)).readAsStringSync()) as Map<String, dynamic>;

class _World {
  final Map<String, LosslessTreeCrdt> replicas = {};
  final Map<String, TreeNodeId> ids = {};

  TreeNodeId id(String label) =>
      ids[label] ?? (throw StateError('unknown node label `$label`'));

  TreeNodeId? afterOf(Map<String, dynamic> op) {
    final after = op['after'];
    if (after == null) return null;
    return id(after as String);
  }

  void buildChildren(Map<String, dynamic> spec, TreeNodeId parent) {
    final children = spec['children'];
    if (children == null) return;
    TreeNodeId? prev;
    for (final childEl in children as List) {
      final child = childEl as Map<String, dynamic>;
      final label = child['label'] as String;
      final nodeId = replicas['a']!.createNode(parent, prev, nodeSeed(child));
      ids[label] = nodeId;
      buildChildren(child, nodeId);
      prev = nodeId;
    }
  }
}

LeafKind _leafKind(String s) {
  switch (s) {
    case 'token':
      return LeafKind.token;
    case 'trivia':
      return LeafKind.trivia;
    case 'raw':
      return LeafKind.raw;
    case 'error':
      return LeafKind.error;
    default:
      throw StateError('unknown leaf kind: $s');
  }
}

NodeSeed nodeSeed(Map<String, dynamic> spec) {
  final element = spec['element'];
  if (element != null) return NodeSeedElement(element as String);
  final leaf = spec['leaf'] as Map<String, dynamic>?;
  if (leaf == null) {
    throw StateError('node spec has neither element nor leaf: $spec');
  }
  return NodeSeedLeaf(
    _leafKind(leaf['kind'] as String),
    leaf['text'] as String,
  );
}

void _applyStep(_World world, Map<String, dynamic> step) {
  final fork = step['fork'] as String?;
  final sync = step['sync'] as Map<String, dynamic>?;
  final deliver = step['deliver'] as Map<String, dynamic>?;
  final on = step['on'] as String?;
  if (fork != null) {
    final peer = step['peer'] as int;
    world.replicas[fork] = world.replicas['a']!.fork(peer);
  } else if (sync != null) {
    final from = sync['from'] as String;
    final to = sync['to'] as String;
    final update = world.replicas[from]!.diff(world.replicas[to]!.frontier());
    world.replicas[to]!.applyUpdate(update);
  } else if (deliver != null) {
    final from = deliver['from'] as String;
    final to = deliver['to'] as String;
    final full = world.replicas[from]!.diff(world.replicas[to]!.frontier());
    final only = (deliver['only'] as List).cast<int>();
    world.replicas[to]!
        .applyUpdate(TreeUpdate(only.map((i) => full.ops[i]).toList()));
  } else if (on != null) {
    _applyOp(world, on, step);
  } else {
    throw StateError('unrecognized step: $step');
  }
}

void _applyOp(_World world, String on, Map<String, dynamic> op) {
  final replica = world.replicas[on]!;
  final kind = op['op'] as String;
  switch (kind) {
    case 'create':
      final parent = world.id(op['parent'] as String);
      final after = world.afterOf(op);
      final label = op['label'] as String;
      world.ids[label] = replica.createNode(parent, after, nodeSeed(op));
    case 'edit_leaf':
      final node = world.id(op['node'] as String);
      final at = op['at_byte'] as int;
      final del = op['delete_bytes'] as int? ?? 0;
      final insert = op['insert'] as String? ?? '';
      replica.editLeaf(node, at, del, insert);
    case 'split':
      final node = world.id(op['node'] as String);
      final at = op['at_byte'] as int;
      final label = op['new_label'] as String;
      world.ids[label] = replica.splitLeaf(node, at);
    case 'merge_leaves':
      final left = world.id(op['left'] as String);
      final right = world.id(op['right'] as String);
      replica.mergeAdjacentLeaves(left, right);
    case 'reorder':
      final node = world.id(op['node'] as String);
      replica.reorderChild(node, world.afterOf(op));
    case 'tombstone':
      final node = world.id(op['node'] as String);
      replica.tombstoneNode(node);
    default:
      throw StateError('unknown op: $kind');
  }
}

void _assertExpect(_World world, Map<String, dynamic> expectSpec, String scenario) {
  final render = expectSpec['render'] as String?;
  if (render != null) {
    expect(world.replicas['a']!.render(), render, reason: '$scenario: render on `a`');
  }
  final renderOn = expectSpec['render_on'] as Map<String, dynamic>?;
  if (renderOn != null) {
    for (final entry in renderOn.entries) {
      expect(world.replicas[entry.key]!.render(), entry.value,
          reason: '$scenario: render on `${entry.key}`');
    }
  }
  final liveNodes = expectSpec['live_nodes'] as int?;
  if (liveNodes != null) {
    expect(world.replicas['a']!.liveNodeCount(), liveNodes,
        reason: '$scenario: live_nodes on `a`');
  }
  final converged = expectSpec['converged'] as List?;
  if (converged != null) {
    final labels = converged.cast<String>();
    final first = world.replicas[labels.first]!.render();
    for (final name in labels.skip(1)) {
      expect(world.replicas[name]!.render(), first,
          reason: '$scenario: `${labels.first}`/`$name` should converge');
    }
  }
}

void _runFixture(String name) {
  final fixture = _loadFixture(name);
  final scenarios = (fixture['scenarios'] as List).cast<Map<String, dynamic>>();
  for (var i = 0; i < scenarios.length; i++) {
    final scenario = scenarios[i];
    final scenarioName =
        scenario['name'] != null ? '$name[${scenario['name']}]' : '$name[$i]';
    final seed = scenario['seed'] as Map<String, dynamic>;
    final peer = seed['peer'] as int;
    final world = _World();
    world.replicas['a'] = LosslessTreeCrdt(peer);
    world.buildChildren(seed['tree'] as Map<String, dynamic>, TreeNodeId.root);
    final steps = scenario['steps'];
    if (steps != null) {
      for (final step in steps as List) {
        _applyStep(world, step as Map<String, dynamic>);
      }
    }
    _assertExpect(world, scenario['expect'] as Map<String, dynamic>, scenarioName);
  }
}

void main() {
  test('conformance exact roundtrip', () => _runFixture('exact_roundtrip.json'));

  test('conformance one leaf edit delta', () => _runFixture('one_leaf_edit_delta.json'));

  test('conformance split merge', () => _runFixture('split_merge.json'));

  test('conformance concurrent insert same parent', () =>
      _runFixture('concurrent_insert_same_parent.json'));

  test('conformance concurrent reorder and leaf edit', () =>
      _runFixture('concurrent_reorder_and_leaf_edit.json'));

  test('conformance non contiguous anti entropy', () =>
      _runFixture('non_contiguous_anti_entropy.json'));

  test('conformance token trivia preservation', () =>
      _runFixture('token_trivia_preservation.json'));

  test('conformance invalid source roundtrip', () =>
      _runFixture('invalid_source_roundtrip.json'));

  test('conformance concurrent conflict preserves text', () =>
      _runFixture('concurrent_conflict_preserves_text.json'));

  group('wire round-trip parity', () {
    test('TreeUpdate toWire/fromWire is byte-stable', () {
      final tree = LosslessTreeCrdt(1);
      final parent = TreeNodeId.root;
      final leaf = tree.createNode(
          parent, null, const NodeSeedLeaf(LeafKind.raw, 'hello'));
      final newNode = tree.splitLeaf(leaf, 2);
      final update = tree.diff(TreeVersionFrontier());
      final wire = update.toWire();
      // Round-trip through JSON — the true wire-parity check.
      final rt = TreeUpdate.fromWire(jsonDecode(jsonEncode(wire)));
      expect(jsonEncode(rt.toWire()), jsonEncode(wire));

      // The wire uses PascalCase tags and u8 frac arrays (no base64).
      final encoded = jsonEncode(wire);
      expect(encoded, contains('"CreateNode"'));
      expect(encoded, contains('"SplitLeaf"'));
      expect(encoded, contains('"frac"'));
      expect(encoded, isNot(contains('base64')));

      // Node ids serialize as bare {counter, peer} op ids.
      expect((wire['ops'] as List).first, isA<Map>());
      expect(newNode, isNotNull);
    });

    test('editLeaf then diff carries LeafEdit with TextOp delta', () {
      final tree = LosslessTreeCrdt(1);
      final leaf = tree.createNode(
          TreeNodeId.root, null, const NodeSeedLeaf(LeafKind.token, 'abc'));
      tree.editLeaf(leaf, 1, 1, 'X');
      final update = tree.diff(TreeVersionFrontier());
      final wire = update.toWire();
      final rt = TreeUpdate.fromWire(jsonDecode(jsonEncode(wire)));
      expect(jsonEncode(rt.toWire()), jsonEncode(wire));
      expect(jsonEncode(wire), contains('"LeafEdit"'));
    });
  });
}
