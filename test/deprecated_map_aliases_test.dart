// ignore_for_file: deprecated_member_use_from_same_package
import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

/// Back-compat guard for the v2 keyed-collection rename.
///
/// The v2 kernel renamed the node kinds to `Source` / `Computed`, so the keyed
/// collections became `SourceMap` / `ComputedMap` (and their `Async` /
/// `ThreadSafe` specializations) and the ordered keyed tree became
/// `SourceTree`. The old `CellMap` / `SlotMap` / `CellTree` spellings are
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
    expect(
        AsyncSlotMap<String, int>(ctx), isA<AsyncComputedMap<String, int>>());
    expect(ThreadSafeCellMap<String, int>(ctx),
        isA<ThreadSafeSourceMap<String, int>>());
    expect(ThreadSafeSlotMap<String, int>(ctx),
        isA<ThreadSafeComputedMap<String, int>>());
  });

  test('deprecated EntryKind.cell / EntryKind.slot aliases resolve', () {
    // Enum values cannot be typedef'd, so these are static const members on the
    // enum rather than deprecated values — the enum itself still has exactly
    // two values.
    expect(EntryKind.cell, EntryKind.source);
    expect(EntryKind.slot, EntryKind.computed);
    expect(EntryKind.values, [EntryKind.source, EntryKind.computed]);
  });

  test('EntryKind wire spelling is unchanged by the v2 rename', () {
    // The rename is Dart-side only. `lazily-spec` fixtures and the nine binding
    // runners that replay them still speak `cell` / `slot`, so anything that
    // serializes an EntryKind must go through `wireName`, NOT `name`. This test
    // is the pin: it fails if the wire words ever follow the Dart words.
    expect(EntryKind.source.wireName, 'cell');
    expect(EntryKind.computed.wireName, 'slot');
    expect(EntryKind.values.map((k) => k.wireName), ['cell', 'slot']);

    // And the trap this guards, stated explicitly: `.name` is NOT the wire form.
    expect(EntryKind.source.name, 'source');
    expect(EntryKind.computed.name, 'computed');
  });

  test('deprecated CellTree alias constructs the renamed type', () {
    final ctx = Context();

    final root = CellTree<String, int>(ctx, 'root', 0);
    expect(root, isA<SourceTree<String, int>>());

    final child = root.insertChild('a', 1);
    expect(child, isA<SourceTree<String, int>>());
    root.insertChild('b', 2);
    expect(root.childIds(), equals(['a', 'b']));
    expect(root.child('a')?.get(), 1);
  });
}
