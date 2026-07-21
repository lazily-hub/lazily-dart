import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

/// Unit tests for the thread-safe reactive context ([ThreadSafeContext]) and its
/// pure batch-flush kernel ([applyBatch] / [flushBatch] / [unionDependents]).
/// Mirrors `lazily-go/thread_safe.go`'s tests and the Lean `ThreadSafe` model.
void main() {
  group('ThreadSafeContext serialization', () {
    test('a one-write section is identical to a plain Cell.set', () {
      // flushBatch_singleton_eq_setCell: the thread-safe context refines the
      // single-threaded kernel — a singleton batch ≡ setCell.
      final ts = ThreadSafeContext();
      final cell = ts.source<int>(0);
      final doubled = ts.read((ctx) => Slot<int>(ctx, (_) => cell.value * 2));
      expect(ts.getSlot(doubled), 0);

      ts.set(cell, 5);
      expect(ts.getSlot(doubled), 10);

      // Same observable result as driving a bare Context/Cell directly.
      final ctx2 = Context();
      final cell2 = Source<int>(ctx2, 0);
      final doubled2 = Slot<int>(ctx2, (_) => cell2.value * 2);
      cell2.set(5);
      expect(doubled2(), ts.getSlot(doubled));
    });

    test('withLock gives access to the underlying Context', () {
      final ts = ThreadSafeContext();
      late Source<int> cell;
      ts.withLock((ctx) {
        cell = Source<int>(ctx, 7);
      });
      expect(ts.get(cell), 7);
      expect(identical(ts.context, ts.context), isTrue);
    });

    test('read returns the closure result under the guard', () {
      final ts = ThreadSafeContext();
      final cell = ts.source<int>(3);
      final v = ts.read((_) => cell.get() + 1);
      expect(v, 4);
    });
  });

  group('ThreadSafeContext reentrancy', () {
    test('withLock body may call batch/setCell without deadlock', () {
      final ts = ThreadSafeContext();
      final a = ts.source<int>(1);
      final b = ts.source<int>(2);
      final sum = ts.read((ctx) => Slot<int>(ctx, (_) => a.value + b.value));
      expect(ts.getSlot(sum), 3);

      ts.withLock((_) {
        expect(ts.depth, 1); // inside the guard
        ts.batch(() {
          expect(ts.depth, 2); // reentrant nesting (withLock → batch)
          ts.set(a, 10); // setCell re-enters to depth 3, unwinds to 2
          ts.set(b, 20);
          expect(ts.depth, 2); // back at the batch level after each setCell
        });
      });
      expect(ts.depth, 0); // fully unwound
      expect(ts.getSlot(sum), 30);
    });

    test('depth returns to zero after each section', () {
      final ts = ThreadSafeContext();
      expect(ts.depth, 0);
      ts.read((_) => 1);
      expect(ts.depth, 0);
      final cell = ts.source<int>(0);
      ts.set(cell, 1);
      expect(ts.depth, 0);
    });
  });

  group('ThreadSafeContext batch coalescing', () {
    test('batched writes flush once at the outermost boundary', () {
      final ts = ThreadSafeContext();
      final a = ts.source<int>(1);
      final b = ts.source<int>(2);
      var recomputes = 0;
      final sum = ts.read((ctx) => Slot<int>(ctx, (_) {
            recomputes++;
            return a.value + b.value;
          }));
      expect(ts.getSlot(sum), 3); // recomputes == 1
      expect(recomputes, 1);

      ts.batch(() {
        ts.set(a, 10);
        ts.set(b, 20);
      });
      // Coalesced: both writes → one invalidation → one recompute on next read.
      expect(ts.getSlot(sum), 30);
      expect(recomputes, 2);
    });
  });

  group('pure batch-flush kernel: applyBatch', () {
    test('PartialEq guard: an equal write produces no churn', () {
      final nodes = <Object, NodeEntry>{
        'a': const NodeEntry.clean(1),
      };
      final res = applyBatch(nodes, const [BatchWrite('a', 1)]);
      expect(res.changed, isEmpty);
      expect(res.nodes['a'], const NodeEntry.clean(1)); // still clean
      // input map untouched
      expect(nodes['a'], const NodeEntry.clean(1));
    });

    test('a changed write dirties the node and records the source once', () {
      final nodes = <Object, NodeEntry>{
        'a': const NodeEntry.clean(1),
      };
      final res =
          applyBatch(nodes, const [BatchWrite('a', 2), BatchWrite('a', 3)]);
      expect(res.changed, ['a']); // deduped despite two writes
      expect(res.nodes['a'], const NodeEntry.dirty(3));
    });

    test('a write to an unknown node is ignored', () {
      final nodes = <Object, NodeEntry>{'a': const NodeEntry.clean(1)};
      final res = applyBatch(nodes, const [BatchWrite('z', 9)]);
      expect(res.changed, isEmpty);
      expect(res.nodes.containsKey('z'), isFalse);
    });
  });

  group('pure batch-flush kernel: flushBatch', () {
    test('empty batch flush is the identity', () {
      // flushBatch_empty
      final nodes = <Object, NodeEntry>{
        'a': const NodeEntry.clean(1),
        'b': const NodeEntry.clean(2),
      };
      final out = flushBatch(nodes, const {}, const []);
      expect(out['a'], const NodeEntry.clean(1));
      expect(out['b'], const NodeEntry.clean(2));
    });

    test('coalesced frontier: a dependent of any changed source is dirty', () {
      // flushBatch_dependent_dirty
      final nodes = <Object, NodeEntry>{
        'a': const NodeEntry.clean(1),
        'b': const NodeEntry.clean(1),
        'd': const NodeEntry.clean(0),
      };
      final deps = <Object, List<Object>>{
        'a': ['d'],
        'b': ['d'],
      };
      final out = flushBatch(
          nodes, deps, const [BatchWrite('a', 2), BatchWrite('b', 2)]);
      expect(out['d']!.state, 'dirty');
      expect(out['a'], const NodeEntry.dirty(2));
    });

    test('coalesced frontier dedups a shared dependent (marked once)', () {
      // The dependent 'd' is reached via both changed sources but appears once
      // in the frontier — marking already-dirty is a no-op, so the result is a
      // deterministic function of the writes.
      final nodes = <Object, NodeEntry>{
        'a': const NodeEntry.clean(1),
        'b': const NodeEntry.clean(1),
        'd': const NodeEntry.clean(0),
      };
      final deps = <Object, List<Object>>{
        'a': ['d'],
        'b': ['d'],
      };
      final union = unionDependents(deps, ['a', 'b']);
      expect(union, ['d', 'd']); // flat union has duplicates...
      final out = flushBatch(
          nodes, deps, const [BatchWrite('a', 2), BatchWrite('b', 2)]);
      expect(out['d']!.state, 'dirty'); // ...but the frontier marks once
    });

    test('glitch-freedom: an unrelated branch keeps its dirty flag', () {
      // flushBatch_preserves_nondependent_dirty
      final nodes = <Object, NodeEntry>{
        'a': const NodeEntry.clean(1),
        'd': const NodeEntry.clean(0),
        'x': const NodeEntry.clean(5), // not a dependent of 'a'
      };
      final deps = <Object, List<Object>>{
        'a': ['d'],
      };
      final out = flushBatch(nodes, deps, const [BatchWrite('a', 2)]);
      expect(out['x'], const NodeEntry.clean(5)); // untouched
      expect(out['d']!.state, 'dirty');
    });

    test('order-independence: reordered writes give the same table', () {
      final nodes = <Object, NodeEntry>{
        'a': const NodeEntry.clean(1),
        'b': const NodeEntry.clean(1),
        'da': const NodeEntry.clean(0),
        'db': const NodeEntry.clean(0),
      };
      final deps = <Object, List<Object>>{
        'a': ['da'],
        'b': ['db'],
      };
      final forward = flushBatch(
          nodes, deps, const [BatchWrite('a', 2), BatchWrite('b', 2)]);
      final reversed = flushBatch(
          nodes, deps, const [BatchWrite('b', 2), BatchWrite('a', 2)]);
      for (final k in ['a', 'b', 'da', 'db']) {
        expect(forward[k], reversed[k], reason: 'node $k differs by order');
      }
    });
  });
}
