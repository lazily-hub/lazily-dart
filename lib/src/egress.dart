/// `EgressCell` — the single-threaded flavor of the transport-agnostic reactive
/// egress family (`#lzegress`).
///
/// Spec: `lazily-spec/docs/transport-egress.md`.
/// Rust reference: `lazily-rs/src/egress.rs`.
///
/// Delivery authority lives in the flavor-neutral [EgressCore]; this shell adds
/// only the reactivity — four reader nodes (`pending`, `inflight`,
/// `ackedThrough`, `retry`) minted on *this* context's graph. Every transition
/// clears exactly the reader set the core reports, in one frontier walk
/// (`Context.invalidateSlots`), and a no-op or stale-generation transition
/// clears nothing.
///
/// ## One Effect per attachment, not a request/ACK protocol
///
/// Transport I/O lives in exactly one [Effect] per attachment
/// ([attachTransport]). The Effect observes `pending` and `inflight`, asks the
/// core to claim eligible envelopes, and sends them. An acknowledgement is
/// domain delivery input to the core: it invalidates `inflight`, which re-runs
/// the same attachment when the bounded window reopens. The Effect never
/// decides admissibility — the core does — so it cannot advance a watermark,
/// clear retained work, or retry on its own.
library;

import 'core.dart';
import 'egress_core.dart';

/// The only transport seam egress owns. Durability and framing remain separate
/// adapters around the envelope.
abstract interface class EgressTransport<T> {
  /// `true` means the transport accepted the send attempt. Domain delivery is
  /// proven later by an acknowledgement ([EgressCell.ack]).
  bool send(EgressEnvelope<T> envelope);
}

/// Single-threaded reactive egress.
final class EgressCell<T> {
  /// Throws [EgressConfigException] for a policy no core can honour.
  EgressCell(this.ctx, int generation,
      [EgressPolicy policy = const EgressPolicy()])
      : _core = EgressCore<T>(generation, policy) {
    _pending = Slot<List<EgressEnvelope<T>>>(ctx, (_) => _core.pending());
    _inflight = Slot<List<EgressEnvelope<T>>>(ctx, (_) => _core.inflight());
    _ackedThrough = Slot<int?>(ctx, (_) => _core.ackedThrough);
    _retry = Slot<EgressRetry?>(ctx, (_) => _core.retry);
  }

  /// The graph this egress mints its readers on.
  final Context ctx;

  final EgressCore<T> _core;
  late final Slot<List<EgressEnvelope<T>>> _pending;
  late final Slot<List<EgressEnvelope<T>>> _inflight;
  late final Slot<int?> _ackedThrough;
  late final Slot<EgressRetry?> _retry;

  /// Apply one core-reported invalidation set in a single frontier walk.
  void _apply(EgressChange change) {
    if (change.isEmpty) return;
    ctx.invalidateSlots(<Slot>[
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

  /// Fence the current attachment and replay unacknowledged records under
  /// [generation].
  EgressReconnect reconnect(int generation) {
    final (change, reconnect) = _core.reconnect(generation);
    _apply(change);
    return reconnect;
  }

  // -- Reactive reads ---------------------------------------------------------

  /// Reactive read: pending envelopes, oldest sequence first.
  List<EgressEnvelope<T>> pending([Compute? cx]) =>
      cx == null ? _pending() : cx.get(_pending);

  /// Reactive read: claimed, unacknowledged envelopes.
  List<EgressEnvelope<T>> inflight([Compute? cx]) =>
      cx == null ? _inflight() : cx.get(_inflight);

  /// Reactive read: the cumulative acknowledgement watermark.
  int? ackedThrough([Compute? cx]) =>
      cx == null ? _ackedThrough() : cx.get(_ackedThrough);

  /// Reactive read: the most recent failure's retry decision.
  EgressRetry? retry([Compute? cx]) => cx == null ? _retry() : cx.get(_retry);

  /// Handle for the pending reader.
  Slot<List<EgressEnvelope<T>>> get pendingHandle => _pending;

  /// Handle for the in-flight reader.
  Slot<List<EgressEnvelope<T>>> get inflightHandle => _inflight;

  /// Handle for the acknowledgement-watermark reader.
  Slot<int?> get ackedThroughHandle => _ackedThrough;

  /// Handle for the retry reader.
  Slot<EgressRetry?> get retryHandle => _retry;

  // -- Transport attachment ---------------------------------------------------

  /// Attach one transport [Effect] at the current producer generation.
  ///
  /// A reconnect does not move this Effect's captured generation, so the old
  /// attachment becomes inert at the core's fence; callers attach one
  /// replacement Effect for the new transport incarnation.
  ///
  /// The claim loop runs BEFORE the tracked reads. A claim invalidates
  /// `pending` and `inflight`; had the Effect already read them in this run,
  /// that invalidation would reach the running Effect itself, and a
  /// run-to-completion Effect drops a rerun requested while it is still
  /// running — leaving the attachment deaf after its very first run (for
  /// instance a fresh attachment replaying a reconnect's retained pending
  /// projection). Reading afterwards subscribes to the post-claim state, so a
  /// later enqueue or a window-reopening acknowledgement re-runs it.
  Effect attachTransport(EgressTransport<T> transport) {
    final captured = _core.generation;
    return Effect(ctx, (cx) {
      while (true) {
        final claim = this.claim(captured);
        if (claim is! EgressClaimed<T>) break;
        if (!transport.send(claim.envelope)) {
          fail(captured, claim.envelope.sequence);
          break;
        }
      }
      // `inflight` is a dependency even though the core stays the authority:
      // an acknowledgement reopens the window and must re-run this attachment.
      cx.get(_inflight);
      cx.get(_pending);
      return null;
    });
  }
}
