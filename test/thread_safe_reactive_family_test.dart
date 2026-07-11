import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

/// Unit tests for the thread-safe keyed reactive family
/// ([ThreadSafeReactiveFamily]). Mirrors `lazily-go/thread_safe_reactive_family.go`'s
/// tests and the Lean `Materialization` confluence pair.
void main() {
  group('ThreadSafeReactiveFamily eager/lazy contract', () {
    test('eager materializes every declared slot at build', () {
      final ctx = Context();
      final fam = ThreadSafeReactiveFamily.eagerSlotFamily<int, int>(
          ctx, [0, 1, 2], (k) => k * 3);
      expect(fam.mode, MaterializationMode.eager);
      expect(fam.entryKind, EntryKind.slot);
      expect(fam.presentCount(), 3);
      expect(fam.presentKeys(), [0, 1, 2]);
      for (final k in [0, 1, 2]) {
        expect(fam.isPresent(k), isTrue);
      }
    });

    test('lazy defers each slot to first read', () {
      final ctx = Context();
      final fam = ThreadSafeReactiveFamily.lazySlotFamily<int, int>(
          ctx, [0, 1, 2], (k) => k * 3);
      expect(fam.mode, MaterializationMode.lazy);
      expect(fam.presentCount(), 0);
      expect(fam.isPresent(1), isFalse);

      expect(fam.get(1), 3);
      expect(fam.isPresent(1), isTrue);
      expect(fam.presentCount(), 1);
      expect(fam.presentKeys(), [1]);
    });

    test('cell entries are materialized in every mode', () {
      final ctx = Context();
      final eager = ThreadSafeReactiveFamily.eagerCellFamily<int, int>(
          ctx, [0, 1], (k) => k);
      final lazy = ThreadSafeReactiveFamily.lazyCellFamily<int, int>(
          ctx, [0, 1], (k) => k);
      expect(eager.presentCount(), 2);
      expect(lazy.presentCount(), 2); // cells materialize at build even lazy
      expect(lazy.entryKind, EntryKind.cell);
    });
  });

  group('ThreadSafeReactiveFamily transparency', () {
    test('observe returns an identical value under either mode', () {
      final ctx = Context();
      final eager = ThreadSafeReactiveFamily.eagerSlotFamily<int, int>(
          ctx, [1, 2, 3], (k) => k * 10);
      final lazy = ThreadSafeReactiveFamily.lazySlotFamily<int, int>(
          ctx, [1, 2, 3], (k) => k * 10);
      for (final k in [1, 2, 3]) {
        expect(lazy.observe(k), eager.observe(k));
      }
    });
  });

  group('ThreadSafeReactiveFamily present-set monotonicity', () {
    test('the materialized set only grows', () {
      final ctx = Context();
      final fam = ThreadSafeReactiveFamily.lazySlotFamily<int, int>(
          ctx, const [], (k) => k);
      expect(fam.presentCount(), 0);
      fam.get(5);
      expect(fam.presentCount(), 1);
      fam.get(5); // warm — no growth
      expect(fam.presentCount(), 1);
      fam.get(6);
      expect(fam.presentCount(), 2);
      expect(fam.presentKeys(), [5, 6]);
    });
  });

  group('ThreadSafeReactiveFamily confluence', () {
    test('materializing in different orders → identical present set + values',
        () {
      final ctx = Context();
      final famA = ThreadSafeReactiveFamily.lazySlotFamily<int, int>(
          ctx, const [], (k) => k * 7);
      final famB = ThreadSafeReactiveFamily.lazySlotFamily<int, int>(
          ctx, const [], (k) => k * 7);

      // materialize_present_comm / materialize_observe_comm: order does not
      // change the present set or the observed values.
      famA.get(1);
      famA.get(2);
      famA.get(3);

      famB.get(3);
      famB.get(1);
      famB.get(2);

      final keysA = famA.presentKeys()..sort();
      final keysB = famB.presentKeys()..sort();
      expect(keysA, keysB); // same present set
      for (final k in [1, 2, 3]) {
        expect(famA.observe(k), famB.observe(k)); // same values
      }
    });
  });

  group('ThreadSafeReactiveFamily set', () {
    test('set on a slot family returns false', () {
      final ctx = Context();
      final slots = ThreadSafeReactiveFamily.eagerSlotFamily<int, int>(
          ctx, [1], (k) => k);
      expect(slots.set(1, 99), isFalse);
    });

    test('set on a cell family overwrites and returns true', () {
      final ctx = Context();
      final cells = ThreadSafeReactiveFamily.eagerCellFamily<int, int>(
          ctx, [1], (k) => k);
      expect(cells.observe(1), 1);
      expect(cells.set(1, 42), isTrue);
      expect(cells.observe(1), 42);
    });
  });
}
