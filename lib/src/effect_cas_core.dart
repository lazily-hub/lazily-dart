/// Generic keyed compare-and-swap effect authority (`#lzeffectcas`).
///
/// Spec: `lazily-spec/docs/durable-sinks.md` § Generic effect compare-and-swap.
/// Rust reference: `lazily-rs/src/effect_cas_core.rs`.
///
/// The pure core owns stable effect identity, keyed single-flight, latest-wins
/// coalescing, logical-clock retry timing, reconnect fencing, exact receipt
/// matching, and the cursor of an ordered effect plan. Backends stay
/// application-owned: an adapter observes an opaque authority token and executes
/// one atomic compare-and-apply ([CompareAndApply]); it never retries, chooses a
/// newer intent, clears retained work, or advances a frontier.
///
/// Type parameters: `K` key, `A` opaque authority token, `P` plan-step payload,
/// `R` receipt, `E` adapter error. The core owns no thread, executor, timer, or
/// I/O.
library;

import 'dart:collection';

// ---------------------------------------------------------------------------
// Identity, intents, attempts, receipts
// ---------------------------------------------------------------------------

/// Stable, non-empty effect identity. A crash MUST NOT mint a new identity for
/// already-retained work.
final class EffectIdentity implements Comparable<EffectIdentity> {
  /// Throws [ArgumentError] for an empty identity.
  EffectIdentity(this.value) {
    if (value.isEmpty) {
      throw ArgumentError.value(value, 'value', 'empty effect identity');
    }
  }

  final String value;

  @override
  int compareTo(EffectIdentity other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) =>
      other is EffectIdentity && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// An ordered, non-empty sequence of idempotent effect payloads.
final class EffectPlan<P> {
  /// Throws [ArgumentError] for an empty plan.
  EffectPlan(Iterable<P> steps) : steps = List<P>.unmodifiable(steps) {
    if (this.steps.isEmpty) {
      throw ArgumentError.value(
          steps, 'steps', 'an effect plan must contain at least one step');
    }
  }

  /// A one-step plan.
  EffectPlan.single(P payload) : steps = List<P>.unmodifiable([payload]);

  final List<P> steps;

  int get length => steps.length;

  @override
  bool operator ==(Object other) =>
      other is EffectPlan<P> && _listEquals(other.steps, steps);

  @override
  int get hashCode => Object.hashAll(steps);

  @override
  String toString() => 'EffectPlan($steps)';
}

/// Immutable desired effect. One epoch names exactly one identity and plan.
final class EffectIntent<K, A, P> {
  const EffectIntent({
    required this.identity,
    required this.epoch,
    required this.key,
    required this.expected,
    required this.plan,
  });

  final EffectIdentity identity;
  final int epoch;
  final K key;

  /// The authority the first plan step must compare against.
  final A expected;
  final EffectPlan<P> plan;

  @override
  bool operator ==(Object other) =>
      other is EffectIntent<K, A, P> &&
      other.identity == identity &&
      other.epoch == epoch &&
      other.key == key &&
      other.expected == expected &&
      other.plan == plan;

  @override
  int get hashCode => Object.hash(identity, epoch, key, expected, plan);

  @override
  String toString() => 'EffectIntent($identity, epoch: $epoch, key: $key, '
      'expected: $expected, plan: $plan)';
}

/// Exact identity of one adapter call.
final class EffectAttemptIdentity {
  const EffectAttemptIdentity({
    required this.effect,
    required this.generation,
    required this.epoch,
    required this.step,
    required this.attempt,
  });

  final EffectIdentity effect;
  final int generation;
  final int epoch;
  final int step;
  final int attempt;

  @override
  bool operator ==(Object other) =>
      other is EffectAttemptIdentity &&
      other.effect == effect &&
      other.generation == generation &&
      other.epoch == epoch &&
      other.step == step &&
      other.attempt == attempt;

  @override
  int get hashCode => Object.hash(effect, generation, epoch, step, attempt);

  @override
  String toString() => 'EffectAttemptIdentity($effect, generation: '
      '$generation, epoch: $epoch, step: $step, attempt: $attempt)';
}

/// A successful step receipt retained as lineage for later plan steps.
final class EffectReceipt<R, A> {
  const EffectReceipt({
    required this.attempt,
    required this.receipt,
    required this.authority,
  });

  final EffectAttemptIdentity attempt;
  final R receipt;
  final A authority;

  @override
  bool operator ==(Object other) =>
      other is EffectReceipt<R, A> &&
      other.attempt == attempt &&
      other.receipt == receipt &&
      other.authority == authority;

  @override
  int get hashCode => Object.hash(attempt, receipt, authority);

  @override
  String toString() => 'EffectReceipt($attempt, $receipt, $authority)';
}

/// The exact compare-and-apply call handed to an application adapter.
final class EffectAttempt<K, A, P, R> {
  EffectAttempt({
    required this.identity,
    required this.key,
    required this.expected,
    required this.payload,
    required List<EffectReceipt<R, A>> priorReceipts,
  }) : priorReceipts = List.unmodifiable(priorReceipts);

  final EffectAttemptIdentity identity;
  final K key;
  final A expected;
  final P payload;
  final List<EffectReceipt<R, A>> priorReceipts;

  @override
  bool operator ==(Object other) =>
      other is EffectAttempt<K, A, P, R> &&
      other.identity == identity &&
      other.key == key &&
      other.expected == expected &&
      other.payload == payload &&
      _listEquals(other.priorReceipts, priorReceipts);

  @override
  int get hashCode => Object.hash(
      identity, key, expected, payload, Object.hashAll(priorReceipts));

  @override
  String toString() => 'EffectAttempt($identity, key: $key, '
      'expected: $expected, payload: $payload)';
}

/// The only outcomes an application adapter may return.
sealed class EffectApply<R, A, E> {
  const EffectApply();
}

final class EffectApplied<R, A, E> extends EffectApply<R, A, E> {
  const EffectApplied(this.receipt, this.authority);
  final R receipt;
  final A authority;
}

final class EffectApplySuperseded<R, A, E> extends EffectApply<R, A, E> {
  const EffectApplySuperseded(this.observed);
  final A observed;
}

final class EffectApplyRetryable<R, A, E> extends EffectApply<R, A, E> {
  const EffectApplyRetryable(this.error);
  final E error;
}

final class EffectApplyRejected<R, A, E> extends EffectApply<R, A, E> {
  const EffectApplyRejected(this.error);
  final E error;
}

/// Narrow application-owned atomic authority boundary.
abstract interface class CompareAndApply<K, A, P, R, E> {
  /// Side-effect-free read of the backend's opaque authority.
  A observe(K key);

  /// One atomic compare-and-apply. A failed comparison returns
  /// [EffectApplySuperseded] with zero backend mutation.
  EffectApply<R, A, E> compareAndApply(EffectAttempt<K, A, P, R> attempt);
}

// ---------------------------------------------------------------------------
// Retained state and projections
// ---------------------------------------------------------------------------

/// Retained work for one key: the intent, its plan cursor, the authority the
/// next step compares against, completed-step receipts, and retry timing.
final class EffectPending<K, A, P, R> {
  EffectPending({
    required this.intent,
    required this.nextStep,
    required this.expected,
    required List<EffectReceipt<R, A>> receipts,
    required this.nextAttempt,
    required this.readyAt,
  }) : receipts = List.unmodifiable(receipts);

  final EffectIntent<K, A, P> intent;
  final int nextStep;
  final A expected;
  final List<EffectReceipt<R, A>> receipts;
  final int nextAttempt;

  /// Logical time before which the work may not be claimed, if any.
  final int? readyAt;

  EffectPending<K, A, P, R> _copyWith({
    int? nextStep,
    A Function()? expected,
    List<EffectReceipt<R, A>>? receipts,
    int? nextAttempt,
    int? Function()? readyAt,
  }) =>
      EffectPending<K, A, P, R>(
        intent: intent,
        nextStep: nextStep ?? this.nextStep,
        expected: expected == null ? this.expected : expected(),
        receipts: receipts ?? this.receipts,
        nextAttempt: nextAttempt ?? this.nextAttempt,
        readyAt: readyAt == null ? this.readyAt : readyAt(),
      );

  @override
  bool operator ==(Object other) =>
      other is EffectPending<K, A, P, R> &&
      other.intent == intent &&
      other.nextStep == nextStep &&
      other.expected == expected &&
      _listEquals(other.receipts, receipts) &&
      other.nextAttempt == nextAttempt &&
      other.readyAt == readyAt;

  @override
  int get hashCode => Object.hash(intent, nextStep, expected,
      Object.hashAll(receipts), nextAttempt, readyAt);
}

/// Retry evidence for the most recent retryable failure.
final class EffectRetry<E> {
  const EffectRetry({
    required this.attempt,
    required this.error,
    required this.retryAt,
  });

  final EffectAttemptIdentity attempt;
  final E error;
  final int retryAt;

  @override
  bool operator ==(Object other) =>
      other is EffectRetry<E> &&
      other.attempt == attempt &&
      other.error == error &&
      other.retryAt == retryAt;

  @override
  int get hashCode => Object.hash(attempt, error, retryAt);
}

/// The kind of a terminal receipt.
enum EffectTerminalKind {
  applied('applied'),
  superseded('superseded'),
  rejected('rejected');

  const EffectTerminalKind(this.wireName);
  final String wireName;
}

/// The most recent terminal outcome of one key.
final class EffectTerminal<R, A, E> {
  EffectTerminal._({
    required this.kind,
    required this.identity,
    required this.epoch,
    required List<EffectReceipt<R, A>> receipts,
    this.observed,
    this.error,
  }) : receipts = List.unmodifiable(receipts);

  factory EffectTerminal.applied(EffectIdentity identity, int epoch,
          List<EffectReceipt<R, A>> receipts) =>
      EffectTerminal._(
        kind: EffectTerminalKind.applied,
        identity: identity,
        epoch: epoch,
        receipts: receipts,
      );

  factory EffectTerminal.superseded(EffectIdentity identity, int epoch,
          A? observed, List<EffectReceipt<R, A>> receipts) =>
      EffectTerminal._(
        kind: EffectTerminalKind.superseded,
        identity: identity,
        epoch: epoch,
        observed: observed,
        receipts: receipts,
      );

  factory EffectTerminal.rejected(EffectIdentity identity, int epoch, E error,
          List<EffectReceipt<R, A>> receipts) =>
      EffectTerminal._(
        kind: EffectTerminalKind.rejected,
        identity: identity,
        epoch: epoch,
        error: error,
        receipts: receipts,
      );

  final EffectTerminalKind kind;
  final EffectIdentity identity;
  final int epoch;
  final List<EffectReceipt<R, A>> receipts;

  /// The authority observed at supersession, when the adapter reported one.
  final A? observed;

  /// The rejection error ([EffectTerminalKind.rejected] only).
  final E? error;

  @override
  bool operator ==(Object other) =>
      other is EffectTerminal<R, A, E> &&
      other.kind == kind &&
      other.identity == identity &&
      other.epoch == epoch &&
      other.observed == observed &&
      other.error == error &&
      _listEquals(other.receipts, receipts);

  @override
  int get hashCode => Object.hash(
      kind, identity, epoch, observed, error, Object.hashAll(receipts));

  @override
  String toString() =>
      'EffectTerminal(${kind.wireName}, $identity, epoch: $epoch, '
      'receipts: ${receipts.length})';
}

/// Reader projection of one key.
final class EffectCasKeyState<K, A, P, R, E> {
  const EffectCasKeyState({
    required this.pending,
    required this.inflight,
    required this.retry,
    required this.appliedThrough,
    required this.terminal,
  });

  final EffectPending<K, A, P, R>? pending;
  final EffectAttempt<K, A, P, R>? inflight;
  final EffectRetry<E>? retry;
  final int? appliedThrough;
  final EffectTerminal<R, A, E>? terminal;

  @override
  bool operator ==(Object other) =>
      other is EffectCasKeyState<K, A, P, R, E> &&
      other.pending == pending &&
      other.inflight == inflight &&
      other.retry == retry &&
      other.appliedThrough == appliedThrough &&
      other.terminal == terminal;

  @override
  int get hashCode =>
      Object.hash(pending, inflight, retry, appliedThrough, terminal);
}

/// Reader projection of the whole core.
final class EffectCasSnapshot<K, A, P, R, E> {
  EffectCasSnapshot(
      this.generation, Map<K, EffectCasKeyState<K, A, P, R, E>> keys)
      : keys = Map.unmodifiable(keys);

  final int generation;

  /// Per-key state, in key order.
  final Map<K, EffectCasKeyState<K, A, P, R, E>> keys;

  @override
  bool operator ==(Object other) {
    if (other is! EffectCasSnapshot<K, A, P, R, E> ||
        other.generation != generation ||
        other.keys.length != keys.length) {
      return false;
    }
    for (final MapEntry(:key, :value) in keys.entries) {
      if (other.keys[key] != value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
      generation, Object.hashAllUnordered(keys.entries.map((e) => e.value)));
}

// ---------------------------------------------------------------------------
// Outcomes
// ---------------------------------------------------------------------------

/// Outcome of [EffectCasCore.upsertDesired].
sealed class EffectCasUpsert {
  const EffectCasUpsert();
}

final class EffectCasUpsertAccepted extends EffectCasUpsert {
  const EffectCasUpsertAccepted();
  @override
  bool operator ==(Object other) => other is EffectCasUpsertAccepted;
  @override
  int get hashCode => 1;
}

final class EffectCasUpsertUnchanged extends EffectCasUpsert {
  const EffectCasUpsertUnchanged();
  @override
  bool operator ==(Object other) => other is EffectCasUpsertUnchanged;
  @override
  int get hashCode => 2;
}

final class EffectCasUpsertAlreadyApplied extends EffectCasUpsert {
  const EffectCasUpsertAlreadyApplied(this.appliedThrough);
  final int appliedThrough;
  @override
  bool operator ==(Object other) =>
      other is EffectCasUpsertAlreadyApplied &&
      other.appliedThrough == appliedThrough;
  @override
  int get hashCode => Object.hash(3, appliedThrough);
}

final class EffectCasUpsertStaleEpoch extends EffectCasUpsert {
  const EffectCasUpsertStaleEpoch(this.current);
  final int current;
  @override
  bool operator ==(Object other) =>
      other is EffectCasUpsertStaleEpoch && other.current == current;
  @override
  int get hashCode => Object.hash(4, current);
}

final class EffectCasUpsertEpochConflict extends EffectCasUpsert {
  const EffectCasUpsertEpochConflict();
  @override
  bool operator ==(Object other) => other is EffectCasUpsertEpochConflict;
  @override
  int get hashCode => 5;
}

/// Outcome of [EffectCasCore.claim].
sealed class EffectCasClaim<K, A, P, R> {
  const EffectCasClaim();
}

final class EffectCasClaimed<K, A, P, R> extends EffectCasClaim<K, A, P, R> {
  const EffectCasClaimed(this.attempt);
  final EffectAttempt<K, A, P, R> attempt;
  @override
  bool operator ==(Object other) =>
      other is EffectCasClaimed<K, A, P, R> && other.attempt == attempt;
  @override
  int get hashCode => attempt.hashCode;
}

final class EffectCasClaimEmpty<K, A, P, R> extends EffectCasClaim<K, A, P, R> {
  const EffectCasClaimEmpty();
  @override
  bool operator ==(Object other) => other is EffectCasClaimEmpty;
  @override
  int get hashCode => 1;
}

final class EffectCasClaimBusy<K, A, P, R> extends EffectCasClaim<K, A, P, R> {
  const EffectCasClaimBusy();
  @override
  bool operator ==(Object other) => other is EffectCasClaimBusy;
  @override
  int get hashCode => 2;
}

final class EffectCasClaimWaiting<K, A, P, R>
    extends EffectCasClaim<K, A, P, R> {
  const EffectCasClaimWaiting(this.retryAt);
  final int retryAt;
  @override
  bool operator ==(Object other) =>
      other is EffectCasClaimWaiting && other.retryAt == retryAt;
  @override
  int get hashCode => Object.hash(3, retryAt);
}

final class EffectCasClaimStaleGeneration<K, A, P, R>
    extends EffectCasClaim<K, A, P, R> {
  const EffectCasClaimStaleGeneration(this.current);
  final int current;
  @override
  bool operator ==(Object other) =>
      other is EffectCasClaimStaleGeneration && other.current == current;
  @override
  int get hashCode => Object.hash(4, current);
}

/// Outcome of [EffectCasCore.recordApplied].
sealed class EffectCasApplied {
  const EffectCasApplied();
}

final class EffectCasStepApplied extends EffectCasApplied {
  const EffectCasStepApplied(this.nextStep);
  final int nextStep;
  @override
  bool operator ==(Object other) =>
      other is EffectCasStepApplied && other.nextStep == nextStep;
  @override
  int get hashCode => Object.hash(1, nextStep);
}

final class EffectCasCompleted extends EffectCasApplied {
  const EffectCasCompleted(this.appliedThrough);
  final int appliedThrough;
  @override
  bool operator ==(Object other) =>
      other is EffectCasCompleted && other.appliedThrough == appliedThrough;
  @override
  int get hashCode => Object.hash(2, appliedThrough);
}

final class EffectCasAppliedSuperseded extends EffectCasApplied {
  const EffectCasAppliedSuperseded();
  @override
  bool operator ==(Object other) => other is EffectCasAppliedSuperseded;
  @override
  int get hashCode => 3;
}

final class EffectCasAppliedDuplicate extends EffectCasApplied {
  const EffectCasAppliedDuplicate();
  @override
  bool operator ==(Object other) => other is EffectCasAppliedDuplicate;
  @override
  int get hashCode => 4;
}

final class EffectCasAppliedUnknownAttempt extends EffectCasApplied {
  const EffectCasAppliedUnknownAttempt();
  @override
  bool operator ==(Object other) => other is EffectCasAppliedUnknownAttempt;
  @override
  int get hashCode => 5;
}

final class EffectCasAppliedStaleGeneration extends EffectCasApplied {
  const EffectCasAppliedStaleGeneration(this.current);
  final int current;
  @override
  bool operator ==(Object other) =>
      other is EffectCasAppliedStaleGeneration && other.current == current;
  @override
  int get hashCode => Object.hash(6, current);
}

/// Outcome of [EffectCasCore.recordSuperseded], [EffectCasCore.recordRetryable]
/// and [EffectCasCore.recordRejected].
sealed class EffectCasFailure {
  const EffectCasFailure();
}

final class EffectCasFailureSuperseded extends EffectCasFailure {
  const EffectCasFailureSuperseded();
  @override
  bool operator ==(Object other) => other is EffectCasFailureSuperseded;
  @override
  int get hashCode => 1;
}

final class EffectCasFailureRetrying extends EffectCasFailure {
  const EffectCasFailureRetrying(this.retryAt);
  final int retryAt;
  @override
  bool operator ==(Object other) =>
      other is EffectCasFailureRetrying && other.retryAt == retryAt;
  @override
  int get hashCode => Object.hash(2, retryAt);
}

final class EffectCasFailureRejected extends EffectCasFailure {
  const EffectCasFailureRejected();
  @override
  bool operator ==(Object other) => other is EffectCasFailureRejected;
  @override
  int get hashCode => 3;
}

final class EffectCasFailureUnknownAttempt extends EffectCasFailure {
  const EffectCasFailureUnknownAttempt();
  @override
  bool operator ==(Object other) => other is EffectCasFailureUnknownAttempt;
  @override
  int get hashCode => 4;
}

final class EffectCasFailureStaleGeneration extends EffectCasFailure {
  const EffectCasFailureStaleGeneration(this.current);
  final int current;
  @override
  bool operator ==(Object other) =>
      other is EffectCasFailureStaleGeneration && other.current == current;
  @override
  int get hashCode => Object.hash(5, current);
}

/// Outcome of [EffectCasCore.reconnect].
sealed class EffectCasReconnect {
  const EffectCasReconnect();
}

final class EffectCasReconnectAdvanced extends EffectCasReconnect {
  const EffectCasReconnectAdvanced(
      this.generation, this.requeued, this.superseded);
  final int generation;
  final int requeued;
  final int superseded;
  @override
  bool operator ==(Object other) =>
      other is EffectCasReconnectAdvanced &&
      other.generation == generation &&
      other.requeued == requeued &&
      other.superseded == superseded;
  @override
  int get hashCode => Object.hash(1, generation, requeued, superseded);
}

final class EffectCasReconnectUnchanged extends EffectCasReconnect {
  const EffectCasReconnectUnchanged(this.generation);
  final int generation;
  @override
  bool operator ==(Object other) =>
      other is EffectCasReconnectUnchanged && other.generation == generation;
  @override
  int get hashCode => Object.hash(2, generation);
}

final class EffectCasReconnectStaleGeneration extends EffectCasReconnect {
  const EffectCasReconnectStaleGeneration(this.current);
  final int current;
  @override
  bool operator ==(Object other) =>
      other is EffectCasReconnectStaleGeneration && other.current == current;
  @override
  int get hashCode => Object.hash(3, current);
}

/// Outcome of [EffectCasCore.recordOutcome].
sealed class EffectCasOutcome {
  const EffectCasOutcome();
}

final class EffectCasOutcomeApplied extends EffectCasOutcome {
  const EffectCasOutcomeApplied(this.applied);
  final EffectCasApplied applied;
  @override
  bool operator ==(Object other) =>
      other is EffectCasOutcomeApplied && other.applied == applied;
  @override
  int get hashCode => applied.hashCode;
}

final class EffectCasOutcomeFailure extends EffectCasOutcome {
  const EffectCasOutcomeFailure(this.failure);
  final EffectCasFailure failure;
  @override
  bool operator ==(Object other) =>
      other is EffectCasOutcomeFailure && other.failure == failure;
  @override
  int get hashCode => failure.hashCode;
}

/// Whether a transition changed the projected state.
final class EffectCasChange {
  const EffectCasChange({this.state = false});
  static const none = EffectCasChange();
  static const changed = EffectCasChange(state: true);
  final bool state;
}

// ---------------------------------------------------------------------------
// Durable image (`#lzeffectcasdurable`)
// ---------------------------------------------------------------------------

/// Durable image of an in-flight attempt and the retained work behind it.
final class EffectCasDurableInflight<K, A, P, R> {
  const EffectCasDurableInflight({
    required this.retained,
    required this.attempt,
  });

  final EffectPending<K, A, P, R> retained;
  final EffectAttempt<K, A, P, R> attempt;

  @override
  bool operator ==(Object other) =>
      other is EffectCasDurableInflight<K, A, P, R> &&
      other.retained == retained &&
      other.attempt == attempt;

  @override
  int get hashCode => Object.hash(retained, attempt);
}

/// Durable image of one key.
final class EffectCasDurableKey<K, A, P, R, E> {
  const EffectCasDurableKey({
    required this.key,
    this.pending,
    this.inflight,
    this.retry,
    this.appliedThrough,
    this.terminal,
    this.terminalIntent,
  });

  final K key;
  final EffectPending<K, A, P, R>? pending;
  final EffectCasDurableInflight<K, A, P, R>? inflight;
  final EffectRetry<E>? retry;
  final int? appliedThrough;
  final EffectTerminal<R, A, E>? terminal;
  final EffectIntent<K, A, P>? terminalIntent;

  @override
  bool operator ==(Object other) =>
      other is EffectCasDurableKey<K, A, P, R, E> &&
      other.key == key &&
      other.pending == pending &&
      other.inflight == inflight &&
      other.retry == retry &&
      other.appliedThrough == appliedThrough &&
      other.terminal == terminal &&
      other.terminalIntent == terminalIntent;

  @override
  int get hashCode => Object.hash(
      key, pending, inflight, retry, appliedThrough, terminal, terminalIntent);
}

/// Full-fidelity durable image of an [EffectCasCore].
///
/// [EffectCasSnapshot] is a reader projection: it omits the retained intent
/// behind an in-flight attempt and the last terminal intent, so it cannot
/// restore the core. This image carries every field the core needs to resume
/// after a crash or in another process. Keys are a list rather than a map so a
/// non-string key survives any serialization the application chooses.
final class EffectCasDurableState<K, A, P, R, E> {
  EffectCasDurableState(
      this.generation, List<EffectCasDurableKey<K, A, P, R, E>> keys)
      : keys = List.unmodifiable(keys);

  final int generation;
  final List<EffectCasDurableKey<K, A, P, R, E>> keys;

  @override
  bool operator ==(Object other) =>
      other is EffectCasDurableState<K, A, P, R, E> &&
      other.generation == generation &&
      _listEquals(other.keys, keys);

  @override
  int get hashCode => Object.hash(generation, Object.hashAll(keys));
}

/// Why a durable image cannot be hydrated. Hydration never repairs an image: a
/// corrupt image is refused so no adapter call runs on invented state.
enum EffectCasHydrateError {
  /// Two entries name the same key.
  duplicateKey,

  /// A retained or terminal intent belongs to a different key.
  keyMismatch,

  /// A plan cursor points past the end of its plan.
  cursorOutOfRange,

  /// An in-flight attempt does not describe its retained cursor.
  attemptMismatch,

  /// An in-flight attempt claims an actor generation newer than the image.
  futureGeneration,
}

/// Thrown by [EffectCasCore.hydrate].
final class EffectCasHydrateException implements Exception {
  const EffectCasHydrateException(this.error);
  final EffectCasHydrateError error;
  @override
  String toString() => 'EffectCasHydrateException(${error.name})';
}

// ---------------------------------------------------------------------------
// The core
// ---------------------------------------------------------------------------

final class _Inflight<K, A, P, R> {
  _Inflight(this.retained, this.attempt);
  final EffectPending<K, A, P, R> retained;
  final EffectAttempt<K, A, P, R> attempt;
}

final class _Entry<K, A, P, R, E> {
  EffectPending<K, A, P, R>? pending;
  _Inflight<K, A, P, R>? inflight;
  EffectRetry<E>? retry;
  int? appliedThrough;
  EffectTerminal<R, A, E>? terminal;
  EffectIntent<K, A, P>? terminalIntent;

  EffectCasKeyState<K, A, P, R, E> state() => EffectCasKeyState(
        pending: pending,
        inflight: inflight?.attempt,
        retry: retry,
        appliedThrough: appliedThrough,
        terminal: terminal,
      );
}

enum _FailureKind { superseded, retryable, rejected }

/// Pure keyed effect-CAS orchestration authority.
final class EffectCasCore<K, A, P, R, E> {
  /// [compare] orders keys for [snapshot] and [pendingKeys]; it defaults to the
  /// natural order of a [Comparable] key.
  EffectCasCore(int generation, {Comparator<K>? compare})
      : _generation = generation,
        _keys = SplayTreeMap<K, _Entry<K, A, P, R, E>>(compare);

  int _generation;
  final SplayTreeMap<K, _Entry<K, A, P, R, E>> _keys;

  /// The current actor generation.
  int get generation => _generation;

  /// Reader projection of every key.
  EffectCasSnapshot<K, A, P, R, E> snapshot() => EffectCasSnapshot(
        _generation,
        {
          for (final MapEntry(:key, :value) in _keys.entries) key: value.state()
        },
      );

  /// Reader projection of one key, or null for a key never upserted.
  EffectCasKeyState<K, A, P, R, E>? state(K key) => _keys[key]?.state();

  /// Keys whose retained work is claimable at logical time [now].
  List<K> pendingKeys(int now) => [
        for (final MapEntry(:key, :value) in _keys.entries)
          if (value.inflight == null &&
              value.pending != null &&
              (value.pending!.readyAt == null ||
                  value.pending!.readyAt! <= now))
            key,
      ];

  /// Accept only a strictly newer epoch. Replacing pending work records an
  /// explicit supersession and retains its completed-step receipts.
  (EffectCasChange, EffectCasUpsert) upsertDesired(
      EffectIntent<K, A, P> intent) {
    final entry = _keys.putIfAbsent(intent.key, _Entry.new);
    final appliedThrough = entry.appliedThrough;
    if (appliedThrough != null && intent.epoch <= appliedThrough) {
      return (
        EffectCasChange.none,
        EffectCasUpsertAlreadyApplied(appliedThrough)
      );
    }

    final pendingIntent = entry.pending?.intent;
    final inflightIntent = entry.inflight?.retained.intent;
    final epochs = <int>[
      if (pendingIntent != null) pendingIntent.epoch,
      if (inflightIntent != null) inflightIntent.epoch,
      if (entry.terminalIntent != null) entry.terminalIntent!.epoch,
    ];
    if (epochs.isNotEmpty) {
      final current = epochs.reduce((a, b) => a > b ? a : b);
      if (intent.epoch < current) {
        return (EffectCasChange.none, EffectCasUpsertStaleEpoch(current));
      }
      if (intent.epoch == current) {
        final same = pendingIntent == intent ||
            inflightIntent == intent ||
            entry.terminalIntent == intent;
        return (
          EffectCasChange.none,
          same
              ? const EffectCasUpsertUnchanged()
              : const EffectCasUpsertEpochConflict(),
        );
      }
    }

    final superseded = entry.pending;
    if (superseded != null) {
      entry.terminalIntent = superseded.intent;
      entry.terminal = EffectTerminal.superseded(superseded.intent.identity,
          superseded.intent.epoch, null, superseded.receipts);
    }
    entry.pending = EffectPending<K, A, P, R>(
      intent: intent,
      nextStep: 0,
      expected: intent.expected,
      receipts: const [],
      nextAttempt: 1,
      readyAt: null,
    );
    entry.retry = null;
    return (EffectCasChange.changed, const EffectCasUpsertAccepted());
  }

  /// With the current generation and an eligible logical clock, move pending
  /// work into the key's sole in-flight slot.
  (EffectCasChange, EffectCasClaim<K, A, P, R>) claim(
      K key, int generation, int now) {
    if (generation != _generation) {
      return (
        EffectCasChange.none,
        EffectCasClaimStaleGeneration<K, A, P, R>(_generation)
      );
    }
    final entry = _keys[key];
    if (entry == null) {
      return (EffectCasChange.none, EffectCasClaimEmpty<K, A, P, R>());
    }
    if (entry.inflight != null) {
      return (EffectCasChange.none, EffectCasClaimBusy<K, A, P, R>());
    }
    final pending = entry.pending;
    if (pending == null) {
      return (EffectCasChange.none, EffectCasClaimEmpty<K, A, P, R>());
    }
    final readyAt = pending.readyAt;
    if (readyAt != null && now < readyAt) {
      return (EffectCasChange.none, EffectCasClaimWaiting<K, A, P, R>(readyAt));
    }

    entry.pending = null;
    final attempt = EffectAttempt<K, A, P, R>(
      identity: EffectAttemptIdentity(
        effect: pending.intent.identity,
        generation: generation,
        epoch: pending.intent.epoch,
        step: pending.nextStep,
        attempt: pending.nextAttempt,
      ),
      key: pending.intent.key,
      expected: pending.expected,
      payload: pending.intent.plan.steps[pending.nextStep],
      priorReceipts: pending.receipts,
    );
    entry.inflight = _Inflight(pending, attempt);
    return (EffectCasChange.changed, EffectCasClaimed<K, A, P, R>(attempt));
  }

  /// Match the exact attempt and retain its receipt; either advance the plan
  /// cursor (the returned authority is the next step's expected token) or
  /// complete and monotonically advance `appliedThrough`.
  (EffectCasChange, EffectCasApplied) recordApplied(
    K key,
    EffectAttemptIdentity attempt,
    R receipt,
    A authority,
  ) {
    if (attempt.generation != _generation) {
      return (
        EffectCasChange.none,
        EffectCasAppliedStaleGeneration(_generation)
      );
    }
    final entry = _keys[key];
    if (entry == null) {
      return (EffectCasChange.none, const EffectCasAppliedUnknownAttempt());
    }
    final terminal = entry.terminal;
    if (terminal != null &&
        terminal.receipts.any(
            (known) => known.attempt == attempt && known.receipt == receipt)) {
      return (EffectCasChange.none, const EffectCasAppliedDuplicate());
    }
    final inflight = entry.inflight;
    if (inflight == null || inflight.attempt.identity != attempt) {
      return (EffectCasChange.none, const EffectCasAppliedUnknownAttempt());
    }

    entry.inflight = null;
    final retained = inflight.retained;
    final receipts = [
      ...retained.receipts,
      EffectReceipt<R, A>(
          attempt: attempt, receipt: receipt, authority: authority),
    ];
    entry.retry = null;

    final newer = entry.pending;
    if (newer != null && newer.intent.epoch > retained.intent.epoch) {
      entry.terminalIntent = retained.intent;
      entry.terminal = EffectTerminal.superseded(
          retained.intent.identity, retained.intent.epoch, authority, receipts);
      return (EffectCasChange.changed, const EffectCasAppliedSuperseded());
    }

    final nextStep = retained.nextStep + 1;
    if (nextStep < retained.intent.plan.length) {
      entry.pending = retained._copyWith(
        nextStep: nextStep,
        expected: () => authority,
        receipts: receipts,
        nextAttempt: 1,
        readyAt: () => null,
      );
      return (EffectCasChange.changed, EffectCasStepApplied(nextStep));
    }

    final epoch = retained.intent.epoch;
    final previous = entry.appliedThrough;
    final through = previous == null || epoch > previous ? epoch : previous;
    entry.appliedThrough = through;
    entry.terminalIntent = retained.intent;
    entry.terminal =
        EffectTerminal.applied(retained.intent.identity, epoch, receipts);
    return (EffectCasChange.changed, EffectCasCompleted(through));
  }

  /// Match and terminally supersede the attempt without advancing
  /// `appliedThrough`; the adapter mutated nothing.
  (EffectCasChange, EffectCasFailure) recordSuperseded(
          K key, EffectAttemptIdentity attempt, A observed) =>
      _finishFailed(key, attempt, _FailureKind.superseded, observed: observed);

  /// Match and restore the same identity/cursor with an incremented attempt
  /// number and the caller-supplied logical [retryAt], unless a newer desired
  /// epoch already supersedes it.
  (EffectCasChange, EffectCasFailure) recordRetryable(
          K key, EffectAttemptIdentity attempt, E error, int retryAt) =>
      _finishFailed(key, attempt, _FailureKind.retryable,
          error: error, retryAt: retryAt);

  /// Match and terminally reject the intent. Rejection never aliases retry.
  (EffectCasChange, EffectCasFailure) recordRejected(
          K key, EffectAttemptIdentity attempt, E error) =>
      _finishFailed(key, attempt, _FailureKind.rejected, error: error);

  /// Route an adapter result to the matching `record*` transition.
  (EffectCasChange, EffectCasOutcome) recordOutcome(
    K key,
    EffectAttemptIdentity attempt,
    EffectApply<R, A, E> outcome,
    int retryAt,
  ) {
    switch (outcome) {
      case EffectApplied(:final receipt, :final authority):
        final (change, applied) =
            recordApplied(key, attempt, receipt, authority);
        return (change, EffectCasOutcomeApplied(applied));
      case EffectApplySuperseded(:final observed):
        final (change, failure) = recordSuperseded(key, attempt, observed);
        return (change, EffectCasOutcomeFailure(failure));
      case EffectApplyRetryable(:final error):
        final (change, failure) = recordRetryable(key, attempt, error, retryAt);
        return (change, EffectCasOutcomeFailure(failure));
      case EffectApplyRejected(:final error):
        final (change, failure) = recordRejected(key, attempt, error);
        return (change, EffectCasOutcomeFailure(failure));
    }
  }

  /// Fence older receipts. Requeue each in-flight cursor with the same identity
  /// and completed-step lineage unless a newer desired intent supersedes it.
  (EffectCasChange, EffectCasReconnect) reconnect(int newGeneration) {
    if (newGeneration < _generation) {
      return (
        EffectCasChange.none,
        EffectCasReconnectStaleGeneration(_generation)
      );
    }
    if (newGeneration == _generation) {
      return (EffectCasChange.none, EffectCasReconnectUnchanged(_generation));
    }

    _generation = newGeneration;
    var requeued = 0;
    var superseded = 0;
    for (final entry in _keys.values) {
      final inflight = entry.inflight;
      if (inflight == null) continue;
      entry.inflight = null;
      final retained = inflight.retained;
      final newer = entry.pending;
      if (newer != null && newer.intent.epoch > retained.intent.epoch) {
        entry.terminalIntent = retained.intent;
        entry.terminal = EffectTerminal.superseded(retained.intent.identity,
            retained.intent.epoch, null, retained.receipts);
        superseded++;
      } else {
        entry.pending = retained._copyWith(
          nextAttempt: retained.nextAttempt + 1,
          readyAt: () => null,
        );
        requeued++;
      }
    }
    return (
      EffectCasChange.changed,
      EffectCasReconnectAdvanced(newGeneration, requeued, superseded),
    );
  }

  (EffectCasChange, EffectCasFailure) _finishFailed(
    K key,
    EffectAttemptIdentity attempt,
    _FailureKind kind, {
    A? observed,
    E? error,
    int? retryAt,
  }) {
    if (attempt.generation != _generation) {
      return (
        EffectCasChange.none,
        EffectCasFailureStaleGeneration(_generation)
      );
    }
    final entry = _keys[key];
    if (entry == null) {
      return (EffectCasChange.none, const EffectCasFailureUnknownAttempt());
    }
    final inflight = entry.inflight;
    if (inflight == null || inflight.attempt.identity != attempt) {
      return (EffectCasChange.none, const EffectCasFailureUnknownAttempt());
    }

    entry.inflight = null;
    final retained = inflight.retained;
    final newer = entry.pending;
    final newerPending =
        newer != null && newer.intent.epoch > retained.intent.epoch;
    final identity = retained.intent.identity;
    final epoch = retained.intent.epoch;
    switch (kind) {
      case _FailureKind.superseded:
        entry.retry = null;
        entry.terminalIntent = retained.intent;
        entry.terminal = EffectTerminal.superseded(
            identity, epoch, observed, retained.receipts);
        return (EffectCasChange.changed, const EffectCasFailureSuperseded());
      case _FailureKind.retryable when !newerPending:
        entry.retry = EffectRetry<E>(
            attempt: attempt, error: error as E, retryAt: retryAt!);
        entry.pending = retained._copyWith(
          nextAttempt: retained.nextAttempt + 1,
          readyAt: () => retryAt,
        );
        return (EffectCasChange.changed, EffectCasFailureRetrying(retryAt));
      case _FailureKind.retryable:
        entry.retry = null;
        entry.terminalIntent = retained.intent;
        entry.terminal =
            EffectTerminal.superseded(identity, epoch, null, retained.receipts);
        return (EffectCasChange.changed, const EffectCasFailureSuperseded());
      case _FailureKind.rejected:
        entry.retry = null;
        entry.terminalIntent = retained.intent;
        entry.terminal = EffectTerminal.rejected(
            identity, epoch, error as E, retained.receipts);
        return (EffectCasChange.changed, const EffectCasFailureRejected());
    }
  }

  // -- Durable image ----------------------------------------------------------

  /// Full-fidelity image for crash recovery and cross-process persistence.
  EffectCasDurableState<K, A, P, R, E> durableState() => EffectCasDurableState(
        _generation,
        [
          for (final MapEntry(:key, :value) in _keys.entries)
            EffectCasDurableKey<K, A, P, R, E>(
              key: key,
              pending: value.pending,
              inflight: value.inflight == null
                  ? null
                  : EffectCasDurableInflight(
                      retained: value.inflight!.retained,
                      attempt: value.inflight!.attempt,
                    ),
              retry: value.retry,
              appliedThrough: value.appliedThrough,
              terminal: value.terminal,
              terminalIntent: value.terminalIntent,
            ),
        ],
      );

  /// Restore a core from [durableState] before the runtime becomes live. The
  /// restored core is observably identical to the one that wrote the image; a
  /// recovering actor then calls [reconnect] with a newer generation to fence
  /// the crashed actor and replay its retained work under the same identity.
  ///
  /// Throws [EffectCasHydrateException] for a corrupt image; it never repairs.
  static EffectCasCore<K, A, P, R, E> hydrate<K, A, P, R, E>(
    EffectCasDurableState<K, A, P, R, E> state, {
    Comparator<K>? compare,
  }) {
    final core =
        EffectCasCore<K, A, P, R, E>(state.generation, compare: compare);
    for (final durable in state.keys) {
      final pending = durable.pending;
      if (pending != null) _validateRetained(durable.key, pending);
      final terminalIntent = durable.terminalIntent;
      if (terminalIntent != null && terminalIntent.key != durable.key) {
        throw const EffectCasHydrateException(
            EffectCasHydrateError.keyMismatch);
      }
      _Inflight<K, A, P, R>? inflight;
      final durableInflight = durable.inflight;
      if (durableInflight != null) {
        final retained = durableInflight.retained;
        final attempt = durableInflight.attempt;
        _validateRetained(durable.key, retained);
        if (attempt.identity.generation > state.generation) {
          throw const EffectCasHydrateException(
              EffectCasHydrateError.futureGeneration);
        }
        if (attempt.key != durable.key ||
            attempt.identity.effect != retained.intent.identity ||
            attempt.identity.epoch != retained.intent.epoch ||
            attempt.identity.step != retained.nextStep ||
            attempt.identity.attempt != retained.nextAttempt ||
            attempt.expected != retained.expected ||
            attempt.payload != retained.intent.plan.steps[retained.nextStep] ||
            !_listEquals(attempt.priorReceipts, retained.receipts)) {
          throw const EffectCasHydrateException(
              EffectCasHydrateError.attemptMismatch);
        }
        inflight = _Inflight(retained, attempt);
      }
      if (core._keys.containsKey(durable.key)) {
        throw const EffectCasHydrateException(
            EffectCasHydrateError.duplicateKey);
      }
      core._keys[durable.key] = _Entry<K, A, P, R, E>()
        ..pending = durable.pending
        ..inflight = inflight
        ..retry = durable.retry
        ..appliedThrough = durable.appliedThrough
        ..terminal = durable.terminal
        ..terminalIntent = durable.terminalIntent;
    }
    return core;
  }

  static void _validateRetained<K, A, P, R>(
      K key, EffectPending<K, A, P, R> retained) {
    if (retained.intent.key != key) {
      throw const EffectCasHydrateException(EffectCasHydrateError.keyMismatch);
    }
    if (retained.nextStep < 0 ||
        retained.nextStep >= retained.intent.plan.length) {
      throw const EffectCasHydrateException(
          EffectCasHydrateError.cursorOutOfRange);
    }
  }
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
