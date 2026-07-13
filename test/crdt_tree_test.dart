import 'dart:convert';
import 'dart:io';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

Map<String, dynamic> _fixture() => jsonDecode(
      File('test/conformance/crdt-tree/algebra.json').readAsStringSync(),
    ) as Map<String, dynamic>;

Map<String, dynamic> _scenario(String name) =>
    (_fixture()['scenarios'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .firstWhere(
          (item) => item['name'] == name,
        );

bool _mapsEqual(Map<int, int> a, Map<int, int> b) =>
    a.length == b.length &&
    a.entries.every((entry) => b[entry.key] == entry.value);

String _opIdentities(TextCrdt tree) {
  final ops = tree.deltaSince({})..sort((a, b) => a.id.compareTo(b.id));
  return jsonEncode(ops.map((op) => op.toWire()).toList());
}

void main() {
  test('CrdtTree merge algebra is order and duplication independent', () {
    final scenario =
        _scenario('merge algebra is order and duplication independent');
    final seed = scenario['seed'] as Map<String, dynamic>;
    final base = TextCrdt.fromStr(seed['peer'] as int, seed['text'] as String);
    final replicas = <String, TextCrdt>{};
    for (final edit in (scenario['replicas'] as List<dynamic>)
        .cast<Map<String, dynamic>>()) {
      final replica = base.fork(edit['peer'] as int);
      replica.insert(replica.len(), edit['insert'] as String);
      replicas[edit['name'] as String] = replica;
    }

    String? expectedText;
    Map<int, int>? expectedFrontier;
    final orders =
        (scenario['merge_orders'] as List<dynamic>).cast<List<dynamic>>();
    for (var index = 0; index < orders.length; index++) {
      final CrdtTree<Map<int, int>, List<TextOp>, String> merged =
          base.fork(100 + index);
      for (final name in orders[index].cast<String>()) {
        merged.mergeFrom(replicas[name]!);
      }
      expectedText ??= merged.text();
      expectedFrontier ??= merged.versionVector();
      expect(merged.text(), expectedText);
      expect(_mapsEqual(merged.versionVector(), expectedFrontier), isTrue);
      expect(merged.value(), merged.text());
    }
  });

  test('empty-frontier snapshot preserves operation lineage', () {
    final scenario = _scenario('empty frontier snapshot preserves lineage');
    final seed = scenario['seed'] as Map<String, dynamic>;
    final source =
        TextCrdt.fromStr(seed['peer'] as int, seed['text'] as String);
    final restored = TextCrdt(scenario['restore_peer'] as int);
    expect(restored.applyDelta(source.deltaSince({})), isTrue);
    expect(restored.text(), source.text());
    expect(_opIdentities(restored), _opIdentities(source));

    source.insert(source.len(), 'a');
    restored.insert(restored.len(), 'b');
    source.mergeFrom(restored);
    restored.mergeFrom(source);
    expect(restored.text(), source.text());
    final ops = source.deltaSince({});
    expect(ops.map((op) => op.id).toSet().length, ops.length);
  });

  test('own frontier emits an idempotent empty delta', () {
    final scenario = _scenario('own frontier emits an empty delta');
    final seed = scenario['seed'] as Map<String, dynamic>;
    final tree = TextCrdt.fromStr(seed['peer'] as int, seed['text'] as String);
    final delta = tree.deltaSince(tree.versionVector());
    expect(delta, isEmpty);
    expect(tree.applyDelta(delta), isFalse);
  });
}
