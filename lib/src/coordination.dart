/// Distributed coordination (`#lzcoord`) — the Dart port.
///
/// See `lazily-spec/docs/coordination.md` and the formal model
/// `lazily-formal/LazilyFormal/Coordination.lean`. Lease / leader / lock /
/// semaphore / barrier + quorum primitives, each a pure compute **core** — the
/// C++/bytes-eligible part — split from a thin reactive **cell** that projects
/// the salient reader onto a [Context] cell so dependents invalidate *only when
/// that reader actually changes* (the backend-portability rule). Time is the
/// logical clock (`now`, an integer). A holder of `null` means "no holder".
library;

import 'core.dart';

// ---------------------------------------------------------------------------
// Lease + fencing token
// ---------------------------------------------------------------------------

/// Single-writer lease authority with a monotone fencing token.
///
/// Peers are identified by an integer id. A grant increments the [fence]; a
/// renew by the current holder keeps the same fence. An acquire while held by
/// another peer is rejected. Expiry is `now >= expiry`.
class LeaseCore {
  int? holderPeer;
  int expiry = 0;
  int fence = 0;

  bool _isExpired(int now) => holderPeer != null && now >= expiry;

  /// Whether the lease is currently held (and not expired) at [now].
  bool isHeld(int now) => holderPeer != null && !_isExpired(now);

  /// The live holder at [now], or `null` when free/expired.
  int? holder(int now) => isHeld(now) ? holderPeer : null;

  /// Grant the lease to [peer]. Returns the fencing token on success, or `null`
  /// when held by another peer. A grant on a free/expired lease bumps the fence;
  /// a renew by the current holder keeps the same fence.
  int? acquire(int peer, int now, int ttl) {
    if (holderPeer == null || _isExpired(now)) {
      fence += 1;
      holderPeer = peer;
      expiry = now + ttl;
      return fence;
    }
    if (holderPeer == peer) {
      expiry = now + ttl; // renew keeps fence
      return fence;
    }
    return null;
  }

  /// Extend the lease if [peer] is the live holder. Returns whether it renewed.
  bool renew(int peer, int now, int ttl) {
    if (isHeld(now) && holderPeer == peer) {
      expiry = now + ttl;
      return true;
    }
    return false;
  }

  /// Release the lease if [peer] is the current holder (no-op otherwise).
  void release(int peer) {
    if (holderPeer == peer) holderPeer = null;
  }

  /// Advance the clock to [now]; clears an expired holder. Returns the expiry
  /// edge (`true` only on the tick that expires a held lease).
  bool tick(int now) {
    if (_isExpired(now)) {
      holderPeer = null;
      return true;
    }
    return false;
  }
}

/// Reactive lease: projects the live holder onto a cell that invalidates only
/// when the holder changes.
class LeaseCell {
  LeaseCell(this.ctx)
      : core = LeaseCore(),
        holderCell = Cell<int?>(ctx, null);

  final Context ctx;
  final LeaseCore core;
  final Cell<int?> holderCell;

  void _refresh(int now) => holderCell.value = core.holder(now);

  int? acquire(int peer, int now, int ttl) {
    final r = core.acquire(peer, now, ttl);
    _refresh(now);
    return r;
  }

  bool renew(int peer, int now, int ttl) {
    final r = core.renew(peer, now, ttl);
    _refresh(now);
    return r;
  }

  void release(int peer, int now) {
    core.release(peer);
    _refresh(now);
  }

  bool tick(int now) {
    final r = core.tick(now);
    _refresh(now);
    return r;
  }

  int? holder(int now) => core.holder(now);

  bool isHeld(int now) => core.isHeld(now);

  int fence() => core.fence;
}

// ---------------------------------------------------------------------------
// Leader / follower / candidate
// ---------------------------------------------------------------------------

/// Leadership role from a node's own perspective.
enum LeaderRole { leader, follower, candidate }

/// Reactive leadership over a lease from node [me]'s perspective. The current
/// leader is projected onto a cell that invalidates only on re-election.
class LeaderCell {
  LeaderCell(this.ctx, this.me)
      : core = LeaseCore(),
        currentLeaderCell = Cell<int?>(ctx, null);

  final Context ctx;
  final int me;
  final LeaseCore core;
  final Cell<int?> currentLeaderCell;

  void _refresh(int now) => currentLeaderCell.value = core.holder(now);

  LeaderRole campaign(int now, int ttl) {
    core.acquire(me, now, ttl);
    _refresh(now);
    return role(now);
  }

  LeaderRole contend(int peer, int now, int ttl) {
    core.acquire(peer, now, ttl);
    _refresh(now);
    return role(now);
  }

  LeaderRole tick(int now) {
    core.tick(now);
    _refresh(now);
    return role(now);
  }

  int? currentLeader(int now) => core.holder(now);

  LeaderRole role(int now) {
    final h = core.holder(now);
    if (h == null) return LeaderRole.candidate;
    return h == me ? LeaderRole.leader : LeaderRole.follower;
  }
}

// ---------------------------------------------------------------------------
// Distributed lock + fencing
// ---------------------------------------------------------------------------

/// Reactive distributed mutex over a lease + fencing token. `isLocked` is
/// projected onto a cell that invalidates only when the lock state flips.
class LockCell {
  LockCell(this.ctx)
      : core = LeaseCore(),
        isLockedCell = Cell<bool>(ctx, false);

  final Context ctx;
  final LeaseCore core;
  final Cell<bool> isLockedCell;

  void _refresh(int now) => isLockedCell.value = core.isHeld(now);

  int? acquire(int peer, int now, int ttl) {
    final r = core.acquire(peer, now, ttl);
    _refresh(now);
    return r;
  }

  void release(int peer, int now) {
    core.release(peer);
    _refresh(now);
  }

  bool tick(int now) {
    final r = core.tick(now);
    _refresh(now);
    return r;
  }

  /// Whether [fence] is the current (non-stale) fencing token.
  bool validate(int fence) => core.fence == fence;

  bool isLocked(int now) => core.isHeld(now);

  int fence() => core.fence;
}

// ---------------------------------------------------------------------------
// Semaphore
// ---------------------------------------------------------------------------

/// Bounded permit pool compute core.
class SemaphoreCore {
  SemaphoreCore(this.capacity);

  final int capacity;
  int acquired = 0;

  int available() => capacity - acquired;

  bool acquire() {
    if (acquired < capacity) {
      acquired += 1;
      return true;
    }
    return false;
  }

  void release() {
    if (acquired > 0) acquired -= 1;
  }
}

/// Reactive semaphore: projects `permitsAvailable` onto a cell that invalidates
/// only when the permit count changes.
class SemaphoreCell {
  SemaphoreCell(this.ctx, int capacity)
      : core = SemaphoreCore(capacity),
        permitsAvailableCell = Cell<int>(ctx, capacity);

  final Context ctx;
  final SemaphoreCore core;
  final Cell<int> permitsAvailableCell;

  void _refresh() => permitsAvailableCell.value = core.available();

  bool acquire() {
    final r = core.acquire();
    _refresh();
    return r;
  }

  void release() {
    core.release();
    _refresh();
  }

  int permitsAvailable() => permitsAvailableCell.value;
}

// ---------------------------------------------------------------------------
// Barrier / quorum
// ---------------------------------------------------------------------------

/// Wait-for-N gate over distinct arriving peers.
class BarrierCore {
  BarrierCore(this.required);

  final int required;
  final Set<int> arrived = <int>{};

  bool arrive(int peer) {
    arrived.add(peer);
    return isOpen();
  }

  int count() => arrived.length;

  bool isOpen() => count() >= required;
}

/// Reactive wait-for-N gate. A quorum is a barrier with `required = total/2 + 1`
/// (strict majority). `isOpen` is projected onto a cell that invalidates only
/// when the gate flips.
class BarrierCell {
  BarrierCell(this.ctx, int required)
      : core = BarrierCore(required),
        // No peers have arrived yet, so the gate starts open only if it
        // requires nothing (`0 >= required`) — mirrors `core.isOpen()`.
        isOpenCell = Cell<bool>(ctx, required <= 0);

  final Context ctx;
  final BarrierCore core;
  final Cell<bool> isOpenCell;

  /// A quorum gate: opens at a strict majority of [total].
  static BarrierCell quorum(Context ctx, int total) =>
      BarrierCell(ctx, (total ~/ 2) + 1);

  void _refresh() => isOpenCell.value = core.isOpen();

  bool arrive(int peer) {
    final r = core.arrive(peer);
    _refresh();
    return r;
  }

  int count() => core.count();

  bool isOpen() => isOpenCell.value;
}
