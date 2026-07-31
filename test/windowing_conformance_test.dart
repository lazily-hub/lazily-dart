import 'dart:convert';
import 'dart:io';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

/// Cross-language conformance tests for stream windowing (`#lzwindow`,
/// `lazily-spec/conformance/windowing/`). Each window projects the last emitted
/// aggregate onto a reactive [Cell]; a [Slot] wrapping that cell lets us observe
/// invalidation via `ctx.contains` — the reader stays cached unless a window
/// actually fires a new aggregate.
///
/// Fixtures mirror `lazily-spec/conformance/windowing/` byte-identically; when
/// that source tree is reachable on disk (sibling repo) it is preferred so this
/// harness also guards against fixture drift across the family. Aggregation is
/// the Sum merge (`(a, b) => a + b`).

final _specDir = Directory('../lazily-spec/conformance/windowing');

Map<String, dynamic> _loadFixture(String name) {
  final src = _specDir.existsSync()
      ? File(_specDir.resolveSymbolicLinksSync() + '/$name')
          .specReadAsStringSync()
      : File('test/conformance/windowing/$name').specReadAsStringSync();
  return attributeFixture(jsonDecode(src)) as Map<String, dynamic>;
}

int _sum(int a, int b) => a + b;

/// Observe a cell through a slot; returns the slot primed (cached).
Slot<Object?> _observe(Context ctx, Cell cell) {
  final slot = Slot<Object?>(ctx, (cx) => cx.get(cell));
  slot();
  return slot;
}

/// Read the slot, returning whether the read triggered a recompute (i.e. the
/// reader had been invalidated).
bool _invalidated(Context ctx, Slot slot) {
  final wasCached = ctx.contains(slot);
  slot();
  return !wasCached;
}

/// Assert the projected output and invalidation flag for one step.
void _check(
    Context ctx, Slot observed, Map<String, dynamic> step, Object? out) {
  final expected = assertionsOf(step['expected']);
  assertKey(expected, 'output', out);
  assertKeyWith(expected, 'invalidates', (v) {
    expect(_invalidated(ctx, observed), equals((v as Map)['output']),
        reason: 'invalidation');
  });
}

void main() {
  test('TumblingCountWindow', () {
    final fx = _loadFixture('tumbling_count.json');
    final ctx = Context();
    final config = fx['config'] as Map<String, dynamic>;
    final w = TumblingCountWindow<int>(ctx, config['n'] as int, _sum);
    final observed = _observe(ctx, w.outputCell);

    for (final step in (fx['steps'] as List).cast<Map<String, dynamic>>()) {
      final op = step['op'] as Map<String, dynamic>;
      expect(w.push(op['value'] as int), equals(step['returns']),
          reason: 'emit');
      _check(ctx, observed, step, w.output());
    }
  });

  test('TumblingTimeWindow', () {
    final fx = _loadFixture('tumbling_time.json');
    final ctx = Context();
    final config = fx['config'] as Map<String, dynamic>;
    final w = TumblingTimeWindow<int>(ctx, config['period'] as int, _sum);
    final observed = _observe(ctx, w.outputCell);

    for (final step in (fx['steps'] as List).cast<Map<String, dynamic>>()) {
      final op = step['op'] as Map<String, dynamic>;
      final int? e;
      if (op['type'] == 'push') {
        w.push(op['now'] as int, op['value'] as int);
        e = null;
      } else {
        e = w.tick(op['now'] as int);
      }
      expect(e, equals(step['returns']), reason: 'emit');
      _check(ctx, observed, step, w.output());
    }
  });

  test('SlidingWindow', () {
    final fx = _loadFixture('sliding_count.json');
    final ctx = Context();
    final config = fx['config'] as Map<String, dynamic>;
    final w = SlidingWindow<int>(
      ctx,
      config['size'] as int,
      config['slide'] as int,
      _sum,
    );
    final observed = _observe(ctx, w.outputCell);

    for (final step in (fx['steps'] as List).cast<Map<String, dynamic>>()) {
      final op = step['op'] as Map<String, dynamic>;
      expect(w.push(op['value'] as int), equals(step['returns']),
          reason: 'emit');
      _check(ctx, observed, step, w.output());
    }
  });

  test('SessionWindow', () {
    final fx = _loadFixture('session.json');
    final ctx = Context();
    final config = fx['config'] as Map<String, dynamic>;
    final w = SessionWindow<int>(ctx, config['gap'] as int, _sum);
    final observed = _observe(ctx, w.outputCell);

    for (final step in (fx['steps'] as List).cast<Map<String, dynamic>>()) {
      final op = step['op'] as Map<String, dynamic>;
      final int? e;
      if (op['type'] == 'push') {
        e = w.push(op['now'] as int, op['value'] as int);
      } else {
        e = w.flush(op['now'] as int);
      }
      expect(e, equals(step['returns']), reason: 'emit');
      _check(ctx, observed, step, w.output());
    }
  });
}
