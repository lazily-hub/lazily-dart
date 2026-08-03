import 'dart:convert';
import 'dart:io';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

/// The keyed-collection ordering contract replayed against **all three**
/// execution flavors.
///
/// `collections_conformance_test.dart` already replays the ordering fixtures,
/// but only against the single-threaded [SourceMap]. That is the blind spot this
/// file closes: [ThreadSafeReactiveMap] and [AsyncReactiveMap] shipped
/// `presentKeys` / `presentCount` and nothing else — no ordering surface, no
/// reactive membership, and no reactive nodes at all (both stored plain values
/// and their `_ctx` was annotated `// ignore: unused_field`). The coverage
/// matrix read OK because *a* flavor passed.
///
/// Invalidation is measured by **recompute count** inside the reader's own
/// compute body, not by a cache flag: a counter the library has to move is the
/// one probe that cannot be satisfied by runner bookkeeping.

final _localDir = Directory('test/conformance/collections');
final _specDir = Directory('../lazily-spec/conformance/collections');

const _fixtures = ['cellmap_atomic_move.json', 'cellmap_independence.json'];

// Sibling-first, as the sibling harness does: the canonical checkout wins
// whenever present, and the mirror is a fallback, never an authority.
String? _fixturePath(String name) {
  if (_specDir.existsSync()) {
    final sibling = '${_specDir.resolveSymbolicLinksSync()}/$name';
    if (File(sibling).existsSync()) return sibling;
  }
  if (_localDir.existsSync()) {
    final local = '${_localDir.resolveSymbolicLinksSync()}/$name';
    if (File(local).existsSync()) return local;
  }
  return null;
}

/// Order-sensitive, so an order reader's *value* changes on a reorder and not
/// merely its cache state.
int _orderDigest(List<String> keys) {
  var acc = 17;
  for (final key in keys) {
    for (final unit in key.codeUnits) {
      acc = acc * 31 + unit;
    }
    acc = acc * 31 + 7;
  }
  return acc;
}

/// One execution flavor, driving the same fixture ops.
abstract class _Flavor {
  final Context ctx = Context();

  String get name;

  void setValue(String key, int value);
  void remove(String key);
  void moveTo(String key, int index);
  void moveBefore(String key, String anchor);
  void moveAfter(String key, String anchor);

  List<String> keysUntracked();
  int? valueUntracked(String key);

  /// The entry's node: stable across a reorder, different after a re-mint. This
  /// is what separates a move from a remove + insert.
  Object? entryIdentity(String key);

  int Function() valueReader(String key);
  int Function() membershipReader();
  int Function() orderReader();

  /// Build a reader that reports how many times it recomputed.
  int Function() reader(int Function(Compute cx) body) {
    var count = 0;
    final node = Slot<int>(ctx, (cx) {
      count += 1;
      return body(cx);
    });
    return () {
      node.call();
      return count;
    };
  }
}

class _SyncFlavor extends _Flavor {
  late final SourceMap<String, int> map = SourceMap<String, int>(ctx);

  @override
  String get name => 'sync';
  @override
  void setValue(String key, int value) => map.set(key, value);
  @override
  void remove(String key) => map.remove(key);
  @override
  void moveTo(String key, int index) => map.moveTo(key, index);
  @override
  void moveBefore(String key, String anchor) => map.moveBefore(key, anchor);
  @override
  void moveAfter(String key, String anchor) => map.moveAfter(key, anchor);
  @override
  List<String> keysUntracked() => map.presentKeys();
  @override
  int? valueUntracked(String key) => map.handle(key)?.value;
  @override
  Object? entryIdentity(String key) => map.handle(key);
  @override
  int Function() valueReader(String key) {
    final handle = map.handle(key);
    return reader((cx) => handle == null ? -1 : cx.get(handle));
  }

  @override
  int Function() membershipReader() => reader((cx) => map.len(cx));
  @override
  int Function() orderReader() => reader((cx) => _orderDigest(map.keys(cx)));
}

class _ThreadSafeFlavor extends _Flavor {
  late final ThreadSafeSourceMap<String, int> map =
      ThreadSafeSourceMap<String, int>(ctx);

  @override
  String get name => 'thread-safe';
  @override
  void setValue(String key, int value) => map.set(key, value);
  @override
  void remove(String key) => map.remove(key);
  @override
  void moveTo(String key, int index) => map.moveTo(key, index);
  @override
  void moveBefore(String key, String anchor) => map.moveBefore(key, anchor);
  @override
  void moveAfter(String key, String anchor) => map.moveAfter(key, anchor);
  @override
  List<String> keysUntracked() => map.presentKeys();
  @override
  int? valueUntracked(String key) => map.handle(key)?.value;
  @override
  Object? entryIdentity(String key) => map.handle(key);
  @override
  int Function() valueReader(String key) {
    final handle = map.handle(key);
    return reader((cx) => handle == null ? -1 : cx.get(handle));
  }

  @override
  int Function() membershipReader() => reader((cx) => map.len(cx));
  @override
  int Function() orderReader() => reader((cx) => _orderDigest(map.keys(cx)));
}

class _AsyncFlavor extends _Flavor {
  late final AsyncSourceMap<String, int> map = AsyncSourceMap<String, int>(ctx);

  @override
  String get name => 'async';
  @override
  void setValue(String key, int value) => map.set(key, value);
  @override
  void remove(String key) => map.remove(key);
  @override
  void moveTo(String key, int index) => map.moveTo(key, index);
  @override
  void moveBefore(String key, String anchor) => map.moveBefore(key, anchor);
  @override
  void moveAfter(String key, String anchor) => map.moveAfter(key, anchor);
  @override
  List<String> keysUntracked() => map.presentKeys();
  @override
  int? valueUntracked(String key) => map.observe(key).$1;
  @override
  Object? entryIdentity(String key) => map.handle(key);
  @override
  int Function() valueReader(String key) {
    final handle = map.handle(key);
    return reader((cx) => handle == null ? -1 : (cx.get(handle) ?? -1));
  }

  @override
  int Function() membershipReader() => reader((cx) => map.len(cx));
  @override
  int Function() orderReader() => reader((cx) => _orderDigest(map.keys(cx)));
}

final _flavorBuilders = <_Flavor Function()>[
  _SyncFlavor.new,
  _ThreadSafeFlavor.new,
  _AsyncFlavor.new,
];

void _replay(_Flavor flavor, String fixtureName) {
  final path = _fixturePath(fixtureName);
  expect(path, isNotNull,
      reason: 'canonical collections fixture missing: $fixtureName');
  final fixture =
      attributeFixture(jsonDecode(File(path!).specReadAsStringSync()))
          as Map<String, dynamic>;
  String where(int i) => '${flavor.name} $fixtureName step $i';

  final initial = fixture['initial'] as Map<String, dynamic>?;
  expect(initial, isNotNull, reason: '${flavor.name}: fixture has no initial');
  final seed = (initial!['order'] as List).cast<String>();
  expect(seed, isNotEmpty, reason: '${flavor.name}: fixture seeds no keys');
  final values = initial['values'] as Map<String, dynamic>;
  for (final key in seed) {
    expect(values.containsKey(key), isTrue,
        reason: '${flavor.name}: no initial value for $key');
    flavor.setValue(key, values[key] as int);
  }

  final steps = fixture['steps'] as List;
  // A zero-step replay asserts nothing and still reports green.
  expect(steps, isNotEmpty,
      reason: '${flavor.name}: fixture $fixtureName has no steps - '
          'a vacuous replay would report green');

  var matrices = 0;

  for (var i = 0; i < steps.length; i++) {
    final step = steps[i] as Map<String, dynamic>;
    final op = step['op'] as Map<String, dynamic>;
    final expected = assertionsOf(step['expected'], 'step $i');

    // Rebuild + settle readers from the CURRENT key set so each step's
    // invalidation is measured against a fully settled graph.
    final beforeKeys = flavor.keysUntracked();
    final valueReaders = {
      for (final key in beforeKeys) key: flavor.valueReader(key),
    };
    final baseline = {
      for (final entry in valueReaders.entries) entry.key: entry.value(),
    };
    final membership = flavor.membershipReader();
    final order = flavor.orderReader();
    final membershipBase = membership();
    final orderBase = order();

    final idsBefore = {
      for (final key in beforeKeys) key: flavor.entryIdentity(key),
    };

    switch (op['type'] as String) {
      case 'set_value':
      case 'insert':
        flavor.setValue(op['key'] as String, op['value'] as int);
        // `at` says where the new key lands; minting appends, so "end" is
        // already right. An unrecognised form must fail, not silently append.
        final at = op['at'];
        if (at is int) {
          flavor.moveTo(op['key'] as String, at);
        } else if (at != null) {
          expect(at, 'end',
              reason: '${where(i)}: unsupported insert placement $at');
        }
      case 'remove':
        flavor.remove(op['key'] as String);
      case 'move_to':
        flavor.moveTo(op['key'] as String, op['index'] as int);
      case 'move_before':
        flavor.moveBefore(op['key'] as String, op['before'] as String);
      case 'move_after':
        flavor.moveAfter(op['key'] as String, op['after'] as String);
      default:
        fail('${where(i)}: unsupported op ${op['type']} - '
            'an unknown op must fail, never silently skip');
    }

    final gotOrder = flavor.keysUntracked();
    assertKeyWith(expected, 'order', (v) {
      expect(gotOrder, (v as List).cast<String>(),
          reason: '${where(i)}: order diverged');
    });

    assertKeyIfPresent(expected, 'membership', (v) {
      expect(gotOrder.toSet(), (v as List).cast<String>().toSet(),
          reason: '${where(i)}: membership set diverged');
    });

    assertKeysOfIfPresent(expected, 'values', gotOrder, (key, want) {
      expect(flavor.valueUntracked(key), want,
          reason: '${where(i)}: value for $key diverged');
    },
        reason:
            '${where(i)}: `values` names a key the collection does not carry');

    // The invalidation matrix, read from expected.invalidates - where the
    // fixtures actually nest it. lazily-rs read it off the step instead, so its
    // assertion never ran once.
    expect(expected['invalidates'], isNotNull,
        reason: '${where(i)}: expected.invalidates is missing - '
            'the matrix is the contract');
    matrices += 1;

    // DESCENDED into (`#lzsubblockkeyset`): the matrix names three reader
    // projections and this runner used to read exactly those three off a raw
    // map, so a fourth added upstream was compared by nothing. The child
    // tracker owns them now.
    final invalidates = subKey(expected, 'invalidates', 'step $i invalidates');
    assertKeyWith<void>(invalidates, 'value', (v) {
      final dirty = (v as List).cast<String>().toSet();
      final survivors = gotOrder.toSet();
      valueReaders.forEach((key, drive) {
        if (!survivors.contains(key)) return; // removed: no entry left to read
        final recomputed = drive() != baseline[key];
        if (dirty.contains(key)) {
          expect(recomputed, isTrue,
              reason: '${where(i)}: value reader for $key '
                  'should have been invalidated');
        } else {
          expect(recomputed, isFalse,
              reason: '${where(i)}: value reader for $key should have stayed '
                  'cached - per-entry independence is the whole point');
        }
      });
    });
    assertKeyWith<void>(invalidates, 'membership', (v) {
      expect(membership() != membershipBase, v == true,
          reason: '${where(i)}: membership reader invalidation mismatch - '
              'a pure reorder must NOT invalidate set-identity readers');
    });
    assertKeyWith<void>(invalidates, 'order', (v) {
      expect(order() != orderBase, v == true,
          reason: '${where(i)}: order reader invalidation mismatch');
    });

    // Handle stability: the law separating an atomic move from a remove +
    // re-mint. A reorder keeps the entry's node, so dependents and lineage
    // survive.
    assertKeysOfIfPresent(expected, 'handle_stable', gotOrder,
        (key, wantStable) {
      final after = flavor.entryIdentity(key);
      final before = idsBefore[key];
      if (wantStable == true) {
        expect(before != null && identical(after, before), isTrue,
            reason: '${where(i)}: handle for $key must survive the move - '
                'a reorder that re-mints is a remove + insert, not a move');
      } else {
        expect(identical(after, before), isFalse,
            reason: '${where(i)}: handle for $key should have changed');
      }
    },
        reason: '${where(i)}: `handle_stable` names a key the collection does '
            'not carry');
  }

  expect(matrices, greaterThan(0),
      reason: '${flavor.name}: $fixtureName asserted no invalidation matrix');
}

void main() {
  for (final build in _flavorBuilders) {
    final flavorName = build().name;
    group('ordering contract ($flavorName)', () {
      for (final fixtureName in _fixtures) {
        test(fixtureName, () => _replay(build(), fixtureName));
      }
    });
  }

  // Cover a direction the canonical corpus does not.
  //
  // `cellmap_atomic_move.json`'s only `move_before` step moves a key that
  // already FOLLOWS its anchor (from=2, anchor=0), so it exercises only the
  // branch where the insertion point is the anchor index itself. The branch
  // where the key PRECEDES its anchor — target `anchor - 1` — is never replayed.
  // That is exactly the direction lazily-zig's `moveBefore` was wrong in:
  // `moveBefore("a","d")` on `[a,b,c,d]` produced `[b,c,d,a]`. The canonical
  // corpus would have scored that binding green.
  for (final build in _flavorBuilders) {
    final flavorName = build().name;
    test('directional moves ($flavorName)', () {
      const seed = ['a', 'b', 'c', 'd'];
      _Flavor make() {
        final flavor = build();
        for (var i = 0; i < seed.length; i++) {
          flavor.setValue(seed[i], i + 1);
        }
        return flavor;
      }

      final cases = <(String, void Function(_Flavor), List<String>)>[
        (
          'move_before, key precedes anchor',
          (f) => f.moveBefore('a', 'd'),
          ['b', 'c', 'a', 'd']
        ),
        (
          'move_before, key follows anchor',
          (f) => f.moveBefore('d', 'b'),
          ['a', 'd', 'b', 'c']
        ),
        (
          'move_after, key precedes anchor',
          (f) => f.moveAfter('a', 'c'),
          ['b', 'c', 'a', 'd']
        ),
        (
          'move_after, key follows anchor',
          (f) => f.moveAfter('d', 'a'),
          ['a', 'd', 'b', 'c']
        ),
        (
          'move_to past the end clamps',
          (f) => f.moveTo('a', 99),
          ['b', 'c', 'd', 'a']
        ),
        (
          'move_to to -1 clamps to the front',
          (f) => f.moveTo('d', -1),
          ['d', 'a', 'b', 'c']
        ),
        (
          'move_to far below zero clamps',
          (f) => f.moveTo('d', -5),
          ['d', 'a', 'b', 'c']
        ),
        (
          'move on an absent key is a no-op',
          (f) {
            f.moveBefore('zz', 'a');
            f.moveTo('zz', 0);
          },
          seed
        ),
      ];

      for (final (what, run, want) in cases) {
        final flavor = make();
        final identityBefore = flavor.entryIdentity('a');
        run(flavor);
        expect(flavor.keysUntracked(), want,
            reason: '$flavorName: $what diverged - '
                'the target must be computed on the pre-removal list');
        expect(identical(flavor.entryIdentity('a'), identityBefore), isTrue,
            reason: '$flavorName: $what re-minted entry a - '
                'a reorder must keep the node');
      }
    });
  }
}
