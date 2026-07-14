/// Temporal source primitives (`#lztime`) — the Dart port.
///
/// See `lazily-spec/docs/temporal-sources.md` and the formal model
/// `lazily-formal/LazilyFormal/Temporal.lean`. Time is a monotone **logical
/// clock** (`now`, an integer) exactly like the relay policies; a binding drives
/// the sources from its own runtime timer by feeding a non-decreasing `now`.
///
/// Each source is a pure compute **core** (`TimerCore`/`IntervalCore`/
/// `CronCore`/`DeadlineCore`) — the C++/bytes-eligible part — split from a thin
/// reactive **cell** that projects the core's fire edge onto a [Context] cell so
/// dependents invalidate *only on an actual fire* (the backend-portability rule).
library;

import 'core.dart';

// ---------------------------------------------------------------------------
// Single-shot timer
// ---------------------------------------------------------------------------

/// Single-shot core: fires exactly once at the first tick with `now >= fireAt`.
class TimerCore {
  TimerCore(this.fireAt);

  final int fireAt;
  bool fired = false;

  /// Advance to [now]; returns the fire edge (`true` only on the first fire).
  bool tick(int now) {
    if (fired || now < fireAt) return false;
    fired = true;
    return true;
  }

  int? nextFire() => fired ? null : fireAt;
}

/// Reactive single-shot timer: edge-only invalidation of `fired`/`value`.
class TimerCell {
  TimerCell(this.ctx, int fireAt)
      : core = TimerCore(fireAt),
        firedCell = Cell<bool>(ctx, false);

  final Context ctx;
  final TimerCore core;
  final Cell<bool> firedCell;

  bool tick(int now) {
    final edge = core.tick(now);
    if (edge) firedCell.value = true;
    return edge;
  }

  bool hasFired() => firedCell.value;

  /// `null` before the fire, the unit marker (`true`) after.
  bool? value() => firedCell.value ? true : null;

  int? nextFire() => core.nextFire();
}

// ---------------------------------------------------------------------------
// Periodic interval
// ---------------------------------------------------------------------------

/// Periodic core: boundaries at `period, 2*period, ...`; a tick counts every
/// boundary in `(frontier, now]`, so a jump past several counts them all.
class IntervalCore {
  IntervalCore(int period)
      : period = period < 1 ? 1 : period,
        next = period < 1 ? 1 : period;

  final int period;
  int next;
  int count = 0;

  int _firesThisTick(int now) =>
      now < next ? 0 : ((now - next) ~/ period) + 1;

  bool tick(int now) {
    final fires = _firesThisTick(now);
    if (fires == 0) return false;
    count += fires;
    next += fires * period;
    return true;
  }

  int nextFire() => next;
}

/// Reactive periodic interval: invalidates only when `count` changes.
class IntervalCell {
  IntervalCell(this.ctx, int period)
      : core = IntervalCore(period),
        countCell = Cell<int>(ctx, 0);

  final Context ctx;
  final IntervalCore core;
  final Cell<int> countCell;

  bool tick(int now) {
    final edge = core.tick(now);
    if (edge) countCell.value = core.count;
    return edge;
  }

  int count() => countCell.value;

  int nextFire() => core.nextFire();
}

// ---------------------------------------------------------------------------
// Cron pattern
// ---------------------------------------------------------------------------

/// Count of `m in 1..=n` with `m mod cycle == o` (`0 <= o < cycle`).
int _countUpto(int n, int o, int cycle) {
  if (o == 0) return n ~/ cycle;
  if (o <= n) return ((n - o) ~/ cycle) + 1;
  return 0;
}

/// Pattern-periodic core: a tick `m >= 1` fires iff `m mod cycle` is in
/// `offsets` — an interval with a match set (a cron expression's shape).
class CronCore {
  CronCore(int cycle, List<int> offsets)
      : cycle = cycle < 1 ? 1 : cycle,
        offsets = _normalizeOffsets(offsets, cycle < 1 ? 1 : cycle);

  final int cycle;
  final List<int> offsets;
  int cursor = 0;
  int count = 0;

  static List<int> _normalizeOffsets(List<int> offsets, int cycle) {
    final set = <int>{};
    for (final o in offsets) {
      set.add(((o % cycle) + cycle) % cycle);
    }
    final list = set.toList()..sort();
    return list;
  }

  int _matchesIn(int lo, int hi) {
    var sum = 0;
    for (final o in offsets) {
      sum += _countUpto(hi, o, cycle) - _countUpto(lo, o, cycle);
    }
    return sum;
  }

  bool tick(int now) {
    if (now <= cursor) {
      cursor = cursor > now ? cursor : now;
      return false;
    }
    final fires = _matchesIn(cursor, now);
    cursor = now;
    if (fires == 0) return false;
    count += fires;
    return true;
  }

  int? nextFire() {
    if (offsets.isEmpty) return null;
    final start = cursor + 1;
    final base = (start ~/ cycle) * cycle;
    for (var cyc = 0; cyc < 2; cyc++) {
      final block = base + cyc * cycle;
      for (final o in offsets) {
        final cand = block + o;
        if (cand >= start) return cand;
      }
    }
    return null;
  }
}

/// Reactive cron source: same reactive contract as [IntervalCell].
class CronCell {
  CronCell(this.ctx, int cycle, List<int> offsets)
      : core = CronCore(cycle, offsets),
        countCell = Cell<int>(ctx, 0);

  final Context ctx;
  final CronCore core;
  final Cell<int> countCell;

  bool tick(int now) {
    final edge = core.tick(now);
    if (edge) countCell.value = core.count;
    return edge;
  }

  int count() => countCell.value;

  int? nextFire() => core.nextFire();
}

// ---------------------------------------------------------------------------
// Value + deadline
// ---------------------------------------------------------------------------

/// Liveness state label for a [DeadlineCell].
enum DeadlinedState { live, expired }

/// Deadline core (bytes-eligible): a [TimerCore] over the deadline.
class DeadlineCore {
  DeadlineCore(int deadline) : timer = TimerCore(deadline);

  final TimerCore timer;

  bool get isExpired => timer.fired;

  bool tick(int now) => timer.tick(now);

  int? nextFire() => timer.nextFire();
}

/// State projection of a [DeadlineCell]: a liveness label plus the preserved
/// value.
class DeadlineState<T> {
  const DeadlineState(this.state, this.value);

  final DeadlinedState state;
  final T value;
}

/// Reactive value + deadline: flips `Live(v) -> Expired(v)` at the deadline,
/// preserving the value; `state` invalidates only on the expiry edge.
class DeadlineCell<T> {
  DeadlineCell(this.ctx, this.value, int deadline)
      : core = DeadlineCore(deadline),
        expiredCell = Cell<bool>(ctx, false);

  final Context ctx;
  final T value;
  final DeadlineCore core;
  final Cell<bool> expiredCell;

  bool tick(int now) {
    final edge = core.tick(now);
    if (edge) expiredCell.value = true;
    return edge;
  }

  /// The liveness label plus preserved value — the value survives the flip.
  DeadlineState<T> state() => DeadlineState<T>(
        expiredCell.value ? DeadlinedState.expired : DeadlinedState.live,
        value,
      );

  bool isExpired() => expiredCell.value;

  int? nextFire() => core.nextFire();
}
