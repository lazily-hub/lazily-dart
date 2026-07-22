import 'dart:convert';
import 'dart:io';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

/// Cross-language conformance tests for the temporal source primitives
/// (`#lztime`, `lazily-spec/conformance/temporal/`). Each source projects its
/// fire edge onto a reactive [Cell]; a [Slot] wrapping that cell lets us observe
/// invalidation via `ctx.contains` — the reader stays cached unless the tick
/// actually fired.
///
/// Fixtures mirror `lazily-spec/conformance/temporal/` byte-identically; when
/// that source tree is reachable on disk (sibling repo) it is preferred so this
/// harness also guards against fixture drift across the family.

final _specDir = Directory('../lazily-spec/conformance/temporal');

Map<String, dynamic> _loadFixture(String name) {
  final src = _specDir.existsSync()
      ? File(_specDir.resolveSymbolicLinksSync() + '/$name').readAsStringSync()
      : File('test/conformance/temporal/$name').readAsStringSync();
  return jsonDecode(src) as Map<String, dynamic>;
}

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

void main() {
  test('TimerCell single-shot', () {
    final fx = _loadFixture('timer_single_shot.json');
    final ctx = Context();
    final initial = fx['initial'] as Map<String, dynamic>;
    final timer = TimerCell(ctx, initial['fire_at'] as int);
    final observed = _observe(ctx, timer.firedCell);

    for (final step in (fx['steps'] as List).cast<Map<String, dynamic>>()) {
      final op = step['op'] as Map<String, dynamic>;
      final expected = step['expected'] as Map<String, dynamic>;
      expect(timer.tick(op['now'] as int), equals(step['returns']),
          reason: 'fire edge');
      expect(timer.hasFired(), equals(expected['fired']));
      final wantValue = expected['value'] == '()' ? true : null;
      expect(timer.value(), equals(wantValue));
      expect(timer.nextFire(), equals(expected['next_fire']));
      final wantInv =
          (expected['invalidates'] as Map<String, dynamic>)['fired'];
      expect(_invalidated(ctx, observed), equals(wantInv),
          reason: 'invalidation');
    }
  });

  test('IntervalCell periodic', () {
    final fx = _loadFixture('interval_periodic.json');
    final ctx = Context();
    final initial = fx['initial'] as Map<String, dynamic>;
    final iv = IntervalCell(ctx, initial['period'] as int);
    final observed = _observe(ctx, iv.countCell);

    for (final step in (fx['steps'] as List).cast<Map<String, dynamic>>()) {
      final op = step['op'] as Map<String, dynamic>;
      final expected = step['expected'] as Map<String, dynamic>;
      expect(iv.tick(op['now'] as int), equals(step['returns']),
          reason: 'fire edge');
      expect(iv.count(), equals(expected['count']));
      expect(iv.nextFire(), equals(expected['next_fire']));
      final wantInv =
          (expected['invalidates'] as Map<String, dynamic>)['count'];
      expect(_invalidated(ctx, observed), equals(wantInv),
          reason: 'invalidation');
    }
  });

  test('CronCell pattern', () {
    final fx = _loadFixture('cron_pattern.json');
    final ctx = Context();
    final initial = fx['initial'] as Map<String, dynamic>;
    final cron = CronCell(
      ctx,
      initial['cycle'] as int,
      (initial['offsets'] as List).cast<int>(),
    );
    final observed = _observe(ctx, cron.countCell);

    for (final step in (fx['steps'] as List).cast<Map<String, dynamic>>()) {
      final op = step['op'] as Map<String, dynamic>;
      final expected = step['expected'] as Map<String, dynamic>;
      expect(cron.tick(op['now'] as int), equals(step['returns']),
          reason: 'fire edge');
      expect(cron.count(), equals(expected['count']));
      expect(cron.nextFire(), equals(expected['next_fire']));
      final wantInv =
          (expected['invalidates'] as Map<String, dynamic>)['count'];
      expect(_invalidated(ctx, observed), equals(wantInv),
          reason: 'invalidation');
    }
  });

  test('DeadlineCell expiry', () {
    final fx = _loadFixture('deadline_expiry.json');
    final ctx = Context();
    final initial = fx['initial'] as Map<String, dynamic>;
    final d = DeadlineCell<String>(
      ctx,
      initial['value'] as String,
      initial['deadline'] as int,
    );
    final observed = _observe(ctx, d.expiredCell);

    for (final step in (fx['steps'] as List).cast<Map<String, dynamic>>()) {
      final op = step['op'] as Map<String, dynamic>;
      final expected = step['expected'] as Map<String, dynamic>;
      expect(d.tick(op['now'] as int), equals(step['returns']),
          reason: 'expiry edge');
      final state = d.state();
      final wantLabel =
          expected['state'] == 'Expired' ? DeadlinedState.expired : DeadlinedState.live;
      expect(state.state, equals(wantLabel));
      expect(state.value, equals(expected['value']));
      final wantInv =
          (expected['invalidates'] as Map<String, dynamic>)['state'];
      expect(_invalidated(ctx, observed), equals(wantInv),
          reason: 'invalidation');
    }
  });
}
