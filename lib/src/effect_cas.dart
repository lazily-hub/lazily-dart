/// Reactive shells for [EffectCasCore] (`#lzeffectcas`).
///
/// Rust reference: `lazily-rs/src/thread_safe_effect_cas.rs`.
///
/// Each shell projects the core's snapshot as one reader node and invalidates
/// it only when a transition reports a state change: a stale generation, an
/// unknown attempt, a duplicate receipt, or any other no-op leaves every reader
/// version untouched. Scheduling observes `pendingKeys(now)` and invokes the
/// application adapter outside any core transition.
library;

import 'async_context.dart';
import 'core.dart';
import 'effect_cas_core.dart';
import 'thread_safe.dart';

/// Single-isolate reactive keyed effect-CAS authority.
final class EffectCas<K, A, P, R, E> {
  EffectCas(this.ctx, int generation, {Comparator<K>? compare})
      : _core = EffectCasCore<K, A, P, R, E>(generation, compare: compare) {
    _state =
        Slot<EffectCasSnapshot<K, A, P, R, E>>(ctx, (_) => _core.snapshot());
  }

  /// Wrap an already-[EffectCasCore.hydrate]d core before the runtime is live.
  EffectCas.hydrated(this.ctx, EffectCasCore<K, A, P, R, E> core)
      : _core = core {
    _state =
        Slot<EffectCasSnapshot<K, A, P, R, E>>(ctx, (_) => _core.snapshot());
  }

  final Context ctx;
  final EffectCasCore<K, A, P, R, E> _core;
  late final Slot<EffectCasSnapshot<K, A, P, R, E>> _state;

  T _transition<T>((EffectCasChange, T) result) {
    if (result.$1.state) ctx.invalidateSlots(<Slot>[_state]);
    return result.$2;
  }

  /// Handle for the snapshot reader.
  Slot<EffectCasSnapshot<K, A, P, R, E>> get stateHandle => _state;

  /// The current actor generation.
  int get generation => _core.generation;

  /// Reactive read: the whole projection.
  EffectCasSnapshot<K, A, P, R, E> snapshot([Compute? cx]) =>
      cx == null ? _state() : cx.get(_state);

  /// Non-reactive projection of one key.
  EffectCasKeyState<K, A, P, R, E>? state(K key) => _core.state(key);

  /// Keys whose retained work is claimable at logical time [now].
  List<K> pendingKeys(int now) => _core.pendingKeys(now);

  /// Full-fidelity durable image.
  EffectCasDurableState<K, A, P, R, E> durableState() => _core.durableState();

  EffectCasUpsert upsertDesired(EffectIntent<K, A, P> intent) =>
      _transition(_core.upsertDesired(intent));

  EffectCasClaim<K, A, P, R> claim(K key, int generation, int now) =>
      _transition(_core.claim(key, generation, now));

  EffectCasApplied recordApplied(
          K key, EffectAttemptIdentity attempt, R receipt, A authority) =>
      _transition(_core.recordApplied(key, attempt, receipt, authority));

  EffectCasFailure recordSuperseded(
          K key, EffectAttemptIdentity attempt, A observed) =>
      _transition(_core.recordSuperseded(key, attempt, observed));

  EffectCasFailure recordRetryable(
          K key, EffectAttemptIdentity attempt, E error, int retryAt) =>
      _transition(_core.recordRetryable(key, attempt, error, retryAt));

  EffectCasFailure recordRejected(
          K key, EffectAttemptIdentity attempt, E error) =>
      _transition(_core.recordRejected(key, attempt, error));

  EffectCasOutcome recordOutcome(K key, EffectAttemptIdentity attempt,
          EffectApply<R, A, E> outcome, int retryAt) =>
      _transition(_core.recordOutcome(key, attempt, outcome, retryAt));

  EffectCasReconnect reconnect(int newGeneration) =>
      _transition(_core.reconnect(newGeneration));
}

/// Run-to-completion flavor for Dart's isolate concurrency model: the
/// single-isolate shell behind [ThreadSafeContext]'s reentrant guard (the same
/// premise `thread_safe_ingress.dart` states).
final class ThreadSafeEffectCas<K, A, P, R, E> {
  ThreadSafeEffectCas(this.ctx, int generation, {Comparator<K>? compare})
      : _inner = ctx.read(
          (raw) => EffectCas<K, A, P, R, E>(raw, generation, compare: compare),
        );

  final ThreadSafeContext ctx;
  final EffectCas<K, A, P, R, E> _inner;

  Slot<EffectCasSnapshot<K, A, P, R, E>> get stateHandle => _inner.stateHandle;
  int get generation => ctx.read((_) => _inner.generation);
  EffectCasSnapshot<K, A, P, R, E> snapshot([Compute? cx]) =>
      ctx.read((_) => _inner.snapshot(cx));
  EffectCasKeyState<K, A, P, R, E>? state(K key) =>
      ctx.read((_) => _inner.state(key));
  List<K> pendingKeys(int now) => ctx.read((_) => _inner.pendingKeys(now));
  EffectCasDurableState<K, A, P, R, E> durableState() =>
      ctx.read((_) => _inner.durableState());

  EffectCasUpsert upsertDesired(EffectIntent<K, A, P> intent) =>
      ctx.read((_) => _inner.upsertDesired(intent));
  EffectCasClaim<K, A, P, R> claim(K key, int generation, int now) =>
      ctx.read((_) => _inner.claim(key, generation, now));
  EffectCasApplied recordApplied(
          K key, EffectAttemptIdentity attempt, R receipt, A authority) =>
      ctx.read((_) => _inner.recordApplied(key, attempt, receipt, authority));
  EffectCasFailure recordSuperseded(
          K key, EffectAttemptIdentity attempt, A observed) =>
      ctx.read((_) => _inner.recordSuperseded(key, attempt, observed));
  EffectCasFailure recordRetryable(
          K key, EffectAttemptIdentity attempt, E error, int retryAt) =>
      ctx.read((_) => _inner.recordRetryable(key, attempt, error, retryAt));
  EffectCasFailure recordRejected(
          K key, EffectAttemptIdentity attempt, E error) =>
      ctx.read((_) => _inner.recordRejected(key, attempt, error));
  EffectCasOutcome recordOutcome(K key, EffectAttemptIdentity attempt,
          EffectApply<R, A, E> outcome, int retryAt) =>
      ctx.read((_) => _inner.recordOutcome(key, attempt, outcome, retryAt));
  EffectCasReconnect reconnect(int newGeneration) =>
      ctx.read((_) => _inner.reconnect(newGeneration));
}

/// Async-graph flavor; transitions stay synchronous, the projection is a
/// synchronous Computed on the async graph.
final class AsyncEffectCas<K, A, P, R, E> {
  AsyncEffectCas(this.ctx, int generation, {Comparator<K>? compare})
      : _core = EffectCasCore<K, A, P, R, E>(generation, compare: compare) {
    _state = ctx.computed<EffectCasSnapshot<K, A, P, R, E>>(
      (_) => _core.snapshot(),
    );
  }

  final AsyncContext ctx;
  final EffectCasCore<K, A, P, R, E> _core;
  late final AsyncSlotHandle<EffectCasSnapshot<K, A, P, R, E>> _state;

  T _transition<T>((EffectCasChange, T) result) {
    if (result.$1.state) ctx.clearSlots([_state]);
    return result.$2;
  }

  AsyncSlotHandle<EffectCasSnapshot<K, A, P, R, E>> get stateHandle => _state;
  int get generation => _core.generation;
  EffectCasSnapshot<K, A, P, R, E> snapshot([AsyncComputeContext? cx]) =>
      cx == null ? ctx.get(_state) : cx.get(_state);
  EffectCasKeyState<K, A, P, R, E>? state(K key) => _core.state(key);
  List<K> pendingKeys(int now) => _core.pendingKeys(now);
  EffectCasDurableState<K, A, P, R, E> durableState() => _core.durableState();

  EffectCasUpsert upsertDesired(EffectIntent<K, A, P> intent) =>
      _transition(_core.upsertDesired(intent));
  EffectCasClaim<K, A, P, R> claim(K key, int generation, int now) =>
      _transition(_core.claim(key, generation, now));
  EffectCasApplied recordApplied(
          K key, EffectAttemptIdentity attempt, R receipt, A authority) =>
      _transition(_core.recordApplied(key, attempt, receipt, authority));
  EffectCasFailure recordSuperseded(
          K key, EffectAttemptIdentity attempt, A observed) =>
      _transition(_core.recordSuperseded(key, attempt, observed));
  EffectCasFailure recordRetryable(
          K key, EffectAttemptIdentity attempt, E error, int retryAt) =>
      _transition(_core.recordRetryable(key, attempt, error, retryAt));
  EffectCasFailure recordRejected(
          K key, EffectAttemptIdentity attempt, E error) =>
      _transition(_core.recordRejected(key, attempt, error));
  EffectCasOutcome recordOutcome(K key, EffectAttemptIdentity attempt,
          EffectApply<R, A, E> outcome, int retryAt) =>
      _transition(_core.recordOutcome(key, attempt, outcome, retryAt));
  EffectCasReconnect reconnect(int newGeneration) =>
      _transition(_core.reconnect(newGeneration));
}
