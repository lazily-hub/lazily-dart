/// `AsyncEgressCell` — the [AsyncContext] flavor of the transport-agnostic
/// reactive egress family (`#lzegress`).
///
/// Spec: `lazily-spec/docs/transport-egress.md`.
/// Rust reference: `lazily-rs/src/async_egress.rs`.
///
/// **Delivery state is not async-coloured.** Whether an envelope may be claimed,
/// acknowledged, failed, rescheduled, or replayed is a function of the sequence
/// space, the window, the watermark, the retry budget, and the generation fence
/// — state nothing has to await. The four readers are therefore synchronous
/// [AsyncContext.computed] derivations on the async graph, and every operation
/// returns a plain value, exactly like the other two shells. Only the transport
/// attachment ([attachTransport]) is async-coloured: it is an
/// [AsyncContext.effectAsync] whose send may await.
///
/// Multi-root invalidation goes through [AsyncContext.clearSlots], which clears
/// the whole dirtied set in one frontier walk.
library;

import 'async_context.dart';
import 'egress_core.dart';

/// The async transport seam. `true` means the transport accepted the send
/// attempt; domain delivery is proven later by [AsyncEgressCell.ack].
abstract interface class AsyncEgressTransport<T> {
  Future<bool> send(EgressEnvelope<T> envelope);
}

/// Async-graph reactive egress with synchronous delivery authority.
final class AsyncEgressCell<T> {
  /// Throws [EgressConfigException] for a policy no core can honour.
  AsyncEgressCell(
    this.ctx,
    int generation, [
    EgressPolicy policy = const EgressPolicy(),
  ]) : _core = EgressCore<T>(generation, policy) {
    _pending = ctx.computed<List<EgressEnvelope<T>>>((_) => _core.pending());
    _inflight = ctx.computed<List<EgressEnvelope<T>>>((_) => _core.inflight());
    _ackedThrough = ctx.computed<int?>((_) => _core.ackedThrough);
    _retry = ctx.computed<EgressRetry?>((_) => _core.retry);
  }

  /// The async graph this egress mints its readers on.
  final AsyncContext ctx;

  final EgressCore<T> _core;
  late final AsyncSlotHandle<List<EgressEnvelope<T>>> _pending;
  late final AsyncSlotHandle<List<EgressEnvelope<T>>> _inflight;
  late final AsyncSlotHandle<int?> _ackedThrough;
  late final AsyncSlotHandle<EgressRetry?> _retry;

  /// Apply one core-reported invalidation set in a single frontier walk.
  void _apply(EgressChange change) {
    if (change.isEmpty) return;
    ctx.clearSlots(<AsyncSlotHandle<dynamic>>[
      if (change.pending) _pending,
      if (change.inflight) _inflight,
      if (change.ackedThrough) _ackedThrough,
      if (change.retry) _retry,
    ]);
  }

  /// The bounds in force.
  EgressPolicy get policy => _core.policy;

  /// The current producer generation.
  int get generation => _core.generation;

  /// The sequence the next enqueue will be assigned.
  int get nextSequence => _core.nextSequence;

  // -- Operations -------------------------------------------------------------

  /// Assign the next sequence to [payload]; returns that sequence.
  int enqueue(T payload) {
    final (change, sequence) = _core.enqueue(payload);
    _apply(change);
    return sequence;
  }

  /// Claim the oldest pending envelope under [generation].
  EgressClaim<T> claim(int generation) {
    final (change, claim) = _core.claim(generation);
    _apply(change);
    return claim;
  }

  /// Cumulatively acknowledge every sequence at or below [through].
  EgressAck ack(int generation, int through) {
    final (change, ack) = _core.ack(generation, through);
    _apply(change);
    return ack;
  }

  /// Record that the in-flight [sequence] failed to send.
  EgressFailure fail(int generation, int sequence) {
    final (change, failure) = _core.fail(generation, sequence);
    _apply(change);
    return failure;
  }

  /// Reschedule a parked failed record.
  EgressRetryAction retryNow(int generation, int sequence) {
    final (change, action) = _core.retryNow(generation, sequence);
    _apply(change);
    return action;
  }

  /// Fence the current attachment and replay unacknowledged records.
  EgressReconnect reconnect(int generation) {
    final (change, reconnect) = _core.reconnect(generation);
    _apply(change);
    return reconnect;
  }

  // -- Reactive reads (synchronous Computeds on the async graph) ---------------

  /// Reactive read: pending envelopes, oldest sequence first.
  List<EgressEnvelope<T>> pending([AsyncComputeContext? cx]) =>
      cx == null ? ctx.get(_pending) : cx.get(_pending);

  /// Reactive read: claimed, unacknowledged envelopes.
  List<EgressEnvelope<T>> inflight([AsyncComputeContext? cx]) =>
      cx == null ? ctx.get(_inflight) : cx.get(_inflight);

  /// Reactive read: the cumulative acknowledgement watermark.
  int? ackedThrough([AsyncComputeContext? cx]) =>
      cx == null ? ctx.get(_ackedThrough) : cx.get(_ackedThrough);

  /// Reactive read: the most recent failure's retry decision.
  EgressRetry? retry([AsyncComputeContext? cx]) =>
      cx == null ? ctx.get(_retry) : cx.get(_retry);

  /// Handle for the pending reader.
  AsyncSlotHandle<List<EgressEnvelope<T>>> get pendingHandle => _pending;

  /// Handle for the in-flight reader.
  AsyncSlotHandle<List<EgressEnvelope<T>>> get inflightHandle => _inflight;

  /// Handle for the acknowledgement-watermark reader.
  AsyncSlotHandle<int?> get ackedThroughHandle => _ackedThrough;

  /// Handle for the retry reader.
  AsyncSlotHandle<EgressRetry?> get retryHandle => _retry;

  // -- Transport attachment (the only async-coloured part) ---------------------

  /// Attach one async transport Effect at the current producer generation.
  ///
  /// The captured generation is the fence: after a reconnect every claim this
  /// attachment makes is refused by the core, so it becomes inert while still
  /// attached, and a replacement attachment replays the retained pending
  /// projection under the new incarnation.
  ///
  /// The claim loop runs before the tracked reads for the reason
  /// [EgressCell.attachTransport] gives; here it additionally means the reads
  /// happen at a synchronous point after the last claim, so no enqueue landing
  /// during an awaited send can slip between "nothing left to claim" and the
  /// subscription that would re-run the attachment.
  AsyncEffectHandle attachTransport(AsyncEgressTransport<T> transport) {
    final captured = _core.generation;
    return ctx.effectAsync((cx) async {
      while (true) {
        final claim = this.claim(captured);
        if (claim is! EgressClaimed<T>) break;
        if (!await transport.send(claim.envelope)) {
          fail(captured, claim.envelope.sequence);
          break;
        }
      }
      cx.get(_inflight);
      cx.get(_pending);
      return null;
    });
  }
}
