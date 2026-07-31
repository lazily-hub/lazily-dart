import 'dart:convert';
import 'dart:io';

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

final _specDir = Directory('../lazily-spec/conformance/presence');

Map<String, dynamic> _loadFixture(String name) {
  final src = _specDir.existsSync()
      ? File(_specDir.resolveSymbolicLinksSync() + '/$name')
          .specReadAsStringSync()
      : File('test/conformance/presence/$name').specReadAsStringSync();
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
      }
      assertKey(expected, 'value', cell.value());
      assertKeyWith(expected, 'invalidates', (v) {
        expect(_invalidated(ctx, observed), equals((v as Map)['value']),
            reason: 'invalidation');
      });
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
      }
      assertKeyWith(expected, 'present', (v) {
        expect(cell.present(),
            equals(_expectedPresent((v as Map).cast<String, dynamic>())),
            reason: 'present');
      });
      assertKeyWith(expected, 'invalidates', (v) {
        expect(_invalidated(ctx, observed), equals((v as Map)['present']),
            reason: 'invalidation');
      });
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
      }
      assertKeyWith(expected, 'present', (v) {
        expect(cell.present(),
            equals(_expectedPresent((v as Map).cast<String, dynamic>())),
            reason: 'present');
      });
      assertKeyWith(expected, 'invalidates', (v) {
        expect(_invalidated(ctx, observed), equals((v as Map)['present']),
            reason: 'invalidation');
      });
    }
  });
}
