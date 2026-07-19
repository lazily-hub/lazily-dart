import 'dart:convert';
import 'dart:io';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

/// Keyed cell collections conformance (lazily-spec/conformance/collections/).
///
/// Replays the canonical fixtures every binding replays, asserting the
/// value / set-membership / order reactivity-independence, the atomic-move
/// stable-handle invariant, and the LIS move-minimized reconciliation. Mirrors
/// `lazily-rs/tests/collections_conformance.rs` (the canonical harness) using
/// the live reactive graph: readers are primed as [Slot]s, and invalidation is
/// observed via `Slot.peek` (null after invalidation, non-null while cached).

final _localDir = Directory('test/conformance/collections');
final _specDir = Directory('../lazily-spec/conformance/collections');

// Fixture resolution is SIBLING-FIRST (`#lzspecconf`): the canonical
// lazily-spec checkout wins whenever it is present, and the mirrored copy under
// `test/conformance/` is a fallback for a checkout without the sibling — never
// an authority. The reverse order silently shadowed the canonical fixture with
// a stale mirror, so CI cloned lazily-spec and then tested the local copy and
// still reported green. `conformance_fixture_drift_test.dart` byte-compares the
// two whenever both exist, so a stale mirror fails loudly instead of hiding.
String _fixturePath(String name) {
  if (_specDir.existsSync()) {
    final sibling = _specDir.resolveSymbolicLinksSync() + '/$name';
    if (File(sibling).existsSync()) return sibling;
  }
  if (_localDir.existsSync()) {
    final local = _localDir.resolveSymbolicLinksSync() + '/$name';
    if (File(local).existsSync()) return local;
  }
  throw StateError('collections fixture not found: $name');
}

Map<String, dynamic> _loadFixture(String name) =>
    jsonDecode(File(_fixturePath(name)).readAsStringSync()) as Map<String, dynamic>;

/// Whether a [Slot]'s cache is still warm (not invalidated) — mirrors
/// `ctx.is_set(reader)` in lazily-rs.
bool _isWarm(Slot<dynamic> reader, Context ctx) => ctx.contains(reader);

void _seedInitial(Context ctx, CellMap<String, int> map, Map<String, dynamic> initial) {
  final order = (initial['order'] as List).cast<String>();
  final values = (initial['values'] as Map).cast<String, dynamic>();
  for (final k in order) {
    map.set(k, values[k] as int);
  }
}

/// Apply a fixture step op to the live map.
void _applyOp(Context ctx, CellMap<String, int> map, Map<String, dynamic> op) {
  switch (op['type'] as String) {
    case 'set_value':
      map.set(op['key'] as String, op['value'] as int);
    case 'insert':
      final key = op['key'] as String;
      final value = op['value'] as int;
      final at = op['at'];
      switch (at) {
        case 'end':
          map.set(key, value);
        case 'front':
          map.set(key, value);
          map.moveTo(key, 0);
        default:
          if (at is int) {
            map.set(key, value);
            map.moveTo(key, at);
          } else if (at is String) {
            map.set(key, value);
            map.moveAfter(key, at);
          } else {
            map.set(key, value);
          }
      }
    case 'remove':
      map.remove(op['key'] as String);
    case 'move_to':
      map.moveTo(op['key'] as String, op['index'] as int);
    case 'move_before':
      map.moveBefore(op['key'] as String, op['before'] as String);
    case 'move_after':
      map.moveAfter(op['key'] as String, op['after'] as String);
    default:
      throw StateError('unknown collections op type: ${op['type']}');
  }
}

List<String> _asOrder(Object? v) {
  if (v is List) return v.cast<String>();
  throw StateError('expected an order array, got $v');
}

void _runStepsFixture(String name) {
  final fixture = _loadFixture(name);
  final ctx = Context();
  final map = CellMap<String, int>(ctx);
  _seedInitial(ctx, map, fixture['initial'] as Map<String, dynamic>);

  final steps = (fixture['steps'] as List).cast<Map<String, dynamic>>();
  for (var i = 0; i < steps.length; i++) {
    final step = steps[i];
    final op = step['op'] as Map<String, dynamic>;
    final expected = step['expected'] as Map<String, dynamic>;
    final invalidates = expected['invalidates'] as Map<String, dynamic>;

    // Build readers from the CURRENT key set so each step's invalidation is
    // measured in isolation (matches lazily-rs).
    final currentKeys = map.keys()..clear();
    final valueReaders = <String, Slot<int?>>{};
    for (final k in currentKeys) {
      final slot = Slot<int?>(ctx, (_) => map.read(k));
      slot(); // prime
      valueReaders[k] = slot;
    }
    final membershipReader = Slot<int>(ctx, (_) => map.len())..call(); // prime
    final orderReader = Slot<List<String>>(ctx, (_) => map.keys())..call(); // prime

    // Snapshot handles for the keys this step checks handle_stability on.
    final handleStableKeys = (expected['handle_stable'] as Map<String, dynamic>?)
            ?.entries
            .where((e) => e.value == true)
            .map((e) => e.key)
            .toList() ??
        const <String>[];
    final handlesBefore = <String, Cell<int>>{
      for (final k in handleStableKeys) k: map.cell(k)!,
    };

    // Apply the op.
    _applyOp(ctx, map, op);

    // Assert invalidation. Value readers: only check survivor keys.
    final expectedValueInvalidations =
        (invalidates['value'] as List?)?.cast<String>() ?? const [];
    final survivors = map.keys();
    for (final entry in valueReaders.entries) {
      final k = entry.key;
      if (!survivors.contains(k)) continue; // removed: not checked
      final warm = _isWarm(entry.value, ctx);
      final invalidated = expectedValueInvalidations.contains(k);
      expect(warm, !invalidated,
          reason: '$name step $i `${op['type']}` value reader `$k`: '
              'expected invalidated=$invalidated');
    }

    // Membership reader.
    final membershipInvalidated = invalidates['membership'] == true;
    expect(_isWarm(membershipReader, ctx), !membershipInvalidated,
        reason: '$name step $i `${op['type']}` membership reader: '
            'expected invalidated=$membershipInvalidated');

    // Order reader.
    final orderInvalidated = invalidates['order'] == true;
    expect(_isWarm(orderReader, ctx), !orderInvalidated,
        reason: '$name step $i `${op['type']}` order reader: '
            'expected invalidated=$orderInvalidated');

    // Assert resulting state: order, membership (set-equal), values.
    final expectedOrder = _asOrder(expected['order']);
    expect(map.keys(), equals(expectedOrder),
        reason: '$name step $i `${op['type']}` order');

    final expectedMembership = _asOrder(expected['membership']);
    expect(map.keys().toSet(), equals(expectedMembership.toSet()),
        reason: '$name step $i `${op['type']}` membership');

    final expectedValues = expected['values'] as Map<String, dynamic>?;
    if (expectedValues != null) {
      for (final e in expectedValues.entries) {
        expect(map.get(e.key), e.value,
            reason: '$name step $i `${op['type']}` value[${e.key}]');
      }
    }

    // Assert handle stability (same Cell identity before & after).
    for (final k in handleStableKeys) {
      final after = map.cell(k);
      expect(after, isNotNull, reason: '$name step $i `$k` handle still present');
      expect(identical(handlesBefore[k], after), isTrue,
          reason: '$name step $i `${op['type']}` `$k` handle_stable');
    }
  }
}

void _runReconcileFixture(String name) {
  final fixture = _loadFixture(name);
  final reconcile = fixture['reconcile'] as Map<String, dynamic>;
  final expected = fixture['expected'] as Map<String, dynamic>;

  List<MapEntry<String, int>> pairs(Map<String, dynamic> state) {
    final order = (state['order'] as List).cast<String>();
    final values = (state['values'] as Map).cast<String, dynamic>();
    return [
      for (final k in order) MapEntry(k, values[k] as int),
    ];
  }

  final prior = pairs(reconcile['prior'] as Map<String, dynamic>);
  final target = pairs(reconcile['target'] as Map<String, dynamic>);
  final ops = reconcileDiff(prior, target);

  final expectedOps = (expected['ops'] as List).cast<Map<String, dynamic>>();
  expect(ops.length, expectedOps.length,
      reason: '$name minimal op set size');

  for (var i = 0; i < expectedOps.length; i++) {
    final want = expectedOps[i];
    final got = ops[i];
    switch (want['type']) {
      case 'remove':
        expect(got, isA<DiffOpRemove<String, int>>(),
            reason: '$name op[$i] is Remove');
        expect((got as DiffOpRemove<String, int>).key, want['key']);
      case 'move':
        expect(got, isA<DiffOpMove<String, int>>(),
            reason: '$name op[$i] is Move');
        final move = got as DiffOpMove<String, int>;
        expect(move.key, want['key'], reason: '$name op[$i] move key');
        // Resolve the fixture's relative anchor to the expected final index.
        final wantOrder = (expected['result_order'] as List).cast<String>();
        final anchor = want['after'] ?? want['before'];
        if (anchor != null) {
          final anchorIdx = wantOrder.indexOf(anchor as String);
          final expectedIdx =
              want['after'] != null ? anchorIdx + 1 : anchorIdx;
          expect(move.to, expectedIdx,
              reason: '$name op[$i] move target');
        }
      case 'insert':
        expect(got, isA<DiffOpInsert<String, int>>(),
            reason: '$name op[$i] is Insert');
        final ins = got as DiffOpInsert<String, int>;
        expect(ins.key, want['key']);
      case 'update':
        expect(got, isA<DiffOpUpdate<String, int>>(),
            reason: '$name op[$i] is Update');
        expect((got as DiffOpUpdate<String, int>).key, want['key']);
    }
  }

  // Convergence: applying the minimal op set to a live map reproduces
  // result_order.
  final ctx = Context();
  final map = CellMap<String, int>(ctx);
  for (final e in prior) {
    map.set(e.key, e.value);
  }
  map.reconcile(
    (target.map((e) => e.key)).toList(),
    {for (final e in target) e.key: e.value},
  );
  expect(map.keys(), equals((expected['result_order'] as List).cast<String>()),
      reason: '$name convergence');

  // stable_keys_not_invalidated: prime a value reader per stable key, run the
  // reconcile, then assert each stable reader stayed cached.
  final stableKeys =
      (expected['stable_keys_not_invalidated'] as List).cast<String>();
  final readers = <String, Slot<int?>>{};
  for (final k in stableKeys) {
    final slot = Slot<int?>(ctx, (_) => map.read(k))..call();
    readers[k] = slot;
  }
  // A second reconcile against the same target is a no-op (stable entries
  // unchanged) — stable readers stay warm.
  map.reconcile(
    (target.map((e) => e.key)).toList(),
    {for (final e in target) e.key: e.value},
  );
  for (final k in stableKeys) {
    expect(_isWarm(readers[k]!, ctx), isTrue,
        reason: '$name stable key `$k` not invalidated by sibling reorder');
  }
}

void main() {
  // The 3 fixtures lazily-rs runs (the family's CellMap conformance scope).
  test('conformance cellmap_independence replays identically', () {
    _runStepsFixture('cellmap_independence.json');
  });

  test('conformance cellmap_atomic_move replays identically', () {
    _runStepsFixture('cellmap_atomic_move.json');
  });

  test('conformance keyed_reconciliation_lis replays identically', () {
    _runReconcileFixture('keyed_reconciliation_lis.json');
  });

  // Live-graph sanity tests for the independence wiring.
  group('CellMap independence', () {
    test('a value write invalidates only that entry value reader', () {
      final ctx = Context();
      final map = CellMap<String, int>(ctx)
        ..set('a', 1)
        ..set('b', 2);
      final ra = Slot<int?>(ctx, (_) => map.read('a'))..call();
      final rb = Slot<int?>(ctx, (_) => map.read('b'))..call();
      final len = Slot<int>(ctx, (_) => map.len())..call();
      final keys = Slot<List<String>>(ctx, (_) => map.keys())..call();
      map.set('a', 11);
      expect(_isWarm(ra, ctx), isFalse, reason: 'a invalidated');
      expect(_isWarm(rb, ctx), isTrue, reason: 'b untouched');
      expect(_isWarm(len, ctx), isTrue, reason: 'membership untouched');
      expect(_isWarm(keys, ctx), isTrue, reason: 'order untouched');
    });

    test('a pure atomic move invalidates only order readers', () {
      final ctx = Context();
      final map = CellMap<String, int>(ctx)
        ..set('a', 1)
        ..set('b', 2)
        ..set('c', 3);
      final len = Slot<int>(ctx, (_) => map.len())..call();
      final keys = Slot<List<String>>(ctx, (_) => map.keys())..call();
      final ra = Slot<int?>(ctx, (_) => map.read('a'))..call();
      expect(map.moveTo('c', 0), isTrue);
      expect(map.keys(), equals(['c', 'a', 'b']));
      expect(_isWarm(len, ctx), isTrue, reason: 'membership untouched by move');
      expect(_isWarm(keys, ctx), isFalse, reason: 'order invalidated');
      expect(_isWarm(ra, ctx), isTrue, reason: 'value untouched by move');
    });

    test('handle is stable across an atomic move', () {
      final ctx = Context();
      final map = CellMap<String, int>(ctx)
        ..set('a', 1)
        ..set('b', 2);
      final before = map.cell('b');
      map.moveTo('b', 0);
      expect(identical(before, map.cell('b')), isTrue);
    });

    test('no-op move does not invalidate', () {
      final ctx = Context();
      final map = CellMap<String, int>(ctx)
        ..set('a', 1)
        ..set('b', 2);
      final keys = Slot<List<String>>(ctx, (_) => map.keys())..call();
      expect(map.moveTo('a', 0), isTrue); // already at 0
      expect(_isWarm(keys, ctx), isTrue, reason: 'no-op move');
    });
  });

  group('CellTree', () {
    test('per-level membership/order reactivity is inherited', () {
      final ctx = Context();
      final root = CellTree<String, int>(ctx, 'root', 0);
      root.insertChild('a', 1);
      root.insertChild('b', 2);
      final childIds = Slot<List<String>>(ctx, (_) => root.childIds())..call();
      expect(root.childIds(), equals(['a', 'b']));
      root.moveChildTo('b', 0);
      expect(root.childIds(), equals(['b', 'a']));
      expect(_isWarm(childIds, ctx), isFalse, reason: 'child order changed');
    });
  });

  group('reconcileDiff', () {
    test('holds the LIS fixed and moves only the remainder', () {
      final prior = [
        MapEntry('a', 1),
        MapEntry('b', 2),
        MapEntry('c', 3),
        MapEntry('d', 4),
      ];
      final target = [
        MapEntry('b', 2),
        MapEntry('c', 3),
        MapEntry('a', 1),
      ];
      final ops = reconcileDiff(prior, target);
      // Expect: remove d, move a (b,c are in the LIS).
      final removes = ops.whereType<DiffOpRemove<String, int>>().toList();
      final moves = ops.whereType<DiffOpMove<String, int>>().toList();
      expect(removes.length, 1);
      expect(removes.first.key, 'd');
      expect(moves.length, 1);
      expect(moves.first.key, 'a');
      expect(moves.first.to, 2, reason: 'a moves to final index 2');
    });
  });
}
