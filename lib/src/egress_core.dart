/// Transport-agnostic reactive egress core (`#lzegress`).
///
/// Spec: `lazily-spec/docs/transport-egress.md`.
/// Rust reference: `lazily-rs/src/egress_core.rs`.
///
/// The core owns delivery authority: monotone sequence assignment, the pending
/// queue and bounded unacknowledged window, the monotone cumulative
/// acknowledgement watermark, bounded retry/backoff/exhaustion, and the
/// producer-generation fence. It owns no graph handles and performs no I/O, so
/// the single-threaded, thread-safe, and async shells share it unchanged.
/// `RelayCell`/`Outbox` remain the conflation and backpressure layer ahead of
/// enqueue; durable recovery and framing stay outside the core.
///
/// Every transition returns an [EgressChange] naming exactly the reader kinds it
/// dirtied. No-op and stale-generation transitions return an empty change, so a
/// shell invalidates nothing for them.
library;

/// Egress policy. [retryBudget] counts retries after the first send attempt.
final class EgressPolicy {
  const EgressPolicy({
    this.inflightLimit = 64,
    this.retryBudget = 3,
    this.retryBase = 10,
    this.retryCeiling = 1000,
  });

  /// Maximum number of claimed-but-unacknowledged envelopes.
  final int inflightLimit;

  /// Retries permitted after the first attempt.
  final int retryBudget;

  /// Backoff of the first retry.
  final int retryBase;

  /// Upper bound of the exponential backoff.
  final int retryCeiling;

  @override
  bool operator ==(Object other) =>
      other is EgressPolicy &&
      other.inflightLimit == inflightLimit &&
      other.retryBudget == retryBudget &&
      other.retryBase == retryBase &&
      other.retryCeiling == retryCeiling;

  @override
  int get hashCode =>
      Object.hash(inflightLimit, retryBudget, retryBase, retryCeiling);

  @override
  String toString() => 'EgressPolicy(inflightLimit: $inflightLimit, '
      'retryBudget: $retryBudget, retryBase: $retryBase, '
      'retryCeiling: $retryCeiling)';
}

/// Why an [EgressPolicy] cannot back an [EgressCore].
enum EgressConfigError {
  zeroInflightLimit,
  zeroRetryBase,
  retryCeilingBelowBase,
  negativeRetryBudget,
}

/// Thrown by [EgressCore.new] for a policy no core can honour.
final class EgressConfigException implements Exception {
  const EgressConfigException(this.error);

  final EgressConfigError error;

  @override
  String toString() => 'EgressConfigException(${error.name})';
}

/// One send attempt. `(generation, sequence)` is the transport idempotency
/// identity.
final class EgressEnvelope<T> {
  const EgressEnvelope({
    required this.generation,
    required this.sequence,
    required this.attempt,
    required this.payload,
  });

  final int generation;
  final int sequence;
  final int attempt;
  final T payload;

  @override
  bool operator ==(Object other) =>
      other is EgressEnvelope<T> &&
      other.generation == generation &&
      other.sequence == sequence &&
      other.attempt == attempt &&
      other.payload == payload;

  @override
  int get hashCode => Object.hash(generation, sequence, attempt, payload);

  @override
  String toString() => 'EgressEnvelope(generation: $generation, '
      'sequence: $sequence, attempt: $attempt, payload: $payload)';
}

/// The most recent failure's retry decision.
final class EgressRetry {
  const EgressRetry({
    required this.sequence,
    required this.attempt,
    required this.backoff,
    required this.exhausted,
  });

  final int sequence;
  final int attempt;
  final int backoff;
  final bool exhausted;

  @override
  bool operator ==(Object other) =>
      other is EgressRetry &&
      other.sequence == sequence &&
      other.attempt == attempt &&
      other.backoff == backoff &&
      other.exhausted == exhausted;

  @override
  int get hashCode => Object.hash(sequence, attempt, backoff, exhausted);

  @override
  String toString() => 'EgressRetry(sequence: $sequence, attempt: $attempt, '
      'backoff: $backoff, exhausted: $exhausted)';
}

/// Outcome of [EgressCore.claim].
sealed class EgressClaim<T> {
  const EgressClaim();
}

/// One pending envelope moved into the unacknowledged window.
final class EgressClaimed<T> extends EgressClaim<T> {
  const EgressClaimed(this.envelope);
  final EgressEnvelope<T> envelope;

  @override
  bool operator ==(Object other) =>
      other is EgressClaimed<T> && other.envelope == envelope;
  @override
  int get hashCode => envelope.hashCode;
  @override
  String toString() => 'EgressClaimed($envelope)';
}

/// Nothing pending.
final class EgressClaimEmpty<T> extends EgressClaim<T> {
  const EgressClaimEmpty();
  @override
  bool operator ==(Object other) => other is EgressClaimEmpty;
  @override
  int get hashCode => 1;
  @override
  String toString() => 'EgressClaimEmpty()';
}

/// The unacknowledged window is at `inflightLimit`.
final class EgressClaimWindowFull<T> extends EgressClaim<T> {
  const EgressClaimWindowFull();
  @override
  bool operator ==(Object other) => other is EgressClaimWindowFull;
  @override
  int get hashCode => 2;
  @override
  String toString() => 'EgressClaimWindowFull()';
}

/// The claiming attachment belongs to a superseded incarnation.
final class EgressClaimStaleGeneration<T> extends EgressClaim<T> {
  const EgressClaimStaleGeneration(this.current);
  final int current;
  @override
  bool operator ==(Object other) =>
      other is EgressClaimStaleGeneration && other.current == current;
  @override
  int get hashCode => Object.hash(3, current);
  @override
  String toString() => 'EgressClaimStaleGeneration($current)';
}

/// Outcome of [EgressCore.ack].
sealed class EgressAck {
  const EgressAck();
}

/// The watermark advanced to [through].
final class EgressAckAdvanced extends EgressAck {
  const EgressAckAdvanced(this.through);
  final int through;
  @override
  bool operator ==(Object other) =>
      other is EgressAckAdvanced && other.through == through;
  @override
  int get hashCode => Object.hash(1, through);
  @override
  String toString() => 'EgressAckAdvanced($through)';
}

/// The acknowledgement did not move the watermark.
final class EgressAckUnchanged extends EgressAck {
  const EgressAckUnchanged(this.through);
  final int? through;
  @override
  bool operator ==(Object other) =>
      other is EgressAckUnchanged && other.through == through;
  @override
  int get hashCode => Object.hash(2, through);
  @override
  String toString() => 'EgressAckUnchanged($through)';
}

/// The acknowledgement names a sequence this producer never assigned
/// (`through >= nextSequence`). Refused: it changes nothing and invalidates
/// nothing, so a bogus ACK cannot lift the watermark over the next sequence and
/// strand the record enqueued there.
final class EgressAckBeyondSent extends EgressAck {
  const EgressAckBeyondSent(this.nextSequence);
  final int nextSequence;
  @override
  bool operator ==(Object other) =>
      other is EgressAckBeyondSent && other.nextSequence == nextSequence;
  @override
  int get hashCode => Object.hash(4, nextSequence);
  @override
  String toString() => 'EgressAckBeyondSent($nextSequence)';
}

/// The acknowledging attachment belongs to a superseded incarnation.
final class EgressAckStaleGeneration extends EgressAck {
  const EgressAckStaleGeneration(this.current);
  final int current;
  @override
  bool operator ==(Object other) =>
      other is EgressAckStaleGeneration && other.current == current;
  @override
  int get hashCode => Object.hash(3, current);
  @override
  String toString() => 'EgressAckStaleGeneration($current)';
}

/// Outcome of [EgressCore.fail].
sealed class EgressFailure {
  const EgressFailure();
}

/// The failed record is parked; it may be rescheduled with
/// [EgressCore.retryNow].
final class EgressFailureRetrying extends EgressFailure {
  const EgressFailureRetrying(this.retry);
  final EgressRetry retry;
  @override
  bool operator ==(Object other) =>
      other is EgressFailureRetrying && other.retry == retry;
  @override
  int get hashCode => Object.hash(1, retry);
  @override
  String toString() => 'EgressFailureRetrying($retry)';
}

/// The retry budget is spent; the record is terminal.
final class EgressFailureExhausted extends EgressFailure {
  const EgressFailureExhausted(this.retry);
  final EgressRetry retry;
  @override
  bool operator ==(Object other) =>
      other is EgressFailureExhausted && other.retry == retry;
  @override
  int get hashCode => Object.hash(2, retry);
  @override
  String toString() => 'EgressFailureExhausted($retry)';
}

/// No in-flight record carries that sequence.
final class EgressFailureUnknownSequence extends EgressFailure {
  const EgressFailureUnknownSequence();
  @override
  bool operator ==(Object other) => other is EgressFailureUnknownSequence;
  @override
  int get hashCode => 3;
  @override
  String toString() => 'EgressFailureUnknownSequence()';
}

/// The failing attachment belongs to a superseded incarnation.
final class EgressFailureStaleGeneration extends EgressFailure {
  const EgressFailureStaleGeneration(this.current);
  final int current;
  @override
  bool operator ==(Object other) =>
      other is EgressFailureStaleGeneration && other.current == current;
  @override
  int get hashCode => Object.hash(4, current);
  @override
  String toString() => 'EgressFailureStaleGeneration($current)';
}

/// Outcome of [EgressCore.retryNow].
sealed class EgressRetryAction {
  const EgressRetryAction();
}

/// The parked record is back in pending, in sequence order.
final class EgressRetryScheduled extends EgressRetryAction {
  const EgressRetryScheduled(this.sequence);
  final int sequence;
  @override
  bool operator ==(Object other) =>
      other is EgressRetryScheduled && other.sequence == sequence;
  @override
  int get hashCode => Object.hash(1, sequence);
  @override
  String toString() => 'EgressRetryScheduled($sequence)';
}

/// No parked record carries that sequence (including an exhausted one).
final class EgressRetryUnknownSequence extends EgressRetryAction {
  const EgressRetryUnknownSequence();
  @override
  bool operator ==(Object other) => other is EgressRetryUnknownSequence;
  @override
  int get hashCode => 2;
  @override
  String toString() => 'EgressRetryUnknownSequence()';
}

/// The scheduling attachment belongs to a superseded incarnation.
final class EgressRetryStaleGeneration extends EgressRetryAction {
  const EgressRetryStaleGeneration(this.current);
  final int current;
  @override
  bool operator ==(Object other) =>
      other is EgressRetryStaleGeneration && other.current == current;
  @override
  int get hashCode => Object.hash(3, current);
  @override
  String toString() => 'EgressRetryStaleGeneration($current)';
}

/// Outcome of [EgressCore.reconnect].
sealed class EgressReconnect {
  const EgressReconnect();
}

/// The generation advanced; [replayed] unacknowledged records returned to
/// pending under it.
final class EgressReconnectAdvanced extends EgressReconnect {
  const EgressReconnectAdvanced(this.generation, this.replayed);
  final int generation;
  final int replayed;
  @override
  bool operator ==(Object other) =>
      other is EgressReconnectAdvanced &&
      other.generation == generation &&
      other.replayed == replayed;
  @override
  int get hashCode => Object.hash(1, generation, replayed);
  @override
  String toString() => 'EgressReconnectAdvanced($generation, $replayed)';
}

/// The requested generation is already current.
final class EgressReconnectUnchanged extends EgressReconnect {
  const EgressReconnectUnchanged(this.generation);
  final int generation;
  @override
  bool operator ==(Object other) =>
      other is EgressReconnectUnchanged && other.generation == generation;
  @override
  int get hashCode => Object.hash(2, generation);
  @override
  String toString() => 'EgressReconnectUnchanged($generation)';
}

/// The requested generation is older than the current one.
final class EgressReconnectStaleGeneration extends EgressReconnect {
  const EgressReconnectStaleGeneration(this.current);
  final int current;
  @override
  bool operator ==(Object other) =>
      other is EgressReconnectStaleGeneration && other.current == current;
  @override
  int get hashCode => Object.hash(3, current);
  @override
  String toString() => 'EgressReconnectStaleGeneration($current)';
}

/// Reader-kind invalidations emitted by one transition.
final class EgressChange {
  const EgressChange({
    this.pending = false,
    this.inflight = false,
    this.ackedThrough = false,
    this.retry = false,
  });

  static const none = EgressChange();

  final bool pending;
  final bool inflight;
  final bool ackedThrough;
  final bool retry;

  bool get isEmpty => !pending && !inflight && !ackedThrough && !retry;

  @override
  bool operator ==(Object other) =>
      other is EgressChange &&
      other.pending == pending &&
      other.inflight == inflight &&
      other.ackedThrough == ackedThrough &&
      other.retry == retry;

  @override
  int get hashCode => Object.hash(pending, inflight, ackedThrough, retry);

  @override
  String toString() => 'EgressChange(pending: $pending, inflight: $inflight, '
      'ackedThrough: $ackedThrough, retry: $retry)';
}

final class _Record<T> {
  _Record(this.generation, this.sequence, this.attempt, this.payload);

  int generation;
  final int sequence;
  int attempt;
  final T payload;

  EgressEnvelope<T> envelope() => EgressEnvelope<T>(
        generation: generation,
        sequence: sequence,
        attempt: attempt,
        payload: payload,
      );
}

/// Pure egress delivery authority.
final class EgressCore<T> {
  /// Throws [EgressConfigException] for a policy no core can honour.
  EgressCore(int generation, [this.policy = const EgressPolicy()])
      : _generation = generation {
    if (policy.inflightLimit <= 0) {
      throw const EgressConfigException(EgressConfigError.zeroInflightLimit);
    }
    if (policy.retryBase <= 0) {
      throw const EgressConfigException(EgressConfigError.zeroRetryBase);
    }
    if (policy.retryCeiling < policy.retryBase) {
      throw const EgressConfigException(
          EgressConfigError.retryCeilingBelowBase);
    }
    if (policy.retryBudget < 0) {
      throw const EgressConfigException(EgressConfigError.negativeRetryBudget);
    }
  }

  /// The bounds in force.
  final EgressPolicy policy;

  int _generation;
  int _nextSequence = 0;
  int? _ackedThrough;
  final List<_Record<T>> _pending = [];
  // Keyed by sequence; iterated in ascending sequence order.
  final Map<int, _Record<T>> _inflight = {};
  final Map<int, _Record<T>> _failed = {};
  EgressRetry? _retry;

  /// The current producer generation.
  int get generation => _generation;

  /// The sequence the next enqueue will be assigned.
  int get nextSequence => _nextSequence;

  /// Pending envelopes, oldest sequence first.
  List<EgressEnvelope<T>> pending() =>
      List.unmodifiable(_pending.map((record) => record.envelope()));

  /// Claimed, unacknowledged envelopes, oldest sequence first.
  List<EgressEnvelope<T>> inflight() => List.unmodifiable(
        _sortedKeys(_inflight)
            .map((sequence) => _inflight[sequence]!.envelope()),
      );

  /// The cumulative acknowledgement watermark, or null before the first ACK.
  int? get ackedThrough => _ackedThrough;

  /// The most recent failure's retry decision.
  EgressRetry? get retry => _retry;

  /// Assign the next sequence and place [payload] in the pending projection.
  (EgressChange, int) enqueue(T payload) {
    final sequence = _nextSequence;
    _nextSequence += 1;
    _pending.add(_Record<T>(_generation, sequence, 0, payload));
    return (const EgressChange(pending: true), sequence);
  }

  /// Move the oldest pending value into the unacknowledged window.
  ///
  /// [generation] is the one captured by the caller's transport attachment; an
  /// attachment from a superseded incarnation cannot claim or replay.
  (EgressChange, EgressClaim<T>) claim(int generation) {
    if (generation != _generation) {
      return (EgressChange.none, EgressClaimStaleGeneration<T>(_generation));
    }
    if (_inflight.length >= policy.inflightLimit) {
      return (EgressChange.none, EgressClaimWindowFull<T>());
    }
    if (_pending.isEmpty) {
      return (EgressChange.none, EgressClaimEmpty<T>());
    }
    final record = _pending.removeAt(0);
    record.generation = _generation;
    record.attempt += 1;
    final envelope = record.envelope();
    _inflight[record.sequence] = record;
    final retryChanged = _retry?.sequence == envelope.sequence;
    if (retryChanged) _retry = null;
    return (
      EgressChange(pending: true, inflight: true, retry: retryChanged),
      EgressClaimed<T>(envelope),
    );
  }

  /// Advance the cumulative watermark and prune acknowledged records. An ACK
  /// at or beyond [nextSequence] is refused with [EgressAckBeyondSent].
  (EgressChange, EgressAck) ack(int generation, int through) {
    if (generation != _generation) {
      return (EgressChange.none, EgressAckStaleGeneration(_generation));
    }
    if (through >= _nextSequence) {
      return (EgressChange.none, EgressAckBeyondSent(_nextSequence));
    }
    final current = _ackedThrough;
    if (current != null && through <= current) {
      return (EgressChange.none, EgressAckUnchanged(current));
    }
    final inflightBefore = _inflight.length;
    final pendingBefore = _pending.length;
    _ackedThrough = through;
    _inflight.removeWhere((sequence, _) => sequence <= through);
    _failed.removeWhere((sequence, _) => sequence <= through);
    _pending.removeWhere((record) => record.sequence <= through);
    final retry = _retry;
    final retryChanged = retry != null && retry.sequence <= through;
    if (retryChanged) _retry = null;
    return (
      EgressChange(
        pending: _pending.length != pendingBefore,
        inflight: _inflight.length != inflightBefore,
        ackedThrough: true,
        retry: retryChanged,
      ),
      EgressAckAdvanced(through),
    );
  }

  /// Park a failed in-flight record while budget remains; past the budget it is
  /// terminal.
  (EgressChange, EgressFailure) fail(int generation, int sequence) {
    if (generation != _generation) {
      return (EgressChange.none, EgressFailureStaleGeneration(_generation));
    }
    final record = _inflight.remove(sequence);
    if (record == null) {
      return (EgressChange.none, const EgressFailureUnknownSequence());
    }
    final exhausted = record.attempt > policy.retryBudget;
    final retry = EgressRetry(
      sequence: sequence,
      attempt: record.attempt,
      backoff: _backoff(record.attempt),
      exhausted: exhausted,
    );
    _retry = retry;
    if (!exhausted) _failed[sequence] = record;
    return (
      const EgressChange(inflight: true, retry: true),
      exhausted ? EgressFailureExhausted(retry) : EgressFailureRetrying(retry),
    );
  }

  /// Return a parked failed record to pending, in sequence order, once its
  /// derived backoff has elapsed. Parking is explicit so a failed send cannot
  /// make the attachment Effect spin.
  (EgressChange, EgressRetryAction) retryNow(int generation, int sequence) {
    if (generation != _generation) {
      return (EgressChange.none, EgressRetryStaleGeneration(_generation));
    }
    final record = _failed.remove(sequence);
    if (record == null) {
      return (EgressChange.none, const EgressRetryUnknownSequence());
    }
    _insertPendingOrdered(record);
    final retryChanged = _retry?.sequence == sequence;
    if (retryChanged) _retry = null;
    return (
      EgressChange(pending: true, retry: retryChanged),
      EgressRetryScheduled(sequence),
    );
  }

  /// Fence the previous attachment and replay every unacknowledged in-flight or
  /// parked record through [generation]. The watermark and the sequence space
  /// survive; only the producer incarnation changes.
  (EgressChange, EgressReconnect) reconnect(int generation) {
    if (generation < _generation) {
      return (EgressChange.none, EgressReconnectStaleGeneration(_generation));
    }
    if (generation == _generation) {
      return (EgressChange.none, EgressReconnectUnchanged(_generation));
    }
    _generation = generation;
    final replayed = _inflight.length + _failed.length;
    for (final sequence in _sortedKeys(_inflight)) {
      _insertPendingOrdered(_inflight[sequence]!..generation = generation);
    }
    _inflight.clear();
    for (final sequence in _sortedKeys(_failed)) {
      _insertPendingOrdered(_failed[sequence]!..generation = generation);
    }
    _failed.clear();
    for (final record in _pending) {
      record.generation = generation;
    }
    final retryChanged = _retry != null;
    _retry = null;
    // Every retained envelope was just rewritten to the new generation, so the
    // pending projection changed even when nothing was replayed into it.
    return (
      EgressChange(
        pending: replayed > 0 || _pending.isNotEmpty,
        inflight: replayed > 0,
        retry: retryChanged,
      ),
      EgressReconnectAdvanced(generation, replayed),
    );
  }

  void _insertPendingOrdered(_Record<T> record) {
    var position =
        _pending.indexWhere((existing) => existing.sequence > record.sequence);
    if (position < 0) position = _pending.length;
    _pending.insert(position, record);
  }

  /// `min(retryCeiling, retryBase * 2^(attempt - 1))`, saturating.
  ///
  /// Doubles by repeated multiplication rather than `1 << n`: a shift is 32-bit
  /// under dart2js, and the loop stops at the ceiling, so it never overflows
  /// on either platform.
  int _backoff(int attempt) {
    var value = policy.retryBase;
    for (var i = 1; i < attempt && value < policy.retryCeiling; i++) {
      value *= 2;
    }
    return value < policy.retryCeiling ? value : policy.retryCeiling;
  }

  static List<int> _sortedKeys(Map<int, Object?> map) =>
      map.keys.toList()..sort();
}
