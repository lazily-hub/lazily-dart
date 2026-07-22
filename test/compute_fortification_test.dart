// The fortified `Compute` view is the sole tracking surface (`#lzcellkernel`).
//
// Dart mirror of `lazily-rs`'s `tests/compute_fortification.rs`. It pins the
// halves of the fortification contract adapted to Dart:
//
// 1. A **tracked** read through the `Compute` handed to a compute/effect closure
//    registers a dependency edge against the *recomputing node* (value-threaded,
//    not ambient), so a change to the dependency recomputes the dependent.
// 2. The explicit **untracked** escape (`Compute.untracked`) registers **no**
//    edge, so the dependent neither gains a dependency nor recomputes.
// 3. An effect tracks through its own `Compute` view.
// 4. Dart-specific fortification: the view is **non-escapable at runtime** — a
//    tracked read through a view captured past its recompute throws
//    `StaleComputeError` (the runtime stand-in for `lazily-rs`'s lifetime +
//    `!Send`, which Dart's type system cannot express).

import 'package:lazily/src/core.dart';
import 'package:test/test.dart';

void main() {
  test('tracked read registers the edge against the recomputing node', () {
    final ctx = Context();
    final a = ctx.source(1);

    // A `Slot` IS the recomputing node (no internal backing indirection), so its
    // edges are directly observable in both directions.
    var calls = 0;
    final b = ctx.slot<int>((c) {
      calls++;
      // Tracked read: the edge must attribute to `b`, the node being
      // recomputed — carried as a value in `c`, not read from an ambient frame.
      return c.get(a) * 10;
    });

    expect(b(), 10);
    expect(calls, 1, reason: 'first read computes once');

    // Structural: the edge exists in both directions.
    expect(ctx.dependentCount(a), 1,
        reason: 'a must have b as its single tracked dependent');
    expect(ctx.dependencyCount(b), 1, reason: 'b must depend on a');

    // Behavioural: changing a recomputes b.
    ctx.set(a, 5);
    expect(b(), 50);
    expect(calls, 2, reason: 'changing the tracked dependency recomputes b');
  });

  test('a guarded computed tracks its dependency through the Compute view', () {
    final ctx = Context();
    final a = ctx.source(1);

    var calls = 0;
    final b = ctx.computed<int>((c) {
      calls++;
      return c.get(a) * 10;
    });

    expect(b.value, 10);
    expect(calls, 1);
    // A `Computed` computes through an internal backing slot, so the dependency
    // edge attaches to that backing node — observable via a's dependent count.
    expect(ctx.dependentCount(a), 1,
        reason: 'the computed (via its backing) is a dependent of a');

    ctx.set(a, 5);
    expect(b.value, 50);
    expect(calls, 2, reason: 'changing the tracked dependency recomputes b');
  });

  test('untracked read registers no edge and does not recompute', () {
    final ctx = Context();
    final a = ctx.source(1);

    var calls = 0;
    final d = ctx.computed<int>((c) {
      calls++;
      // The explicit untracked escape: read `a` with tracking suppressed, so no
      // dependency edge forms.
      return c.untracked(() => a.value) * 10;
    });

    expect(d.value, 10);
    expect(calls, 1);

    // Structural: no edge was formed by the untracked read.
    expect(ctx.dependentCount(a), 0,
        reason: 'an untracked read must not register a dependent');
    expect(ctx.dependencyCount(d), 0,
        reason: 'd must have acquired no dependency');

    // Behavioural: changing a does NOT recompute d — its cached value stands.
    ctx.set(a, 5);
    expect(d.value, 10, reason: 'untracked dependent keeps its stale value');
    expect(calls, 1, reason: 'untracked dependent never recomputes');
  });

  test('reading through the owning Context is untracked', () {
    final ctx = Context();
    final a = ctx.source(1);

    var calls = 0;
    final d = ctx.computed<int>((c) {
      calls++;
      // `Context` is the untracked surface — its `get` forms no edge even inside
      // a recompute.
      return c.context.get(a) * 10;
    });

    expect(d.value, 10);
    expect(ctx.dependentCount(a), 0);
    ctx.set(a, 5);
    expect(d.value, 10);
    expect(calls, 1);
  });

  test('effect tracks through its compute view', () {
    final ctx = Context();
    final a = ctx.source(1);

    var runs = 0;
    ctx.effect((c) {
      runs++;
      c.get(a);
      return null;
    });

    expect(runs, 1, reason: 'effect runs once on creation');
    expect(ctx.dependentCount(a), 1, reason: 'effect owns the edge to a');

    ctx.set(a, 2);
    expect(runs, 2, reason: 'a change reruns the tracking effect');
  });

  test('a Compute view is non-escapable: a stale tracked read throws', () {
    final ctx = Context();
    final a = ctx.source(1);

    late Compute escaped;
    final b = ctx.computed<int>((c) {
      escaped = c; // capture the view past its recompute (forbidden)
      return c.get(a);
    });

    // Drive the recompute so `escaped` is retired.
    expect(b.value, 1);

    // A tracked read through the retired view must not silently register an edge
    // against the wrong node — it throws.
    expect(() => escaped.get(a), throwsA(isA<StaleComputeError>()));
    expect(() => escaped.untracked(() => a.value),
        throwsA(isA<StaleComputeError>()));
  });

  test('dependencies re-bind per recompute (conditional read drops a branch)',
      () {
    final ctx = Context();
    final cond = ctx.source(true);
    final a = ctx.source(10);
    final b = ctx.source(20);

    final picked = ctx.slot<int>((c) => c.get(cond) ? c.get(a) : c.get(b));

    expect(picked(), 10);
    // Took the `a` branch: depends on cond + a, not b.
    expect(ctx.dependencyCount(picked), 2);
    expect(ctx.dependentCount(b), 0, reason: 'the untaken branch forms no edge');

    // Flip to the `b` branch.
    ctx.set(cond, false);
    expect(picked(), 20);
    expect(ctx.dependentCount(a), 0,
        reason: 'a was dropped when its branch was not taken');
    expect(ctx.dependentCount(b), 1, reason: 'b is now a dependency');
  });
}
