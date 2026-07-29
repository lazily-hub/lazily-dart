/// Portable logical-clock standard-library primitives.
///
/// These APIs deliberately do not own a wall clock, event loop, timer, or
/// cancellation source. Callers supply logical time and adapter callbacks, so
/// the same state machines work in Flutter, browsers, isolates, and native Dart.
///
/// Clock values are [BigInt] rather than [int]. Dart's JavaScript target cannot
/// represent every uint64 value as an `int`, while the conformance contract
/// requires exact checked uint64 deadline arithmetic.
library;

import 'dart:async';

/// Largest value accepted by the portable clock contract.
final BigInt maxUint64 = (BigInt.one << 64) - BigInt.one;

/// Largest integer represented exactly by every Dart target, including JS.
final BigInt maxJsonSafeInteger = (BigInt.one << 53) - BigInt.one;

/// A typed portable-stdlib failure.
class StdlibUnavailable implements Exception {
  const StdlibUnavailable(this.reason);

  final String reason;

  @override
  String toString() => 'StdlibUnavailable($reason)';
}

BigInt _uint64(BigInt value, String name) {
  if (value.isNegative || value > maxUint64) {
    throw RangeError('$name must be in the uint64 range');
  }
  return value;
}

/// Return `now + duration`, or throw a typed `deadline_overflow` failure.
BigInt checkedDeadline(BigInt now, BigInt duration) {
  if (now.isNegative || duration.isNegative) {
    throw RangeError('logical clock values must be non-negative');
  }
  if (now > maxUint64 || duration > maxUint64 || duration > maxUint64 - now) {
    throw const StdlibUnavailable('deadline_overflow');
  }
  return now + duration;
}

/// Project an exact uint64 into a value accepted by `dart:convert`.
///
/// Canonical fixture-sized values stay JSON numbers. Values outside the
/// browser-safe integer range become decimal strings, which prevents
/// `jsonEncode`/`jsonDecode` from silently rounding them on JavaScript targets.
/// Peer inputs accept both forms, so the representation round-trips exactly.
Object jsonSafeUint64(BigInt value) {
  _uint64(value, 'value');
  return value <= maxJsonSafeInteger ? value.toInt() : value.toString();
}

/// An externally observable [Timer] state.
class TimerObservation {
  const TimerObservation._(
    this.outcome, {
    this.deadline,
    this.firedAt,
    this.reason,
  });

  const TimerObservation.pending(BigInt deadline)
      : this._('pending', deadline: deadline);

  const TimerObservation.fired(BigInt firedAt)
      : this._('fired', firedAt: firedAt);

  const TimerObservation.unavailable(String reason, {BigInt? deadline})
      : this._('unavailable', reason: reason, deadline: deadline);

  final String outcome;
  final BigInt? deadline;
  final BigInt? firedAt;
  final String? reason;

  Map<String, Object> toJson() => {
        'outcome': outcome,
        if (deadline case final value?) 'deadline': jsonSafeUint64(value),
        if (firedAt case final value?) 'fired_at': jsonSafeUint64(value),
        if (reason case final value?) 'reason': value,
      };
}

/// A deterministic single-shot timer driven by caller-supplied logical time.
class Timer {
  Timer(BigInt now, BigInt duration)
      : deadline = checkedDeadline(now, duration),
        _lastNow = now;

  final BigInt deadline;
  BigInt _lastNow;
  BigInt? _firedAt;

  TimerObservation get initial => TimerObservation.pending(deadline);

  /// Observe the timer at [now].
  ///
  /// A regressing clock returns a typed unavailable observation without
  /// changing state. Firing is inclusive at the deadline and terminal results
  /// latch the first observed fire time.
  TimerObservation observe(BigInt now) {
    _uint64(now, 'now');
    final firedAt = _firedAt;
    if (firedAt != null) return TimerObservation.fired(firedAt);
    if (now < _lastNow) {
      return TimerObservation.unavailable(
        'clock_regression',
        deadline: deadline,
      );
    }
    _lastNow = now;
    if (now >= deadline) {
      _firedAt = now;
      return TimerObservation.fired(now);
    }
    return TimerObservation.pending(deadline);
  }

  /// Await a caller-owned wait seam, then observe the supplied logical time.
  ///
  /// The waiter is not invoked after the timer has fired.
  Future<TimerObservation> wait(
    FutureOr<BigInt> Function(BigInt deadline) waiter,
  ) async {
    final firedAt = _firedAt;
    if (firedAt != null) return TimerObservation.fired(firedAt);
    return observe(await waiter(deadline));
  }
}

/// State supplied by one timeout operation-adapter poll.
class TimeoutOperation<T> {
  const TimeoutOperation._(this.state, [this.value]);

  const TimeoutOperation.pending() : this._('pending');

  const TimeoutOperation.completed(T value) : this._('completed', value);

  const TimeoutOperation.unavailable() : this._('unavailable');

  final String state;
  final T? value;
}

/// State supplied by a caller-owned cancellation adapter.
enum TimeoutCancellation { pending, cancelled, unavailable }

/// An externally observable [Timeout] state.
class TimeoutObservation<T> {
  const TimeoutObservation._(
    this.outcome, {
    this.deadline,
    this.value,
    this.reason,
  });

  const TimeoutObservation.pending(BigInt deadline)
      : this._('pending', deadline: deadline);

  const TimeoutObservation.completed(T value)
      : this._('completed', value: value);

  const TimeoutObservation.timedOut() : this._('timed_out');

  const TimeoutObservation.cancelled() : this._('cancelled');

  const TimeoutObservation.unavailable(String reason)
      : this._('unavailable', reason: reason);

  final String outcome;
  final BigInt? deadline;
  final T? value;
  final String? reason;

  Map<String, Object?> toJson() => {
        'outcome': outcome,
        if (deadline case final deadline?) 'deadline': jsonSafeUint64(deadline),
        if (outcome == 'completed') 'value': value,
        if (reason case final reason?) 'reason': reason,
      };
}

/// A deterministic timeout wrapper with caller-driven operation and
/// cancellation adapters.
class Timeout<T> {
  Timeout(BigInt now, BigInt duration)
      : deadline = checkedDeadline(now, duration),
        _lastNow = now;

  final BigInt deadline;
  BigInt _lastNow;
  TimeoutObservation<T>? _terminal;

  TimeoutObservation<T> get initial => TimeoutObservation.pending(deadline);

  TimeoutObservation<T>? _beforeAdapters(BigInt now) {
    _uint64(now, 'now');
    final terminal = _terminal;
    if (terminal != null) return terminal;
    if (now < _lastNow) {
      return _latch(
        const TimeoutObservation.unavailable('clock_regression'),
      );
    }
    _lastNow = now;
    if (now >= deadline) {
      return _latch(const TimeoutObservation.timedOut());
    }
    return null;
  }

  TimeoutObservation<T> _settle(
    TimeoutOperation<T> operation,
    TimeoutCancellation cancellation,
  ) {
    final terminal = _terminal;
    if (terminal != null) return terminal;
    switch (operation.state) {
      case 'completed':
        return _latch(TimeoutObservation.completed(operation.value as T));
      case 'unavailable':
        return _latch(
          const TimeoutObservation.unavailable('operation_unavailable'),
        );
      case 'pending':
        break;
      default:
        return _latch(
          const TimeoutObservation.unavailable('operation_unavailable'),
        );
    }
    switch (cancellation) {
      case TimeoutCancellation.cancelled:
        return _latch(const TimeoutObservation.cancelled());
      case TimeoutCancellation.unavailable:
        return _latch(
          const TimeoutObservation.unavailable('cancellation_unavailable'),
        );
      case TimeoutCancellation.pending:
        return TimeoutObservation.pending(deadline);
    }
  }

  /// Poll both adapters exactly once before the deadline.
  ///
  /// Precedence is completion, unavailable operation, cancellation, pending.
  /// At or after the deadline and after any terminal result, neither adapter is
  /// invoked.
  TimeoutObservation<T> poll(
    BigInt now,
    TimeoutOperation<T> Function() operation,
    TimeoutCancellation Function() cancellation,
  ) {
    final immediate = _beforeAdapters(now);
    if (immediate != null) return immediate;
    final operationValue = operation();
    final cancellationValue = cancellation();
    return _settle(operationValue, cancellationValue);
  }

  /// Future adapter for caller-owned async operation and cancellation seams.
  Future<TimeoutObservation<T>> pollFuture(
    BigInt now,
    FutureOr<TimeoutOperation<T>> Function() operation,
    FutureOr<TimeoutCancellation> Function() cancellation,
  ) async {
    final immediate = _beforeAdapters(now);
    if (immediate != null) return immediate;
    // Invoke both before awaiting either, preserving the sync adapter's
    // exactly-once contract and result precedence.
    final operationResult = Future<TimeoutOperation<T>>.sync(operation);
    final cancellationResult = Future<TimeoutCancellation>.sync(cancellation);
    return _settle(
      await operationResult,
      await cancellationResult,
    );
  }

  TimeoutObservation<T> _latch(TimeoutObservation<T> observation) {
    _terminal = observation;
    return observation;
  }
}

/// An externally observable [RevisionBarrier] state.
class RevisionBarrierObservation {
  const RevisionBarrierObservation({
    required this.outcome,
    required this.revision,
    required this.generation,
    this.reason,
  });

  final String outcome;
  final BigInt revision;
  final BigInt generation;
  final String? reason;

  Map<String, Object> toJson() => {
        'outcome': outcome,
        'revision': jsonSafeUint64(revision),
        'generation': jsonSafeUint64(generation),
        if (reason case final reason?) 'reason': reason,
      };
}

/// A revision barrier with separate authoritative revision and wake generation.
class RevisionBarrier {
  RevisionBarrier({
    required BigInt revision,
    required this.requiredRevision,
    this.deadline,
  }) : _revision = _uint64(revision, 'revision') {
    _uint64(requiredRevision, 'requiredRevision');
    if (deadline case final deadline?) _uint64(deadline, 'deadline');
  }

  BigInt _revision;
  final BigInt requiredRevision;
  final BigInt? deadline;
  BigInt _generation = BigInt.zero;
  BigInt? _lastNow;
  String? _terminal;
  String? _terminalReason;

  RevisionBarrierObservation get initial => _snapshot();

  RevisionBarrierObservation? _beforeCancellation(
    BigInt now,
    bool predicate,
  ) {
    _uint64(now, 'now');
    if (_terminal != null) return _snapshot();
    final clockFailure = _acceptNow(now);
    if (clockFailure != null) return clockFailure;
    if (deadline case final deadline? when now >= deadline) {
      return _latch('timed_out');
    }
    if (predicate && _revision >= requiredRevision) {
      return _latch('satisfied');
    }
    return null;
  }

  /// Observe deadline, predicate, and cancellation in that order.
  RevisionBarrierObservation observe(
    BigInt now,
    bool predicate,
    TimeoutCancellation Function() cancellation,
  ) {
    final immediate = _beforeCancellation(now, predicate);
    if (immediate != null) return immediate;
    final cancellationValue = cancellation();
    return _settleCancellation(cancellationValue);
  }

  /// Future adapter for a caller-owned cancellation seam.
  Future<RevisionBarrierObservation> observeFuture(
    BigInt now,
    bool predicate,
    FutureOr<TimeoutCancellation> Function() cancellation,
  ) async {
    final immediate = _beforeCancellation(now, predicate);
    if (immediate != null) return immediate;
    final cancellationValue = await cancellation();
    return _settleCancellation(cancellationValue);
  }

  RevisionBarrierObservation _settleCancellation(
    TimeoutCancellation cancellation,
  ) {
    // A caller-owned callback may synchronously reenter, or an awaited Future
    // may let another task settle the barrier. That earlier terminal result
    // owns the latch.
    if (_terminal != null) return _snapshot();
    switch (cancellation) {
      case TimeoutCancellation.cancelled:
        return _latch('cancelled');
      case TimeoutCancellation.unavailable:
        return _latch('unavailable', 'cancellation_unavailable');
      case TimeoutCancellation.pending:
        return _snapshot();
    }
  }

  /// Model register-then-recheck by accepting an observed revision before the
  /// post-registration predicate test.
  RevisionBarrierObservation registerRecheck(
    BigInt now,
    BigInt observedRevision,
    bool predicate,
  ) {
    _uint64(now, 'now');
    _uint64(observedRevision, 'observedRevision');
    if (_terminal != null) return _snapshot();
    final clockFailure = _acceptNow(now);
    if (clockFailure != null) return clockFailure;
    if (deadline case final deadline? when now >= deadline) {
      return _latch('timed_out');
    }
    _acceptRevision(observedRevision);
    if (predicate && _revision >= requiredRevision) {
      return _latch('satisfied');
    }
    return _snapshot();
  }

  /// Accept a newer authoritative revision and increment generation once.
  RevisionBarrierObservation advance(BigInt revision, bool predicate) {
    _uint64(revision, 'revision');
    if (_terminal != null) return _snapshot();
    _acceptRevision(revision);
    if (predicate && _revision >= requiredRevision) {
      return _latch('satisfied');
    }
    return _snapshot();
  }

  RevisionBarrierObservation dispose() =>
      _terminal == null ? _latch('disposed') : _snapshot();

  /// A receipt may wake transport work, but is never revision authority.
  RevisionBarrierObservation receipt(String _) => _snapshot();

  void _acceptRevision(BigInt revision) {
    if (revision > _revision) {
      _revision = revision;
      _generation += BigInt.one;
    }
  }

  RevisionBarrierObservation? _acceptNow(BigInt now) {
    final lastNow = _lastNow;
    if (lastNow != null && now < lastNow) {
      return _latch('unavailable', 'clock_regression');
    }
    _lastNow = now;
    return null;
  }

  RevisionBarrierObservation _latch(String outcome, [String? reason]) {
    _terminal = outcome;
    _terminalReason = reason;
    return _snapshot();
  }

  RevisionBarrierObservation _snapshot() => RevisionBarrierObservation(
        outcome: _terminal ?? 'pending',
        revision: _revision,
        generation: _generation,
        reason: _terminalReason,
      );
}
