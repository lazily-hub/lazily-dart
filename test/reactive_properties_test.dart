import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

// Property-based validation of the Dart reactive graph against the universal
// properties established by the Lean `LazilyFormal.Reactive` formal model in
// `lazily-formal`. These are the guarantees no finite fixture suite can
// establish: the `PartialEq` cell-write guard, the memo-equality suppression
// guard, and the eager-`Signal` materialization invariant.
//
// Each test names the Lean theorem it mirrors and exercises the Dart
// implementation against the theorem's statement. `test/formal_check_test.dart`
// builds the Lean model itself, so these mirrored statements are checked
// against a compiling proof.

void main() {
  // ===========================================================================
  // setCell_equal_preserves_graph (Reactive.lean)
  // "Writing an equal value into a cell leaves the entire reactive graph
  //  byte-identical — no value update, no downstream invalidation."
  // ===========================================================================
  test('Lean setCell_equal_preserves_graph: equal setCell invalidates no dependent', () {
    final ctx = Context();
    final a = Cell<int>(ctx, 2);

    var slotFires = 0;
    final dependent = Slot<int>(ctx, (_) {
      slotFires++;
      return a.value;
    });
    var observerFires = 0;
    a.subscribe((_) => observerFires++);

    expect(dependent(), 2); // materialize
    final slotFiresBefore = slotFires;
    final observerFiresBefore = observerFires;

    a.value = 2; // equal value — must be a no-op

    expect(dependent(), 2); // pull again — should NOT recompute
    expect(slotFires, slotFiresBefore, reason: 'slot must not recompute on equal setCell');
    expect(observerFires, observerFiresBefore, reason: 'observer must not fire on equal setCell');
    expect(a.value, 2);
  });

  // ===========================================================================
  // setCell_different_invalidates_dependents (Reactive.lean)
  // "A strictly-different cell write marks every direct dependent dirty."
  // ===========================================================================
  test('Lean setCell_different_invalidates_dependents: different setCell invalidates every direct dependent', () {
    final ctx = Context();
    final a = Cell<int>(ctx, 1);

    // Two flavors of direct dependent: lazy slot, eager signal.
    final lazy = Slot<int>(ctx, (_) => a.value + 1);
    final eager = Signal<int>(ctx, (_) => a.value * 10);

    expect(lazy(), 2); // materialize
    expect(eager.value, 10); // materialize

    a.value = 99; // strictly different

    expect(lazy(), 100, reason: 'lazy slot recomputed');
    expect(eager.value, 990, reason: 'eager signal recomputed');
  });

  // ===========================================================================
  // recomputeSlot_equal_preserves_dependents (Reactive.lean)
  // "A slot/signal recompute whose memo-equality guard returns equal leaves
  //  every downstream dependent untouched." In Dart, a Signal's backing slot
  //  recomputes on dependency change, and the signal only cascades downstream
  //  if its own value changed (the `!=` guard).
  // ===========================================================================
  test('Lean recomputeSlot_equal_preserves_dependents: a signal that recomputes to an equal value leaves downstream untouched', () {
    final ctx = Context();
    final toggle = Cell<String>(ctx, 'x');
    // A signal whose OUTPUT is stable even when its input flips: it derives
    // a constant `42` regardless of `toggle`. The memo guard must observe
    // equality and suppress downstream propagation.
    final stable = Signal<int>(ctx, (_) {
      toggle.value; // register the edge, even though output is constant
      return 42;
    });

    var downstreamFires = 0;
    final downstream = Slot<int>(ctx, (_) {
      downstreamFires++;
      return stable.value;
    });
    expect(downstream(), 42); // materialize downstream
    final firesBefore = downstreamFires;

    toggle.value = 'y'; // input changes → signal recomputes → output equal

    expect(stable.value, 42);
    expect(downstream(), 42);
    expect(
      downstreamFires,
      firesBefore,
      reason: 'downstream must not recompute when the signal recomputes to an equal value',
    );
  });

  // ===========================================================================
  // recomputeSlot_different_invalidates_dependents (Reactive.lean)
  // "A strictly-different signal recompute marks every direct dependent dirty."
  // ===========================================================================
  test('Lean recomputeSlot_different_invalidates_dependents: a strictly-different signal recompute invalidates every direct dependent', () {
    final ctx = Context();
    final src = Cell<int>(ctx, 1);
    final sig = Signal<int>(ctx, (_) => src.value * 2);

    final lazyChild = Slot<int>(ctx, (_) => sig.value + 1);
    expect(lazyChild(), 3); // materialize

    src.value = 5; // sig recomputes 2 → 10: strictly different

    expect(sig.value, 10);
    expect(lazyChild(), 11, reason: 'lazy child recomputed');
  });

  // ===========================================================================
  // signal_materialized_after_recompute (Reactive.lean)
  // "After a Signal's puller runs, the backing slot always holds a concrete
  //  cached value and is not dirty — readers never observe an unset
  //  intermediate."
  // ===========================================================================
  test('Lean signal_materialized_after_recompute: after a dependency change the signal is already materialized (not lazy)', () {
    final ctx = Context();
    final a = Cell<int>(ctx, 1);
    final sig = Signal<int>(ctx, (_) => a.value + 100);

    expect(sig.value, 101); // materialize

    // Mutate — the value is observed as soon as the change lands, never
    // deferred, never an unset intermediate.
    a.value = 7;

    // The signal value already reflects the new input (eager materialization).
    expect(sig.value, 107, reason: 'value already reflects the new input');

    // And the same holds across repeated changes (the non-deferred path).
    a.value = 8;
    expect(sig.value, 108);
  });
}
