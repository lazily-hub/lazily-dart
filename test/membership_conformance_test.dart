import 'dart:convert';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

/// Cross-language conformance tests for membership + failure detection
/// (`#lzmemb`, `lazily-spec/conformance/membership/`). Each op drives the SWIM
/// state machine; the derived alive `PeerSet` is projected onto a reactive
/// [Cell], and a [Slot] wrapping that cell lets us observe invalidation via
/// `ctx.contains` — the reader stays cached unless the alive set actually
/// changes.
///
/// Fixtures mirror `lazily-spec/conformance/membership/` byte-identically; when
/// that source tree is reachable on disk (sibling repo) it is preferred so this
/// harness also guards against fixture drift across the family.

/// This runner's slice of the shared corpus. The root itself — and the
/// `LAZILY_SPEC_CONFORMANCE_DIR` override, and the sibling-first-then-mirror
/// ordering — lives in `conformance_manifest.dart` so every runner and the
/// coverage guard auditing them resolve ONE corpus (#lzoverrideallrunners).
const _family = 'membership';

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

void main() {
  test('MembershipCell lifecycle', () {
    final fx = _loadFixture('membership_lifecycle.json');
    final c = fx['config'] as Map<String, dynamic>;
    final config = MembershipConfig(
      phiThreshold: (c['phi_threshold'] as num).toDouble(),
      suspectTimeout: c['suspect_timeout'] as int,
      maxSamples: c['max_samples'] as int,
      minStd: (c['min_std'] as num).toDouble(),
    );
    final ctx = Context();
    final m = MembershipCell<int>(ctx, config);
    final observed = _observe(ctx, m.peerSetCell);

    // Every peer the fixture's OPS name — the population `states` is bounded
    // by (`#lzsubblockkeyset`). Derived from the op stream, never from the
    // expectation blocks it is used to check.
    final peers = <String>{
      for (final step in (fx['steps'] as List).cast<Map<String, dynamic>>())
        if ((step['op'] as Map<String, dynamic>)['peer'] case final int peer)
          '$peer',
    };

    for (final step in (fx['steps'] as List).cast<Map<String, dynamic>>()) {
      final op = step['op'] as Map<String, dynamic>;
      final expected = assertionsOf(step['expected']);
      final now = op['now'] as int;
      switch (op['type'] as String) {
        case 'join':
          m.join(op['peer'] as int, now);
        case 'heartbeat':
          m.heartbeat(op['peer'] as int, now);
        case 'leave':
          m.leave(op['peer'] as int, now);
        case 'tick':
          m.tick(now);
        default:
          fail('unknown op ${op['type']}');
      }

      // Per-peer state.
      // Keyed by peer id, bounded by the peers this fixture's ops really name
      // (`#lzsubblockkeyset`).
      assertKeysOf(expected, 'states', peers, (peer, want) {
        expect(m.state(int.parse(peer))?.label, equals(want),
            reason: 'state of peer $peer');
      }, reason: '`states` names a peer no op in this fixture ever touched');

      // Alive set (the reactive `PeerSet`).
      assertKeyWith(expected, 'alive_set', (v) {
        expect(m.peerSet(), equals((v as List).cast<int>()),
            reason: 'alive_set');
      });

      // `PeerSet` invalidation — only on a set change.
      assertKey(
          expected, 'invalidates', _invalidated(ctx, observed), 'invalidation');
    }
  });
}
