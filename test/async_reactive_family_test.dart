import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

/// Unit tests for the async keyed reactive family ([AsyncReactiveFamily]).
/// Mirrors `lazily-go/async_reactive_family.go`'s tests and the Lean
/// `AsyncMaterialization` theorems.
void main() {
  group('AsyncReactiveFamily resolution axis', () {
    test('observe returns pending for a fresh slot, resolves after drive', () {
      // observe_pending_is_none, then eventual_transparency.
      final ctx = Context();
      final fam = AsyncReactiveFamily.eagerSlotFamily<int, int>(
          ctx, [1], (k) => k * 100);
      // Allocated at build (eager) but pending until driven.
      expect(fam.isPresent(1), isTrue);
      expect(fam.isResolved(1), isFalse);

      final (value, resolved) = fam.observe(1);
      expect(resolved, isFalse);
      expect(value, isNull);

      expect(fam.drive(1), 100);
      expect(fam.isResolved(1), isTrue);
      final (value2, resolved2) = fam.observe(1);
      expect(resolved2, isTrue);
      expect(value2, 100);
    });

    test('lazy slot is absent until observed, then pending until driven', () {
      final ctx = Context();
      final fam = AsyncReactiveFamily.lazySlotFamily<int, int>(
          ctx, [1], (k) => k * 100);
      expect(fam.isPresent(1), isFalse); // deferred under lazy
      final (value, resolved) = fam.observe(1);
      expect(resolved, isFalse);
      expect(value, isNull);
      expect(fam.isPresent(1), isTrue); // now allocated (pending)
      expect(fam.drive(1), 100);
      expect(fam.isResolved(1), isTrue);
    });
  });

  group('AsyncReactiveFamily cell entries', () {
    test('cell entries are resolved at build', () {
      // cell_resolved_at_build
      final ctx = Context();
      final fam = AsyncReactiveFamily.eagerCellFamily<int, int>(
          ctx, [1, 2], (k) => k * 5);
      expect(fam.entryKind, EntryKind.cell);
      expect(fam.isResolved(1), isTrue);
      final (value, resolved) = fam.observe(1);
      expect(resolved, isTrue);
      expect(value, 5);
    });

    test('lazy cell entries still resolve at build', () {
      final ctx = Context();
      final fam =
          AsyncReactiveFamily.lazyCellFamily<int, int>(ctx, [1], (k) => k * 5);
      expect(fam.isResolved(1), isTrue);
      expect(fam.observe(1), (5, true));
    });
  });

  group('AsyncReactiveFamily resolve monotonicity', () {
    test('a driven key stays resolved (false → true only)', () {
      // resolve_monotone
      final ctx = Context();
      final fam =
          AsyncReactiveFamily.eagerSlotFamily<int, int>(ctx, [1], (k) => k);
      expect(fam.isResolved(1), isFalse);
      fam.drive(1);
      expect(fam.isResolved(1), isTrue);
      fam.observe(1); // a read never un-resolves
      expect(fam.isResolved(1), isTrue);
      fam.drive(1); // re-drive is idempotent
      expect(fam.isResolved(1), isTrue);
    });
  });

  group('AsyncReactiveFamily eventual transparency', () {
    test('resolved value == the synchronous family value', () {
      // async_resolved_matches_sync
      final ctx = Context();
      final asyncFam = AsyncReactiveFamily.eagerSlotFamily<int, int>(
          ctx, [1, 2, 3], (k) => k * 11);
      final syncFam = ThreadSafeReactiveFamily.eagerSlotFamily<int, int>(
          ctx, [1, 2, 3], (k) => k * 11);
      for (final k in [1, 2, 3]) {
        expect(asyncFam.drive(k), syncFam.observe(k));
      }
    });
  });

  group('AsyncReactiveFamily present-set', () {
    test('present set grows in first-materialization order', () {
      final ctx = Context();
      final fam =
          AsyncReactiveFamily.lazySlotFamily<int, int>(ctx, const [], (k) => k);
      expect(fam.presentCount(), 0);
      fam.observe(3);
      fam.observe(1);
      fam.observe(3); // warm — no growth
      expect(fam.presentCount(), 2);
      expect(fam.presentKeys(), [3, 1]);
    });
  });

  group('AsyncReactiveFamily set', () {
    test('set on a slot family returns false', () {
      final ctx = Context();
      final slots =
          AsyncReactiveFamily.eagerSlotFamily<int, int>(ctx, [1], (k) => k);
      expect(slots.set(1, 99), isFalse);
    });

    test('set on a cell family overwrites and stays resolved', () {
      final ctx = Context();
      final cells =
          AsyncReactiveFamily.eagerCellFamily<int, int>(ctx, [1], (k) => k);
      expect(cells.set(1, 42), isTrue);
      expect(cells.isResolved(1), isTrue);
      expect(cells.observe(1), (42, true));
    });
  });
}
