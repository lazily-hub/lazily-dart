import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

/// Unit tests for the unified keyed reactive map ([ReactiveMap]) and its
/// [SourceMap] / [ComputedMap] specializations (`#reactivemap`). Mirrors the Rust unit
/// tests in `lazily-rs/src/cell_family.rs`. (Reactive membership/order/move
/// independence is covered by `collections_conformance_test.dart`.)
void main() {
  group('SourceMap specialization', () {
    test('entry caches one cell per key', () {
      final ctx = Context();
      final map = SourceMap<String, int>(ctx);
      final a1 = map.entry('a', 1);
      final a2 = map.entry('a', 999);
      // Same key -> same cell; the second default is ignored.
      expect(identical(a1, a2), isTrue);
      expect(a1.get(), 1);
      expect(map.lenUntracked, 1);
      expect(map.entryKind, EntryKind.source);
    });

    test('getOrInsertWith mints once then returns existing', () {
      final ctx = Context();
      final map = SourceMap<String, int>(ctx);
      var calls = 0;
      expect(
          map.getOrInsertWith('a', (_, __) {
            calls++;
            return 7;
          }),
          7);
      expect(map.lenUntracked, 1);
      // Second access returns the existing value; factory is NOT called again.
      expect(
          map.getOrInsertWith('a', (_, __) {
            calls++;
            return 999;
          }),
          7);
      expect(calls, 1);
      // An explicit set is observed by a subsequent getOrInsertWith.
      map.set('a', 42);
      expect(map.getOrInsertWith('a', (_, __) => 0), 42);
    });

    test('set drives dependents through the map', () {
      final ctx = Context();
      final map = SourceMap<String, int>(ctx);
      map.entry('x', 1);
      final doubled = Slot<int>(ctx, (cx) => map.read('x', cx)! * 2);
      expect(doubled(), 2);
      map.set('x', 5);
      expect(doubled(), 10);
    });
  });

  group('ComputedMap specialization', () {
    test('mints lazily and caches', () {
      final ctx = Context();
      final fam = ComputedMap<int, int>(ctx);
      // Nothing present until first access.
      expect(fam.presentCount(), 0);
      expect(fam.getOrInsertWith(7, (_, k) => k * 2), 14);
      expect(fam.presentCount(), 1);
      expect(fam.isPresent(7), isTrue);
      // Same key -> same derived slot (value preserved, factory not re-run).
      expect(fam.get(7), 14);
      expect(fam.getOrInsertWith(7, (_, k) => k * 999), 14);
      expect(fam.entryKind, EntryKind.computed);
    });

    test('materializeAll is eager (pre-mint)', () {
      final ctx = Context();
      final fam = ComputedMap<int, int>(ctx)
        ..materializeAll([0, 1, 2, 5, 9], (_, k) => k * 3);
      expect(fam.presentCount(), 5);
      for (final k in [0, 1, 2, 5, 9]) {
        expect(fam.isPresent(k), isTrue);
      }
      expect(fam.get(5), 15);
    });

    test('present set is monotone across lazy reads', () {
      final ctx = Context();
      final fam = ComputedMap<int, int>(ctx);
      final sizes = <int>[];
      for (final k in [2, 4, 2, 5]) {
        fam.getOrInsertWith(k, (_, k) => k * 2);
        sizes.add(fam.presentCount());
      }
      // Re-reading 2 does not re-materialize; sizes are non-decreasing.
      expect(sizes, [1, 2, 2, 3]);
      expect(fam.presentKeys(), [2, 4, 5]);
    });

    test('a derived slot recomputes when an upstream cell changes', () {
      final ctx = Context();
      final base = Source<int>(ctx, 2);
      final fam = ComputedMap<int, int>(ctx);
      expect(fam.getOrInsertWith(3, (cx, k) => cx.get(base) * k), 6);
      base.value = 10;
      expect(fam.get(3), 30);
    });

    test('entries are guarded Computed handles', () {
      final ctx = Context();
      final base = Source<int>(ctx, 1);
      final fam = ComputedMap<String, int>(ctx);
      expect(fam.getOrInsertWith('parity', (cx, _) => cx.get(base) & 1), 1);

      final handle = fam.handle('parity');
      expect(handle, isA<Computed<int>>());

      var downstreamRuns = 0;
      final downstream = Slot<int>(ctx, (cx) {
        downstreamRuns++;
        return cx.get(handle!);
      });
      expect(downstream(), 1);
      expect(downstreamRuns, 1);

      base.value =
          3; // parity is unchanged: the Computed guard stops the ripple.
      expect(downstream(), 1);
      expect(downstreamRuns, 1);
    });

    test('remove disposes a computed and bumps membership', () {
      final ctx = Context();
      final fam = ComputedMap<int, int>(ctx)
        ..materializeAll([1, 2], (_, k) => k);
      expect(fam.remove(1), isTrue);
      expect(fam.isPresent(1), isFalse);
      expect(fam.remove(1), isFalse);
      expect(fam.presentKeys(), [2]);
    });
  });

  group('eager and lazy observe identically', () {
    test('ComputedMap eager (materializeAll) == lazy (getOrInsertWith)', () {
      final ctx = Context();
      final eager = ComputedMap<int, int>(ctx)
        ..materializeAll([0, 1, 2, 5, 9], (_, k) => k * 3);
      final lazy = ComputedMap<int, int>(ctx);
      for (final k in [0, 1, 2, 5, 9]) {
        expect(lazy.getOrInsertWith(k, (_, k) => k * 3), eager.get(k));
      }
    });
  });
}
