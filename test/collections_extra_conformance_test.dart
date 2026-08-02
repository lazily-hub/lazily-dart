import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:lazily/lazily.dart';

import 'conformance_manifest.dart';

/// Replay the lazily-spec collection conformance fixtures:
/// - textcrdt_convergence.json
/// - textcrdt_delta_sync.json
/// - seqcrdt_convergence.json
/// - semtree_incremental.json
/// - stableid_alignment.json
///
/// Prefers the sibling `../lazily-spec/conformance/collections/` checkout,
/// falling back to the mirrored `test/conformance/collections/` copies.

Map<String, dynamic> _loadFixture(String name) {
  final candidates = [
    '../lazily-spec/conformance/collections/$name',
    'test/conformance/collections/$name',
  ];
  for (final path in candidates) {
    final f = File(path);
    if (f.existsSync()) {
      return attributeFixture(jsonDecode(f.specReadAsStringSync()))
          as Map<String, dynamic>;
    }
  }
  throw StateError('fixture not found: $name');
}

void main() {
  group('TextCrdt convergence', () {
    final fixture = _loadFixture('textcrdt_convergence.json');
    for (final scenario in scenariosOf(fixture)) {
      test(scenario['name'] as String, () {
        _playTextCrdtScenario(scenario);
      });
    }
  });

  group('TextCrdt delta sync', () {
    final fixture = _loadFixture('textcrdt_delta_sync.json');
    for (final scenario in scenariosOf(fixture)) {
      test(scenario['name'] as String, () {
        _playTextCrdtDeltaScenario(scenario);
      });
    }
  });

  group('SeqCrdt convergence', () {
    final fixture = _loadFixture('seqcrdt_convergence.json');
    for (final scenario in scenariosOf(fixture)) {
      test(scenario['name'] as String, () {
        _playSeqCrdtScenario(scenario);
      });
    }
  });

  group('SemTree incremental', () {
    final fixture = _loadFixture('semtree_incremental.json');
    for (final scenario in scenariosOf(fixture)) {
      test(scenario['name'] as String, () {
        _playSemTreeScenario(scenario);
      });
    }
  });

  group('Stable-id alignment', () {
    final fixture = _loadFixture('stableid_alignment.json');
    for (final scenario in scenariosOf(fixture)) {
      test(scenario['name'] as String, () {
        _playStableIdScenario(scenario);
      });
    }
  });
}

// ---------------------------------------------------------------------------
// TextCrdt convergence
// ---------------------------------------------------------------------------

void _playTextCrdtScenario(Map<String, dynamic> scenario) {
  final replicas = <String, TextCrdt>{};

  // Seed: either a peer+text object or a plain string.
  final seed = scenario['seed'];
  final replicaSpec = scenario['replica'];
  if (seed != null) {
    if (seed is String) {
      final peer =
          replicaSpec != null ? (replicaSpec as Map)['peer'] as int : 1;
      replicas['a'] = TextCrdt.fromStr(peer, seed);
    } else if (seed is Map) {
      final peer = seed['peer'] as int;
      final text = seed['text'] as String;
      replicas['a'] = TextCrdt.fromStr(peer, text);
    }
  } else if (replicaSpec != null) {
    final peer = (replicaSpec as Map)['peer'] as int;
    replicas['a'] = TextCrdt(peer);
  } else {
    replicas['a'] = TextCrdt(1);
  }

  for (final step in (scenario['steps'] as List).cast<Map<String, dynamic>>()) {
    _applyTextCrdtStep(replicas, step);
  }

  final expect_ = assertionsOfOrNull(scenario['expect']);
  if (expect_ != null) {
    _checkTextCrdtExpect(replicas, expect_);
  }
}

void _applyTextCrdtStep(
    Map<String, TextCrdt> replicas, Map<String, dynamic> step) {
  final onReplica = step['on'] as String? ?? 'a';
  final forkName = step['fork'] as String?;
  final forkPeer = step['peer'];
  if (forkName != null) {
    replicas[forkName] =
        (replicas[onReplica] ?? replicas['a']!).fork(forkPeer as int);
    return;
  }
  final cloneName = step['clone'] as String?;
  final cloneFrom = step['from'];
  if (cloneName != null) {
    replicas[cloneName] = (replicas[cloneFrom] ?? replicas['a']!).clone();
    return;
  }
  final merge = step['merge'] as Map<String, dynamic>?;
  if (merge != null) {
    final into = merge['into'] as String;
    final from = merge['from'] as String;
    replicas[into]!.merge(replicas[from]!);
    return;
  }
  final op = step['op'] as String?;
  if (op != null) {
    final crdt = replicas[onReplica]!;
    switch (op) {
      case 'insert':
        crdt.insert(step['index'] as int, step['ch'] as String);
      case 'insert_str':
        crdt.insertStr(step['index'] as int, step['str'] as String);
      case 'delete':
        crdt.delete(step['index'] as int);
      case 'gc':
        final stable = step['stable'] as bool;
        final collected = crdt.gcWith((_) => stable);
        final expectCollected = step['expect_collected'] as int?;
        if (expectCollected != null) {
          expect(collected, expectCollected, reason: 'gc collected count');
        }
      // Fail closed on an unrecognised `op` (`#lzscenariobodyskip`): the chain
      // used to fall out of the switch and `return`, so a fixture naming an
      // operation this runner has not implemented mutated nothing and the
      // scenario's later expectations were checked against an untouched CRDT.
      default:
        fail('TextCrdt step: unknown op `$op`');
    }
    return;
  }
  // Same fail-open one level up: a step whose shape matches none of the
  // branches above was a silent no-op (`#lzscenariobodyskip`).
  fail('TextCrdt step: unrecognised step shape ${step.keys.toList()}');
}

void _checkTextCrdtExpect(
    Map<String, TextCrdt> replicas, Map<String, dynamic> expect_) {
  assertKeyIfPresent(
      expect_, 'text', (v) => expect(replicas['a']!.text(), v, reason: 'text'));
  assertKeyIfPresent(
      expect_, 'len', (v) => expect(replicas['a']!.len(), v, reason: 'len'));
  assertKeyIfPresent(expect_, 'texts_equal', (v) {
    // The fixture value names WHICH replicas must agree; it reaches the
    // comparison by selecting both operands.
    final pair = ((v as List)[0] as List);
    final a = pair[0] as String;
    final b = pair[1] as String;
    expect(replicas[a]!.text(), replicas[b]!.text(),
        reason: 'texts_equal $a/$b');
  });
  assertKeyIfPresent(expect_, 'a_starts_with',
      (v) => expect(replicas['a']!.text(), startsWith(v as String)));
  assertKeyIfPresent(expect_, 'a_ends_with',
      (v) => expect(replicas['a']!.text(), endsWith(v as String)));
  assertKeyIfPresent(expect_, 'tombstone_count',
      (v) => expect(replicas['a']!.tombstoneCount(), v));
}

// ---------------------------------------------------------------------------
// TextCrdt delta sync
// ---------------------------------------------------------------------------

void _playTextCrdtDeltaScenario(Map<String, dynamic> scenario) {
  final replicas = <String, TextCrdt>{};
  final seed = scenario['seed'] as Map<String, dynamic>;
  replicas['a'] = TextCrdt.fromStr(seed['peer'] as int, seed['text'] as String);

  for (final step in (scenario['steps'] as List).cast<Map<String, dynamic>>()) {
    _applyTextCrdtDeltaStep(replicas, step);
  }

  final expect_ = assertionsOfOrNull(scenario['expect']);
  if (expect_ != null) {
    _checkTextCrdtDeltaExpect(replicas, expect_);
  }
}

void _applyTextCrdtDeltaStep(
    Map<String, TextCrdt> replicas, Map<String, dynamic> step) {
  final onReplica = step['on'] as String? ?? 'a';
  final forkName = step['fork'] as String?;
  if (forkName != null) {
    replicas[forkName] = replicas[onReplica]!.fork(step['peer'] as int);
    return;
  }
  final newName = step['new'] as String?;
  if (newName != null) {
    replicas[newName] = TextCrdt(step['peer'] as int);
    return;
  }
  final snapshot = step['snapshot'] as Map<String, dynamic>?;
  if (snapshot != null) {
    final from = snapshot['from'] as String;
    final into = snapshot['into'] as String;
    final peer = snapshot['peer'] as int;
    final ops = replicas[from]!.deltaSince({});
    replicas[into] = TextCrdt(peer);
    final changed = replicas[into]!.applyDelta(ops);
    final expectChanged = step['expect_changed'] as bool?;
    if (expectChanged != null) {
      expect(changed, expectChanged, reason: 'snapshot apply_delta changed');
    }
    return;
  }
  final exchange = step['exchange'];
  if (exchange is List) {
    final a = exchange[0] as String;
    final b = exchange[1] as String;
    // Bidirectional delta exchange.
    final opsAB = replicas[a]!.deltaSince(replicas[b]!.versionVector());
    final opsBA = replicas[b]!.deltaSince(replicas[a]!.versionVector());
    replicas[a]!.applyDelta(opsBA);
    replicas[b]!.applyDelta(opsAB);
    return;
  }
  final delta = step['delta'] as Map<String, dynamic>?;
  if (delta != null) {
    final into = delta['into'] as String;
    final from = delta['from'] as String;
    final ops = replicas[from]!.deltaSince(replicas[into]!.versionVector());
    final changed = replicas[into]!.applyDelta(ops);
    final expectChanged = step['expect_changed'] as bool?;
    if (expectChanged != null) {
      expect(changed, expectChanged, reason: 'delta apply changed');
    }
    return;
  }
  final op = step['op'] as String?;
  if (op != null) {
    final crdt = replicas[onReplica]!;
    switch (op) {
      case 'insert':
        crdt.insert(step['index'] as int, step['ch'] as String);
      case 'insert_str':
        crdt.insertStr(step['index'] as int, step['str'] as String);
      case 'delete':
        crdt.delete(step['index'] as int);
      // Fail closed on an unrecognised `op` (`#lzscenariobodyskip`) — see
      // `_applyTextCrdtStep`.
      default:
        fail('TextCrdt delta step: unknown op `$op`');
    }
    return;
  }
  fail('TextCrdt delta step: unrecognised step shape ${step.keys.toList()}');
}

void _checkTextCrdtDeltaExpect(
    Map<String, TextCrdt> replicas, Map<String, dynamic> expect_) {
  assertKeyIfPresent(expect_, 'texts_equal', (v) {
    final pair = ((v as List)[0] as List);
    final a = pair[0] as String;
    final b = pair[1] as String;
    expect(replicas[a]!.text(), replicas[b]!.text(), reason: 'texts_equal');
  });
  assertKeyIfPresent(expect_, 'text_on', (v) {
    for (final entry in (v as Map).entries) {
      expect(replicas[entry.key]!.text(), entry.value,
          reason: 'text_on ${entry.key}');
    }
  });
  assertKeyIfPresent(expect_, 'version_vector_on', (v) {
    for (final entry in (v as Map).entries) {
      final expected = (entry.value as Map)
          .map((k, v) => MapEntry(int.parse(k as String), v as int));
      expect(replicas[entry.key]!.versionVector(), expected,
          reason: 'version_vector_on ${entry.key}');
    }
  });
}

// ---------------------------------------------------------------------------
// SeqCrdt convergence
// ---------------------------------------------------------------------------

void _playSeqCrdtScenario(Map<String, dynamic> scenario) {
  final replicas = <String, SeqCrdt<String, dynamic>>{};
  final seed = scenario['seed'];
  int seedPeer = (scenario['replica'] as Map?)?['peer'] as int? ?? 1;
  if (seed != null) {
    final s = seed as Map<String, dynamic>;
    seedPeer = s['peer'] as int;
    replicas['a'] = SeqCrdt<String, dynamic>(seedPeer);
    for (final ins in (s['inserts'] as List).cast<Map<String, dynamic>>()) {
      replicas['a']!
          .insertBack(ins['id'] as String, ins['value'], ins['now'] as int);
    }
  } else {
    replicas['a'] = SeqCrdt<String, dynamic>(seedPeer);
  }

  for (final step in (scenario['steps'] as List).cast<Map<String, dynamic>>()) {
    _applySeqCrdtStep(replicas, step);
  }

  final expect_ = assertionsOfOrNull(scenario['expect']);
  if (expect_ != null) {
    _checkSeqCrdtExpect(replicas, expect_);
  }
}

void _applySeqCrdtStep(
    Map<String, SeqCrdt<String, dynamic>> replicas, Map<String, dynamic> step) {
  final onReplica = step['on'] as String? ?? 'a';
  final forkName = step['fork'] as String?;
  if (forkName != null) {
    replicas[forkName] = replicas[onReplica]!.fork(step['peer'] as int);
    return;
  }
  final cloneName = step['clone'] as String?;
  final cloneFrom = step['from'];
  if (cloneName != null) {
    replicas[cloneName] = replicas[cloneFrom]!.clone();
    return;
  }
  final merge = step['merge'] as Map<String, dynamic>?;
  if (merge != null) {
    final into = merge['into'] as String;
    final from = merge['from'] as String;
    final now = step['now'] as int;
    replicas[into]!.merge(replicas[from]!, now);
    return;
  }
  final op = step['op'] as String?;
  if (op != null) {
    final crdt = replicas[onReplica]!;
    final now = step['now'] as int;
    final id = step['id'] as String;
    switch (op) {
      case 'insert_back':
        crdt.insertBack(id, step['value'], now);
      case 'insert_front':
        crdt.insertFront(id, step['value'], now);
      case 'set_value':
        crdt.setValue(id, step['value'], now);
      case 'move_after':
        crdt.moveAfter(id, step['anchor'] as String, now);
      case 'move_before':
        crdt.moveBefore(id, step['anchor'] as String, now);
      case 'remove':
        crdt.remove(id, now);
      // Fail closed on an unrecognised `op` (`#lzscenariobodyskip`) — see
      // `_applyTextCrdtStep`.
      default:
        fail('SeqCrdt step: unknown op `$op`');
    }
    return;
  }
  fail('SeqCrdt step: unrecognised step shape ${step.keys.toList()}');
}

void _checkSeqCrdtExpect(Map<String, SeqCrdt<String, dynamic>> replicas,
    Map<String, dynamic> expect_) {
  // Determine which replica to check for bare fields (order, len, get).
  String primaryReplica = 'a';
  final ordersEqual = expect_['orders_equal'];
  if (ordersEqual is List && ordersEqual.isNotEmpty) {
    primaryReplica = ((ordersEqual[0] as List)[0] as String);
  }
  final orderOnRef = expect_['order_on'];
  if (orderOnRef is Map && orderOnRef.isNotEmpty) {
    primaryReplica = orderOnRef.keys.first;
  }

  assertKeyIfPresent(
      expect_,
      'order',
      (v) => expect(
          replicas[primaryReplica]!.order().map((s) => s.toString()).toList(),
          v));
  assertKeyIfPresent(
      expect_, 'len', (v) => expect(replicas[primaryReplica]!.len(), v));
  assertKeyIfPresent(expect_, 'get', (v) {
    for (final entry in (v as Map).entries) {
      expect(replicas[primaryReplica]!.get(entry.key), entry.value,
          reason: 'get ${entry.key}');
    }
  });
  assertKeyIfPresent(expect_, 'orders_equal', (v) {
    final pair = ((v as List)[0] as List);
    final a = pair[0] as String;
    final b = pair[1] as String;
    expect(replicas[a]!.order(), replicas[b]!.order(), reason: 'orders_equal');
  });
  assertKeyIfPresent(expect_, 'contains_all', (v) {
    for (final id in (v as List)) {
      expect(replicas[primaryReplica]!.contains(id.toString()), isTrue,
          reason: 'contains $id');
    }
  });
  assertKeyIfPresent(expect_, 'order_on', (v) {
    for (final entry in (v as Map).entries) {
      expect(replicas[entry.key]!.order().map((s) => s.toString()).toList(),
          entry.value,
          reason: 'order_on ${entry.key}');
    }
  });
  assertKeyIfPresent(expect_, 'get_on', (v) {
    for (final entry in (v as Map).entries) {
      final rep = replicas[entry.key]!;
      for (final kv in (entry.value as Map).entries) {
        expect(rep.get(kv.key), kv.value,
            reason: 'get_on ${entry.key}/${kv.key}');
      }
    }
  });
  assertKeyIfPresent(expect_, 'not_contains_on', (v) {
    for (final entry in (v as Map).entries) {
      final rep = replicas[entry.key]!;
      for (final id in (entry.value as List)) {
        expect(rep.contains(id.toString()), isFalse,
            reason: 'not_contains ${entry.key}/$id');
      }
    }
  });
}

// ---------------------------------------------------------------------------
// SemTree
// ---------------------------------------------------------------------------

void _playSemTreeScenario(Map<String, dynamic> scenario) {
  final ctx = Context();
  final foldName = scenario['fold'] as String;
  dynamic fold(dynamic v, List<dynamic> ds) {
    switch (foldName) {
      case 'sum':
        num sum = (v as num).toDouble();
        for (final d in ds) {
          sum += (d as num);
        }
        return sum.toInt() == sum ? sum.toInt() : sum;
      case 'count_positive':
        var count = 0;
        if ((v as num) > 0) count++;
        for (final d in ds) {
          if ((d as int) > 0) count++;
        }
        return count;
      default:
        throw StateError('unknown fold $foldName');
    }
  }

  final treeSpec = _parseTreeNode(scenario['tree'] as Map<String, dynamic>);
  final tree = SemTree.build<num, dynamic>(ctx, treeSpec, fold);

  // A downstream consumer of the root's derived value. `downstream_consumer_reran`
  // is a real observable fact — count the reruns rather than letting the fixture
  // value gate an assertion about something else. Built BEFORE the edit so the
  // initial run is excluded from the count.
  var downstreamRuns = 0;

  final expectInitial = assertionsOfOrNull(scenario['expect_initial']);
  if (expectInitial != null) {
    // `keys` deliberately does not count as a read, so the snapshot below is
    // taken without marking anything; every key then goes through assertKey.
    for (final key in expectInitial.keys.toList()) {
      assertKey(expectInitial, key, tree.nodeValue(key), 'initial $key');
    }
  }

  final downstream = ctx.effect((cx) {
    cx.get(tree.rootHandle());
    downstreamRuns++;
    return null;
  });
  final runsBeforeEdit = downstreamRuns;

  final edit = scenario['edit'];
  if (edit is Map) {
    tree.setValue(edit['id'] as String, edit['value'] as num);

    final expectAfter = assertionsOfOrNull(scenario['expect_after']);
    if (expectAfter != null) {
      for (final key in expectAfter.keys.toList()) {
        switch (key) {
          case 'sibling_a_cached':
            // 'a' subtree should still be cached after editing 'b1'.
            assertKey(expectAfter, key, tree.isCached('a'), 'sibling_a_cached');
          case 'downstream_consumer_reran':
            assertKey(expectAfter, key, downstreamRuns > runsBeforeEdit,
                'downstream_consumer_reran');
          default:
            assertKey(expectAfter, key, tree.nodeValue(key), 'after $key');
        }
      }
    }
  }
  downstream.dispose();

  final removeChild = scenario['remove_child'];
  if (removeChild is Map) {
    tree.removeChild(
        removeChild['parent'] as String, removeChild['child'] as String);
    final expectAfter = assertionsOfOrNull(scenario['expect_after']);
    if (expectAfter != null) {
      for (final key in expectAfter.keys.toList()) {
        assertKey(expectAfter, key, tree.nodeValue(key), 'after $key');
      }
    }
  }
}

TreeNodeSpec _parseTreeNode(Map<String, dynamic> m) {
  final childrenData = m['children'] as Map<String, dynamic>?;
  TreeNodeChildren? children;
  if (childrenData != null) {
    final order = (childrenData['order'] as List?)?.cast<String>();
    final valuesData = childrenData['values'] as Map<String, dynamic>?;
    Map<String, TreeNodeSpec>? values;
    if (valuesData != null) {
      values = {
        for (final entry in valuesData.entries)
          entry.key: _parseTreeNode(entry.value as Map<String, dynamic>),
      };
    }
    children = TreeNodeChildren(order: order, values: values);
  }
  return TreeNodeSpec(
    id: m['id'] as String,
    value: m['value'],
    children: children,
  );
}

// ---------------------------------------------------------------------------
// Stable-id alignment
// ---------------------------------------------------------------------------

void _playStableIdScenario(Map<String, dynamic> scenario) {
  final blocksField = scenario['blocks'];
  if (blocksField is List) {
    // Key-equality scenarios: compute blockKey for each and compare.
    final blocks =
        blocksField.map((b) => _parseBlock(b as Map<String, dynamic>)).toList();
    final keys = blocks.map(blockKey).toList();

    final expect_ = assertionsOf(scenario['expect']);
    assertKeyIfPresent(expect_, 'key_equal', (v) {
      for (final pair in (v as List).cast<List>()) {
        final i = pair[0] as int;
        final j = pair[1] as int;
        expect(keys[i].equals(keys[j]), isTrue, reason: 'key_equal [$i,$j]');
      }
    });
    assertKeyIfPresent(expect_, 'key_not_equal', (v) {
      for (final pair in (v as List).cast<List>()) {
        final i = pair[0] as int;
        final j = pair[1] as int;
        expect(keys[i].equals(keys[j]), isFalse,
            reason: 'key_not_equal [$i,$j]');
      }
    });
    return;
  }

  final oldField = scenario['old'];
  final newField = scenario['new'];
  if (oldField is List && newField is List) {
    final oldBlocks =
        oldField.map((b) => _parseBlock(b as Map<String, dynamic>)).toList();
    final newBlocks =
        newField.map((b) => _parseBlock(b as Map<String, dynamic>)).toList();

    final expect_ = assertionsOf(scenario['expect']);

    assertKeyIfPresent(expect_, 'matches', (v) {
      final matches = v as List;
      final alignment = align(oldBlocks, newBlocks);
      for (var i = 0; i < matches.length; i++) {
        final expected = matches[i] as String;
        final actual = alignment.newMatches[i].toString();
        expect(actual, expected, reason: 'match[$i]');
      }
    });

    assertKeyIfPresent(expect_, 'removed', (v) {
      final alignment = align(oldBlocks, newBlocks);
      expect(alignment.removed, v, reason: 'removed');
    });

    assertKeyIfPresent(expect_, 'similarity_min', (v) {
      final min = (v as num).toDouble();
      final alignment = align(oldBlocks, newBlocks);
      for (final m in alignment.newMatches) {
        if (m.kind == 'edited') {
          expect(m.similarity, greaterThanOrEqualTo(min),
              reason: 'similarity_min');
        }
      }
    });

    assertKeyIfPresent(expect_, 'new_key_equals_old_key', (v) {
      final keys = assignStableKeys(oldBlocks, newBlocks);
      final oldKeys = oldBlocks.map(blockKey).map((k) => k.asString()).toList();
      for (final pair in (v as List).cast<List>()) {
        final ni = pair[0] as int;
        final oi = pair[1] as int;
        expect(keys[ni], oldKeys[oi],
            reason: 'new_key_equals_old_key [$ni,$oi]');
      }
    });
  }
}

Block _parseBlock(Map<String, dynamic> m) {
  if (m['anchor'] case final String anchor) {
    return Block.anchored(anchor, m['text'] as String);
  }
  return Block.text(m['text'] as String);
}
