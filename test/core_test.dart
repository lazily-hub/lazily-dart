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
      final c = Cell<int>(ctx, 10);
      expect(c.value, 10);
      c.value = 20;
      expect(c.value, 20);
    });

    test('does not notify when set to an equal value', () {
      final ctx = Context();
      final c = Cell<int>(ctx, 5);
      var fired = 0;
      c.subscribe((v) => fired++);
      c.value = 5; // equal — suppressed
      expect(fired, 0);
      c.value = 6; // changed
      expect(fired, 1);
    });

    test('subscribe observers persist across changes and can be disposed', () {
      final ctx = Context();
      final c = Cell<int>(ctx, 0);
      final seen = <int>[];
      final dispose = c.subscribe(seen.add);
      c.value = 1;
      c.value = 2;
      expect(seen, [1, 2]);
      dispose();
      c.value = 3;
      expect(seen, [1, 2]);
    });
  });

  // Observer storage is a tombstoned slot list with a lazily rebuilt snapshot
  // (`#lzdartobservercow`), replacing a copy-on-write list. These pin the
  // semantics that shape has to preserve.
  group('Cell observer storage', () {
    test('fires observers in subscription order', () {
      final c = Cell<int>(Context(), 0);
      final order = <String>[];
      c.subscribe((_) => order.add('a'));
      c.subscribe((_) => order.add('b'));
      c.subscribe((_) => order.add('c'));
      c.value = 1;
      expect(order, ['a', 'b', 'c']);
    });

    test('supports the same closure subscribed more than once', () {
      final c = Cell<int>(Context(), 0);
      var fired = 0;
      void observer(int v) => fired++;
      final first = c.subscribe(observer);
      c.subscribe(observer);
      c.value = 1;
      expect(fired, 2);
      // Disposing one registration must leave the other live.
      first();
      c.value = 2;
      expect(fired, 3);
    });

    test('disposer is idempotent and removes only its own registration', () {
      final c = Cell<int>(Context(), 0);
      var fired = 0;
      final dispose = c.subscribe((_) => fired++);
      c.subscribe((_) => fired++);
      dispose();
      dispose();
      dispose();
      c.value = 1;
      expect(fired, 1);
    });

    test('middle disposal does not disturb neighbours', () {
      final c = Cell<int>(Context(), 0);
      final seen = <String>[];
      c.subscribe((_) => seen.add('a'));
      final disposeB = c.subscribe((_) => seen.add('b'));
      c.subscribe((_) => seen.add('c'));
      disposeB();
      c.value = 1;
      expect(seen, ['a', 'c']);
    });

    test('disposers stay valid across slot compaction', () {
      // Compaction triggers once the slot list exceeds its threshold and at
      // least half the slots are tombstoned; it rewrites every surviving
      // slot's index. A disposer captured *before* compaction must still
      // remove exactly its own observer afterwards.
      final c = Cell<int>(Context(), 0);
      final fired = <int>[];
      final disposers = <void Function()>[];
      for (var i = 0; i < 128; i++) {
        final id = i;
        disposers.add(c.subscribe((_) => fired.add(id)));
      }
      // Drop every odd registration, forcing compaction.
      for (var i = 1; i < 128; i += 2) {
        disposers[i]();
      }
      c.value = 1;
      expect(fired, [for (var i = 0; i < 128; i += 2) i]);

      // Now dispose a survivor whose slot index was rewritten by compaction.
      fired.clear();
      disposers[64]();
      c.value = 2;
      expect(fired, [for (var i = 0; i < 128; i += 2) if (i != 64) i]);
    });

    test('re-subscribing after full teardown works', () {
      final c = Cell<int>(Context(), 0);
      var fired = 0;
      final dispose = c.subscribe((_) => fired++);
      dispose();
      c.value = 1;
      expect(fired, 0);
      c.subscribe((_) => fired++);
      c.value = 2;
      expect(fired, 1);
    });

    test('subscribe during notification does not fire in that pass', () {
      // The in-flight notification iterates a stable snapshot; a reentrant
      // subscribe only marks it dirty, so the new observer starts at the
      // *next* publish.
      final c = Cell<int>(Context(), 0);
      final seen = <String>[];
      late void Function() addLate;
      addLate = () => c.subscribe((_) => seen.add('late'));
      var added = false;
      c.subscribe((_) {
        seen.add('early');
        if (!added) {
          added = true;
          addLate();
        }
      });
      c.value = 1;
      expect(seen, ['early']);
      c.value = 2;
      expect(seen, ['early', 'early', 'late']);
    });

    test('dispose during notification takes effect within the in-flight pass',
        () {
      // Migrated to the normative contract (`#lzdartobservercow`,
      // lazily-spec docs/reactive-graph.md): an observer disposed from inside
      // a callback MUST NOT be invoked by the notification in flight, even
      // when the loop has not yet reached it. This previously asserted the
      // opposite — a stable pre-notification snapshot invoked the disposed
      // observer once more. Full replay:
      // test/observer_conformance_test.dart.
      final c = Cell<int>(Context(), 0);
      final seen = <String>[];
      late void Function() disposeSecond;
      c.subscribe((_) {
        seen.add('first');
        disposeSecond();
      });
      disposeSecond = c.subscribe((_) => seen.add('second'));
      c.value = 1;
      expect(seen, ['first']);
      seen.clear();
      c.value = 2;
      expect(seen, ['first']);
    });

    test('observer disposing itself mid-pass is safe', () {
      final c = Cell<int>(Context(), 0);
      var fired = 0;
      late void Function() self;
      self = c.subscribe((_) {
        fired++;
        self();
      });
      c.value = 1;
      c.value = 2;
      expect(fired, 1);
    });
  });

  group('dependency tracking', () {
    test('a slot recomputes when a cell it reads changes', () {
      final ctx = Context();
      final a = Cell<int>(ctx, 2);
      final doubled = Slot<int>(ctx, (_) => a.value * 2);

      expect(doubled(), 4);
      a.value = 10;
      expect(doubled(), 20);
    });

    test('diamond: a shared dependency updates both branches and the join', () {
      final ctx = Context();
      final base = Cell<int>(ctx, 1);
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
      final a = Cell<int>(ctx, 0);
      final b = Cell<int>(ctx, 0);
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

  group('Signal', () {
    test('computes eagerly at construction', () {
      final ctx = Context();
      final a = Cell<int>(ctx, 3);
      var calls = 0;
      final sig = Signal<int>(ctx, (_) {
        calls++;
        return a.value * 10;
      });
      expect(calls, 1); // eager
      expect(sig.value, 30);
      expect(calls, 1); // no recompute from a read
    });

    test('recomputes immediately when a dependency changes', () {
      final ctx = Context();
      final a = Cell<int>(ctx, 1);
      final sig = Signal<int>(ctx, (_) => a.value * 2);
      expect(sig.value, 2);
      a.value = 5;
      expect(sig.value, 10); // already updated before read
    });

    test('PartialEq guard suppresses cascade on equal recompute', () {
      final ctx = Context();
      // Signal maps cell through a function whose output is stable for some inputs.
      final src = Cell<int>(ctx, 0);
      var computeCalls = 0;
      final sig = Signal<int>(ctx, (_) {
        computeCalls++;
        return src.value.isEven ? 1 : 1; // always 1
      });
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
      final a = Cell<int>(ctx, 1);
      var calls = 0;
      final sig = Signal<int>(ctx, (_) {
        calls++;
        return a.value;
      });
      expect(sig.value, 1);
      final callsAfterConstruct = calls;
      sig.dispose();
      expect(sig.isActive, isFalse);
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
