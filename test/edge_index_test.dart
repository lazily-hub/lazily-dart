// Behavioural tests for the dependency-edge hash index (`#lzspecedgeindex`).
//
// The index is an implementation concern — the contract fixes the edge *set*,
// not how membership is tested — so every test here asserts observable graph
// behaviour at degrees that straddle the promote/demote thresholds. They are
// cheap enough for CI; the width ladder in `benchmark/edge_index_load.dart` is
// the manual, on-demand counterpart.

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

void main() {
  group('edge index thresholds', () {
    test('demote threshold sits well below promote (hysteresis)', () {
      // A shared boundary makes a list oscillating by one rebuild its index on
      // every recompute. The gap is the guard against that.
      expect(edgeIndexDemoteThreshold, lessThan(edgeIndexPromoteThreshold));
      expect(
        edgeIndexPromoteThreshold / edgeIndexDemoteThreshold,
        greaterThanOrEqualTo(2.0),
        reason: 'demotion needs real hysteresis, not an off-by-one margin',
      );
    });
  });

  group('fan-out correctness across the promote threshold', () {
    // Widths straddling the threshold in both directions, plus the exact
    // boundary and boundary+1 where thrash hides.
    final widths = <int>[
      1,
      2,
      edgeIndexDemoteThreshold,
      edgeIndexPromoteThreshold - 1,
      edgeIndexPromoteThreshold,
      edgeIndexPromoteThreshold + 1,
      edgeIndexPromoteThreshold * 4,
    ];

    for (final width in widths) {
      test('width $width: every dependent observes every publish', () {
        final ctx = Context();
        final source = Source<int>(ctx, 0);
        final subs = [
          for (var i = 0; i < width; i++)
            Slot<int>(ctx, (cx) => cx.get(source) * 1000 + i),
        ];

        for (final s in subs) {
          s();
        }

        // Several publish/read cycles: each publish clears the dependent list
        // and each read re-registers it, exercising promote and demote.
        for (var round = 1; round <= 4; round++) {
          source.value = round;
          for (var i = 0; i < width; i++) {
            expect(subs[i](), equals(round * 1000 + i));
          }
        }
      });
    }
  });

  test('reading a source twice in one computation registers one edge', () {
    // Dedup must survive the indexed path, not just the scan path.
    final ctx = Context();
    final source = Source<int>(ctx, 1);
    var runs = 0;

    // Pad the source's dependent list past the promote threshold so the
    // duplicate read below is deduped by the index rather than by scan.
    final padding = [
      for (var i = 0; i < edgeIndexPromoteThreshold + 8; i++)
        Slot<int>(ctx, (cx) => cx.get(source) + i),
    ];
    for (final p in padding) {
      p();
    }

    final doubleReader = Slot<int>(ctx, (cx) {
      runs++;
      return cx.get(source) + cx.get(source);
    });
    expect(doubleReader(), equals(2));
    expect(runs, equals(1));

    source.value = 5;
    expect(doubleReader(), equals(10));
    expect(runs, equals(2), reason: 'a duplicate read must not double-notify');
  });

  test('a shrinking wide node does not retain stale index entries', () {
    // Drive a node from wide (indexed) down past the demote threshold via
    // dynamic dependencies, then back up. A stale index would either resurrect
    // dropped edges or lose live ones.
    final ctx = Context();
    final source = Source<int>(ctx, 0);
    final gate = Source<bool>(ctx, true);

    final subs = [
      for (var i = 0; i < edgeIndexPromoteThreshold * 2; i++)
        Slot<int>(ctx, (cx) => cx.get(gate) ? cx.get(source) + i : -1),
    ];
    for (final s in subs) {
      s();
    }

    // Close the gate: every subscriber drops its edge to `source`, taking the
    // dependent list from wide to empty — through the demote threshold.
    gate.value = false;
    for (var i = 0; i < subs.length; i++) {
      expect(subs[i](), equals(-1));
    }

    // `source` now has no live dependents; a write must not resurrect any.
    source.value = 99;
    for (var i = 0; i < subs.length; i++) {
      expect(subs[i](), equals(-1));
    }

    // Re-open the gate and climb back through the promote threshold.
    gate.value = true;
    for (var i = 0; i < subs.length; i++) {
      expect(subs[i](), equals(99 + i));
    }

    source.value = 7;
    for (var i = 0; i < subs.length; i++) {
      expect(subs[i](), equals(7 + i));
    }
  });

  test('wide fan-in: one slot reading many sources tracks all of them', () {
    // The upstream (`_dependencies`) index is the symmetric case.
    final ctx = Context();
    final sources = [
      for (var i = 0; i < edgeIndexPromoteThreshold * 3; i++) Source<int>(ctx, 1),
    ];
    final total = Slot<int>(ctx, (cx) {
      var sum = 0;
      for (final c in sources) {
        sum += cx.get(c);
      }
      return sum;
    });

    expect(total(), equals(sources.length));

    // Changing any single source must invalidate — including the last one
    // registered, which is the one a broken index would drop.
    sources.last.value = 10;
    expect(total(), equals(sources.length + 9));

    sources.first.value = 10;
    expect(total(), equals(sources.length + 18));

    sources[sources.length ~/ 2].value = 10;
    expect(total(), equals(sources.length + 27));
  });

  test('effects at wide fan-out fire exactly once per publish', () {
    final ctx = Context();
    final source = Source<int>(ctx, 0);
    final counts = List<int>.filled(edgeIndexPromoteThreshold * 2, 0);
    final effects = <Effect>[
      for (var i = 0; i < counts.length; i++)
        Effect(ctx, (cx) {
          cx.get(source);
          counts[i]++;
          return null;
        }),
    ];

    for (final c in counts) {
      expect(c, equals(1));
    }

    source.value = 1;
    for (final c in counts) {
      expect(c, equals(2));
    }

    source.value = 2;
    for (final c in counts) {
      expect(c, equals(3));
    }

    for (final e in effects) {
      e.dispose();
    }
    source.value = 3;
    for (final c in counts) {
      expect(c, equals(3), reason: 'disposed effects must not rerun');
    }
  });

  _disposalPlaneTests();
}

// -- Disposal / teardown-scope plane (`#lzspecedgeindex`) --------------------
//
// The shared reactive-graph corpus (replayed in
// `reactive_graph_conformance_test.dart`) pins most of this plane, but two of
// its three stated semantics are NOT discriminated by any fixture in it, which
// was established by mutation rather than assumed:
//
//   * "effects reached by the disposal walk MUST NOT be scheduled" — every
//     corpus fixture that has an effect in a disposed cone disposes that effect
//     first, so scheduling it instead changes nothing observable there;
//   * "teardown order is reverse creation order" — the only scope in the corpus
//     that carries a `cleanup_order` assertion owns exactly one effect, and the
//     assertion projects onto effect entries, so a forward-order teardown
//     produces the identical single-entry log.
//
// Both mutations left the whole corpus green. These tests are the ones that go
// red, so the semantics are pinned by something rather than by nobody.
void _disposalPlaneTests() {
  group('disposal', () {
    test('dirties the surviving dependent cone', () {
      // The single most likely thing to get wrong (`lazily-rs` 5db90d2,
      // `lazily-js` 4d20670): detaching edges without marking dependents leaves
      // a live reader frozen on the value it cached *through* the disposed node.
      final ctx = Context();
      final src = Source<int>(ctx, 1);
      final mid = Slot<int>(ctx, (cx) => cx.get(src) + 1);
      final reader = Slot<int>(ctx, (cx) => cx.get(mid) * 10);

      expect(reader(), 20);
      ctx.disposeNode(mid);

      expect(() => reader(), throwsA(isA<DisposedNodeError>()),
          reason: 'a live reader that still names a disposed dependency must '
              'error on its next recompute, not serve its cached value');
    });

    test('does not schedule effects reached by the walk', () {
      // Disposal is not a publish. Running an effect during teardown re-enters
      // a compute that reads the node being disposed, which turns `dispose`
      // itself into a throw and breaks teardown idempotence. Mark dirty only —
      // the contract is "errors on the next recompute".
      final ctx = Context();
      final src = Source<int>(ctx, 1);
      final mid = Slot<int>(ctx, (cx) => cx.get(src) + 1);

      var runs = 0;
      var sawDisposed = false;
      Effect(ctx, (cx) {
        runs++;
        // Reads `src` directly as well as through `mid`, so the effect still
        // holds a live edge after `mid` is disposed and a later write to `src`
        // genuinely reaches it. An effect whose *only* dependency was the
        // disposed node has nothing left to schedule it and is deaf by
        // construction, which would make this test vacuous.
        cx.get(src);
        try {
          cx.get(mid);
        } on DisposedNodeError {
          sawDisposed = true;
        }
        return null;
      });
      expect(runs, 1);

      ctx.disposeNode(mid);
      expect(runs, 1,
          reason: 'the effect reached by the disposal walk must not rerun');
      expect(sawDisposed, isFalse);

      // Nor may it be left *queued*. A teardown that enqueues the effect defers
      // the damage rather than avoiding it: the effect then fires on the next
      // unrelated flush — a write to a cell it does not even read — as a
      // spurious rerun no publish asked for.
      final unrelated = Source<int>(ctx, 0);
      Effect(ctx, (cx) {
        cx.get(unrelated);
        return null;
      });
      unrelated.value = 1;
      expect(runs, 1,
          reason: 'a publish the effect does not observe must not flush it');
      expect(sawDisposed, isFalse);

      // A real write still reaches it, and *that* recompute is where the error
      // surfaces.
      src.value = 2;
      expect(runs, 2);
      expect(sawDisposed, isTrue);
    });

    test('is idempotent', () {
      final ctx = Context();
      final cell = Source<int>(ctx, 1);
      final slot = Slot<int>(ctx, (cx) => cx.get(cell));
      expect(slot(), 1);

      ctx.disposeNode(slot);
      expect(() => ctx.disposeNode(slot), returnsNormally);
      ctx.disposeNode(cell);
      expect(() => ctx.disposeNode(cell), returnsNormally);
    });

    test('detaches edges in both directions', () {
      final ctx = Context();
      final src = Source<int>(ctx, 1);
      final mid = Slot<int>(ctx, (cx) => cx.get(src) + 1);
      final sink = Slot<int>(ctx, (cx) => cx.get(mid) + 10);

      expect(sink(), 12);
      expect(ctx.dependentCount(src), 1);
      expect(ctx.dependencyCount(sink), 1);

      ctx.disposeNode(mid);
      expect(ctx.dependentCount(src), 0, reason: 'upstream half-edge leaked');
      expect(ctx.dependencyCount(sink), 0,
          reason: 'downstream half-edge leaked');
      expect(ctx.dependentCount(mid), 0);
      expect(ctx.dependencyCount(mid), 0);
    });

    test('subscribe/unsubscribe churn returns to baseline', () {
      final ctx = Context();
      final topic = Source<int>(ctx, 0);
      final subs = <Effect>[
        for (var i = 0; i < 8; i++)
          Effect(ctx, (cx) {
            cx.get(topic);
            return null;
          }),
      ];
      expect(ctx.dependentCount(topic), 8);

      for (var c = 0; c < 200; c++) {
        final at = c % 8;
        subs[at].dispose();
        subs[at] = Effect(ctx, (cx) {
          cx.get(topic);
          return null;
        });
      }
      expect(ctx.dependentCount(topic), 8,
          reason: 'the dependent set must track live subscribers, not total '
              'ever created');
    });
  });

  group('teardown scope', () {
    test('tears down in reverse creation order', () {
      // Graph state is order-independent, but effect *cleanups* are side
      // effects and their order is observable. Reverse creation order means
      // dependents go before what they read, so a scope never transiently
      // dangles inside itself.
      final ctx = Context();
      final topic = Source<int>(ctx, 1);
      final cleanups = <String>[];
      final scope = ctx.scope();
      final a = scope.slot<int>((cx) => cx.get(topic) + 1);
      final b = scope.slot<int>((cx) => cx.get(a) + 2);
      scope.effect((cx) {
        cx.get(b);
        return () => cleanups.add('watch_b');
      });
      scope.effect((cx) {
        cx.get(b);
        return () => cleanups.add('watch_b2');
      });

      expect(scope.length, 4);
      scope.end();
      expect(cleanups, ['watch_b2', 'watch_b'],
          reason: 'later-created members tear down first');
      expect(scope.length, 0);
    });

    test('ending is observationally equal to disposing each member', () {
      List<Object> run(bool useScope) {
        final ctx = Context();
        final topic = Source<int>(ctx, 1);
        final cleanups = <String>[];
        final scope = ctx.scope();
        final a = useScope
            ? scope.slot<int>((cx) => cx.get(topic) + 1)
            : Slot<int>(ctx, (cx) => cx.get(topic) + 1);
        final b = useScope
            ? scope.slot<int>((cx) => cx.get(a) + 2)
            : Slot<int>(ctx, (cx) => cx.get(a) + 2);
        Effect effect(Context c) => Effect(c, (cx) {
              cx.get(b);
              return () => cleanups.add('watch');
            });
        final w = useScope ? scope.adopt(effect(ctx)) : effect(ctx);
        expect(b(), 4);

        if (useScope) {
          scope.end();
        } else {
          w.dispose();
          b.dispose();
          a.dispose();
        }
        return [cleanups.join(','), ctx.dependentCount(topic), w.isActive];
      }

      expect(run(true), equals(run(false)));
    });

    test('disarm cancels teardown and disposes nothing', () {
      final ctx = Context();
      final topic = Source<int>(ctx, 1);
      final scope = ctx.scope();
      final escaped = scope.slot<int>((cx) => cx.get(topic));
      expect(escaped(), 1);
      expect(scope.length, 1);

      scope.disarm();
      expect(scope.length, 0);
      scope.end();

      expect(escaped(), 1, reason: 'a disarmed scope disposes nothing');
      expect(ctx.dependentCount(topic), 1, reason: 'and detaches nothing');

      topic.value = 5;
      expect(escaped(), 5, reason: 'the nodes still propagate');

      // Nodes revert to plain context ownership and stay individually
      // disposable.
      escaped.dispose();
      expect(ctx.dependentCount(topic), 0);
    });

    test('withScope ends the scope even on a throw', () {
      final ctx = Context();
      final topic = Source<int>(ctx, 1);
      late Slot<int> leaked;
      expect(
        () => ctx.withScope((scope) {
          leaked = scope.slot<int>((cx) => cx.get(topic));
          leaked();
          throw StateError('boom');
        }),
        throwsA(isA<StateError>()),
      );
      expect(() => leaked(), throwsA(isA<DisposedNodeError>()));
      expect(ctx.dependentCount(topic), 0);
    });

    test('bounds teardown, not visibility', () {
      final ctx = Context();
      final topic = Source<int>(ctx, 2);
      final parentOwned = Slot<int>(ctx, (cx) => cx.get(topic) + 3);

      final g1 = ctx.scope();
      final g2 = ctx.scope();
      final fromParent = g1.slot<int>((cx) => cx.get(parentOwned) + 1);
      final fromSibling = g2.slot<int>((cx) => cx.get(fromParent) + 10);
      final parentReadsChild = Slot<int>(ctx, (cx) => cx.get(fromSibling));

      expect(parentReadsChild(), 16,
          reason: 'reads cross scope boundaries freely in every direction');

      g2.end();
      expect(fromParent(), 6, reason: 'the sibling scope is untouched');
      expect(parentOwned(), 5, reason: 'the parent is untouched');

      g1.end();
      expect(() => fromParent(), throwsA(isA<DisposedNodeError>()));
      expect(parentOwned(), 5);
    });
  });

  group('degree introspection', () {
    test('reports counts, and zero for disposed or wrong-kind nodes', () {
      final ctx = Context();
      final cell = Source<int>(ctx, 1);
      final slot = Slot<int>(ctx, (cx) => cx.get(cell));
      final effect = Effect(ctx, (cx) {
        cx.get(slot);
        return null;
      });

      expect(ctx.dependencyCount(cell), 0, reason: 'cells are pure sources');
      expect(ctx.dependentCount(effect), 0, reason: 'effects are pure sinks');
      expect(ctx.dependentCount(cell), 1);
      expect(ctx.dependencyCount(slot), 1);
      expect(ctx.dependentCount(slot), 1);

      expect(ctx.isNodeDisposed(slot), isFalse);
      ctx.disposeNode(slot);
      expect(ctx.isNodeDisposed(slot), isTrue);
      expect(ctx.dependentCount(slot), 0);
      expect(ctx.dependencyCount(slot), 0);
    });
  });
}
