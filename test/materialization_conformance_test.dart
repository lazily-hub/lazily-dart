import 'dart:convert';
import 'dart:io';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

/// ReactiveFamily materialization-mode conformance (`#lzmatmode`,
/// lazily-spec/conformance/materialization/).
///
/// Replays the shared cross-language fixtures against the Dart [ReactiveFamily]
/// — the same fixtures `lazily-rs/tests/materialization_conformance.rs` runs.
/// Each fixture names the `lazily-formal` `Materialization` theorem it pins:
/// `observe_canonical` / `eager_lazy_observationally_equivalent`,
/// `cell_entries_materialized_in_every_mode` / `slot_entries_deferred_under_lazy`,
/// `materialize_present_monotone` / `lazy_present_subset_eager` /
/// `materialize_preserves_observe`.
final _localDir = Directory('test/conformance/materialization');
final _specDir = Directory('../lazily-spec/conformance/materialization');

String _fixturePath(String name) {
  final local = '${_localDir.path}/$name';
  if (File(local).existsSync()) return local;
  final sibling = '${_specDir.path}/$name';
  if (File(sibling).existsSync()) return sibling;
  throw StateError('fixture not found: $name (looked in $local, $sibling)');
}

Map<String, dynamic> _load(String name) =>
    jsonDecode(File(_fixturePath(name)).readAsStringSync())
        as Map<String, dynamic>;

/// Extract the (ordered) key → value map and per-key entry-kind resolver from a
/// fixture's `spec`. A `spec.val` fixture is all-slots; a `spec.entries` fixture
/// carries a `{kind, val}` per key.
({
  List<String> keys,
  Map<String, int> values,
  Map<String, EntryKind> kinds,
}) _parseSpec(Map<String, dynamic> fixture) {
  final spec = fixture['spec'] as Map<String, dynamic>;
  final keys = <String>[];
  final values = <String, int>{};
  final kinds = <String, EntryKind>{};
  if (spec.containsKey('entries')) {
    final entries = spec['entries'] as Map<String, dynamic>;
    for (final e in entries.entries) {
      keys.add(e.key);
      final entry = e.value as Map<String, dynamic>;
      values[e.key] = entry['val'] as int;
      kinds[e.key] =
          entry['kind'] == 'cell' ? EntryKind.cell : EntryKind.slot;
    }
  } else {
    final val = spec['val'] as Map<String, dynamic>;
    for (final e in val.entries) {
      keys.add(e.key);
      values[e.key] = e.value as int;
      kinds[e.key] = EntryKind.slot;
    }
  }
  return (keys: keys, values: values, kinds: kinds);
}

ReactiveFamily<String, int> _build(
  Context ctx,
  MaterializationMode mode,
  ({List<String> keys, Map<String, int> values, Map<String, EntryKind> kinds})
      spec,
) {
  final entryKind = spec.kinds.values.every((k) => k == EntryKind.slot)
      ? EntryKind.slot
      : (String key) => spec.kinds[key]!;
  return ReactiveFamily<String, int>(
    ctx,
    mode,
    spec.keys,
    (key) => spec.values[key]!,
    entryKind: entryKind,
  );
}

void _runFixture(String name) {
  final fixture = _load(name);
  final spec = _parseSpec(fixture);
  final expected = fixture['expected'] as Map<String, dynamic>;

  // default_mode_eager: the required default mode is eager.
  expect(expected['default_mode'], 'eager');
  expect(kDefaultMaterializationMode, MaterializationMode.eager);
  expect(ReactiveFamily.create(Context(), spec.keys, (k) => 0).mode,
      MaterializationMode.eager);

  // observe_canonical / eager_lazy_observationally_equivalent: identical values
  // under either mode.
  final observe = (expected['observe'] as Map<String, dynamic>);
  final eagerCtx = Context();
  final eager = _build(eagerCtx, MaterializationMode.eager, spec);
  final lazyObsCtx = Context();
  final lazyObs = _build(lazyObsCtx, MaterializationMode.lazy, spec);
  for (final key in observe.keys) {
    expect(eager.observe(key), observe[key], reason: 'eager observe $key');
    expect(lazyObs.observe(key), observe[key], reason: 'lazy observe $key');
  }

  // eager_materializes_all: eager present set is every declared key.
  expect(eager.presentKeys(),
      (expected['eager_present'] as List).cast<String>(),
      reason: 'eager_present');

  // The lazy build + read replay (a fresh family so the observe pass above does
  // not perturb the present set).
  final lazyCtx = Context();
  final lazy = _build(lazyCtx, MaterializationMode.lazy, spec);

  // cell_entries_materialized_in_every_mode / slot_entries_deferred_under_lazy:
  // under lazy, only input cells are present at build.
  if (expected.containsKey('lazy_present_at_build')) {
    expect(lazy.presentKeys(),
        (expected['lazy_present_at_build'] as List).cast<String>(),
        reason: 'lazy_present_at_build');
  }

  final reads = (fixture['reads'] as List).cast<String>();
  final presentAfterEachRead = <int>[];
  for (final key in reads) {
    lazy.observe(key);
    presentAfterEachRead.add(lazy.presentCount());
  }

  // materialize_present_monotone: the present-set size is non-decreasing and
  // unchanged by re-reads.
  if (expected.containsKey('present_after_each_read')) {
    expect(presentAfterEachRead,
        (expected['present_after_each_read'] as List).cast<int>(),
        reason: 'present_after_each_read');
  }

  // lazy_present_subset_eager: the final lazy present set is a subset of the
  // eager present set, in first-materialization order.
  final lazyPresent =
      (expected['lazy_present_after_reads'] as List).cast<String>();
  expect(lazy.presentKeys(), lazyPresent, reason: 'lazy_present_after_reads');
  for (final key in lazyPresent) {
    expect(eager.isPresent(key), isTrue,
        reason: 'lazy present key $key must be in the eager present set');
  }
}

void main() {
  group('ReactiveFamily materialization conformance (#lzmatmode)', () {
    test('observational_transparency replays identically', () {
      _runFixture('observational_transparency.json');
    });

    test('deferral_not_deallocation replays identically', () {
      _runFixture('deferral_not_deallocation.json');
    });

    test('entry_kind_orthogonal_to_mode replays identically', () {
      _runFixture('entry_kind_orthogonal_to_mode.json');
    });
  });
}
