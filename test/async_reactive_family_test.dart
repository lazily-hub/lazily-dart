import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

/// Unit tests for the async keyed reactive map ([AsyncReactiveMap]) and its
/// [AsyncCellMap] / [AsyncSlotMap] specializations (`#reactivemap`, async).
/// Mirrors the Rust unit tests in `lazily-rs/src/async_reactive_family.rs` and
/// the Lean `AsyncMaterialization` theorems. Eager = pre-mint loop
/// ([AsyncSlotMap.materializeAll]); lazy = mint-on-access ([AsyncSlotMap.touch]
/// + [AsyncSlotMap.drive]) — no mode flag.
void main() {
  group('AsyncSlotMap resolution axis', () {
    test('eager slot is present-but-pending, resolves after drive', () {
      // observe_pending_is_none, then eventual_transparency.
      final ctx = Context();
      final fam = AsyncSlotMap<int, int>(ctx)..materializeAll([1]);
      // Allocated (eager) but pending until driven.
      expect(fam.isPresent(1), isTrue);
      expect(fam.isResolved(1), isFalse);

      final (value, resolved) = fam.observe(1);
      expect(resolved, isFalse);
      expect(value, isNull);

      expect(fam.drive(1, (k) => k * 100), 100);
      expect(fam.isResolved(1), isTrue);
      final (value2, resolved2) = fam.observe(1);
      expect(resolved2, isTrue);
      expect(value2, 100);
    });

    test('lazy slot is absent until touched, then pending until driven', () {
      final ctx = Context();
      final fam = AsyncSlotMap<int, int>(ctx);
      expect(fam.isPresent(1), isFalse); // deferred under lazy
      fam.touch(1);
      expect(fam.isPresent(1), isTrue); // now allocated (pending)
      final (value, resolved) = fam.observe(1);
      expect(resolved, isFalse);
      expect(value, isNull);
      expect(fam.drive(1, (k) => k * 100), 100);
      expect(fam.isResolved(1), isTrue);
    });
  });

  group('AsyncCellMap cell entries', () {
    test('cell entries are resolved at build', () {
      // cell_resolved_at_build
      final ctx = Context();
      final fam = AsyncCellMap<int, int>(ctx)..materializeAll({1: 5, 2: 10});
      expect(fam.entryKind, EntryKind.cell);
      expect(fam.isResolved(1), isTrue);
      final (value, resolved) = fam.observe(1);
      expect(resolved, isTrue);
      expect(value, 5);
    });

    test('set on a cell overwrites and stays resolved', () {
      final ctx = Context();
      final fam = AsyncCellMap<int, int>(ctx);
      expect(fam.set(1, 42), isTrue);
      expect(fam.isResolved(1), isTrue);
      expect(fam.observe(1), (42, true));
    });
  });

  group('AsyncSlotMap resolve monotonicity', () {
    test('a driven key stays resolved (false → true only)', () {
      // resolve_monotone
      final ctx = Context();
      final fam = AsyncSlotMap<int, int>(ctx)..materializeAll([1]);
      expect(fam.isResolved(1), isFalse);
      fam.drive(1, (k) => k);
      expect(fam.isResolved(1), isTrue);
      fam.observe(1); // a read never un-resolves
      expect(fam.isResolved(1), isTrue);
      fam.drive(1, (k) => k * 999); // re-drive is idempotent
      expect(fam.isResolved(1), isTrue);
      expect(fam.observe(1), (1, true));
    });
  });

  group('AsyncSlotMap eventual transparency', () {
    test('resolved value == the synchronous (thread-safe) map value', () {
      // async_resolved_matches_sync
      final ctx = Context();
      final asyncFam = AsyncSlotMap<int, int>(ctx)..materializeAll([1, 2, 3]);
      final syncFam = ThreadSafeSlotMap<int, int>(ctx);
      for (final k in [1, 2, 3]) {
        expect(asyncFam.drive(k, (k) => k * 11),
            syncFam.getOrInsertWith(k, (k) => k * 11));
      }
    });
  });

  group('AsyncSlotMap present-set', () {
    test('present set grows in first-materialization order', () {
      final ctx = Context();
      final fam = AsyncSlotMap<int, int>(ctx);
      expect(fam.presentCount(), 0);
      fam.touch(3);
      fam.touch(1);
      fam.touch(3); // warm — no growth
      expect(fam.presentCount(), 2);
      expect(fam.presentKeys(), [3, 1]);
    });
  });
}
