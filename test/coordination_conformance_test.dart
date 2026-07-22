import 'dart:convert';
import 'dart:io';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

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
      ? File(_specDir.resolveSymbolicLinksSync() + '/$name').readAsStringSync()
      : File('test/conformance/coordination/$name').readAsStringSync();
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
  test('LeaseCell', () {
    final fx = _loadFixture('lease.json');
    final ctx = Context();
    final lease = LeaseCell(ctx);
    final observed = _observe(ctx, lease.holderCell);

    for (final step in (fx['steps'] as List).cast<Map<String, dynamic>>()) {
      final op = step['op'] as Map<String, dynamic>;
      final expected = step['expected'] as Map<String, dynamic>;
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
      expect(lease.holder(now), equals(expected['holder']));
      expect(lease.isHeld(now), equals(expected['held']));
      expect(lease.fence(), equals(expected['fence']));
      final wantInv =
          (expected['invalidates'] as Map<String, dynamic>)['holder'];
      expect(_invalidated(ctx, observed), equals(wantInv),
          reason: 'holder invalidation');
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
      final expected = step['expected'] as Map<String, dynamic>;
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
      final wantRole = {
        'Leader': LeaderRole.leader,
        'Follower': LeaderRole.follower,
        'Candidate': LeaderRole.candidate,
      }[expected['role']];
      expect(role, equals(wantRole));
      expect(leader.currentLeader(now), equals(expected['current_leader']));
      final wantInv =
          (expected['invalidates'] as Map<String, dynamic>)['current_leader'];
      expect(_invalidated(ctx, observed), equals(wantInv),
          reason: 'current_leader invalidation');
    }
  });

  test('LockCell', () {
    final fx = _loadFixture('lock.json');
    final ctx = Context();
    final lock = LockCell(ctx);
    final observed = _observe(ctx, lock.isLockedCell);

    for (final step in (fx['steps'] as List).cast<Map<String, dynamic>>()) {
      final op = step['op'] as Map<String, dynamic>;
      final expected = step['expected'] as Map<String, dynamic>;
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
      expect(lock.isLocked(now), equals(expected['is_locked']));
      expect(lock.fence(), equals(expected['fence']));
      final wantInv =
          (expected['invalidates'] as Map<String, dynamic>)['is_locked'];
      expect(_invalidated(ctx, observed), equals(wantInv),
          reason: 'is_locked invalidation');
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
      final expected = step['expected'] as Map<String, dynamic>;
      if (op['type'] == 'acquire') {
        expect(sem.acquire(), equals(step['returns']));
      } else {
        sem.release();
      }
      expect(sem.permitsAvailable(), equals(expected['permits_available']));
      final wantInv =
          (expected['invalidates'] as Map<String, dynamic>)['permits_available'];
      expect(_invalidated(ctx, observed), equals(wantInv),
          reason: 'permits_available invalidation');
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
      final expected = step['expected'] as Map<String, dynamic>;
      expect(q.arrive(op['peer'] as int), equals(step['returns']));
      expect(q.count(), equals(expected['votes']));
      expect(q.isOpen(), equals(expected['is_open']));
      final wantInv =
          (expected['invalidates'] as Map<String, dynamic>)['is_open'];
      expect(_invalidated(ctx, observed), equals(wantInv),
          reason: 'is_open invalidation');
    }
  });
}
