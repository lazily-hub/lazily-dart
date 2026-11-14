/// `ThreadSafeEgressCell` — the run-to-completion flavor of the
/// transport-agnostic reactive egress family (`#lzegress`).
///
/// Spec: `lazily-spec/docs/transport-egress.md`.
/// Rust reference: `lazily-rs/src/thread_safe_egress.rs`.
///
/// DART RUNTIME PREMISE (the same one `thread_safe_ingress.dart` and
/// `thread_safe_queue_family.dart` state). Dart isolates have **no shared
/// mutable heap**, and synchronous code inside an isolate runs to completion
/// without yielding, so it already serializes access to the reactive graph. The
/// shipped "thread-safe" surface is therefore a reentrant run-to-completion
/// guard around [Context] rather than an OS mutex, and this shell reuses the
/// single-threaded [EgressCell] while routing every operation, read, and
/// attachment through that guard.
///
/// Delivery authority stays in the shared [EgressCore]: the shell computes the
/// whole [EgressChange] before invalidating, so no invalidation runs while the
/// core is mid-transition — the Dart spelling of the Rust shell releasing the
/// core lock before touching the context. One attached transport Effect exists
/// per incarnation, fenced by the generation it captured.
library;

import 'core.dart';
import 'egress.dart';
import 'egress_core.dart';
import 'thread_safe.dart';

/// Run-to-completion reactive egress.
final class ThreadSafeEgressCell<T> {
  /// Throws [EgressConfigException] for a policy no core can honour.
  ThreadSafeEgressCell(
    this.ctx,
    int generation, [
    EgressPolicy policy = const EgressPolicy(),
  ]) : _inner = ctx.read((raw) => EgressCell<T>(raw, generation, policy));

  /// The guarded graph this egress mints its readers on.
  final ThreadSafeContext ctx;
  final EgressCell<T> _inner;

  /// The bounds in force.
  EgressPolicy get policy => _inner.policy;

  /// The current producer generation.
  int get generation => ctx.read((_) => _inner.generation);

  /// The sequence the next enqueue will be assigned.
  int get nextSequence => ctx.read((_) => _inner.nextSequence);

  // -- Operations -------------------------------------------------------------

  /// Assign the next sequence to [payload]; returns that sequence.
  int enqueue(T payload) => ctx.read((_) => _inner.enqueue(payload));

  /// Claim the oldest pending envelope under [generation].
  EgressClaim<T> claim(int generation) =>
      ctx.read((_) => _inner.claim(generation));

  /// Cumulatively acknowledge every sequence at or below [through].
  EgressAck ack(int generation, int through) =>
      ctx.read((_) => _inner.ack(generation, through));

  /// Record that the in-flight [sequence] failed to send.
  EgressFailure fail(int generation, int sequence) =>
      ctx.read((_) => _inner.fail(generation, sequence));

  /// Reschedule a parked failed record.
  EgressRetryAction retryNow(int generation, int sequence) =>
      ctx.read((_) => _inner.retryNow(generation, sequence));

  /// Fence the current attachment and replay unacknowledged records.
  EgressReconnect reconnect(int generation) =>
      ctx.read((_) => _inner.reconnect(generation));

  // -- Reactive reads ---------------------------------------------------------

  /// Reactive read: pending envelopes, oldest sequence first.
  List<EgressEnvelope<T>> pending([Compute? cx]) =>
      ctx.read((_) => _inner.pending(cx));

  /// Reactive read: claimed, unacknowledged envelopes.
  List<EgressEnvelope<T>> inflight([Compute? cx]) =>
      ctx.read((_) => _inner.inflight(cx));

  /// Reactive read: the cumulative acknowledgement watermark.
  int? ackedThrough([Compute? cx]) => ctx.read((_) => _inner.ackedThrough(cx));

  /// Reactive read: the most recent failure's retry decision.
  EgressRetry? retry([Compute? cx]) => ctx.read((_) => _inner.retry(cx));

  /// Handle for the pending reader.
  Slot<List<EgressEnvelope<T>>> get pendingHandle => _inner.pendingHandle;

  /// Handle for the in-flight reader.
  Slot<List<EgressEnvelope<T>>> get inflightHandle => _inner.inflightHandle;

  /// Handle for the acknowledgement-watermark reader.
  Slot<int?> get ackedThroughHandle => _inner.ackedThroughHandle;

  /// Handle for the retry reader.
  Slot<EgressRetry?> get retryHandle => _inner.retryHandle;

  /// Attach one transport Effect at the current producer generation, under the
  /// guard. See [EgressCell.attachTransport].
  Effect attachTransport(EgressTransport<T> transport) =>
      ctx.read((_) => _inner.attachTransport(transport));
}
