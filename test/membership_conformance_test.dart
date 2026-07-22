import 'dart:convert';
import 'dart:io';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

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

final _specDir = Directory('../lazily-spec/conformance/membership');

Map<String, dynamic> _loadFixture(String name) {
  final src = _specDir.existsSync()
      ? File(_specDir.resolveSymbolicLinksSync() + '/$name').readAsStringSync()
      : File('test/conformance/membership/$name').readAsStringSync();
  return jsonDecode(src) as Map<String, dynamic>;
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

    for (final step in (fx['steps'] as List).cast<Map<String, dynamic>>()) {
      final op = step['op'] as Map<String, dynamic>;
      final expected = step['expected'] as Map<String, dynamic>;
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
      final states = expected['states'] as Map<String, dynamic>;
      states.forEach((peer, want) {
        expect(m.state(int.parse(peer))?.label, equals(want),
            reason: 'state of peer $peer');
      });

      // Alive set (the reactive `PeerSet`).
      final wantSet = (expected['alive_set'] as List).cast<int>();
      expect(m.peerSet(), equals(wantSet), reason: 'alive_set');

      // `PeerSet` invalidation — only on a set change.
      expect(_invalidated(ctx, observed), equals(expected['invalidates']),
          reason: 'invalidation');
    }
  });
}
