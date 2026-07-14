/// Fault-tolerance primitives (`#lzresilience`) — the Dart port.
///
/// See `lazily-spec/docs/resilience.md` and the formal model
/// `lazily-formal/LazilyFormal/Resilience.lean`. Circuit breaker / retry /
/// bulkhead / timeout, each a pure compute **core** (a state machine / counter
/// over the logical clock) split from a thin reactive **cell** projecting the
/// salient reader onto a [Context] cell so dependents invalidate *only when the
/// projected value actually changes* (the backend-portability rule). Composes
/// with the command transport so RPCs degrade gracefully.
library;

import 'core.dart';

// ---------------------------------------------------------------------------
// Circuit breaker
// ---------------------------------------------------------------------------

/// Circuit-breaker state. Enum value equality drives the projected cell's
/// `!=` guard, so a refresh to the same state cascades to nothing.
enum BreakerState {
  /// Calls pass; failures accumulate in the window.
  closed,

  /// Fast-fail until the reset deadline.
  open,

  /// Allow a single probe.
  halfOpen,
}

/// Circuit-breaker compute core: a sliding window of outcomes trips
/// `Closed -> Open` at [failureThreshold]; `Open -> HalfOpen` at the deadline; a
/// HalfOpen success closes, a failure re-opens.
class CircuitBreakerCore {
  CircuitBreakerCore(int window, int failureThreshold, this.resetTimeout)
      : window = window < 1 ? 1 : window,
        failureThreshold = failureThreshold < 1 ? 1 : failureThreshold;

  final int window;
  final int failureThreshold;
  final int resetTimeout;
  BreakerState state = BreakerState.closed;
  final List<bool> outcomes = []; // true = success
  int openUntil = 0;

  int _failures() => outcomes.where((s) => !s).length;

  /// Whether a call is permitted; performs the `Open -> HalfOpen` transition at
  /// the deadline.
  bool allow(int now) {
    switch (state) {
      case BreakerState.closed:
        return true;
      case BreakerState.open:
        if (now >= openUntil) {
          state = BreakerState.halfOpen;
          return true;
        }
        return false;
      case BreakerState.halfOpen:
        return true;
    }
  }

  /// Feed a call outcome and drive the state machine.
  void record(bool success, int now) {
    switch (state) {
      case BreakerState.halfOpen:
        if (success) {
          state = BreakerState.closed;
          outcomes.clear();
        } else {
          state = BreakerState.open;
          openUntil = now + resetTimeout;
        }
      case BreakerState.closed:
        outcomes.add(success);
        while (outcomes.length > window) {
          outcomes.removeAt(0);
        }
        if (_failures() >= failureThreshold) {
          state = BreakerState.open;
          openUntil = now + resetTimeout;
        }
      case BreakerState.open:
        break;
    }
  }
}

/// Reactive circuit breaker: projects the [state] onto a cell that invalidates
/// its readers only on an actual state transition.
class CircuitBreakerCell {
  CircuitBreakerCell(
    this.ctx,
    int window,
    int failureThreshold,
    int resetTimeout,
  )   : core = CircuitBreakerCore(window, failureThreshold, resetTimeout),
        stateCell = Cell<BreakerState>(ctx, BreakerState.closed);

  final Context ctx;
  final CircuitBreakerCore core;
  final Cell<BreakerState> stateCell;

  void _refresh() {
    stateCell.value = core.state;
  }

  bool allow(int now) {
    final r = core.allow(now);
    _refresh();
    return r;
  }

  void record(bool success, int now) {
    core.record(success, now);
    _refresh();
  }

  BreakerState state() => core.state;
}

// ---------------------------------------------------------------------------
// Retry backoff
// ---------------------------------------------------------------------------

/// Exponential-backoff compute core: `delay(attempt) = min(cap, base·2^attempt)`,
/// saturating to [cap] on shift overflow.
class RetryPolicyCore {
  RetryPolicyCore(this.base, this.cap);

  final int base;
  final int cap;
  int attempt = 0;

  /// The delay for [attempt] (saturating at [cap]).
  int delay(int attempt) {
    if (attempt >= 63) return cap;
    final shifted = base << attempt;
    return shifted < cap ? shifted : cap;
  }

  /// The current attempt's delay, then advance.
  int nextDelay() {
    final d = delay(attempt);
    attempt += 1;
    return d;
  }

  void reset() {
    attempt = 0;
  }
}

/// Reactive retry policy: projects the current delay onto a cell that
/// invalidates only when the delay changes.
class RetryPolicyCell {
  RetryPolicyCell(this.ctx, int base, int cap)
      : core = RetryPolicyCore(base, cap),
        delayCell = Cell<int>(ctx, 0);

  final Context ctx;
  final RetryPolicyCore core;
  final Cell<int> delayCell;

  int nextDelay() {
    final d = core.nextDelay();
    delayCell.value = d;
    return d;
  }

  void reset() {
    core.reset();
    delayCell.value = 0;
  }

  int delay() => delayCell.value;
}

// ---------------------------------------------------------------------------
// Bulkhead
// ---------------------------------------------------------------------------

/// Bounded isolation-pool compute core.
class BulkheadCore {
  BulkheadCore(this.capacity);

  final int capacity;
  int inUse = 0;

  bool acquire() {
    if (inUse < capacity) {
      inUse += 1;
      return true;
    }
    return false;
  }

  void release() {
    if (inUse > 0) inUse -= 1;
  }
}

/// Reactive bulkhead: projects `permitsInUse` onto a cell that invalidates only
/// when the in-use count changes.
class BulkheadCell {
  BulkheadCell(this.ctx, int capacity)
      : core = BulkheadCore(capacity),
        inUseCell = Cell<int>(ctx, 0);

  final Context ctx;
  final BulkheadCore core;
  final Cell<int> inUseCell;

  void _refresh() {
    inUseCell.value = core.inUse;
  }

  bool acquire() {
    final r = core.acquire();
    _refresh();
    return r;
  }

  void release() {
    core.release();
    _refresh();
  }

  int permitsInUse() => inUseCell.value;
}

// ---------------------------------------------------------------------------
// Timeout
// ---------------------------------------------------------------------------

/// Deadline-bounded call compute core.
class TimeoutCore {
  int deadline = 0;
  bool armed = false;
  bool timedOut = false;

  /// Arm the timeout with `deadline = now + timeout`.
  void arm(int now, int timeout) {
    deadline = now + timeout;
    armed = true;
    timedOut = false;
  }

  /// Fast-fail when `now >= deadline`; returns the timeout edge (once).
  bool tick(int now) {
    if (armed && !timedOut && now >= deadline) {
      timedOut = true;
      return true;
    }
    return false;
  }

  bool isTimedOut() => timedOut;
}

/// Reactive timeout: projects `isTimedOut` onto a cell that invalidates only on
/// the timeout edge.
class TimeoutCell {
  TimeoutCell(this.ctx)
      : core = TimeoutCore(),
        timedOutCell = Cell<bool>(ctx, false);

  final Context ctx;
  final TimeoutCore core;
  final Cell<bool> timedOutCell;

  void _refresh() {
    timedOutCell.value = core.isTimedOut();
  }

  void arm(int now, int timeout) {
    core.arm(now, timeout);
    _refresh();
  }

  bool tick(int now) {
    final r = core.tick(now);
    _refresh();
    return r;
  }

  bool isTimedOut() => timedOutCell.value;
}
