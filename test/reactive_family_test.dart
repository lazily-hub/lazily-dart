import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

/// Unit tests for the unified keyed reactive family ([ReactiveFamily]) and its
/// materialization mode (`#lzmatmode`). Mirrors the Rust unit tests in
/// `lazily-rs/src/reactive_family.rs`.
void main() {
  group('ReactiveFamily materialization mode', () {
    test('default mode is eager', () {
      expect(kDefaultMaterializationMode, MaterializationMode.eager);
      final ctx = Context();
      final fam = ReactiveFamily.create<int, int>(ctx, [1], (k) => k);
      expect(fam.mode, MaterializationMode.eager);
    });

    test('eager materializes all up front', () {
      final ctx = Context();
      final fam =
          ReactiveFamily.eager<int, int>(ctx, [0, 1, 2, 5, 9], (k) => k * 3);
      expect(fam.presentCount(), 5);
      for (final k in [0, 1, 2, 5, 9]) {
        expect(fam.isPresent(k), isTrue);
      }
    });

    test('lazy defers slots until read', () {
      final ctx = Context();
      final fam =
          ReactiveFamily.lazy<int, int>(ctx, [0, 1, 2, 5, 9], (k) => k * 3);
      expect(fam.presentCount(), 0);
      expect(fam.isPresent(5), isFalse);

      // First read materializes just that key ("materialize on pull").
      expect(fam.observe(5), 15);
      expect(fam.isPresent(5), isTrue);
      expect(fam.presentKeys(), [5]);
    });

    test('eager and lazy observe identically', () {
      final ctx = Context();
      final eager =
          ReactiveFamily.eager<int, int>(ctx, [0, 1, 2, 5, 9], (k) => k * 3);
      final lazy =
          ReactiveFamily.lazy<int, int>(ctx, [0, 1, 2, 5, 9], (k) => k * 3);
      for (final k in [0, 1, 2, 5, 9]) {
        expect(eager.observe(k), lazy.observe(k));
      }
    });

    test('present set is monotone across reads', () {
      final ctx = Context();
      final fam =
          ReactiveFamily.lazy<int, int>(ctx, [1, 2, 3, 4, 5], (k) => k * 2);
      final sizes = <int>[];
      for (final k in [2, 4, 2, 5]) {
        fam.observe(k);
        sizes.add(fam.presentCount());
      }
      // Re-reading 2 does not re-materialize; sizes are non-decreasing.
      expect(sizes, [1, 2, 2, 3]);
      expect(fam.presentKeys(), [2, 4, 5]);
    });
  });

  group('ReactiveFamily entry kind', () {
    test('cell family is materialized in every mode', () {
      final ctx = Context();
      for (final lazyMode in [false, true]) {
        final keys = ['a', 'b', 'c'];
        final fam = lazyMode
            ? ReactiveFamily.lazy<String, int>(ctx, keys, (_) => 0,
                entryKind: EntryKind.cell)
            : ReactiveFamily.eager<String, int>(ctx, keys, (_) => 0,
                entryKind: EntryKind.cell);
        expect(fam.entryKind('a'), EntryKind.cell);
        // Cells are always present at build, even under lazy.
        expect(fam.presentCount(), 3);
      }
    });

    test('cell family entries are writable inputs', () {
      final ctx = Context();
      final fam = ReactiveFamily.eager<int, int>(ctx, [7], (k) => k,
          entryKind: EntryKind.cell);
      final cell = fam.cell(7);
      expect(cell.get(), 7);
      cell.set(100);
      expect(fam.observe(7), 100);
    });

    test('setCell drives dependents through the family', () {
      final ctx = Context();
      final fam = ReactiveFamily.eager<String, int>(ctx, ['x'], (_) => 1,
          entryKind: EntryKind.cell);
      final doubled = Slot<int>(ctx, (_) => fam.observe('x') * 2);
      expect(doubled(), 2);
      fam.setCell('x', 5);
      expect(doubled(), 10);
    });

    test('mixed per-key entry kinds via resolver', () {
      final ctx = Context();
      final vals = {'in': 5, 'der': 12};
      final fam = ReactiveFamily.lazy<String, int>(
        ctx,
        ['in', 'der'],
        (k) => vals[k]!,
        entryKind: (k) => k == 'in' ? EntryKind.cell : EntryKind.slot,
      );
      // The input cell is present at build; the derived slot is deferred.
      expect(fam.presentKeys(), ['in']);
      expect(fam.entryKind('in'), EntryKind.cell);
      expect(fam.entryKind('der'), EntryKind.slot);
      expect(fam.observe('der'), 12);
      expect(fam.presentKeys(), ['in', 'der']);
    });

    test('cell() rejects a derived slot; slot() rejects an input cell', () {
      final ctx = Context();
      final fam = ReactiveFamily.eager<String, int>(
        ctx,
        ['in', 'der'],
        (k) => 0,
        entryKind: (k) => k == 'in' ? EntryKind.cell : EntryKind.slot,
      );
      expect(() => fam.cell('der'), throwsStateError);
      expect(() => fam.slot('in'), throwsStateError);
      expect(fam.cell('in'), isA<Cell<int>>());
      expect(fam.slot('der'), isA<Slot<int>>());
    });

    test('cellFamily helper fixes entry kind to cell', () {
      final ctx = Context();
      final fam = cellFamily<String, int>(ctx, ['a', 'b'], (_) => 1);
      expect(fam.entryKind('a'), EntryKind.cell);
      expect(fam.presentCount(), 2);
    });
  });

  group('ReactiveFamily reactivity', () {
    test('derived slot recomputes when an upstream cell changes', () {
      final ctx = Context();
      final base = Cell<int>(ctx, 2);
      final fam = ReactiveFamily.lazy<int, int>(
          ctx, const <int>[], (k) => base.value * k);
      expect(fam.observe(3), 6);
      base.value = 10;
      expect(fam.observe(3), 30);
    });
  });
}
