import 'dart:convert';
import 'dart:io';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

/// Cross-language conformance tests for the full Harel state-chart spec
/// (`lazily-spec/docs/state-charts.md`), replaying the canonical fixtures every
/// binding replays. Each test loads a chart, asserts `initial_active` (and
/// `initial_actions` when present), replays the `steps`, and asserts `accepted`,
/// `active`, `matches`, and `actions` after each step.
///
/// Fixtures mirror `lazily-spec/conformance/statechart/` byte-identically; when
/// that source tree is reachable on disk (sibling repo), it is preferred so this
/// harness also guards against fixture drift across the family.

final _specDir = Directory('../lazily-spec/conformance/statechart');

Map<String, dynamic> _loadFixture(String name) {
  final specPath = _specDir.resolveSymbolicLinksSync() + '/$name';
  final src = File(specPath).existsSync()
      ? File(specPath).readAsStringSync()
      : (() {
          final resource = 'test/conformance/statechart/$name';
          return File(resource).readAsStringSync();
        })();
  return jsonDecode(src) as Map<String, dynamic>;
}

List<String> _activeExpected(Object? expected) {
  if (expected is String) return [expected];
  if (expected is List) return expected.cast<String>();
  throw StateError('active must be a string or array');
}

void main() {
  for (final name in [
    'flat_cycle.json',
    'hierarchical_player.json',
    'guarded_door.json',
    'parallel_regions.json',
    'history_shallow.json',
    'history_deep.json',
    'entry_exit_actions.json',
  ]) {
    test('statechart fixture $name replays identically', () {
      final fixture = _loadFixture(name);
      final ctx = Context();
      final chart = StateChart(ctx, ChartDef.fromJson(fixture['chart'] as Map<String, dynamic>));

      // initial_active (asserted once before any step).
      final wantInitial = _activeExpected(fixture['initial_active'])..sort();
      final gotInitial = chart.activeLeaves();
      expect(gotInitial, equals(wantInitial), reason: 'initial_active');

      // initial_actions (optional).
      final initialActions = (fixture['initial_actions'] as List?)?.cast<String>() ?? const [];
      if (initialActions.isNotEmpty) {
        expect(chart.lastActions(), equals(initialActions), reason: 'initial_actions');
      }

      final steps = (fixture['steps'] as List).cast<Map<String, dynamic>>();
      for (var i = 0; i < steps.length; i++) {
        final step = steps[i];
        final event = step['event']! as String;
        final guards = (step['guards'] as Map<String, dynamic>?)?.map(
              (k, v) => MapEntry(k, v == true),
            ) ??
            const <String, bool>{};

        final accepted = chart.send(event, guards);
        expect(accepted, equals(step['accepted'] == true),
            reason: 'step $i `$event` accepted');

        final wantActive = _activeExpected(step['active'])..sort();
        expect(chart.activeLeaves(), equals(wantActive), reason: 'step $i `$event` active');

        final matches = step['matches'];
        if (matches is Map<String, dynamic>) {
          for (final entry in matches.entries) {
            expect(
              chart.matches(entry.key),
              equals(entry.value == true),
              reason: 'step $i `$event` matches(${entry.key})',
            );
          }
        }

        if (step['actions'] is List) {
          final wantActions = (step['actions'] as List).cast<String>();
          expect(chart.lastActions(), equals(wantActions),
              reason: 'step $i `$event` actions');
        }
      }
    });
  }

  test('all statechart fixtures replay identically (batched)', () {
    for (final name in [
      'flat_cycle.json',
      'hierarchical_player.json',
      'guarded_door.json',
      'parallel_regions.json',
      'history_shallow.json',
      'history_deep.json',
      'entry_exit_actions.json',
    ]) {
      final fixture = _loadFixture(name);
      final ctx = Context();
      final chart = StateChart(ctx, ChartDef.fromJson(fixture['chart'] as Map<String, dynamic>));
      final wantInitial = _activeExpected(fixture['initial_active'])..sort();
      expect(chart.activeLeaves(), equals(wantInitial), reason: '$name initial_active');
      for (final step in (fixture['steps'] as List).cast<Map<String, dynamic>>()) {
        final event = step['event']! as String;
        final guards = (step['guards'] as Map<String, dynamic>?)?.map(
              (k, v) => MapEntry(k, v == true),
            ) ??
            const <String, bool>{};
        chart.send(event, guards);
        final wantActive = _activeExpected(step['active'])..sort();
        expect(chart.activeLeaves(), equals(wantActive), reason: '$name step `$event` active');
      }
    }
  });
}
