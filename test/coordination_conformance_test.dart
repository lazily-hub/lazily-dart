import 'dart:convert';
import 'dart:io';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

/// Cross-language conformance tests for the coordination primitives
/// (`#lzcoord`, `lazily-spec/conformance/coordination/`). Each primitive
/// projects a salient reader (holder / current leader / lock state / permits /
/// gate) onto a reactive [Cell]; a [Slot] wrapping that cell lets us observe
/// invalidation via `ctx.contains` — the reader stays cached unless the op
/// actually changed the projected value.
///
/// Fixtures mirror `lazily-spec/conformance/coordination/` byte-identically;
/// when that source tree is reachable on disk (sibling repo) it is preferred so
/// this harness also guards against fixture drift across the family.

final _specDir = Directory('../lazily-spec/conformance/coordination');

Map<String, dynamic> _loadFixture(String name) {
  final src = _specDir.existsSync()
      ? File(_specDir.resolveSymbolicLinksSync() + '/$name').specReadAsStringSync()
      : File('test/conformance/coordination/$name').specReadAsStringSync();
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
  test('LeaseCell', () {
    final fx = _loadFixture('lease.json');
    final ctx = Context();
    final lease = LeaseCell(ctx);
    final observed = _observe(ctx, lease.holderCell);

    for (final step in (fx['steps'] as List).cast<Map<String, dynamic>>()) {
      final op = step['op'] as Map<String, dynamic>;
      final expected = assertionsOf(step['expected']);
      final now = op['now'] as int;
      switch (op['type']) {
        case 'acquire':
          expect(lease.acquire(op['peer'] as int, now, op['ttl'] as int),
              equals(step['returns']));
          break;
        case 'renew':
          expect(lease.renew(op['peer'] as int, now, op['ttl'] as int),
              equals(step['returns']));
          break;
        case 'tick':
          expect(lease.tick(now), equals(step['returns']));
          break;
      }
      assertKey(expected, 'holder', lease.holder(now));
      assertKey(expected, 'held', lease.isHeld(now));
      assertKey(expected, 'fence', lease.fence());
      assertKeyWith(expected, 'invalidates', (v) {
        expect(_invalidated(ctx, observed), equals((v as Map)['holder']),
            reason: 'holder invalidation');
      });
    }
  });

  test('LeaderCell', () {
    final fx = _loadFixture('leader.json');
    final ctx = Context();
    final config = fx['config'] as Map<String, dynamic>;
    final leader = LeaderCell(ctx, config['me'] as int);
    final observed = _observe(ctx, leader.currentLeaderCell);

    for (final step in (fx['steps'] as List).cast<Map<String, dynamic>>()) {
      final op = step['op'] as Map<String, dynamic>;
      final expected = assertionsOf(step['expected']);
      final now = op['now'] as int;
      final LeaderRole role;
      switch (op['type']) {
        case 'campaign':
          role = leader.campaign(now, op['ttl'] as int);
          break;
        case 'contend':
          role = leader.contend(op['peer'] as int, now, op['ttl'] as int);
          break;
        default:
          role = leader.tick(now);
      }
      assertKeyWith(expected, 'role', (v) {
        final wantRole = {
          'Leader': LeaderRole.leader,
          'Follower': LeaderRole.follower,
          'Candidate': LeaderRole.candidate,
        }[v];
        expect(role, equals(wantRole));
      });
      assertKey(expected, 'current_leader', leader.currentLeader(now));
      assertKeyWith(expected, 'invalidates', (v) {
        expect(_invalidated(ctx, observed), equals((v as Map)['current_leader']),
            reason: 'current_leader invalidation');
      });
    }
  });

  test('LockCell', () {
    final fx = _loadFixture('lock.json');
    final ctx = Context();
    final lock = LockCell(ctx);
    final observed = _observe(ctx, lock.isLockedCell);

    for (final step in (fx['steps'] as List).cast<Map<String, dynamic>>()) {
      final op = step['op'] as Map<String, dynamic>;
      final expected = assertionsOf(step['expected']);
      final now = (op['now'] as int?) ?? 0;
      switch (op['type']) {
        case 'acquire':
          expect(lock.acquire(op['peer'] as int, now, op['ttl'] as int),
              equals(step['returns']));
          break;
        case 'validate':
          expect(lock.validate(op['fence'] as int), equals(step['returns']));
          break;
        case 'tick':
          expect(lock.tick(now), equals(step['returns']));
          break;
      }
      assertKey(expected, 'is_locked', lock.isLocked(now));
      assertKey(expected, 'fence', lock.fence());
      assertKeyWith(expected, 'invalidates', (v) {
        expect(_invalidated(ctx, observed), equals((v as Map)['is_locked']),
            reason: 'is_locked invalidation');
      });
    }
  });

  test('SemaphoreCell', () {
    final fx = _loadFixture('semaphore.json');
    final ctx = Context();
    final config = fx['config'] as Map<String, dynamic>;
    final sem = SemaphoreCell(ctx, config['capacity'] as int);
    final observed = _observe(ctx, sem.permitsAvailableCell);

    for (final step in (fx['steps'] as List).cast<Map<String, dynamic>>()) {
      final op = step['op'] as Map<String, dynamic>;
      final expected = assertionsOf(step['expected']);
      if (op['type'] == 'acquire') {
        expect(sem.acquire(), equals(step['returns']));
      } else {
        sem.release();
      }
      assertKey(expected, 'permits_available', sem.permitsAvailable());
      assertKeyWith(expected, 'invalidates', (v) {
        expect(_invalidated(ctx, observed),
            equals((v as Map)['permits_available']),
            reason: 'permits_available invalidation');
      });
    }
  });

  test('QuorumCell', () {
    final fx = _loadFixture('quorum.json');
    final ctx = Context();
    final config = fx['config'] as Map<String, dynamic>;
    final q = BarrierCell.quorum(ctx, config['total'] as int);
    final observed = _observe(ctx, q.isOpenCell);

    for (final step in (fx['steps'] as List).cast<Map<String, dynamic>>()) {
      final op = step['op'] as Map<String, dynamic>;
      final expected = assertionsOf(step['expected']);
      expect(q.arrive(op['peer'] as int), equals(step['returns']));
      assertKey(expected, 'votes', q.count());
      assertKey(expected, 'is_open', q.isOpen());
      assertKeyWith(expected, 'invalidates', (v) {
        expect(_invalidated(ctx, observed), equals((v as Map)['is_open']),
            reason: 'is_open invalidation');
      });
    }
  });
}
