import 'dart:convert';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

/// Cross-language conformance tests for the presence / ephemeral plane
/// (`#lzpresence`, `lazily-spec/conformance/presence/`). Each primitive projects
/// its live view onto a reactive [Cell]; a [Slot] wrapping that cell lets us
/// observe invalidation via `ctx.contains` — the reader stays cached unless the
/// live view actually changed.
///
/// Fixtures mirror `lazily-spec/conformance/presence/` byte-identically; when
/// that source tree is reachable on disk (sibling repo) it is preferred so this
/// harness also guards against fixture drift across the family.

/// This runner's slice of the shared corpus. The root itself — and the
/// `LAZILY_SPEC_CONFORMANCE_DIR` override, and the sibling-first-then-mirror
/// ordering — lives in `conformance_manifest.dart` so every runner and the
/// coverage guard auditing them resolve ONE corpus (#lzoverrideallrunners).
const _family = 'presence';

Map<String, dynamic> _loadFixture(String name) {
  final src = specReadFixture('$_family/$name');
  return attributeFixture(jsonDecode(src)) as Map<String, dynamic>;
}

/// Observe a cell through a slot; returns the slot primed (cached).
Slot<Object?> _observe(Context ctx, Cell cell) {
  final slot = Slot<Object?>(ctx, (cx) => cx.get(cell));
  slot();
  return slot;
}

/// Read the slot, returning whether the read triggered a recompute (i.e. the
/// reader had been invalidated).
bool _invalidated(Context ctx, Slot slot) {
  final wasCached = ctx.contains(slot);
  slot();
  return !wasCached;
}

/// Expected `present` maps arrive with JSON string keys (`"1"`); the fixtures
/// use integer peers, so re-key to `int` for comparison with `present()`.
Map<int, String> _expectedPresent(Map<String, dynamic> present) {
  return {
    for (final entry in present.entries)
      int.parse(entry.key): entry.value as String,
  };
}

void main() {
  test('EphemeralCell single value', () {
    final fx = _loadFixture('ephemeral.json');
    final ctx = Context();
    final cell = EphemeralCell<String>(ctx);
    final observed = _observe(ctx, cell.valueCell);

    for (final step in (fx['steps'] as List).cast<Map<String, dynamic>>()) {
      final op = step['op'] as Map<String, dynamic>;
      final expected = assertionsOf(step['expected']);
      switch (op['type']) {
        case 'set':
          cell.set(op['value'] as String, op['now'] as int, op['ttl'] as int);
        case 'tick':
          cell.tick(op['now'] as int);
        // Fail closed on an unrecognised op (`#lzscenariobodyskip`): a
        // defaultless `switch` over a String is a silent no-op in Dart, so an
        // op this runner does not implement left the cell untouched while the
        // step's `expected` block still compared green against the PREVIOUS
        // state.
        default:
          fail('EphemeralCell: unknown op type `${op['type']}`');
      }
      assertKey(expected, 'value', cell.value());
      assertKey(subKey(expected, 'invalidates'), 'value',
          _invalidated(ctx, observed), 'invalidation');
    }
  });

  test('PresenceCell heartbeat/evict/TTL', () {
    final fx = _loadFixture('presence.json');
    final ctx = Context();
    final config = fx['config'] as Map<String, dynamic>;
    final cell = PresenceCell<int, String>(ctx, config['ttl'] as int);
    final observed = _observe(ctx, cell.presentCell);

    for (final step in (fx['steps'] as List).cast<Map<String, dynamic>>()) {
      final op = step['op'] as Map<String, dynamic>;
      final expected = assertionsOf(step['expected']);
      switch (op['type']) {
        case 'heartbeat':
          cell.heartbeat(
              op['peer'] as int, op['value'] as String, op['now'] as int);
        case 'evict':
          cell.evict(op['peer'] as int, op['now'] as int);
        case 'tick':
          cell.tick(op['now'] as int);
        // Fail closed on an unrecognised op (`#lzscenariobodyskip`).
        default:
          fail('PresenceCell: unknown op type `${op['type']}`');
      }
      // Key set first (`#lzsubblockkeyset`): the peers this run really has
      // present, compared both directions against the peers the fixture names.
      // The value equality below then covers the payloads.
      final present = assertKeySet(
          expected, 'present', cell.present().keys.map((peer) => '$peer'),
          reason: 'the peer set this run reports present must equal the peer '
              'set the fixture names, in both directions');
      expect(cell.present(), equals(_expectedPresent(present)),
          reason: 'present');
      assertKey(subKey(expected, 'invalidates'), 'present',
          _invalidated(ctx, observed), 'invalidation');
    }
  });

  test('AwarenessCell last-writer', () {
    final fx = _loadFixture('awareness.json');
    final ctx = Context();
    final config = fx['config'] as Map<String, dynamic>;
    final cell = AwarenessCell<int, String>(ctx, config['ttl'] as int);
    final observed = _observe(ctx, cell.presentCell);

    for (final step in (fx['steps'] as List).cast<Map<String, dynamic>>()) {
      final op = step['op'] as Map<String, dynamic>;
      final expected = assertionsOf(step['expected']);
      switch (op['type']) {
        case 'set':
          cell.set(op['peer'] as int, op['value'] as String, op['now'] as int);
        case 'tick':
          cell.tick(op['now'] as int);
        // Fail closed on an unrecognised op (`#lzscenariobodyskip`).
        default:
          fail('AwarenessCell: unknown op type `${op['type']}`');
      }
      // Key set first (`#lzsubblockkeyset`): the peers this run really has
      // present, compared both directions against the peers the fixture names.
      // The value equality below then covers the payloads.
      final present = assertKeySet(
          expected, 'present', cell.present().keys.map((peer) => '$peer'),
          reason: 'the peer set this run reports present must equal the peer '
              'set the fixture names, in both directions');
      expect(cell.present(), equals(_expectedPresent(present)),
          reason: 'present');
      assertKey(subKey(expected, 'invalidates'), 'present',
          _invalidated(ctx, observed), 'invalidation');
    }
  });
}
