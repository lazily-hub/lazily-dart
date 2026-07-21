import 'package:test/test.dart';
import 'package:lazily/lazily.dart';

void main() {
  group('Effect', () {
    test('runs on creation and reruns on dependency change', () {
      final ctx = Context();
      final a = Cell<int>(ctx, 1);
      final log = <int>[];
      Effect(ctx, (_) {
        log.add(a.value);
        return null;
      });
      expect(log, [1]);
      a.value = 2;
      expect(log, [1, 2]);
      a.value = 3;
      expect(log, [1, 2, 3]);
    });

    test('cleanup runs before rerun and on dispose', () {
      final ctx = Context();
      final a = Cell<int>(ctx, 0);
      final cleanups = <int>[];
      final effect = Effect(ctx, (_) {
        final seen = a.value;
        return () => cleanups.add(seen);
      });
      a.value = 1;
      expect(cleanups, [0]); // cleanup for the first run (seen=0)
      effect.dispose();
      expect(cleanups, [0, 1]); // cleanup for the second run (seen=1)
      a.value = 2;
      expect(cleanups.length, 2); // no rerun after dispose
    });

    test('does not rerun when an unrelated cell changes', () {
      final ctx = Context();
      final tracked = Cell<int>(ctx, 10);
      final untracked = Cell<int>(ctx, 100);
      var runs = 0;
      Effect(ctx, (_) {
        tracked.value;
        runs++;
        return null;
      });
      expect(runs, 1);
      untracked.value = 200;
      expect(runs, 1); // no rerun
      tracked.value = 20;
      expect(runs, 2);
    });

    test('isActive is false after dispose', () {
      final ctx = Context();
      final a = Cell<int>(ctx, 0);
      final effect = Effect(ctx, (_) {
        a.value;
        return null;
      });
      expect(effect.isActive, isTrue);
      effect.dispose();
      expect(effect.isActive, isFalse);
    });
  });

  group('Computed (guarded)', () {
    test('suppresses downstream when recomputed value is equal', () {
      final ctx = Context();
      final width = Cell<int>(ctx, 4);
      final parity =
          computed<String>(ctx, (_) => width.value.isEven ? 'even' : 'odd');
      var effectRuns = 0;
      Effect(ctx, (_) {
        parity();
        effectRuns++;
        return null;
      });
      expect(effectRuns, 1);
      // 4 -> 6: still even — the guard suppresses the cascade, effect does NOT
      // rerun.
      width.value = 6;
      expect(effectRuns, 1);
      // 6 -> 7: odd — computed value changed, effect reruns.
      width.value = 7;
      expect(effectRuns, 2);
    });

    test('returns the cached value on read', () {
      final ctx = Context();
      final a = Cell<int>(ctx, 2);
      final b = Cell<int>(ctx, 3);
      final sum = computed<int>(ctx, (_) => a.value + b.value);
      expect(sum(), 5);
      a.value = 10;
      expect(sum(), 13);
    });

    test('cascades normally when value changes', () {
      final ctx = Context();
      final src = Cell<int>(ctx, 1);
      final doubled = computed<int>(ctx, (_) => src.value * 2);
      final quadrupled = computed<int>(ctx, (_) => doubled() * 2);
      expect(quadrupled(), 4);
      src.value = 5;
      expect(quadrupled(), 20);
    });
  });

  group('batch', () {
    test('coalesces multiple cell writes into one cascade', () {
      final ctx = Context();
      final a = Cell<int>(ctx, 1);
      final b = Cell<int>(ctx, 2);
      var runs = 0;
      Effect(ctx, (_) {
        a.value;
        b.value;
        runs++;
        return null;
      });
      expect(runs, 1);
      ctx.batch(() {
        a.value = 10;
        b.value = 20;
      });
      expect(runs, 2); // single rerun, not two
    });

    test('nested batch defers to outermost exit', () {
      final ctx = Context();
      final a = Cell<int>(ctx, 0);
      var runs = 0;
      Effect(ctx, (_) {
        a.value;
        runs++;
        return null;
      });
      expect(runs, 1);
      ctx.batch(() {
        a.value = 1;
        ctx.batch(() {
          a.value = 2;
        });
        // Still inside outer batch — no rerun yet.
        expect(runs, 1);
        a.value = 3;
      });
      expect(runs, 2);
    });

    test('cell writes inside batch are visible immediately', () {
      final ctx = Context();
      final a = Cell<int>(ctx, 0);
      ctx.batch(() {
        a.value = 42;
        expect(a.peek, 42);
      });
    });

    test('no-op batch does not trigger spurious effects', () {
      final ctx = Context();
      final a = Cell<int>(ctx, 1);
      var runs = 0;
      Effect(ctx, (_) {
        a.value;
        runs++;
        return null;
      });
      expect(runs, 1);
      ctx.batch(() {});
      expect(runs, 1);
    });

    test('equal writes inside batch are absorbed', () {
      final ctx = Context();
      final a = Cell<int>(ctx, 5);
      var runs = 0;
      Effect(ctx, (_) {
        a.value;
        runs++;
        return null;
      });
      expect(runs, 1);
      ctx.batch(() {
        a.value = 5; // equal — absorbed
      });
      expect(runs, 1);
    });
  });
}
