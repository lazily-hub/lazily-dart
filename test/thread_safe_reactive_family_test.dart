import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

/// Unit tests for the thread-safe keyed reactive map ([ThreadSafeReactiveMap])
/// and its [ThreadSafeSourceMap] / [ThreadSafeComputedMap] specializations
/// (`#reactivemap`, thread-safe). Mirrors the Rust unit tests in
/// `lazily-rs/src/thread_safe_reactive_family.rs` and the Lean `Materialization`
/// confluence pair. Eager = pre-mint loop ([ThreadSafeComputedMap.materializeAll]);
/// lazy = mint-on-access ([ThreadSafeReactiveMap.getOrInsertWith]) — no mode
/// flag.
void main() {
  group('ThreadSafeComputedMap eager/lazy contract', () {
    test('eager materializes every declared slot at build', () {
      final ctx = Context();
      final fam = ThreadSafeComputedMap<int, int>(ctx)
        ..materializeAll([0, 1, 2], (k) => k * 3);
      expect(fam.entryKind, EntryKind.slot);
      expect(fam.presentCount(), 3);
      expect(fam.presentKeys(), [0, 1, 2]);
      for (final k in [0, 1, 2]) {
        expect(fam.isPresent(k), isTrue);
      }
    });

    test('lazy defers each slot to first read', () {
      final ctx = Context();
      final fam = ThreadSafeComputedMap<int, int>(ctx);
      expect(fam.presentCount(), 0);
      expect(fam.isPresent(1), isFalse);

      expect(fam.getOrInsertWith(1, (k) => k * 3), 3);
      expect(fam.isPresent(1), isTrue);
      expect(fam.presentCount(), 1);
      expect(fam.presentKeys(), [1]);
    });

    test('cell entries are materialized eagerly', () {
      final ctx = Context();
      final cells = ThreadSafeSourceMap<int, int>(ctx)
        ..materializeAll({0: 0, 1: 1});
      expect(cells.entryKind, EntryKind.cell);
      expect(cells.presentCount(), 2);
    });
  });

  group('ThreadSafeComputedMap transparency', () {
    test('observe returns an identical value under eager and lazy', () {
      final ctx = Context();
      final eager = ThreadSafeComputedMap<int, int>(ctx)
        ..materializeAll([1, 2, 3], (k) => k * 10);
      final lazy = ThreadSafeComputedMap<int, int>(ctx);
      for (final k in [1, 2, 3]) {
        expect(lazy.getOrInsertWith(k, (k) => k * 10), eager.observe(k));
      }
    });
  });

  group('ThreadSafeComputedMap present-set monotonicity', () {
    test('the materialized set only grows', () {
      final ctx = Context();
      final fam = ThreadSafeComputedMap<int, int>(ctx);
      expect(fam.presentCount(), 0);
      fam.getOrInsertWith(5, (k) => k);
      expect(fam.presentCount(), 1);
      fam.getOrInsertWith(5, (k) => k); // warm — no growth
      expect(fam.presentCount(), 1);
      fam.getOrInsertWith(6, (k) => k);
      expect(fam.presentCount(), 2);
      expect(fam.presentKeys(), [5, 6]);
    });
  });

  group('ThreadSafeComputedMap confluence', () {
    test('materializing in different orders → identical present set + values',
        () {
      final ctx = Context();
      final famA = ThreadSafeComputedMap<int, int>(ctx);
      final famB = ThreadSafeComputedMap<int, int>(ctx);

      // materialize_present_comm / materialize_observe_comm: order does not
      // change the present set or the observed values.
      famA.getOrInsertWith(1, (k) => k * 7);
      famA.getOrInsertWith(2, (k) => k * 7);
      famA.getOrInsertWith(3, (k) => k * 7);

      famB.getOrInsertWith(3, (k) => k * 7);
      famB.getOrInsertWith(1, (k) => k * 7);
      famB.getOrInsertWith(2, (k) => k * 7);

      final keysA = famA.presentKeys()..sort();
      final keysB = famB.presentKeys()..sort();
      expect(keysA, keysB); // same present set
      for (final k in [1, 2, 3]) {
        expect(famA.observe(k), famB.observe(k)); // same values
      }
    });
  });

  group('ThreadSafeSourceMap set', () {
    test('set overwrites and returns true', () {
      final ctx = Context();
      final cells = ThreadSafeSourceMap<int, int>(ctx)..set(1, 1);
      expect(cells.observe(1), 1);
      expect(cells.set(1, 42), isTrue);
      expect(cells.observe(1), 42);
    });
  });
}
