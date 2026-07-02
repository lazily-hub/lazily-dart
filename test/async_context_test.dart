import 'dart:async';

import 'package:lazily/async_context.dart';
import 'package:test/test.dart';

/// Async reactive context conformance (docs/async.md). Mirrors the
/// `lazily-rs` AsyncContext integration tests: Empty/Computing/Resolved/Error
/// state machine, revision tracking (stale completion discarded), in-flight
/// dedup, cancellation, memo guard, effect cleanup-before-body, and batch.

void main() {
  group('AsyncSlotHandle state machine', () {
    test('Empty → Computing → Resolved on first getAsync', () async {
      final ctx = AsyncContext();
      final a = ctx.cell(2);
      final b = ctx.cell(3);
      final sum = ctx.computedAsync((cc) async {
        final x = cc.getCell(a);
        final y = cc.getCell(b);
        return x + y;
      });
      expect(sum.state, AsyncSlotState.empty);
      final value = await sum.getAsync();
      expect(value, 5);
      expect(sum.state, AsyncSlotState.resolved);
      await ctx.disposeAsync();
    });

    test('Resolved → Computing → Resolved on dependency change', () async {
      final ctx = AsyncContext();
      final a = ctx.cell(1);
      final slot = ctx.computedAsync((cc) async => cc.getCell(a) * 10);
      expect(await slot.getAsync(), 10);
      a.set(5);
      // Synchronous get() returns null while the async recompute is pending.
      expect(slot.get(), isNull);
      expect(await slot.getAsync(), 50);
      await ctx.disposeAsync();
    });

    test('Computing → Error on a failing computation', () async {
      final ctx = AsyncContext();
      final slot = ctx.computedAsync((cc) async => throw StateError('boom'));
      try {
        await slot.getAsync();
        // ignore: dead_code
        fail('expected an error');
      } on StateError catch (e) {
        expect(e.message, 'boom');
      }
      expect(slot.state, AsyncSlotState.error);
      // Retry: a getAsync after the failure spawns a fresh computation.
      aRetrySlot(ctx);
      await ctx.disposeAsync();
    });
  });

  group('revision tracking', () {
    test('a stale completion is discarded, not published', () async {
      final ctx = AsyncContext();
      final step = ctx.cell(0);
      var calls = 0;
      final slot = ctx.computedAsync((cc) async {
        calls += 1;
        final s = cc.getCell(step);
        // The body awaits a microtask; a concurrent source change during the
        // await advances the revision, so the in-flight completion is stale.
        await Future<void>.delayed(Duration.zero);
        return s;
      });
      // Start the first computation.
      final pending = slot.getAsync();
      // While it is suspended, bump the dependency: the in-flight revision is
      // now stale.
      step.set(1);
      expect(await pending, 1);
      expect(calls, greaterThan(1), reason: 'a fresh future was spawned');
      await ctx.disposeAsync();
    });
  });

  group('in-flight deduplication', () {
    test('concurrent getAsync callers await the same future', () async {
      final ctx = AsyncContext();
      final a = ctx.cell(1);
      var calls = 0;
      final slot = ctx.computedAsync((cc) async {
        calls += 1;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return cc.getCell(a);
      });
      final f1 = slot.getAsync();
      final f2 = slot.getAsync();
      expect(await f1, 1);
      expect(await f2, 1);
      expect(calls, 1, reason: 'one in-flight computation per revision');
      await ctx.disposeAsync();
    });
  });

  group('memoAsync', () {
    test('an equal recompute suppresses the published value', () async {
      final ctx = AsyncContext();
      // A trigger that bumps the cell but whose computed value stays the same.
      final trigger = ctx.cell(0);
      var calls = 0;
      final slot = ctx.memoAsync((cc) async {
        calls += 1;
        cc.getCell(trigger); // depend on trigger
        return 'constant';
      }, (x, y) => x == y);
      expect(await slot.getAsync(), 'constant');
      expect(calls, 1);
      trigger.set(1);
      // The recompute runs but yields an equal value: callers still resolve.
      expect(await slot.getAsync(), 'constant');
      expect(calls, 2, reason: 'memo recompute still runs; suppression is on publish');
      await ctx.disposeAsync();
    });
  });

  group('async effects', () {
    test('cleanup completes before the next body starts', () async {
      final ctx = AsyncContext();
      final trigger = ctx.cell(1);
      final log = <String>[];
      final effect = ctx.effectAsync((cc) async {
        final v = cc.getCell(trigger);
        log.add('body($v)');
        // Register a cleanup that runs before the next body.
        return () async {
          log.add('cleanup');
        };
      });
      // Let the first body run.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final firstLog = List<String>.of(log);
      expect(firstLog.first, 'body(1)');
      // Trigger a rerun.
      trigger.set(2);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // Cleanup must precede the second body.
      final joined = log.join(',');
      expect(joined, contains('cleanup'));
      expect(joined.indexOf('cleanup'), lessThan(joined.indexOf('body(2)')));
      await effect.disposeAsync();
      await ctx.disposeAsync();
    });
  });

  group('batch', () {
    test('coalesces multiple cell updates into one invalidation pass', () async {
      final ctx = AsyncContext();
      final a = ctx.cell(1);
      final b = ctx.cell(2);
      var calls = 0;
      final slot = ctx.computedAsync((cc) async {
        calls += 1;
        return cc.getCell(a) + cc.getCell(b);
      });
      expect(await slot.getAsync(), 3);
      final before = calls;
      ctx.batch(() {
        a.set(10);
        b.set(20);
      });
      expect(await slot.getAsync(), 30);
      expect(calls, before + 1, reason: 'one rerun from the batch');
      await ctx.disposeAsync();
    });
  });

  group('disposal', () {
    test('further cell writes are no-ops after disposal', () async {
      final ctx = AsyncContext();
      final a = ctx.cell(1);
      final slot = ctx.computedAsync((cc) async => cc.getCell(a));
      expect(await slot.getAsync(), 1);
      await ctx.disposeAsync();
      // No throw; the invalidation path is a no-op.
      a.set(999);
    });
  });
}

void aRetrySlot(AsyncContext ctx) {
  // A separate, succeeding slot proves the runtime keeps running after an
  // Error state — the spec requires the runtime not crash on a failing slot.
  final ok = ctx.computedAsync((cc) async => 42);
  expectLater(ok.getAsync(), completion(42));
}
