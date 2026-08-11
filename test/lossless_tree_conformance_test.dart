import 'dart:convert';
import 'dart:io';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

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

/// This runner's slice of the shared corpus. Root resolution — the
/// `LAZILY_SPEC_CONFORMANCE_DIR` override, the sibling-first-then-mirror
/// ordering, and the fail-closed behaviour when an explicit override cannot be
/// read — lives in `conformance_manifest.dart`, so every runner and the
/// coverage guard auditing them resolve ONE corpus (#lzoverrideallrunners).
const _family = 'lossless-tree';

String _fixturePath(String name) => specFixturePath('$_family/$name');

Map<String, dynamic> _loadFixture(String name) => attributeFixture(
        jsonDecode(File(_fixturePath(name)).specReadAsStringSync()))
    as Map<String, dynamic>;

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
    // The SAME diff a `sync` step computes — `deliver` differs from `sync` only
    // in WHICH of its entries reach `applyUpdate`, and in what sequence.
    final full = world.replicas[from]!.diff(world.replicas[to]!.frontier());
    // ONE `applyUpdate` call, carrying the selection exactly as
    // `deliverySequence` built it. Splitting it across calls would let each
    // fragment drain the dependency buffer on its own, which is precisely the
    // behaviour `order` exists to deny (#lzspecoutoforderfixtures).
    world.replicas[to]!
        .applyUpdate(TreeUpdate(deliverySequence(full, deliver)));
  } else if (on != null) {
    _applyOp(world, on, step);
  } else {
    throw StateError('unrecognized step: $step');
  }
}

/// The ops one `deliver` step hands to `applyUpdate`, in the sequence the
/// fixture asked for.
///
/// [full] is `from.diff(to.frontier())` — the same list a `sync` step delivers,
/// and already in canonical dotted `(counter, peer)` order (pinned directly by
/// `lossless_tree_diff_order_test.dart`, because the corpus addresses it
/// POSITIONALLY and cannot police the order itself).
///
/// The step carries EXACTLY ONE of two selectors, and they mean different
/// things:
///
/// * `only` — a SUBSET, delivered in canonical order. Which entries arrive is
///   the variable; the order is not. Indexes are sorted before selection so the
///   meaning does not quietly depend on how the fixture happened to list them.
/// * `order` — a SEQUENCE. The listed indexes are delivered in the LISTED
///   sequence, unsorted, and the list need not be a permutation of the diff.
///   Re-sorting it destroys the fixture: measured in a sibling binding, a
///   runner that sorted `order` went GREEN against a library with NO dependency
///   buffer at all, because the ops then arrived parent-before-child and
///   nothing ever needed buffering (#lzspecoutoforderfixtures).
///
/// An out-of-range index FAILS rather than clamping or being dropped: clamping
/// would silently deliver a different batch than the fixture named, which is
/// the same class of lie as re-sorting.
List<TreeOp> deliverySequence(TreeUpdate full, Map<String, dynamic> deliver) {
  final only = deliver['only'];
  final order = deliver['order'];
  if (only != null && order != null) {
    throw StateError('deliver step carries BOTH `only` and `order`; they are '
        'different contracts (subset-in-canonical-order vs exact sequence) '
        'and one step cannot mean both: $deliver');
  }
  if (only == null && order == null) {
    throw StateError(
        'deliver step carries NEITHER `only` nor `order`: $deliver');
  }
  final indexes = ((only ?? order) as List).cast<int>();
  for (final i in indexes) {
    if (i < 0 || i >= full.ops.length) {
      throw StateError('deliver index $i is out of range for a diff of '
          '${full.ops.length} op(s): $deliver');
    }
  }
  if (only != null) {
    final canonical = List<int>.from(indexes)..sort();
    return canonical.map((i) => full.ops[i]).toList();
  }
  return indexes.map((i) => full.ops[i]).toList();
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

void _assertExpect(
    _World world, Map<String, dynamic> expectSpec, String scenario) {
  assertKeyIfPresent(expectSpec, 'render', (v) {
    expect(world.replicas['a']!.render(), v,
        reason: '$scenario: render on `a`');
  });
  // Keyed by replica label, bounded by the replicas this scenario really
  // built (`#lzsubblockkeyset`).
  assertKeysOfIfPresent(expectSpec, 'render_on', world.replicas.keys,
      (label, want) {
    expect(world.replicas[label]!.render(), want,
        reason: '$scenario: render on `$label`');
  },
      reason:
          '$scenario: `render_on` names a replica this scenario never built');
  assertKeyIfPresent(expectSpec, 'live_nodes', (v) {
    expect(world.replicas['a']!.liveNodeCount(), v,
        reason: '$scenario: live_nodes on `a`');
  });
  assertKeyIfPresent(expectSpec, 'converged', (v) {
    // The fixture value names WHICH replicas must agree; it reaches the
    // comparison by selecting every operand.
    final labels = (v as List).cast<String>();
    final first = world.replicas[labels.first]!.render();
    for (final name in labels.skip(1)) {
      expect(world.replicas[name]!.render(), first,
          reason: '$scenario: `${labels.first}`/`$name` should converge');
    }
  });
}

void _runFixture(String name) {
  final fixture = _loadFixture(name);
  var i = -1;
  for (final scenario in scenariosOf(fixture)) {
    i++;
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
    _assertExpect(world, assertionsOf(scenario['expect']), scenarioName);
  }
}

/// A replica that records what reaches [applyUpdate], and how many times.
///
/// The recording sits ON the `applyUpdate` boundary rather than beside it: a
/// spy the RUNNER writes to would prove only what the runner reported, and a
/// runner that recorded the listed sequence and then sorted it before calling
/// the library would satisfy it.
class _RecordingTree extends LosslessTreeCrdt {
  _RecordingTree(int peer) : super(peer);

  final List<List<TreeOpId>> batches = [];

  @override
  void applyUpdate(TreeUpdate update) {
    batches.add(update.ops.map((op) => op.id).toList());
    super.applyUpdate(update);
  }
}

/// A world shaped like `out_of_order_delivery_buffers.json`: replica `a` holds
/// exactly three ops, and [b] holds none, so `a.diff(b.frontier())` returns all
/// three and index `i` addresses a known op.
_World _deliverWorld(_RecordingTree b) {
  final world = _World();
  world.replicas['a'] = LosslessTreeCrdt(1);
  world.buildChildren({
    'children': [
      {'label': 'para', 'element': 'para', 'children': <dynamic>[]}
    ],
  }, TreeNodeId.root);
  final a = world.replicas['a']!;
  world.ids['outer'] =
      a.createNode(world.id('para'), null, const NodeSeedElement('wrap'));
  world.ids['inner'] = a.createNode(
      world.id('outer'), null, const NodeSeedLeaf(LeafKind.raw, 'deep'));
  world.replicas['b'] = b;
  return world;
}

/// The canonical dotted order of the diff `_deliverWorld` sets up — the list
/// `deliver` indexes address.
List<TreeOpId> _canonicalIds(_World world) => world.replicas['a']!
    .diff(world.replicas['b']!.frontier())
    .ops
    .map((op) => op.id)
    .toList();

void main() {
  test(
      'conformance exact roundtrip', () => _runFixture('exact_roundtrip.json'));

  test('conformance one leaf edit delta',
      () => _runFixture('one_leaf_edit_delta.json'));

  test('conformance split merge', () => _runFixture('split_merge.json'));

  test('conformance concurrent insert same parent',
      () => _runFixture('concurrent_insert_same_parent.json'));

  test('conformance concurrent reorder and leaf edit',
      () => _runFixture('concurrent_reorder_and_leaf_edit.json'));

  test('conformance non contiguous anti entropy',
      () => _runFixture('non_contiguous_anti_entropy.json'));

  test('conformance token trivia preservation',
      () => _runFixture('token_trivia_preservation.json'));

  test('conformance invalid source roundtrip',
      () => _runFixture('invalid_source_roundtrip.json'));

  test('conformance concurrent conflict preserves text',
      () => _runFixture('concurrent_conflict_preserves_text.json'));

  // `apply_update` advances the Lamport counter past every observed op —
  // unconditionally, and BEFORE the idempotence skip — so a write minted AFTER
  // a sync outranks the stamps that sync delivered. The failure is SYMMETRIC
  // (both replicas converge on the wrong text), so `render_on` is the
  // load-bearing assertion here, not `converged` (#lzspecoutoforderfixtures).
  test('conformance apply update advances counter',
      () => _runFixture('apply_update_advances_counter.json'));

  // `apply_update` BUFFERS an op whose dependency has not arrived and retries
  // it as later ops in the SAME batch land. Needs `deliver.order`
  // (#lzspecoutoforderfixtures).
  test('conformance out of order delivery buffers',
      () => _runFixture('out_of_order_delivery_buffers.json'));

  // The `deliver` step's CONTRACT, asserted directly.
  //
  // A fixture cannot assert on how its own step was interpreted: an
  // `out_of_order_delivery_buffers.json` whose runner sorts `order` back into
  // canonical order still replays, still renders `deepX`, and still reports
  // green — against a library with no dependency buffer at all. Only a test
  // that watches the `applyUpdate` boundary can see the difference, so these
  // tests watch it.
  group('deliver step contract', () {
    test('`order` reaches applyUpdate in the LISTED sequence, in ONE call', () {
      final b = _RecordingTree(2);
      final world = _deliverWorld(b);
      final canonical = _canonicalIds(world);

      // Non-vacuity, asserted before the check it protects: the requested
      // sequence must genuinely differ from canonical order, or an
      // `order`-sorting runner would satisfy the assertion below.
      final wanted = [canonical[2], canonical[1], canonical[0]];
      expect(wanted, isNot(equals(canonical)),
          reason: 'the reversed sequence must differ from canonical order');

      _applyStep(world, {
        'deliver': {
          'from': 'a',
          'to': 'b',
          'order': [2, 1, 0],
        },
      });

      expect(b.batches.length, 1,
          reason: 'the whole selection must reach `applyUpdate` as ONE batch; '
              'splitting it would let each fragment drain the dependency '
              'buffer on its own');
      expect(b.batches.single, equals(wanted),
          reason: 'the ops must reach `applyUpdate` in the sequence `order` '
              'listed, UNSORTED');
    });

    test('`order` need not be a permutation of the diff', () {
      final b = _RecordingTree(2);
      final world = _deliverWorld(b);
      final canonical = _canonicalIds(world);

      _applyStep(world, {
        'deliver': {
          'from': 'a',
          'to': 'b',
          'order': [2, 0],
        },
      });

      expect(b.batches.single, equals([canonical[2], canonical[0]]));
    });

    test('an out-of-range `order` index FAILS rather than clamping', () {
      final b = _RecordingTree(2);
      final world = _deliverWorld(b);
      expect(_canonicalIds(world).length, 3,
          reason: 'index 3 is out of range only while the diff holds 3 ops');

      expect(
          () => _applyStep(world, {
                'deliver': {
                  'from': 'a',
                  'to': 'b',
                  'order': [0, 3],
                },
              }),
          throwsA(isA<StateError>()));
      expect(b.batches, isEmpty,
          reason: 'a rejected step must deliver NOTHING — not a clamped or '
              'truncated batch');
    });

    test('a negative `order` index FAILS rather than wrapping', () {
      final b = _RecordingTree(2);
      final world = _deliverWorld(b);
      expect(
          () => _applyStep(world, {
                'deliver': {
                  'from': 'a',
                  'to': 'b',
                  'order': [-1],
                },
              }),
          throwsA(isA<StateError>()));
      expect(b.batches, isEmpty);
    });

    test('an out-of-range `only` index FAILS rather than clamping', () {
      final b = _RecordingTree(2);
      final world = _deliverWorld(b);
      expect(
          () => _applyStep(world, {
                'deliver': {
                  'from': 'a',
                  'to': 'b',
                  'only': [0, 9],
                },
              }),
          throwsA(isA<StateError>()));
      expect(b.batches, isEmpty);
    });

    test('carrying BOTH `only` and `order` is rejected', () {
      final b = _RecordingTree(2);
      final world = _deliverWorld(b);
      expect(
          () => _applyStep(world, {
                'deliver': {
                  'from': 'a',
                  'to': 'b',
                  'only': [0],
                  'order': [0],
                },
              }),
          throwsA(isA<StateError>()));
      expect(b.batches, isEmpty);
    });

    test('carrying NEITHER `only` nor `order` is rejected', () {
      final b = _RecordingTree(2);
      final world = _deliverWorld(b);
      expect(
          () => _applyStep(world, {
                'deliver': {'from': 'a', 'to': 'b'},
              }),
          throwsA(isA<StateError>()));
      expect(b.batches, isEmpty);
    });

    test('`only` still delivers its subset in CANONICAL order', () {
      final b = _RecordingTree(2);
      final world = _deliverWorld(b);
      final canonical = _canonicalIds(world);

      _applyStep(world, {
        'deliver': {
          'from': 'a',
          'to': 'b',
          'only': [2, 0],
        },
      });

      expect(b.batches.single, equals([canonical[0], canonical[2]]),
          reason: '`only` selects a SUBSET; the order stays canonical however '
              'the fixture listed the indexes');
    });
  });

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
