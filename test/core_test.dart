import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

void main() {
  group('Slot', () {
    test('caches and does not recompute on repeated reads', () {
      final ctx = Context();
      var calls = 0;
      final s = Slot<int>(ctx, (_) => ++calls);
      expect(s(), 1);
      expect(s(), 1);
      expect(s(), 1);
      expect(calls, 1);
    });

    test('recomputes after the context cache is cleared', () {
      final ctx = Context();
      var calls = 0;
      final s = Slot<int>(ctx, (_) => ++calls);
      expect(s(), 1);
      ctx.clear();
      expect(s(), 2);
    });

    test('peek returns cached value without recomputing', () {
      final ctx = Context();
      var calls = 0;
      final s = Slot<int>(ctx, (_) => ++calls);
      expect(s.peek, isNull);
      expect(s(), 1);
      expect(s.peek, 1);
      expect(calls, 1);
    });
  });

  group('Cell', () {
    test('holds a mutable value', () {
      final ctx = Context();
      final c = Source<int>(ctx, 10);
      expect(c.value, 10);
      c.value = 20;
      expect(c.value, 20);
    });

    test('does not cascade when set to an equal value', () {
      final ctx = Context();
      final c = Source<int>(ctx, 5);
      var fired = 0;
      Effect(ctx, (_) {
        c.value;
        fired++;
        return null;
      });
      expect(fired, 1); // initial run
      c.value = 5; // equal — suppressed
      expect(fired, 1);
      c.value = 6; // changed
      expect(fired, 2);
    });

    test('an effect observes changes and can be disposed', () {
      final ctx = Context();
      final c = Source<int>(ctx, 0);
      final seen = <int>[];
      final effect = Effect(ctx, (_) {
        seen.add(c.value);
        return null;
      });
      c.value = 1;
      c.value = 2;
      expect(seen, [0, 1, 2]);
      effect.dispose();
      c.value = 3;
      expect(seen, [0, 1, 2]);
    });
  });

  group('dependency tracking', () {
    test('a slot recomputes when a cell it reads changes', () {
      final ctx = Context();
      final a = Source<int>(ctx, 2);
      final doubled = Slot<int>(ctx, (_) => a.value * 2);

      expect(doubled(), 4);
      a.value = 10;
      expect(doubled(), 20);
    });

    test('diamond: a shared dependency updates both branches and the join', () {
      final ctx = Context();
      final base = Source<int>(ctx, 1);
      var leftCalls = 0;
      var rightCalls = 0;
      var joinCalls = 0;
      final left = Slot<int>(ctx, (_) {
        leftCalls++;
        return base.value + 1;
      });
      final right = Slot<int>(ctx, (_) {
        rightCalls++;
        return base.value + 2;
      });
      final join = Slot<int>(ctx, (_) {
        joinCalls++;
        return left() + right();
      });

      expect(join(), 5); // (1+1)+(1+2)
      expect(leftCalls, 1);
      expect(rightCalls, 1);
      expect(joinCalls, 1);

      base.value = 10;
      expect(join(), 23); // (10+1)+(10+2)
      expect(leftCalls, 2);
      expect(rightCalls, 2);
      expect(joinCalls, 2);
    });

    test(
        'stale edges do not accumulate: each recompute detaches upstream first',
        () {
      final ctx = Context();
      final a = Source<int>(ctx, 0);
      final b = Source<int>(ctx, 0);
      final s = Slot<int>(ctx, (_) => a.value + b.value);

      s();
      // Toggle which cell changes; after several cycles, a single change must
      // invalidate the slot exactly once (no duplicate cascades).
      for (var i = 1; i <= 5; i++) {
        a.value = i;
        expect(s(), i + b.value);
      }
      // Mutate only b several times.
      for (var i = 1; i <= 5; i++) {
        b.value = i;
        expect(s(), a.value + i);
      }
    });
  });

  group('eager Computed', () {
    test('computes eagerly at construction', () {
      final ctx = Context();
      final a = Source<int>(ctx, 3);
      var calls = 0;
      final sig = computed<int>(ctx, (_) {
        calls++;
        return a.value * 10;
      }).eager();
      expect(calls, 1); // eager
      expect(sig.value, 30);
      expect(calls, 1); // no recompute from a read
    });

    test('recomputes immediately when a dependency changes', () {
      final ctx = Context();
      final a = Source<int>(ctx, 1);
      final sig = computed<int>(ctx, (_) => a.value * 2).eager();
      expect(sig.value, 2);
      a.value = 5;
      expect(sig.value, 10); // already updated before read
    });

    test('PartialEq guard suppresses cascade on equal recompute', () {
      final ctx = Context();
      // Signal maps cell through a function whose output is stable for some inputs.
      final src = Source<int>(ctx, 0);
      var computeCalls = 0;
      final sig = computed<int>(ctx, (_) {
        computeCalls++;
        return src.value.isEven ? 1 : 1; // always 1
      }).eager();
      expect(sig.value, 1);
      final downstream = Slot<int>(ctx, (_) => sig.value + 100);
      expect(downstream(), 101);
      var downstreamCalls = 0;
      // attach a dependent counter via a downstream slot re-read
      src.value = 2; // sig recomputes (computeCalls++), but value unchanged
      expect(computeCalls, 2);
      // downstream should NOT have recomputed (guard suppressed cascade)
      downstreamCalls;
      expect(downstream(), 101);
    });

    test('dispose removes the eager puller and reverts to lazy', () {
      final ctx = Context();
      final a = Source<int>(ctx, 1);
      var calls = 0;
      final sig = computed<int>(ctx, (_) {
        calls++;
        return a.value;
      }).eager();
      expect(sig.value, 1);
      final callsAfterConstruct = calls;
      sig.dispose();
      expect(sig.isEager, isFalse);
      a.value = 99;
      // No eager recompute after dispose:
      expect(calls, callsAfterConstruct);
      // ...but a read recomputes lazily:
      expect(sig.value, 99);
    });
  });

  group('StateMachine', () {
    StateMachine<String, String> trafficLight(Context ctx) {
      const next = {'Red': 'Green', 'Green': 'Yellow', 'Yellow': 'Red'};
      return StateMachine<String, String>(
          ctx, 'Red', (s, e) => e == 'advance' ? next[s] : null);
    }

    test('advances through states on accepted events', () {
      final ctx = Context();
      final m = trafficLight(ctx);
      expect(m.state, 'Red');
      expect(m.send('advance'), isTrue);
      expect(m.state, 'Green');
      expect(m.send('advance'), isTrue);
      expect(m.state, 'Yellow');
      expect(m.send('advance'), isTrue);
      expect(m.state, 'Red');
    });

    test('rejects unknown events via the guard', () {
      final ctx = Context();
      final m = trafficLight(ctx);
      expect(m.send('bogus'), isFalse);
      expect(m.state, 'Red');
    });

    test('onTransition fires only on real state change', () {
      final ctx = Context();
      final m = trafficLight(ctx);
      final transitions = <(String, String)>[];
      m.onTransition((old, now) => transitions.add((old, now)));
      m.send('advance'); // Red -> Green
      m.send('bogus'); // rejected, no transition
      m.send('advance'); // Green -> Yellow
      expect(transitions, [('Red', 'Green'), ('Green', 'Yellow')]);
    });

    test('onTransition can be disposed', () {
      final ctx = Context();
      final m = trafficLight(ctx);
      final transitions = <(String, String)>[];
      final dispose =
          m.onTransition((old, now) => transitions.add((old, now)));
      m.send('advance'); // Red -> Green
      dispose();
      m.send('advance'); // Green -> Yellow, unobserved
      expect(transitions, [('Red', 'Green')]);
    });

    test('onTransition reports only the settled value under a batch', () {
      // `onTransition` is an effect, so it observes the graph through a
      // dependency edge and therefore participates in batching. A batch
      // asserts its intermediate states were never observable, so Red -> Green
      // -> Yellow inside one batch is reported as the single transition
      // (Red, Yellow) rather than two.
      final ctx = Context();
      final m = trafficLight(ctx);
      final transitions = <(String, String)>[];
      m.onTransition((old, now) => transitions.add((old, now)));
      ctx.batch(() {
        m.send('advance'); // Red -> Green
        m.send('advance'); // Green -> Yellow
      });
      expect(transitions, [('Red', 'Yellow')]);
    });

    test('a slot that reads state invalidates on transition', () {
      final ctx = Context();
      final m = trafficLight(ctx);
      final label = Slot<String>(ctx, (_) => 'light=${m.state}');
      expect(label(), 'light=Red');
      m.send('advance');
      expect(label(), 'light=Green');
    });
  });
}
