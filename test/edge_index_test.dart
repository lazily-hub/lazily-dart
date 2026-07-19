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
        final source = Cell<int>(ctx, 0);
        final subs = [
          for (var i = 0; i < width; i++)
            Slot<int>(ctx, (_) => source.value * 1000 + i),
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
    final source = Cell<int>(ctx, 1);
    var runs = 0;

    // Pad the source's dependent list past the promote threshold so the
    // duplicate read below is deduped by the index rather than by scan.
    final padding = [
      for (var i = 0; i < edgeIndexPromoteThreshold + 8; i++)
        Slot<int>(ctx, (_) => source.value + i),
    ];
    for (final p in padding) {
      p();
    }

    final doubleReader = Slot<int>(ctx, (_) {
      runs++;
      return source.value + source.value;
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
    final source = Cell<int>(ctx, 0);
    final gate = Cell<bool>(ctx, true);

    final subs = [
      for (var i = 0; i < edgeIndexPromoteThreshold * 2; i++)
        Slot<int>(ctx, (_) => gate.value ? source.value + i : -1),
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
      for (var i = 0; i < edgeIndexPromoteThreshold * 3; i++) Cell<int>(ctx, 1),
    ];
    final total = Slot<int>(ctx, (_) {
      var sum = 0;
      for (final c in sources) {
        sum += c.value;
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
    final source = Cell<int>(ctx, 0);
    final counts = List<int>.filled(edgeIndexPromoteThreshold * 2, 0);
    final effects = <Effect>[
      for (var i = 0; i < counts.length; i++)
        Effect(ctx, (_) {
          source.value;
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
}
