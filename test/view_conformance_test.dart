import 'dart:convert';
import 'dart:io';

import 'package:lazily/src/view.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

void main() {
  final skip = specFamilySkipReason('view');
  test('view conformance replays the canonical fixtures', () {
    final dir = specFamilyDir('view');
    final names = dir
        .listSync()
        .whereType<File>()
        .map((file) => file.uri.pathSegments.last)
        .where((name) => name.endsWith('.json'))
        .toList()
      ..sort();
    expect(names, [
      'batch_send.json',
      'counter.json',
      'field_change.json',
      'malformed_rejected.json',
    ]);
    for (final name in names) {
      final doc =
          jsonDecode(specReadFixture('view/$name')) as Map<String, dynamic>;
      if (doc['kind'] == 'ViewMalformed') {
        for (final raw in doc['cases'] as List) {
          final scenario = raw as Map<String, dynamic>;
          expect(() => View.install(scenario['view'] as Map<String, dynamic>),
              throwsA(anything),
              reason: scenario['name'] as String);
        }
        continue;
      }
      final view = View.install(doc['view'] as Map<String, dynamic>);
      expect(view.subscription, isNotNull);
      expect(doc['trace'], isEmpty);
      _expect(doc['signals'], view.signalsJson());
      _expect(doc['expressions'], view.expressionsJson());
      _expect(doc['layout'], view.layoutJson());
      _expect(doc['chart'], view.chartJson());
      for (final raw in doc['steps'] as List) {
        final step = raw as Map<String, dynamic>;
        final trace = view.dispatchJson(
            step['node'] as String, step['event'] as String, step['value']);
        _expect(step['signals'], view.signalsJson());
        _expect(step['expressions'], view.expressionsJson());
        _expect(step['trace'], trace);
        _expect(step['chart'], view.chartJson());
      }
    }
  }, skip: skip);
}

void _expect(Object? want, Object? got) {
  expect(_norm(got), equals(_norm(want)));
}

Object? _norm(Object? value) {
  if (value is Map) {
    return {for (final e in value.entries) e.key.toString(): _norm(e.value)};
  }
  if (value is List) return value.map(_norm).toList();
  if (value is double && value == value.roundToDouble()) return value.toInt();
  return value;
}
