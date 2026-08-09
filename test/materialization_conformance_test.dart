import 'dart:convert';
import 'dart:io';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

/// `ComputedMap` materialization conformance (`#reactivemap`,
/// lazily-spec/conformance/materialization/).
///
/// Replays the shared cross-language fixtures against the Dart [ComputedMap] (and,
/// for mixed-kind fixtures, [SourceMap]) specializations of [ReactiveMap] — the
/// same fixtures `lazily-rs/tests/materialization_conformance.rs` runs. Each
/// fixture names the `lazily-formal` `Materialization` theorem it pins:
/// `observe_canonical` / `eager_lazy_observationally_equivalent`,
/// `cell_entries_materialized_in_every_mode` / `slot_entries_deferred_under_lazy`,
/// `materialize_present_monotone` / `lazy_present_subset_eager` /
/// `materialize_preserves_observe`.
///
/// There is no eager/lazy mode flag: **eager** = pre-mint loop
/// ([ComputedMap.materializeAll]); **lazy** = mint-on-access
/// ([ReactiveMap.getOrInsertWith]). A single `ReactiveMap<K,V,H>` fixes one
/// handle kind, so a mixed-kind fixture is modelled by a [SourceMap] over the cell
/// entries and a [ComputedMap] over the slot entries, sharing one logical key space.
final _localDir = Directory('test/conformance/materialization');

/// The canonical corpus, overridable by `LAZILY_SPEC_CONFORMANCE_DIR`.
///
/// The same variable `scripts/check-conformance-coverage.sh` reads, and CI sets
/// for that step. The runners of this repo hardcoded the relative sibling, which
/// means a corpus PERTURBATION — flip a fixture's field, prove the suite reddens
/// — could not be pointed at a scratch copy, and the shared `../lazily-spec`
/// checkout is the one thing a probe must not edit. Honouring the variable here
/// makes the probe repeatable; the default is unchanged.
Directory get _specDir => Directory(
    '${Platform.environment['LAZILY_SPEC_CONFORMANCE_DIR'] ?? '../lazily-spec/conformance'}'
    '/materialization');

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

Map<String, dynamic> _load(String name) => attributeFixture(
        jsonDecode(File(_fixturePath(name)).specReadAsStringSync()))
    as Map<String, dynamic>;

Set<String> _asSet(Iterable<String> keys) => keys.toSet();

List<String> _strArray(Map<String, dynamic> m, String key) =>
    (m[key] as List).cast<String>();

/// Accepted spellings of a derived-slot keyed-map fixture's `model` field.
///
/// The canonical corpus renamed `SlotMap` → `ComputedMap` (and `CellMap` →
/// `SourceMap`) alongside the v2 kernel's `Source` / `Computed` node kinds. A
/// runner that pinned the new spelling alone would fail against any checkout of
/// lazily-spec predating the rename, so both are accepted.
const _computedMapModels = {'ComputedMap', 'SlotMap'};

/// Parse a fixture entry's `kind` word into the runner's [EntryKind].
///
/// Accepts BOTH spellings of the entry-kind axis for the same reason
/// [_computedMapModels] accepts both model spellings: the canonical fixture
/// still says `cell` / `slot`, and will later be flipped to the v2 kernel's
/// `source` / `computed`. A runner pinned to either spelling alone breaks on
/// one side of that flip.
///
/// Anything else is a hard error — never a silent default, and never a skip
/// that would let a malformed fixture report green.
EntryKind _parseEntryKind(String raw) => switch (raw) {
      'cell' || 'source' => EntryKind.source,
      'slot' || 'computed' => EntryKind.computed,
      _ => throw ArgumentError.value(raw, 'kind', 'unknown entry kind'),
    };

/// A `spec.val` fixture: ordered keys → canonical value.
({List<String> keys, Map<String, int> values}) _parseVal(
    Map<String, dynamic> fixture) {
  final val =
      (fixture['spec'] as Map<String, dynamic>)['val'] as Map<String, dynamic>;
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
  expect(_computedMapModels, contains(fixture['model']),
      reason: 'fixture model');
  final spec = _parseVal(fixture);
  final expected = assertionsOf(fixture['expected']);
  final lookup = (Compute cx, String k) => spec.values[k]!;

  final ctx = Context();

  // The map this fixture describes, built by one strategy: `eager` pre-mints the
  // whole keyset, `lazy` mints on access and so holds nothing at build.
  ComputedMap<String, int> build({required bool eager}) {
    final map = ComputedMap<String, int>(ctx);
    if (eager) map.materializeAll(spec.keys, lookup);
    return map;
  }

  // default_mode, clause `default_mode_eager` (`#lzdefaultmodeuniform`).
  //
  // There is no mode flag to read back, so the fixture's word SELECTS THE BUILD
  // and the fact asserted is behavioural: a map built the way the fixture names
  // its default is fully materialized at build. Dispatch chooses the
  // construction and nothing else; an unknown word is a hard failure, never a
  // silent skip and never a default arm.
  //
  // The right-hand side is the TOTAL declared keyset, never "what this mode
  // implies". Asserting the per-mode implication instead — eager ⇒ all, lazy ⇒
  // none — is a TAUTOLOGY on the lazy arm: the library really does defer
  // everything, so a corpus flipped to `lazy` would stay green and the
  // perturbation would prove nothing. Only the eager build satisfies the form
  // written here, so the flip reddens; and so does a pre-mint loop that stops
  // materializing.
  //
  // This replaced `assertKey(expected, 'default_mode', 'eager', ...)`, which
  // compared the fixture's value to a hardcoded literal and therefore asserted
  // only that the fixture equals itself (`#lzconsumednotasserted`): a binding
  // whose eager build materialized NOTHING passed it.
  assertKeyWith(expected, 'default_mode', (v) {
    final mode = v as String;
    final byDefault = switch (mode) {
      'eager' => build(eager: true),
      'lazy' => build(eager: false),
      _ => throw ArgumentError.value(
          v, 'default_mode', 'unknown materialization default'),
    };
    expect(_asSet(byDefault.presentKeys()), _asSet(spec.keys),
        reason: 'default_mode_eager: a map built the fixture default way '
            '($mode) materializes every declared key at build');
  });

  // eager: pre-mint the whole keyset.
  final eager = build(eager: true);
  expect(eager.entryKind, EntryKind.computed);
  expect(eager.presentCount(), spec.keys.length,
      reason: 'eager_materializes_all');
  assertKeyWith(
      expected,
      'eager_present',
      (v) => expect(
          _asSet(eager.presentKeys()), _asSet((v as List).cast<String>())));

  // lazy: empty, mint-on-access.
  final lazy = build(eager: false);
  expect(lazy.presentCount(), 0, reason: 'lazy defers every derived slot');

  // observe_canonical / eager_lazy_observationally_equivalent.
  // Keyed by spec key, bounded by the spec this run really materialized
  // (`#lzsubblockkeyset`).
  assertKeysOf(expected, 'observe', spec.keys, (k, want) {
    expect(eager.get(k), want, reason: 'eager observe $k');
    expect(lazy.getOrInsertWith(k, lookup), want, reason: 'lazy observe $k');
  }, reason: '`observe` names a key the spec does not carry');

  return fixture;
}

void main() {
  group('ComputedMap materialization conformance (#reactivemap)', () {
    test('observational_transparency replays identically', () {
      final fixture = _checkValFixture('observational_transparency.json');
      final expected = assertionsOf(fixture['expected']);
      final spec = _parseVal(fixture);
      final lookup = (Compute cx, String k) => spec.values[k]!;

      // Replay the lazy read sequence on a fresh map; the lazy present set is
      // exactly the read keys (lazy_defers_slots).
      final lazy = ComputedMap<String, int>(Context());
      for (final k in _strArray(fixture, 'reads')) {
        lazy.getOrInsertWith(k, lookup);
      }
      assertKeyWith(expected, 'lazy_present_after_reads', (v) {
        expect(_asSet(lazy.presentKeys()), _asSet((v as List).cast<String>()));
      });
    });

    test('deferral_not_deallocation replays identically', () {
      final fixture = _checkValFixture('deferral_not_deallocation.json');
      final expected = assertionsOf(fixture['expected']);
      final spec = _parseVal(fixture);
      final lookup = (Compute cx, String k) => spec.values[k]!;

      final lazy = ComputedMap<String, int>(Context());

      // present_after_each_read: cumulative present-set size, monotone and
      // unchanged by a re-read (materialize_present_monotone).
      final gotSizes = <int>[];
      for (final k in _strArray(fixture, 'reads')) {
        lazy.getOrInsertWith(k, lookup);
        gotSizes.add(lazy.presentCount());
      }
      assertKeyWith(expected, 'present_after_each_read', (v) {
        expect(gotSizes, (v as List).cast<int>(),
            reason: 'cumulative present-set sizes');
      });

      // lazy_present_after_reads is a subset of eager_present
      // (lazy_present_subset_eager).
      final lazyPresent = _asSet(lazy.presentKeys());
      assertKeyWith(expected, 'lazy_present_after_reads',
          (v) => expect(lazyPresent, _asSet((v as List).cast<String>())));
      final eagerPresent = _asSet(_strArray(expected, 'eager_present'));
      expect(lazyPresent.difference(eagerPresent), isEmpty,
          reason: 'lazy present set must be a subset of eager present set');
    });

    test('entry-kind parsing accepts both fixture spellings', () {
      // Current canonical spelling.
      expect(_parseEntryKind('cell'), EntryKind.source);
      expect(_parseEntryKind('slot'), EntryKind.computed);
      // v2 kernel spelling the fixture will later be flipped to.
      expect(_parseEntryKind('source'), EntryKind.source);
      expect(_parseEntryKind('computed'), EntryKind.computed);
      // Anything else is a hard error, not a default or a skip.
      expect(() => _parseEntryKind('Cell'), throwsArgumentError);
      expect(() => _parseEntryKind('signal'), throwsArgumentError);
      expect(() => _parseEntryKind(''), throwsArgumentError);

      // The fixture actually on disk parses — whichever spelling it carries.
      final entries = (_load('entry_kind_orthogonal_to_mode.json')['spec']
          as Map<String, dynamic>)['entries'] as Map<String, dynamic>;
      expect(entries, isNotEmpty);
      final kinds = entries.values
          .map((e) =>
              _parseEntryKind((e as Map<String, dynamic>)['kind'] as String))
          .toSet();
      expect(kinds, {EntryKind.source, EntryKind.computed},
          reason: 'the mixed-kind fixture must carry both entry kinds');
    });

    test('entry_kind_orthogonal_to_mode replays identically', () {
      final fixture = _load('entry_kind_orthogonal_to_mode.json');
      expect(_computedMapModels, contains(fixture['model']));
      final expected = assertionsOf(fixture['expected']);

      final entries = (fixture['spec'] as Map<String, dynamic>)['entries']
          as Map<String, dynamic>;

      // Split the map's declared entries by kind: input cells vs derived slots.
      final cellKeys = <String>[];
      final slotKeys = <String>[];
      final vals = <String, int>{};
      for (final e in entries.entries) {
        final entry = e.value as Map<String, dynamic>;
        vals[e.key] = entry['val'] as int;
        switch (_parseEntryKind(entry['kind'] as String)) {
          case EntryKind.source:
            cellKeys.add(e.key);
          case EntryKind.computed:
            slotKeys.add(e.key);
        }
      }
      final lookup = (String k) => vals[k]!;

      final ctx = Context();

      // One build of the fixture's mixed-kind map by one strategy. A single
      // ReactiveMap fixes one handle kind, so the source half and the computed
      // half are two maps over one logical key space. Source entries are
      // materialized at build under EVERY strategy; the derived computeds are
      // pre-minted only under eager.
      ({SourceMap<String, int> cells, ComputedMap<String, int> slots}) build(
          {required bool eager}) {
        final cells = SourceMap<String, int>(ctx);
        for (final k in cellKeys) {
          cells.entry(k, lookup(k));
        }
        final slots = ComputedMap<String, int>(ctx);
        if (eager) slots.materializeAll(slotKeys, (_, k) => lookup(k));
        return (cells: cells, slots: slots);
      }

      Set<String> presentAtBuild(
              ({
                SourceMap<String, int> cells,
                ComputedMap<String, int> slots
              }) m) =>
          _asSet(m.cells.presentKeys())..addAll(m.slots.presentKeys());

      // default_mode, clause `default_mode_eager` (`#lzdefaultmodeuniform`).
      //
      // Same behavioural shape as the `spec.val` fixtures above: the fixture's
      // word selects the build, and the build is asserted to hold every DECLARED
      // entry — sources and computeds alike — at build time. The entry-kind split
      // belongs to the construction, not to the right-hand side: asserting
      // "under lazy, exactly the source entries are present" is the tautology
      // this fixture is most likely to hide behind, since that is precisely how
      // the library behaves, and a corpus flipped to `lazy` would stay green.
      // An unknown word is a hard failure. (Was a hardcoded-literal comparison,
      // which asserted only that the fixture equals itself —
      // `#lzconsumednotasserted`.)
      assertKeyWith(expected, 'default_mode', (v) {
        final mode = v as String;
        final byDefault = switch (mode) {
          'eager' => build(eager: true),
          'lazy' => build(eager: false),
          _ => throw ArgumentError.value(
              v, 'default_mode', 'unknown materialization default'),
        };
        expect(presentAtBuild(byDefault), {...cellKeys, ...slotKeys},
            reason: 'default_mode_eager: a map built the fixture default way '
                '($mode) materializes every declared entry at build');
      });

      // Eager build: every entry present (cells + slots).
      final eagerBuild = build(eager: true);
      final eagerCells = eagerBuild.cells;
      final eagerSlots = eagerBuild.slots;
      expect(eagerCells.entryKind, EntryKind.source);
      expect(eagerSlots.entryKind, EntryKind.computed);
      final eagerPresent = presentAtBuild(eagerBuild);
      assertKeyWith(expected, 'eager_present',
          (v) => expect(eagerPresent, _asSet((v as List).cast<String>())));

      // Lazy build: cells present at build (always materialized), slots deferred.
      final lazyBuild = build(eager: false);
      final lazyCells = lazyBuild.cells;
      final lazySlots = lazyBuild.slots;
      expect(lazySlots.presentKeys(), isEmpty,
          reason: 'slots deferred at build');
      assertKeyWith(expected, 'lazy_present_at_build', (v) {
        expect(_asSet(lazyCells.presentKeys()),
            _asSet((v as List).cast<String>()));
      });

      // Reads (slot pulls) grow only the slot present set.
      for (final k in _strArray(fixture, 'reads')) {
        if (slotKeys.contains(k)) {
          lazySlots.getOrInsertWith(k, (_, key) => lookup(key));
        } else {
          lazyCells.getOrInsertWith(k, (_, key) => lookup(key));
        }
      }
      final lazyAfter = _asSet(lazyCells.presentKeys())
        ..addAll(lazySlots.presentKeys());
      assertKeyWith(expected, 'lazy_present_after_reads',
          (v) => expect(lazyAfter, _asSet((v as List).cast<String>())));

      // Observational transparency across kinds.
      assertKeysOf(expected, 'observe', {...cellKeys, ...slotKeys}, (k, want) {
        if (cellKeys.contains(k)) {
          expect(eagerCells.get(k), want);
          expect(lazyCells.get(k), want);
        } else {
          expect(eagerSlots.get(k), want);
          expect(lazySlots.getOrInsertWith(k, (_, key) => lookup(key)), want);
        }
      }, reason: '`observe` names a key the spec does not carry');
    });
  });
}
