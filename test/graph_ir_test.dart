import 'dart:convert';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

const counter = '''
{
  "kind": "graph", "ir": "1", "id": "counter",
  "nodes": [
    {"id": "count", "kind": "source", "init": 1},
    {"id": "doubled", "kind": "computed", "eager": true,
      "expr": {"op": "mul", "args": [{"ref": "count"}, {"lit": 2}]}},
    {"id": "log", "kind": "effect", "body": {"do": "eval", "expr": {"ref": "doubled"}}}
  ]
}
''';

const counterEdit = '''
{
  "kind": "edit", "ir": "1",
  "ops": [
    {"op": "replace", "node": {"id": "doubled", "kind": "computed",
      "expr": {"op": "add", "args": [{"ref": "count"}, {"lit": 10}]}}},
    {"op": "add", "node": {"id": "label", "kind": "source", "init": "n"}},
    {"op": "add", "node": {"id": "shown", "kind": "computed",
      "expr": {"op": "concat", "args": [{"ref": "label"}, {"lit": ":"}]}}},
    {"op": "remove", "id": "log"}
  ]
}
''';

const counterSource =
    'graph counter ir 1\n'
    'source count = 1\n'
    'computed doubled eager = mul(ref(count), lit(2))\n'
    'effect log = eval(ref(doubled))\n';

List<Edge> reads(List<Edge> edges) => [
  for (final edge in edges) Edge(edge.from, EdgeKind.read, edge.to),
];

void main() {
  test('counter lowers then an edit replaces the graph', () {
    final doc = GraphIr.fromJsonStr(counter);
    expect(doc.id, 'counter');
    final doubled = doc.node('doubled')!;
    expect(doubled.eager, isTrue);
    expect(doubled.expr!.op, 'mul');
    expect(reads(doc.staticEdges()), [
      Edge('doubled', EdgeKind.read, 'count'),
      Edge('log', EdgeKind.read, 'doubled'),
    ]);
    expect(doc.emitSource(), counterSource);
    expect(
      GraphIr.fromJsonStr(jsonEncode(doc.toJson())).emitSource(),
      counterSource,
    );

    final rt = GraphRuntime.lower(doc);
    expect(rt.get('doubled'), 2);
    expect(rt.effectTrace(), hasLength(1));
    expect(rt.effectTrace().first.id, 'log');
    expect(rt.effectTrace().first.result, 2);
    expect(rt.observedReads('doubled'), {'count'});
    expect(rt.observedReads('log'), {'doubled'});
    expect(rt.isEager('doubled'), isTrue);
    expect(rt.sourcePolicy('count'), Policy.keepLatest);

    final before = rt.emitSource();
    rt.writeSource('count', 4);
    expect(rt.get('doubled'), 8);
    expect(rt.effectTrace(), hasLength(2));
    expect(rt.effectTrace()[1].result, 8);
    expect(rt.emitSource(), before);

    rt.apply(GraphEdit.fromJsonStr(counterEdit));
    expect(rt.get('doubled'), 14);
    expect(rt.get('shown'), 'n:');
    expect(rt.contains('log'), isFalse);
    expect(rt.isEager('doubled'), isFalse);
    final traceLen = rt.effectTrace().length;
    rt.writeSource('count', 5);
    expect(rt.get('doubled'), 15);
    expect(rt.effectTrace(), hasLength(traceLen));
    expect(
      rt.emitSource(),
      'graph counter ir 1\n'
      'source count = 1\n'
      'computed doubled = add(ref(count), lit(10))\n'
      'source label = "n"\n'
      'computed shown = concat(ref(label), lit(":"))\n',
    );
  });

  test('dynamic if observes only the taken branch', () {
    final rt = GraphRuntime.loadJson('''
    {"kind":"graph","ir":"1","nodes":[
      {"id":"flag","kind":"source","init":false},
      {"id":"left","kind":"source","init":"L"},
      {"id":"right","kind":"source","init":"R"},
      {"id":"picked","kind":"computed","expr":{"op":"if","args":[{"ref":"flag"},{"ref":"left"},{"ref":"right"}]}}
    ]}''');
    expect(reads(rt.staticEdges()), [
      Edge('picked', EdgeKind.read, 'flag'),
      Edge('picked', EdgeKind.read, 'left'),
      Edge('picked', EdgeKind.read, 'right'),
    ]);
    expect(rt.get('picked'), 'R');
    expect(rt.observedReads('picked'), {'flag', 'right'});
    rt.writeSource('flag', true);
    expect(rt.get('picked'), 'L');
    expect(rt.observedReads('picked'), {'flag', 'left'});
  });

  test('sum policy folds and skips an equal write', () {
    final rt = GraphRuntime.loadJson('''
    {"kind":"graph","ir":"1","nodes":[
      {"id":"tick","kind":"source","init":0},
      {"id":"total","kind":"source","init":0,"policy":"sum"},
      {"id":"bump","kind":"effect","body":{"do":"seq","steps":[
        {"do":"eval","expr":{"ref":"tick"}},
        {"do":"merge","target":"total","expr":{"lit":1}}
      ]}}
    ]}''');
    expect(rt.emitSource(), contains('policy sum'));
    expect(rt.emitSource(), contains('merge(total, lit(1))'));
    expect(rt.get('total'), 1);
    expect(rt.effectTrace().single.id, 'bump');
    expect(rt.effectTrace().single.result, [0, 1]);
    expect(rt.sourcePolicy('total'), Policy.sum);
    rt.writeSource('tick', 1);
    expect(rt.get('total'), 2);
    expect(rt.effectTrace(), hasLength(2));
    rt.writeSource('tick', 1);
    expect(rt.effectTrace(), hasLength(2));
    expect(rt.get('total'), 2);
  });

  test('structures read fields length and objects', () {
    final rt = GraphRuntime.loadJson('''
    {"kind":"graph","ir":"1","nodes":[
      {"id":"row","kind":"source","init":{"name":"ada","n":2}},
      {"id":"name","kind":"computed","expr":{"op":"get","args":[{"ref":"row"},{"lit":"name"}]}},
      {"id":"n","kind":"computed","expr":{"op":"get","args":[{"ref":"row"},{"lit":"n"}]}},
      {"id":"tag","kind":"computed","expr":{"op":"concat","args":[{"ref":"name"},{"lit":"#"}]}},
      {"id":"width","kind":"computed","expr":{"op":"len","args":[{"ref":"name"}]}},
      {"id":"pair","kind":"computed","expr":{"op":"array","args":[{"ref":"name"},{"ref":"n"}]}},
      {"id":"wrapped","kind":"computed","expr":{"object":[{"key":"name","value":{"ref":"name"}}]}}
    ]}''');
    expect(rt.get('name'), 'ada');
    expect(rt.get('n'), 2);
    expect(rt.get('tag'), 'ada#');
    expect(rt.get('width'), 3);
    expect(rt.get('pair'), ['ada', 2]);
    expect(rt.get('wrapped'), {'name': 'ada'});
  });

  test('cycle is rejected and a snapshot is not a graph', () {
    expect(
      () => GraphIr.fromJsonStr(
        '{"kind":"graph","ir":"1","nodes":[{"id":"a","kind":"computed","expr":{"ref":"b"}},{"id":"b","kind":"computed","expr":{"ref":"a"}}]}',
      ),
      throwsA(
        isA<GraphIrError>().having(
          (error) => error.message,
          'message',
          contains('cycle in read edges'),
        ),
      ),
    );
    expect(
      () => GraphIr.fromJsonStr(
        '{"Snapshot":{"epoch":0,"nodes":[],"edges":[],"roots":[]}}',
      ),
      throwsA(
        isA<GraphIrError>().having(
          (error) => error.message,
          'message',
          contains('graph'),
        ),
      ),
    );
  });

  test('null init and ordered boolean policies', () {
    final rt = GraphRuntime.loadJson('''
    {"kind":"graph","ir":"1","nodes":[
      {"id":"empty","kind":"source","init":null},
      {"id":"hi","kind":"source","init":3,"policy":"max"},
      {"id":"lo","kind":"source","init":3,"policy":"min"},
      {"id":"both","kind":"source","init":true,"policy":"and"},
      {"id":"either","kind":"source","init":false,"policy":"or"},
      {"id":"fold","kind":"effect","body":{"do":"seq","steps":[
        {"do":"merge","target":"hi","expr":{"lit":1}},
        {"do":"merge","target":"hi","expr":{"lit":5}},
        {"do":"merge","target":"hi","expr":{"lit":5}},
        {"do":"merge","target":"lo","expr":{"lit":1}},
        {"do":"merge","target":"both","expr":{"lit":false}},
        {"do":"merge","target":"either","expr":{"lit":true}}
      ]}}
    ]}''');
    expect(rt.get('empty'), isNull);
    expect(rt.get('hi'), 5);
    expect(rt.get('lo'), 1);
    expect(rt.get('both'), isFalse);
    expect(rt.get('either'), isTrue);
    expect(rt.sourcePolicy('hi'), Policy.max);
    expect(rt.sourcePolicy('lo'), Policy.min);
    expect(rt.sourcePolicy('both'), Policy.and);
    expect(rt.sourcePolicy('either'), Policy.or);
  });

  test('and short-circuits and div by zero faults on get', () {
    final rt = GraphRuntime.loadJson('''
    {"kind":"graph","ir":"1","nodes":[
      {"id":"flag","kind":"source","init":false},
      {"id":"n","kind":"source","init":1},
      {"id":"bad","kind":"computed","expr":{"op":"div","args":[{"ref":"n"},{"lit":0}]}},
      {"id":"gate","kind":"computed","expr":{"op":"and","args":[{"ref":"flag"},{"ref":"bad"}]}}
    ]}''');
    expect(rt.get('gate'), isFalse);
    expect(rt.observedReads('gate'), {'flag'});
    expect(
      () => rt.get('bad'),
      throwsA(
        isA<GraphIrError>().having(
          (error) => error.message,
          'message',
          contains('division by zero'),
        ),
      ),
    );
  });

  test('failed edits leave the previous graph', () {
    final rt = GraphRuntime.loadJson(
      '{"kind":"graph","ir":"1","nodes":[{"id":"a","kind":"source","init":1},{"id":"b","kind":"computed","expr":{"ref":"a"}}]}',
    );
    expect(
      () => rt.apply(
        GraphEdit.fromJsonStr(
          '{"kind":"edit","ir":"1","ops":[{"op":"remove","id":"a"}]}',
        ),
      ),
      throwsA(
        isA<GraphIrError>().having(
          (error) => error.message,
          'message',
          contains('edit op 0'),
        ),
      ),
    );
    expect(rt.contains('a') && rt.contains('b'), isTrue);
    expect(rt.get('b'), 1);

    final empty = GraphRuntime.loadJson('{"kind":"graph","ir":"1","nodes":[]}');
    expect(
      () => empty.apply(
        GraphEdit.fromJsonStr(
          '{"kind":"edit","ir":"1","ops":[{"op":"add","node":{"id":"a","kind":"computed","expr":{"ref":"b"}}},{"op":"add","node":{"id":"b","kind":"source","init":1}}]}',
        ),
      ),
      throwsA(
        isA<GraphIrError>().having(
          (error) => error.message,
          'message',
          contains('edit op 0'),
        ),
      ),
    );
    expect(empty.contains('a') || empty.contains('b'), isFalse);
    expect(empty.emitSource(), 'graph ir 1\n');
  });

  test('replace source resets the live value and when records null', () {
    final rt = GraphRuntime.loadJson(
      '{"kind":"graph","ir":"1","id":"g","nodes":[{"id":"count","kind":"source","init":1}]}',
    );
    rt.writeSource('count', 9);
    expect(rt.get('count'), 9);
    expect(rt.emitSource(), 'graph g ir 1\nsource count = 1\n');
    rt.apply(
      GraphEdit.fromJsonStr(
        '{"kind":"edit","ir":"1","ops":[{"op":"replace","node":{"id":"count","kind":"source","init":0}}]}',
      ),
    );
    expect(rt.get('count'), 0);
    expect(rt.emitSource(), 'graph g ir 1\nsource count = 0\n');

    final on = GraphRuntime.loadJson(
      '{"kind":"graph","ir":"1","nodes":[{"id":"on","kind":"source","init":true},{"id":"value","kind":"source","init":0},{"id":"apply","kind":"effect","body":{"do":"when","cond":{"ref":"on"},"then":{"do":"set","target":"value","expr":{"lit":7}}}}]}',
    );
    expect(on.get('value'), 7);
    expect(on.effectTrace().single.result, 7);
    final off = GraphRuntime.loadJson(
      '{"kind":"graph","ir":"1","nodes":[{"id":"on","kind":"source","init":false},{"id":"value","kind":"source","init":0},{"id":"apply","kind":"effect","body":{"do":"when","cond":{"ref":"on"},"then":{"do":"set","target":"value","expr":{"lit":7}}}}]}',
    );
    expect(off.get('value'), 0);
    expect(off.effectTrace().single.result, isNull);
  });

  test('empty graph accepts an add and rejections fail closed', () {
    final rt = GraphRuntime.loadJson('{"kind":"graph","ir":"1","nodes":[]}');
    rt.apply(
      GraphEdit.fromJsonStr(
        '{"kind":"edit","ir":"1","ops":[{"op":"add","node":{"id":"x","kind":"source","init":1}}]}',
      ),
    );
    expect(rt.get('x'), 1);
    expect(rt.emitSource(), 'graph ir 1\nsource x = 1\n');
    for (final text in [
      '{"kind":"graph","ir":"2","nodes":[]}',
      '{"kind":"graph","ir":"1","nodes":[{"id":"1count","kind":"source","init":0}]}',
      '{"kind":"graph","ir":"1","nodes":[{"id":"c","kind":"computed","expr":{"op":"pow","args":[{"lit":2},{"lit":3}]}}]}',
      '{"kind":"graph","ir":"1","nodes":[{"id":"e","kind":"effect","body":"log"}]}',
    ]) {
      expect(() => GraphIr.fromJsonStr(text), throwsA(isA<GraphIrError>()));
    }
    expect(
      () => GraphEdit.fromJsonStr('{"kind":"edit","ir":"1","ops":[]}'),
      throwsA(isA<GraphIrError>()),
    );
  });

  test('feedback stops at the drain budget', () {
    final doc = GraphIr.fromJsonStr(
      '{"kind":"graph","ir":"1","nodes":[{"id":"n","kind":"source","init":0},{"id":"loop","kind":"effect","body":{"do":"set","target":"n","expr":{"op":"add","args":[{"ref":"n"},{"lit":1}]}}}]}',
    );
    final rt = GraphRuntime.lower(doc, drainBudget: 4);
    expect(rt.lastDrainExhaustion, 4);
    expect(rt.get('n'), 4);
  });
}
