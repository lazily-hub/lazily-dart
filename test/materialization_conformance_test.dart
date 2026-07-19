import 'dart:convert';
import 'dart:io';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

/// `SlotMap` materialization conformance (`#reactivemap`,
/// lazily-spec/conformance/materialization/).
///
/// Replays the shared cross-language fixtures against the Dart [SlotMap] (and,
/// for mixed-kind fixtures, [CellMap]) specializations of [ReactiveMap] — the
/// same fixtures `lazily-rs/tests/materialization_conformance.rs` runs. Each
/// fixture names the `lazily-formal` `Materialization` theorem it pins:
/// `observe_canonical` / `eager_lazy_observationally_equivalent`,
/// `cell_entries_materialized_in_every_mode` / `slot_entries_deferred_under_lazy`,
/// `materialize_present_monotone` / `lazy_present_subset_eager` /
/// `materialize_preserves_observe`.
///
/// There is no eager/lazy mode flag: **eager** = pre-mint loop
/// ([SlotMap.materializeAll]); **lazy** = mint-on-access
/// ([ReactiveMap.getOrInsertWith]). A single `ReactiveMap<K,V,H>` fixes one
/// handle kind, so a mixed-kind fixture is modelled by a [CellMap] over the cell
/// entries and a [SlotMap] over the slot entries, sharing one logical key space.
final _localDir = Directory('test/conformance/materialization');
final _specDir = Directory('../lazily-spec/conformance/materialization');

// Fixture resolution is SIBLING-FIRST (`#lzspecconf`): the canonical
// lazily-spec checkout wins whenever it is present, and the mirrored copy under
// `test/conformance/` is a fallback for a checkout without the sibling — never
// an authority. The reverse order silently shadowed the canonical fixture with
// a stale mirror, so CI cloned lazily-spec and then tested the local copy and
// still reported green. `conformance_fixture_drift_test.dart` byte-compares the
// two whenever both exist, so a stale mirror fails loudly instead of hiding.
String _fixturePath(String name) {
  final sibling = '${_specDir.path}/$name';
  if (File(sibling).existsSync()) return sibling;
  final local = '${_localDir.path}/$name';
  if (File(local).existsSync()) return local;
  throw StateError('fixture not found: $name (looked in $local, $sibling)');
}

Map<String, dynamic> _load(String name) =>
    jsonDecode(File(_fixturePath(name)).readAsStringSync())
        as Map<String, dynamic>;

Set<String> _asSet(Iterable<String> keys) => keys.toSet();

List<String> _strArray(Map<String, dynamic> m, String key) =>
    (m[key] as List).cast<String>();

/// A `spec.val` fixture: ordered keys → canonical value.
({List<String> keys, Map<String, int> values}) _parseVal(
    Map<String, dynamic> fixture) {
  final val = (fixture['spec'] as Map<String, dynamic>)['val']
      as Map<String, dynamic>;
  final keys = <String>[];
  final values = <String, int>{};
  for (final e in val.entries) {
    keys.add(e.key);
    values[e.key] = e.value as int;
  }
  return (keys: keys, values: values);
}

/// The shared invariants both `spec.val` fixtures declare: default mode eager,
/// eager materializes all up front, observationally-transparent reads.
Map<String, dynamic> _checkValFixture(String name) {
  final fixture = _load(name);
  expect(fixture['model'], 'SlotMap', reason: 'fixture model');
  final spec = _parseVal(fixture);
  final expected = fixture['expected'] as Map<String, dynamic>;
  final lookup = (String k) => spec.values[k]!;

  // default_mode_eager.
  expect(expected['default_mode'], 'eager');

  final ctx = Context();

  // eager: pre-mint the whole keyset.
  final eager = SlotMap<String, int>(ctx)..materializeAll(spec.keys, lookup);
  expect(eager.entryKind, EntryKind.slot);
  expect(eager.presentCount(), spec.keys.length, reason: 'eager_materializes_all');
  expect(_asSet(eager.presentKeys()), _asSet(_strArray(expected, 'eager_present')));

  // lazy: empty, mint-on-access.
  final lazy = SlotMap<String, int>(ctx);
  expect(lazy.presentCount(), 0, reason: 'lazy defers every derived slot');

  // observe_canonical / eager_lazy_observationally_equivalent.
  final observe = expected['observe'] as Map<String, dynamic>;
  for (final e in observe.entries) {
    expect(eager.get(e.key), e.value, reason: 'eager observe ${e.key}');
    expect(lazy.getOrInsertWith(e.key, lookup), e.value,
        reason: 'lazy observe ${e.key}');
  }

  return fixture;
}

void main() {
  group('SlotMap materialization conformance (#reactivemap)', () {
    test('observational_transparency replays identically', () {
      final fixture = _checkValFixture('observational_transparency.json');
      final expected = fixture['expected'] as Map<String, dynamic>;
      final spec = _parseVal(fixture);
      final lookup = (String k) => spec.values[k]!;

      // Replay the lazy read sequence on a fresh map; the lazy present set is
      // exactly the read keys (lazy_defers_slots).
      final lazy = SlotMap<String, int>(Context());
      for (final k in _strArray(fixture, 'reads')) {
        lazy.getOrInsertWith(k, lookup);
      }
      expect(_asSet(lazy.presentKeys()),
          _asSet(_strArray(expected, 'lazy_present_after_reads')));
    });

    test('deferral_not_deallocation replays identically', () {
      final fixture = _checkValFixture('deferral_not_deallocation.json');
      final expected = fixture['expected'] as Map<String, dynamic>;
      final spec = _parseVal(fixture);
      final lookup = (String k) => spec.values[k]!;

      final lazy = SlotMap<String, int>(Context());

      // present_after_each_read: cumulative present-set size, monotone and
      // unchanged by a re-read (materialize_present_monotone).
      final gotSizes = <int>[];
      for (final k in _strArray(fixture, 'reads')) {
        lazy.getOrInsertWith(k, lookup);
        gotSizes.add(lazy.presentCount());
      }
      expect(gotSizes, (expected['present_after_each_read'] as List).cast<int>(),
          reason: 'cumulative present-set sizes');

      // lazy_present_after_reads is a subset of eager_present
      // (lazy_present_subset_eager).
      final lazyPresent = _asSet(lazy.presentKeys());
      expect(lazyPresent, _asSet(_strArray(expected, 'lazy_present_after_reads')));
      final eagerPresent = _asSet(_strArray(expected, 'eager_present'));
      expect(lazyPresent.difference(eagerPresent), isEmpty,
          reason: 'lazy present set must be a subset of eager present set');
    });

    test('entry_kind_orthogonal_to_mode replays identically', () {
      final fixture = _load('entry_kind_orthogonal_to_mode.json');
      expect(fixture['model'], 'SlotMap');
      final expected = fixture['expected'] as Map<String, dynamic>;
      expect(expected['default_mode'], 'eager');

      final entries = (fixture['spec'] as Map<String, dynamic>)['entries']
          as Map<String, dynamic>;

      // Split the map's declared entries by kind: input cells vs derived slots.
      final cellKeys = <String>[];
      final slotKeys = <String>[];
      final vals = <String, int>{};
      for (final e in entries.entries) {
        final entry = e.value as Map<String, dynamic>;
        vals[e.key] = entry['val'] as int;
        switch (entry['kind'] as String) {
          case 'cell':
            cellKeys.add(e.key);
          case 'slot':
            slotKeys.add(e.key);
          case final other:
            fail('unknown entry kind $other');
        }
      }
      final lookup = (String k) => vals[k]!;

      final ctx = Context();

      // Eager build: every entry present (cells + slots).
      final eagerCells = CellMap<String, int>(ctx);
      for (final k in cellKeys) {
        eagerCells.entry(k, lookup(k));
      }
      final eagerSlots = SlotMap<String, int>(ctx)
        ..materializeAll(slotKeys, lookup);
      expect(eagerCells.entryKind, EntryKind.cell);
      expect(eagerSlots.entryKind, EntryKind.slot);
      final eagerPresent = _asSet(eagerCells.presentKeys())
        ..addAll(eagerSlots.presentKeys());
      expect(eagerPresent, _asSet(_strArray(expected, 'eager_present')));

      // Lazy build: cells present at build (always materialized), slots deferred.
      final lazyCells = CellMap<String, int>(ctx);
      for (final k in cellKeys) {
        lazyCells.entry(k, lookup(k));
      }
      final lazySlots = SlotMap<String, int>(ctx);
      expect(lazySlots.presentKeys(), isEmpty, reason: 'slots deferred at build');
      expect(_asSet(lazyCells.presentKeys()),
          _asSet(_strArray(expected, 'lazy_present_at_build')));

      // Reads (slot pulls) grow only the slot present set.
      for (final k in _strArray(fixture, 'reads')) {
        if (slotKeys.contains(k)) {
          lazySlots.getOrInsertWith(k, lookup);
        } else {
          lazyCells.getOrInsertWith(k, lookup);
        }
      }
      final lazyAfter = _asSet(lazyCells.presentKeys())
        ..addAll(lazySlots.presentKeys());
      expect(lazyAfter, _asSet(_strArray(expected, 'lazy_present_after_reads')));

      // Observational transparency across kinds.
      final observe = expected['observe'] as Map<String, dynamic>;
      for (final e in observe.entries) {
        if (cellKeys.contains(e.key)) {
          expect(eagerCells.get(e.key), e.value);
          expect(lazyCells.get(e.key), e.value);
        } else {
          expect(eagerSlots.get(e.key), e.value);
          expect(lazySlots.getOrInsertWith(e.key, lookup), e.value);
        }
      }
    });
  });
}
