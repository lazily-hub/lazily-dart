import 'dart:convert';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

/// Cross-language conformance tests for the temporal source primitives
/// (`#lztime`, `lazily-spec/conformance/temporal/`). Each source projects its
/// fire edge onto a reactive [Cell]; a [Slot] wrapping that cell lets us observe
/// invalidation via `ctx.contains` — the reader stays cached unless the tick
/// actually fired.
///
/// Fixtures mirror `lazily-spec/conformance/temporal/` byte-identically; when
/// that source tree is reachable on disk (sibling repo) it is preferred so this
/// harness also guards against fixture drift across the family.

/// This runner's slice of the shared corpus. The root itself — and the
/// `LAZILY_SPEC_CONFORMANCE_DIR` override, and the sibling-first-then-mirror
/// ordering — lives in `conformance_manifest.dart` so every runner and the
/// coverage guard auditing them resolve ONE corpus (#lzoverrideallrunners).
const _family = 'temporal';

Map<String, dynamic> _loadFixture(String name) {
  final src = specReadFixture('$_family/$name');
  return attributeFixture(jsonDecode(src)) as Map<String, dynamic>;
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
      final expected = assertionsOf(step['expected']);
      expect(timer.tick(op['now'] as int), equals(step['returns']),
          reason: 'fire edge');
      assertKey(expected, 'fired', timer.hasFired());
      assertKeyWith(expected, 'value', (v) {
        // The corpus spells the fired payload as the unit sentinel `"()"`;
        // Dart's TimerCell carries `true`. Fail loudly on any other spelling
        // rather than silently degrading to `null`.
        final Object? wantValue = switch (v) {
          null => null,
          '()' => true,
          _ => fail('unexpected timer value sentinel $v'),
        };
        expect(timer.value(), equals(wantValue));
      });
      assertKey(expected, 'next_fire', timer.nextFire());
      assertKey(subKey(expected, 'invalidates'), 'fired',
          _invalidated(ctx, observed), 'invalidation');
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
      final expected = assertionsOf(step['expected']);
      expect(iv.tick(op['now'] as int), equals(step['returns']),
          reason: 'fire edge');
      assertKey(expected, 'count', iv.count());
      assertKey(expected, 'next_fire', iv.nextFire());
      assertKey(subKey(expected, 'invalidates'), 'count',
          _invalidated(ctx, observed), 'invalidation');
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
      final expected = assertionsOf(step['expected']);
      expect(cron.tick(op['now'] as int), equals(step['returns']),
          reason: 'fire edge');
      assertKey(expected, 'count', cron.count());
      assertKey(expected, 'next_fire', cron.nextFire());
      assertKey(subKey(expected, 'invalidates'), 'count',
          _invalidated(ctx, observed), 'invalidation');
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
      final expected = assertionsOf(step['expected']);
      expect(d.tick(op['now'] as int), equals(step['returns']),
          reason: 'expiry edge');
      final state = d.state();
      assertKeyWith(expected, 'state', (v) {
        final wantLabel = switch (v) {
          'Expired' => DeadlinedState.expired,
          'Live' => DeadlinedState.live,
          _ => fail('unknown deadline state $v'),
        };
        expect(state.state, equals(wantLabel));
      });
      assertKey(expected, 'value', state.value);
      assertKey(subKey(expected, 'invalidates'), 'state',
          _invalidated(ctx, observed), 'invalidation');
    }
  });
}
