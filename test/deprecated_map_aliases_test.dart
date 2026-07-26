// ignore_for_file: deprecated_member_use_from_same_package
import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

/// Back-compat guard for the v2 keyed-map rename.
///
/// The v2 kernel renamed the node kinds to `Source` / `Computed`, so the keyed
/// collections became `SourceMap` / `ComputedMap` (and their `Async` /
/// `ThreadSafe` specializations). The old `CellMap` / `SlotMap` spellings are
/// deprecated typedefs, not deletions — callers on the previous names must keep
/// compiling AND keep constructing the same runtime type. Asserting `isA<...>`
/// on a real instance is the positive check: a typedef that resolved to the
/// wrong class, or an alias that stopped being usable as a constructor, fails
/// here rather than silently in a downstream package.
void main() {
  test('deprecated CellMap / SlotMap aliases construct the renamed types', () {
    final ctx = Context();

    final cells = CellMap<String, int>(ctx)..set('a', 1);
    expect(cells, isA<SourceMap<String, int>>());
    expect(cells.get('a'), 1);

    final slots = ComputedMap<String, int>(ctx);
    final aliased = SlotMap<String, int>(ctx)
      ..materializeAll(['a'], (cx, k) => 7);
    expect(aliased, isA<ComputedMap<String, int>>());
    expect(aliased.get('a'), 7);
    expect(slots.entryKind, aliased.entryKind);
  });

  test('deprecated Async / ThreadSafe map aliases construct the renamed types',
      () {
    final ctx = Context();

    expect(AsyncCellMap<String, int>(ctx), isA<AsyncSourceMap<String, int>>());
    expect(AsyncSlotMap<String, int>(ctx), isA<AsyncComputedMap<String, int>>());
    expect(ThreadSafeCellMap<String, int>(ctx),
        isA<ThreadSafeSourceMap<String, int>>());
    expect(ThreadSafeSlotMap<String, int>(ctx),
        isA<ThreadSafeComputedMap<String, int>>());
  });
}
