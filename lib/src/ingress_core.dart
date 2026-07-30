/// `IngressCore` — the graph-agnostic admission algebra behind every ingress
/// flavor (`#designimplementtransport`).
///
/// Spec: `lazily-spec/docs/transport-ingress.md`.
/// Rust reference: `lazily-rs/src/ingress_core.rs`.
/// Formal: `lazily-formal/LazilyFormal/Ingress.lean`.
///
/// The same core/shell split [WorkQueueCell]'s family makes for the queue
/// family and `KeyedOrder` makes for the map family, and for the same reason:
/// deciding whether an inbound envelope is *admissible* touches no reactive
/// node and awaits nothing, so the single-threaded, run-to-completion, and
/// async shells share it verbatim — while **reactivity deliberately stays
/// out**. Invalidation is a graph write, so each flavor mints its own per-scope
/// readers on its own graph and clears them after the core call returns.
///
/// Every mutator therefore returns an [IngressChange] — *which* reader kinds
/// the transition dirtied — rather than performing the invalidation itself.
/// That return value is the whole contract between the core and a shell, and it
/// is a pure function of the transition, which is what makes the plane portable
/// across flavors without re-deriving values per flavor.
///
/// ## Transport-agnostic by construction
///
/// The core never touches a transport. An envelope is a value
/// ([IngressEnvelope]) carrying its own provenance — `generation`, `sequence`,
/// `stampedAt` — so a WebSocket frame, an RPC response, and a polled page are
/// the *same* input once decoded. That is what makes the admission decisions
/// (stale rejection, dedupe, reorder, freshness, backpressure) independent of
/// how bytes arrived, and why [IngressTransportKind] exists only to derive a
/// *schedule*.
///
/// ## What is a derive and what is a call
///
/// Readiness, authority, and retry are **not** imperative refresh calls. They
/// are pure functions of scope state ([ScopeView.readiness],
/// [ScopeView.authority], [ScopeView.retry]) that each shell exposes as a
/// reader node. Freshness is time-dependent, so it enters through an explicit
/// [IngressCore.tick] rather than a hidden clock read — the same discipline the
/// temporal family uses, and the reason staleness transitions are deterministic
/// and fixture-replayable.
library;

import 'merge.dart';
import 'relay.dart';

// ---------------------------------------------------------------------------
// Transport seam
// ---------------------------------------------------------------------------

/// How envelopes reach a scope. Event delivery is the default and needs no
/// schedule; the other two exist so a deployment without an event channel still
/// has a *bounded* fallback rather than an unbounded refresh loop.
enum IngressTransportKind {
  /// Server-initiated delivery (WebSocket, SSE, in-isolate channel). Preferred.
  eventChannel,

  /// Client-initiated, but triggered by an out-of-band event rather than a
  /// timer — an RPC issued *because* something happened.
  rpcTriggered,

  /// Client-initiated on a bounded interval. The fallback of last resort.
  boundedPolling,
}

/// When, if ever, a scope should ask the transport for more data.
///
/// [pollInterval] is non-null only for [IngressTransportKind.boundedPolling] —
/// making "we polled a transport that pushes" unrepresentable rather than
/// merely discouraged.
final class IngressSchedule {
  const IngressSchedule(this.kind, this.pollInterval);

  /// Derive the schedule for [kind]. A poll interval is offered only where
  /// event delivery is unavailable, and never zero.
  factory IngressSchedule.forKind(IngressTransportKind kind, int pollInterval) =>
      IngressSchedule(
        kind,
        kind == IngressTransportKind.boundedPolling
            ? (pollInterval < 1 ? 1 : pollInterval)
            : null,
      );

  /// The transport this schedule was derived from.
  final IngressTransportKind kind;

  /// Bounded poll period, or `null` when delivery is event-driven.
  final int? pollInterval;

  @override
  bool operator ==(Object other) =>
      other is IngressSchedule &&
      other.kind == kind &&
      other.pollInterval == pollInterval;

  @override
  int get hashCode => Object.hash(kind, pollInterval);

  @override
  String toString() => 'IngressSchedule(${kind.name}, $pollInterval)';
}

/// What a reconnect needs from the transport to close its gap.
final class ReplayRequest {
  const ReplayRequest(this.generation, this.fromSequence);

  /// The generation being resumed.
  final int generation;

  /// First sequence the consumer has not delivered.
  final int fromSequence;

  @override
  bool operator ==(Object other) =>
      other is ReplayRequest &&
      other.generation == generation &&
      other.fromSequence == fromSequence;

  @override
  int get hashCode => Object.hash(generation, fromSequence);

  @override
  String toString() => 'ReplayRequest(generation: $generation, '
      'fromSequence: $fromSequence)';
}

/// One decoded inbound message, with the provenance admission needs.
///
/// [generation] fences a producer incarnation (a reconnect, a redeploy, a build
/// skew); [sequence] orders within a generation; [stampedAt] is the producer's
/// logical time, which is what freshness is measured against.
final class IngressEnvelope<K, T> {
  const IngressEnvelope(
    this.key,
    this.generation,
    this.sequence,
    this.stampedAt,
    this.payload,
  );

  /// Lifecycle-scoped identity this envelope belongs to.
  final K key;

  /// Producer incarnation. Monotone per key; a higher value fences lower ones.
  final int generation;

  /// Position within [generation], starting at 0.
  final int sequence;

  /// Producer's logical timestamp, compared against the freshness horizon.
  final int stampedAt;

  /// The decoded payload.
  final T payload;

  @override
  String toString() => 'IngressEnvelope($key, g$generation, s$sequence, '
      't$stampedAt, $payload)';
}

/// A decoded source of envelopes.
///
/// The core never calls this — a shell's `pump` does — which is exactly what
/// keeps admission independent of delivery. Implementations decode; they do not
/// decide.
abstract interface class IngressTransport<K, T> {
  /// How this transport delivers. Drives [IngressSchedule] and nothing else.
  IngressTransportKind get kind;

  /// Take everything decoded since the last call. Never blocks.
  List<IngressEnvelope<K, T>> drain();

  /// Ask the producer to resend from [request]'s `fromSequence`. Returns
  /// whether the transport could carry the request — a polling transport that
  /// cannot address history answers `false`, which is what makes "this gap will
  /// never close" observable rather than silent.
  bool requestReplay(K key, ReplayRequest request);
}

/// An in-isolate event channel: the reference [IngressTransport], and the one
/// the conformance corpus replays against.
///
/// [kind] is configurable so one implementation exercises all three delivery
/// modes — including the [IngressTransportKind.boundedPolling] case that cannot
/// serve a replay.
final class InProcIngress<K, T> implements IngressTransport<K, T> {
  InProcIngress(this.kind);

  @override
  final IngressTransportKind kind;

  final List<IngressEnvelope<K, T>> _inbound = [];
  final List<(K, ReplayRequest)> _replays = [];

  /// Queue one envelope for the next [drain].
  void push(IngressEnvelope<K, T> envelope) => _inbound.add(envelope);

  /// Replay requests observed so far, oldest first.
  List<(K, ReplayRequest)> get replays => List.unmodifiable(_replays);

  @override
  List<IngressEnvelope<K, T>> drain() {
    final batch = List<IngressEnvelope<K, T>>.of(_inbound);
    _inbound.clear();
    return batch;
  }

  @override
  bool requestReplay(K key, ReplayRequest request) {
    // A bounded poll has no addressable history: it can only wait for the next
    // page, so it cannot honour a replay.
    if (kind == IngressTransportKind.boundedPolling) return false;
    _replays.add((key, request));
    return true;
  }
}

// ---------------------------------------------------------------------------
// Decisions, outcomes, and receipts
// ---------------------------------------------------------------------------

/// Why an envelope was refused. Every variant is a *decision*, not a failure —
/// dropping a superseded envelope is correct behaviour and is receipted as
/// such.
enum IngressDropReason {
  /// `generation` is below the scope's fence: a zombie producer.
  staleGeneration('stale_generation'),

  /// `sequence` was already delivered in this generation.
  duplicateSequence('duplicate_sequence'),

  /// `sequence` is already sitting in the reorder buffer.
  duplicateBuffered('duplicate_buffered'),

  /// The reorder buffer is at `reorderWindow` and this envelope does not fill
  /// the gap.
  reorderWindowOverflow('reorder_window_overflow'),

  /// `now - stampedAt` exceeds the freshness horizon.
  expired('expired'),

  /// The hot window is at `highWater` under a bounding overflow policy.
  backpressure('backpressure'),

  /// The scope is closed; it admits nothing until reopened.
  scopeClosed('scope_closed');

  const IngressDropReason(this.wire);

  /// The cross-language conformance spelling.
  final String wire;
}

/// A transport- or decode-level failure attributed to a scope. Distinct from a
/// drop: an error means we could not *decide*, so it drives retry.
enum IngressError {
  /// The transport closed or reset under us.
  transportClosed('transport_closed'),

  /// The frame could not be decoded into an envelope.
  decodeFailed('decode_failed'),

  /// The producer reported that our generation is no longer authoritative.
  authorityLost('authority_lost');

  const IngressError(this.wire);

  /// The cross-language conformance spelling.
  final String wire;
}

/// The outcome of admitting one envelope.
sealed class IngressAdmission {
  const IngressAdmission();

  /// Whether the envelope became visible to readers.
  bool get isDelivered =>
      this is IngressAccepted ||
      this is IngressConflated ||
      this is IngressGenerationHandoff;
}

/// Delivered in order, and the window holds exactly this one op.
final class IngressAccepted extends IngressAdmission {
  const IngressAccepted(this.deliveredThrough);

  /// Highest in-order sequence now delivered (buffered successors flush).
  final int deliveredThrough;

  @override
  bool operator ==(Object other) =>
      other is IngressAccepted && other.deliveredThrough == deliveredThrough;

  @override
  int get hashCode => Object.hash('accepted', deliveredThrough);

  @override
  String toString() => 'IngressAccepted($deliveredThrough)';
}

/// Delivered in order and coalesced with at least one other op — either a prior
/// undrained op, or a buffered successor this delivery flushed.
final class IngressConflated extends IngressAdmission {
  const IngressConflated(this.deliveredThrough);

  /// Highest in-order sequence now delivered.
  final int deliveredThrough;

  @override
  bool operator ==(Object other) =>
      other is IngressConflated && other.deliveredThrough == deliveredThrough;

  @override
  int get hashCode => Object.hash('conflated', deliveredThrough);

  @override
  String toString() => 'IngressConflated($deliveredThrough)';
}

/// Held pending an earlier sequence. Nothing is visible yet.
final class IngressBuffered extends IngressAdmission {
  const IngressBuffered(this.gapFrom);

  /// The first sequence still missing.
  final int gapFrom;

  @override
  bool operator ==(Object other) =>
      other is IngressBuffered && other.gapFrom == gapFrom;

  @override
  int get hashCode => Object.hash('buffered', gapFrom);

  @override
  String toString() => 'IngressBuffered($gapFrom)';
}

/// A newer producer incarnation took over: sequence expectations reset and the
/// envelope was delivered.
final class IngressGenerationHandoff extends IngressAdmission {
  const IngressGenerationHandoff(this.from, this.to);

  /// The fence we held.
  final int from;

  /// The fence we now hold.
  final int to;

  @override
  bool operator ==(Object other) =>
      other is IngressGenerationHandoff && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash('handoff', from, to);

  @override
  String toString() => 'IngressGenerationHandoff($from -> $to)';
}

/// Refused, with the reason receipted.
final class IngressDropped extends IngressAdmission {
  const IngressDropped(this.reason);

  /// Why the envelope was refused.
  final IngressDropReason reason;

  @override
  bool operator ==(Object other) =>
      other is IngressDropped && other.reason == reason;

  @override
  int get hashCode => Object.hash('dropped', reason);

  @override
  String toString() => 'IngressDropped(${reason.wire})';
}

/// Refused by [Overflow.block]; the producer must retry after a drain.
final class IngressBlocked extends IngressAdmission {
  const IngressBlocked();

  @override
  bool operator ==(Object other) => other is IngressBlocked;

  @override
  int get hashCode => 0x1B10C;

  @override
  String toString() => 'IngressBlocked()';
}

/// Which receipt channel a receipt belongs to. The three are separate reader
/// kinds because they have separate consumers: a projection wants accepts, a
/// dashboard wants drops, a supervisor wants errors.
enum IngressReceiptChannel { accepted, dropped, error }

/// The decision a receipt records.
sealed class IngressReceiptOutcome {
  const IngressReceiptOutcome();

  /// The channel this outcome is read from.
  IngressReceiptChannel get channel;
}

/// Delivered, with the resulting watermark.
final class IngressAcceptedReceipt extends IngressReceiptOutcome {
  const IngressAcceptedReceipt(this.deliveredThrough, this.conflated);

  /// Highest in-order sequence delivered after this envelope.
  final int deliveredThrough;

  /// Whether the payload coalesced into a non-empty window.
  final bool conflated;

  @override
  IngressReceiptChannel get channel => IngressReceiptChannel.accepted;

  @override
  bool operator ==(Object other) =>
      other is IngressAcceptedReceipt &&
      other.deliveredThrough == deliveredThrough &&
      other.conflated == conflated;

  @override
  int get hashCode => Object.hash('accepted', deliveredThrough, conflated);
}

/// Refused by a decision.
final class IngressDroppedReceipt extends IngressReceiptOutcome {
  const IngressDroppedReceipt(this.reason);

  /// Why the envelope was refused.
  final IngressDropReason reason;

  @override
  IngressReceiptChannel get channel => IngressReceiptChannel.dropped;

  @override
  bool operator ==(Object other) =>
      other is IngressDroppedReceipt && other.reason == reason;

  @override
  int get hashCode => Object.hash('dropped', reason);
}

/// Could not be decided.
final class IngressErrorReceipt extends IngressReceiptOutcome {
  const IngressErrorReceipt(this.error);

  /// The failure attributed to the scope.
  final IngressError error;

  @override
  IngressReceiptChannel get channel => IngressReceiptChannel.error;

  @override
  bool operator ==(Object other) =>
      other is IngressErrorReceipt && other.error == error;

  @override
  int get hashCode => Object.hash('error', error);
}

/// One durable record of an admission decision.
final class IngressReceipt<K> {
  const IngressReceipt({
    required this.offset,
    required this.key,
    required this.generation,
    required this.sequence,
    required this.outcome,
  });

  /// Monotone receipt offset, stable across eviction.
  final int offset;

  /// Scope the decision was made for.
  final K key;

  /// Generation the decision was made under.
  final int generation;

  /// Sequence the decision was made for, when there was one.
  final int? sequence;

  /// The decision.
  final IngressReceiptOutcome outcome;

  /// The channel this receipt is read from.
  IngressReceiptChannel get channel => outcome.channel;

  @override
  String toString() =>
      'IngressReceipt(#$offset, $key, g$generation, s$sequence, $outcome)';
}

// ---------------------------------------------------------------------------
// Lifecycle, derives, and policy
// ---------------------------------------------------------------------------

/// Where a scope is in its lifecycle. Scopes are keyed and independent: closing
/// one never touches another.
enum IngressLifecycle {
  /// Opened, nothing delivered yet.
  opening('opening'),

  /// Delivering.
  live('live'),

  /// Disconnected but retained: state and cursors survive for replay.
  suspended('suspended'),

  /// Terminal until reopened. Admits nothing.
  closed('closed');

  const IngressLifecycle(this.wire);

  /// The cross-language conformance spelling.
  final String wire;
}

/// The derived answer to "can a consumer trust this scope right now?".
enum IngressReadiness {
  /// No such scope.
  unknown('unknown'),

  /// Open, nothing delivered yet.
  warming('warming'),

  /// Delivered and inside the freshness horizon.
  ready('ready'),

  /// Delivered, but the newest accepted stamp is older than the horizon.
  stale('stale'),

  /// Disconnected; retained state may be replayed.
  suspended('suspended'),

  /// Terminal.
  closed('closed');

  const IngressReadiness(this.wire);

  /// The cross-language conformance spelling.
  final String wire;
}

/// What the scope currently claims authority over — the fence plus the in-order
/// watermark a replay request must resume from.
final class IngressAuthority {
  const IngressAuthority({
    required this.generation,
    required this.deliveredThrough,
    required this.stampedAt,
  });

  /// The generation fence currently held.
  final int generation;

  /// Highest in-order sequence delivered, or `null` before first delivery.
  final int? deliveredThrough;

  /// Producer stamp of the newest delivered envelope.
  final int stampedAt;

  @override
  bool operator ==(Object other) =>
      other is IngressAuthority &&
      other.generation == generation &&
      other.deliveredThrough == deliveredThrough &&
      other.stampedAt == stampedAt;

  @override
  int get hashCode => Object.hash(generation, deliveredThrough, stampedAt);

  @override
  String toString() => 'IngressAuthority(g$generation, '
      'deliveredThrough: $deliveredThrough, stampedAt: $stampedAt)';
}

/// The derived retry decision for a scope that has errored.
final class IngressRetry {
  const IngressRetry({
    required this.attempt,
    required this.backoff,
    required this.resumeFrom,
  });

  /// Consecutive errors since the last delivery.
  final int attempt;

  /// Exponential backoff, clamped to the policy ceiling.
  final int backoff;

  /// Sequence a replay should resume from.
  final int resumeFrom;

  @override
  bool operator ==(Object other) =>
      other is IngressRetry &&
      other.attempt == attempt &&
      other.backoff == backoff &&
      other.resumeFrom == resumeFrom;

  @override
  int get hashCode => Object.hash(attempt, backoff, resumeFrom);

  @override
  String toString() =>
      'IngressRetry(attempt: $attempt, backoff: $backoff, '
      'resumeFrom: $resumeFrom)';
}

/// Bounds and taxes, all flavor-neutral.
final class IngressPolicy {
  const IngressPolicy({
    this.reorderWindow = 8,
    this.freshnessHorizon = 1000,
    this.highWater = 64,
    this.overflow = Overflow.conflate,
    this.receiptCapacity = 256,
    this.retryBase = 10,
    this.retryCeiling = 10000,
  });

  /// How many out-of-order envelopes may be held per scope. `0` disables
  /// reordering: a gap drops immediately.
  final int reorderWindow;

  /// `now - stampedAt` above this marks a scope [IngressReadiness.stale]; an
  /// *arriving* envelope that old is dropped as [IngressDropReason.expired].
  final int freshnessHorizon;

  /// Merged-op count at which [overflow] engages.
  final int highWater;

  /// What to do at [highWater]. Reuses the relay algebra's [Overflow].
  final Overflow overflow;

  /// Retained receipts, oldest evicted first.
  final int receiptCapacity;

  /// First retry backoff; doubles per consecutive error.
  final int retryBase;

  /// Backoff clamp.
  final int retryCeiling;

  @override
  bool operator ==(Object other) =>
      other is IngressPolicy &&
      other.reorderWindow == reorderWindow &&
      other.freshnessHorizon == freshnessHorizon &&
      other.highWater == highWater &&
      other.overflow == overflow &&
      other.receiptCapacity == receiptCapacity &&
      other.retryBase == retryBase &&
      other.retryCeiling == retryCeiling;

  @override
  int get hashCode => Object.hash(reorderWindow, freshnessHorizon, highWater,
      overflow, receiptCapacity, retryBase, retryCeiling);
}

/// Why a policy was refused at construction time.
enum IngressConfigError {
  /// [Overflow.conflate] chosen for a non-conflating merge policy.
  conflateNotBounding,

  /// A zero receipt capacity would discard every receipt it just minted.
  zeroReceiptCapacity,
}

/// Thrown when an ingress is constructed with a policy its merge algebra cannot
/// honour.
///
/// Extends [ArgumentError] so callers may catch it either as the specific
/// [IngressConfigException] (inspecting [error]) or as a generic argument error
/// — exactly how [RelayConfigException] behaves.
class IngressConfigException extends ArgumentError {
  IngressConfigException(this.error) : super(error.name);

  /// Which construction rule was violated.
  final IngressConfigError error;
}

/// Read-only projection of one scope, from which every derive is computed.
///
/// A shell's reader closures call these and nothing else, which is why the
/// three flavors cannot disagree about readiness, authority, or retry.
final class ScopeView {
  const ScopeView({
    required this.lifecycle,
    required this.generation,
    required this.deliveredThrough,
    required this.stampedAt,
    required this.buffered,
    required this.windowDepth,
    required this.consecutiveErrors,
    required this.observedNow,
    required this.policy,
  });

  /// Lifecycle position.
  final IngressLifecycle lifecycle;

  /// Generation fence.
  final int generation;

  /// In-order watermark.
  final int? deliveredThrough;

  /// Producer stamp of the newest delivered envelope.
  final int stampedAt;

  /// Buffered out-of-order envelopes.
  final int buffered;

  /// Merged ops in the hot window.
  final int windowDepth;

  /// Consecutive errors since the last delivery.
  final int consecutiveErrors;

  /// Logical now, as of the last [IngressCore.tick].
  final int observedNow;

  /// Bounds in force.
  final IngressPolicy policy;

  /// Whether the newest delivered stamp is inside the freshness horizon.
  bool get isFresh => (observedNow - stampedAt) <= policy.freshnessHorizon;

  /// Derived readiness. A scope that has never delivered is
  /// [IngressReadiness.warming], not [IngressReadiness.stale], because there is
  /// no stamp to be old.
  IngressReadiness get readiness => switch (lifecycle) {
        IngressLifecycle.closed => IngressReadiness.closed,
        IngressLifecycle.suspended => IngressReadiness.suspended,
        IngressLifecycle.opening => IngressReadiness.warming,
        IngressLifecycle.live => deliveredThrough == null
            ? IngressReadiness.warming
            : (isFresh ? IngressReadiness.ready : IngressReadiness.stale),
      };

  /// Derived authority. A closed scope claims none.
  IngressAuthority? get authority => lifecycle == IngressLifecycle.closed
      ? null
      : IngressAuthority(
          generation: generation,
          deliveredThrough: deliveredThrough,
          stampedAt: stampedAt,
        );

  /// The first sequence not yet delivered in order.
  int get resumeFrom {
    final seq = deliveredThrough;
    return seq == null ? 0 : seq + 1;
  }

  /// Whether the scope is holding a gap open — an out-of-order buffer that a
  /// replay, not a retry, is the fix for.
  bool get hasGap => buffered > 0;

  /// Derived retry. `null` while no error is outstanding — a healthy scope has
  /// no backoff, rather than a zero one.
  IngressRetry? get retry {
    if (consecutiveErrors == 0) return null;
    final shift = (consecutiveErrors - 1).clamp(0, 31);
    final doubled = policy.retryBase * (1 << shift);
    return IngressRetry(
      attempt: consecutiveErrors,
      backoff: doubled < policy.retryCeiling ? doubled : policy.retryCeiling,
      resumeFrom: resumeFrom,
    );
  }
}

// ---------------------------------------------------------------------------
// The invalidation contract
// ---------------------------------------------------------------------------

/// Which of a scope's reader kinds a transition dirtied.
///
/// Four kinds exist because they have four different invalidation boundaries: a
/// buffered envelope moves nothing but its own gap, a `tick` across the horizon
/// moves only readiness, and an error moves only retry.
final class IngressScopeChange {
  const IngressScopeChange({
    this.value = false,
    this.readiness = false,
    this.authority = false,
    this.retry = false,
  });

  /// Everything moved — one delivery is visible to every reader kind.
  const IngressScopeChange.all()
      : value = true,
        readiness = true,
        authority = true,
        retry = true;

  /// A freshness-horizon crossing, or a suspend: readiness alone.
  const IngressScopeChange.readinessOnly()
      : value = false,
        readiness = true,
        authority = false,
        retry = false;

  /// A drain: the coalesced window alone.
  const IngressScopeChange.valueOnly()
      : value = true,
        readiness = false,
        authority = false,
        retry = false;

  /// An error: the backoff alone.
  const IngressScopeChange.retryOnly()
      : value = false,
        readiness = false,
        authority = false,
        retry = true;

  /// What materializing a previously-unknown scope changes: an unknown scope
  /// reads [IngressReadiness.unknown]/`null`, so its first appearance moves
  /// readiness and authority — and nothing else. A reader that observed a key
  /// before it opened must learn that it did.
  const IngressScopeChange.creation()
      : value = false,
        readiness = true,
        authority = true,
        retry = false;

  /// The coalesced window changed.
  final bool value;

  /// [IngressReadiness] changed.
  final bool readiness;

  /// [IngressAuthority] changed.
  final bool authority;

  /// [IngressRetry] changed.
  final bool retry;

  /// Nothing changed — the shell must not clear a reader.
  bool get isEmpty => !(value || readiness || authority || retry);

  /// The pointwise disjunction of two change sets.
  IngressScopeChange union(IngressScopeChange other) => IngressScopeChange(
        value: value || other.value,
        readiness: readiness || other.readiness,
        authority: authority || other.authority,
        retry: retry || other.retry,
      );

  @override
  bool operator ==(Object other) =>
      other is IngressScopeChange &&
      other.value == value &&
      other.readiness == readiness &&
      other.authority == authority &&
      other.retry == retry;

  @override
  int get hashCode => Object.hash(value, readiness, authority, retry);

  @override
  String toString() => 'IngressScopeChange(value: $value, '
      'readiness: $readiness, authority: $authority, retry: $retry)';
}

/// The pure invalidation set of one transition: the whole contract between the
/// core and a flavor shell.
final class IngressChange<K> {
  IngressChange();

  /// Per-scope dirty reader kinds, in transition order.
  final List<(K, IngressScopeChange)> scopes = [];

  /// The accepted-receipt reader grew.
  bool acceptedReceipts = false;

  /// The dropped-receipt reader grew.
  bool droppedReceipts = false;

  /// The error-receipt reader grew.
  bool errorReceipts = false;

  /// Whether this transition dirtied nothing at all.
  bool get isEmpty =>
      scopes.isEmpty &&
      !acceptedReceipts &&
      !droppedReceipts &&
      !errorReceipts;

  void _mark(K key, IngressScopeChange change) {
    if (!change.isEmpty) scopes.add((key, change));
  }

  void _markChannel(IngressReceiptChannel channel) {
    switch (channel) {
      case IngressReceiptChannel.accepted:
        acceptedReceipts = true;
      case IngressReceiptChannel.dropped:
        droppedReceipts = true;
      case IngressReceiptChannel.error:
        errorReceipts = true;
    }
  }

  @override
  String toString() => 'IngressChange(scopes: $scopes, '
      'accepted: $acceptedReceipts, dropped: $droppedReceipts, '
      'error: $errorReceipts)';
}

// ---------------------------------------------------------------------------
// The core
// ---------------------------------------------------------------------------

final class _Scope<T> {
  _Scope(this.generation);

  IngressLifecycle lifecycle = IngressLifecycle.opening;
  int generation;
  int? deliveredThrough;
  int stampedAt = 0;
  final Map<int, (T, int)> pending = {};
  T? window;
  bool hasWindow = false;
  int windowDepth = 0;
  int consecutiveErrors = 0;

  ScopeView view(int observedNow, IngressPolicy policy) => ScopeView(
        lifecycle: lifecycle,
        generation: generation,
        deliveredThrough: deliveredThrough,
        stampedAt: stampedAt,
        buffered: pending.length,
        windowDepth: windowDepth,
        consecutiveErrors: consecutiveErrors,
        observedNow: observedNow,
        policy: policy,
      );

  int get nextExpected {
    final seq = deliveredThrough;
    return seq == null ? 0 : seq + 1;
  }

  /// Everything a reader can observe *about shape rather than payload*. The
  /// buffered path diffs these to derive its invalidation set, so "a buffered
  /// envelope invalidates nothing" is a computed fact rather than a claim — and
  /// the handoff-then-buffer case (which clears the window) cannot slip
  /// through.
  (IngressLifecycle, int, int?, bool) get stamp =>
      (lifecycle, generation, deliveredThrough, hasWindow);

  IngressLifecycle get liveOrOpening =>
      deliveredThrough == null ? IngressLifecycle.opening : IngressLifecycle.live;

  void clearWindow() {
    window = null;
    hasWindow = false;
    windowDepth = 0;
  }
}

/// What the admission algebra decided, before any receipt is minted.
sealed class _Decision {
  const _Decision();
}

final class _Refuse extends _Decision {
  const _Refuse(this.reason);
  final IngressDropReason reason;
}

final class _Block extends _Decision {
  const _Block();
}

final class _BufferedDecision extends _Decision {
  const _BufferedDecision(this.gapFrom);
  final int gapFrom;
}

final class _Delivered extends _Decision {
  const _Delivered(this.deliveredThrough, this.conflated, this.handoff);
  final int deliveredThrough;
  final bool conflated;
  final (int, int)? handoff;
}

/// Keyed lifecycle scopes, an admission algebra, and a bounded receipt log. No
/// reactive node, no context, no interior mutability beyond its own maps — each
/// flavor wraps this and owns its own reactivity.
final class IngressCore<K, T> {
  /// Build a core over [policy], validating the overflow choice against the
  /// merge algebra the way [RelayCell]'s constructor does: [Overflow.conflate]
  /// bounds nothing for a non-conflating `⊕`.
  IngressCore(this.policy, this.mergePolicy) {
    if (policy.overflow == Overflow.conflate && !mergePolicy.conflates) {
      throw IngressConfigException(IngressConfigError.conflateNotBounding);
    }
    if (policy.receiptCapacity < 1) {
      throw IngressConfigException(IngressConfigError.zeroReceiptCapacity);
    }
  }

  /// The bounds in force.
  final IngressPolicy policy;

  /// The associative `⊕` the hot window folds under.
  final MergePolicy<T> mergePolicy;

  final Map<K, _Scope<T>> _scopes = {};
  final List<IngressReceipt<K>> _receipts = [];
  int _nextReceiptOffset = 0;
  int _observedNow = 0;

  /// Logical now, as of the last [tick].
  int get observedNow => _observedNow;

  /// Every known scope key, for a shell rebuilding its reader table.
  List<K> scopeKeys() => List.unmodifiable(_scopes.keys);

  /// Read-only projection of one scope, or `null` when unknown.
  ScopeView? view(K key) => _scopes[key]?.view(_observedNow, policy);

  /// Readiness of a scope. Unknown scopes are [IngressReadiness.unknown] rather
  /// than an error: a reader may legitimately observe a key before it opens.
  IngressReadiness readiness(K key) =>
      view(key)?.readiness ?? IngressReadiness.unknown;

  /// Authority claimed by a scope.
  IngressAuthority? authority(K key) => view(key)?.authority;

  /// Retry decision for a scope.
  IngressRetry? retry(K key) => view(key)?.retry;

  /// The coalesced window awaiting drain.
  T? peek(K key) => _scopes[key]?.window;

  /// Receipts on one channel, oldest first.
  List<IngressReceipt<K>> receipts(IngressReceiptChannel channel) =>
      List.unmodifiable(
        _receipts.where((receipt) => receipt.channel == channel),
      );

  /// Open (or reopen) a scope at [generation].
  ///
  /// Reopening a suspended scope preserves its watermark so a replay can resume
  /// from the gap; reopening a *closed* scope resets it, because a closed
  /// scope's producer is gone and its sequence space is not resumable.
  IngressChange<K> open(K key, int generation) {
    final change = IngressChange<K>();
    var scope = _scopes[key];
    if (scope == null) {
      _scopes[key] = _Scope<T>(generation);
      change._mark(key, const IngressScopeChange.creation());
      return change;
    }
    final before = (scope.lifecycle, scope.generation, scope.deliveredThrough);
    if (scope.lifecycle == IngressLifecycle.closed) {
      scope = _Scope<T>(generation);
      _scopes[key] = scope;
    } else {
      scope.lifecycle = scope.liveOrOpening;
      if (generation > scope.generation) {
        scope.generation = generation;
        scope.deliveredThrough = null;
        scope.pending.clear();
      }
    }
    final after = (scope.lifecycle, scope.generation, scope.deliveredThrough);
    if (before != after) {
      change._mark(
        key,
        IngressScopeChange(
          readiness: before.$1 != after.$1,
          authority: true,
        ),
      );
    }
    return change;
  }

  /// Suspend a scope: retain state and cursors, stop delivering. Returns the
  /// replay request a reconnect will need, or `null` when there was nothing to
  /// suspend.
  (IngressChange<K>, ReplayRequest?) suspend(K key) {
    final change = IngressChange<K>();
    final scope = _scopes[key];
    if (scope == null) return (change, null);
    if (scope.lifecycle == IngressLifecycle.suspended ||
        scope.lifecycle == IngressLifecycle.closed) {
      return (change, null);
    }
    scope.lifecycle = IngressLifecycle.suspended;
    change._mark(key, const IngressScopeChange.readinessOnly());
    return (change, ReplayRequest(scope.generation, scope.nextExpected));
  }

  /// Reconnect a scope at [generation], clearing the error streak.
  ///
  /// A higher generation is a producer handoff: the sequence space restarts, so
  /// the buffered reorder window and the coalesced value are discarded rather
  /// than replayed against a fence they no longer belong to.
  (IngressChange<K>, ReplayRequest) reconnect(K key, int generation) {
    final change = IngressChange<K>();
    final created = !_scopes.containsKey(key);
    final scope = _scopes.putIfAbsent(key, () => _Scope<T>(generation));
    final handoff = generation > scope.generation;
    final hadWindow = scope.hasWindow;
    if (handoff) {
      scope.generation = generation;
      scope.deliveredThrough = null;
      scope.pending.clear();
      scope.clearWindow();
    }
    final beforeLifecycle = scope.lifecycle;
    scope.lifecycle = scope.liveOrOpening;
    final hadErrors = scope.consecutiveErrors > 0;
    scope.consecutiveErrors = 0;
    final request = ReplayRequest(scope.generation, scope.nextExpected);
    var base = IngressScopeChange(
      value: handoff && hadWindow,
      readiness: beforeLifecycle != scope.lifecycle,
      authority: handoff,
      retry: hadErrors,
    );
    if (created) base = base.union(const IngressScopeChange.creation());
    change._mark(key, base);
    return (change, request);
  }

  /// Close a scope. It admits nothing and claims no authority until reopened.
  IngressChange<K> close(K key) {
    final change = IngressChange<K>();
    final scope = _scopes[key];
    if (scope == null || scope.lifecycle == IngressLifecycle.closed) {
      return change;
    }
    final hadWindow = scope.hasWindow;
    final hadErrors = scope.consecutiveErrors > 0;
    scope.lifecycle = IngressLifecycle.closed;
    scope.pending.clear();
    scope.clearWindow();
    scope.consecutiveErrors = 0;
    change._mark(
      key,
      IngressScopeChange(
        value: hadWindow,
        readiness: true,
        authority: true,
        retry: hadErrors,
      ),
    );
    return change;
  }

  /// Advance logical time. Only scopes that *crossed* the freshness horizon are
  /// dirtied — a tick inside the horizon invalidates nothing, which is what
  /// keeps a polling shell from re-rendering on every tick.
  IngressChange<K> tick(int now) {
    final change = IngressChange<K>();
    if (now == _observedNow) return change;
    final before = _observedNow;
    _observedNow = now;
    for (final entry in _scopes.entries) {
      final scope = entry.value;
      if (scope.view(before, policy).readiness !=
          scope.view(now, policy).readiness) {
        change._mark(entry.key, const IngressScopeChange.readinessOnly());
      }
    }
    return change;
  }

  /// Record a transport/decode failure against a scope, deepening its backoff.
  IngressChange<K> fail(K key, IngressError error) {
    final change = IngressChange<K>();
    final created = !_scopes.containsKey(key);
    final scope = _scopes.putIfAbsent(key, () => _Scope<T>(0));
    scope.consecutiveErrors += 1;
    var base = const IngressScopeChange.retryOnly();
    if (created) base = base.union(const IngressScopeChange.creation());
    change._mark(key, base);
    change._markChannel(_pushReceipt(
      key: key,
      generation: scope.generation,
      sequence: null,
      outcome: IngressErrorReceipt(error),
    ));
    return change;
  }

  /// Drain a scope's coalesced window, resetting its depth. Returns `null` for
  /// an empty window and dirties nothing.
  ///
  /// A drain is an *egress*, not an ack: it never moves the watermark, so a
  /// replay after a drain still resumes from the same sequence.
  (IngressChange<K>, T?) drain(K key) {
    final change = IngressChange<K>();
    final scope = _scopes[key];
    if (scope == null || !scope.hasWindow) return (change, null);
    final value = scope.window;
    scope.clearWindow();
    change._mark(key, const IngressScopeChange.valueOnly());
    return (change, value);
  }

  /// Admit one envelope, applying — in this order — scope lifecycle, the
  /// generation fence, freshness, generation handoff, dedupe, ordering,
  /// backpressure, and merge.
  ///
  /// The order is the contract: a zombie generation is rejected before its
  /// stale sequence is consulted, and an expired envelope is rejected before it
  /// can occupy a reorder slot.
  (IngressChange<K>, IngressAdmission) admit(IngressEnvelope<K, T> envelope) {
    final key = envelope.key;
    final created = !_scopes.containsKey(key);
    final before = _scopes[key]?.stamp;
    final scope = _scopes.putIfAbsent(key, () => _Scope<T>(envelope.generation));
    final decision = _decide(scope, envelope);

    // A refused envelope must not leave a scope behind: an expired or blocked
    // message for a key we do not track is not an admission plane, and
    // materializing one would report a readiness change that never happened.
    final admitted = decision is _BufferedDecision || decision is _Delivered;
    if (created && !admitted) _scopes.remove(key);

    final change = IngressChange<K>();
    final fence = _scopes[key]?.generation ?? envelope.generation;

    switch (decision) {
      case _Refuse(:final reason):
        change._markChannel(_pushReceipt(
          key: key,
          generation: fence,
          sequence: envelope.sequence,
          outcome: IngressDroppedReceipt(reason),
        ));
        return (change, IngressDropped(reason));
      case _Block():
        change._markChannel(_pushReceipt(
          key: key,
          generation: fence,
          sequence: envelope.sequence,
          outcome: const IngressDroppedReceipt(IngressDropReason.backpressure),
        ));
        return (change, const IngressBlocked());
      case _BufferedDecision(:final gapFrom):
        // A buffered envelope mints no receipt, and for an already-current
        // scope it dirties no reader, because nothing a reader can observe
        // moved. Two cases are NOT invisible and are derived rather than
        // assumed: the scope's own first appearance (it moves off `unknown`),
        // and a generation handoff that buffers — which resets the fence, the
        // watermark, and the window before parking the envelope.
        var scopeChange = created
            ? const IngressScopeChange.creation()
            : const IngressScopeChange();
        final after = _scopes[key]?.stamp;
        if (before != null && after != null) {
          scopeChange = scopeChange.union(IngressScopeChange(
            value: before.$4 != after.$4,
            readiness: before.$1 != after.$1 ||
                (before.$3 == null) != (after.$3 == null),
            authority: before.$2 != after.$2 || before.$3 != after.$3,
          ));
        }
        change._mark(key, scopeChange);
        return (change, IngressBuffered(gapFrom));
      case _Delivered(:final deliveredThrough, :final conflated, :final handoff):
        change._mark(key, const IngressScopeChange.all());
        change._markChannel(_pushReceipt(
          key: key,
          generation: fence,
          sequence: envelope.sequence,
          outcome: IngressAcceptedReceipt(deliveredThrough, conflated),
        ));
        final admission = handoff != null
            ? IngressGenerationHandoff(handoff.$1, handoff.$2)
            : (conflated
                ? IngressConflated(deliveredThrough)
                : IngressAccepted(deliveredThrough));
        return (change, admission);
    }
  }

  /// The admission algebra proper: pure over one scope, mutating only that
  /// scope, minting nothing.
  _Decision _decide(_Scope<T> scope, IngressEnvelope<K, T> envelope) {
    if (scope.lifecycle == IngressLifecycle.closed) {
      return const _Refuse(IngressDropReason.scopeClosed);
    }
    if (envelope.generation < scope.generation) {
      return const _Refuse(IngressDropReason.staleGeneration);
    }
    if (_observedNow - envelope.stampedAt > policy.freshnessHorizon) {
      return const _Refuse(IngressDropReason.expired);
    }

    (int, int)? handoff;
    if (envelope.generation > scope.generation) {
      // A handoff is a baseline reset, not a continuation: the new
      // incarnation's first envelope is authoritative, so the old
      // incarnation's undrained window and buffered successors are discarded
      // rather than folded into it. Merging a superseded delta into a fresh
      // baseline is exactly the build-skew corruption the generation fence
      // exists to prevent, and it is the same rule `reconnect` at a higher
      // generation applies.
      handoff = (scope.generation, envelope.generation);
      scope.generation = envelope.generation;
      scope.deliveredThrough = null;
      scope.pending.clear();
      scope.clearWindow();
    }

    final expected = scope.nextExpected;
    if (envelope.sequence < expected) {
      return const _Refuse(IngressDropReason.duplicateSequence);
    }
    if (envelope.sequence > expected) {
      if (scope.pending.containsKey(envelope.sequence)) {
        return const _Refuse(IngressDropReason.duplicateBuffered);
      }
      if (scope.pending.length >= policy.reorderWindow) {
        return const _Refuse(IngressDropReason.reorderWindowOverflow);
      }
      scope.pending[envelope.sequence] = (envelope.payload, envelope.stampedAt);
      return _BufferedDecision(expected);
    }

    // In order. Backpressure is checked here and not earlier: refusing an
    // in-order envelope leaves a gap the reorder buffer cannot close, so
    // `Block` must be observable by the producer as its own outcome.
    if (scope.windowDepth >= policy.highWater) {
      switch (policy.overflow) {
        case Overflow.block:
          return const _Block();
        case Overflow.dropNewest:
          return const _Refuse(IngressDropReason.backpressure);
        case Overflow.dropOldest:
          scope.clearWindow();
        // `Conflate` *is* the bound; `Spill` degrades to it until a durable
        // tail is wired, exactly as `RelayCell` does.
        case Overflow.conflate:
        case Overflow.spill:
          break;
      }
    }

    var conflated = _mergeInto(scope, envelope.payload, envelope.stampedAt);
    scope.deliveredThrough = envelope.sequence;
    scope.lifecycle = IngressLifecycle.live;
    scope.consecutiveErrors = 0;
    var deliveredThrough = envelope.sequence;

    // Flush every buffered successor this delivery unblocked. One invalidation
    // covers the whole flush: readers observe the coalesced window, never a
    // partial replay.
    while (true) {
      final next = scope.nextExpected;
      final buffered = scope.pending.remove(next);
      if (buffered == null) break;
      conflated = _mergeInto(scope, buffered.$1, buffered.$2) || conflated;
      scope.deliveredThrough = next;
      deliveredThrough = next;
    }

    return _Delivered(deliveredThrough, conflated, handoff);
  }

  /// Merge one payload into a scope's hot head. Returns whether it coalesced
  /// with an existing window.
  bool _mergeInto(_Scope<T> scope, T payload, int stampedAt) {
    final bool conflated;
    if (!scope.hasWindow) {
      scope.window = payload;
      scope.hasWindow = true;
      conflated = false;
    } else {
      scope.window = mergePolicy.merge(scope.window as T, payload);
      conflated = true;
    }
    scope.windowDepth += 1;
    if (stampedAt > scope.stampedAt) scope.stampedAt = stampedAt;
    return conflated;
  }

  IngressReceiptChannel _pushReceipt({
    required K key,
    required int generation,
    required int? sequence,
    required IngressReceiptOutcome outcome,
  }) {
    _receipts.add(IngressReceipt<K>(
      offset: _nextReceiptOffset++,
      key: key,
      generation: generation,
      sequence: sequence,
      outcome: outcome,
    ));
    while (_receipts.length > policy.receiptCapacity) {
      _receipts.removeAt(0);
    }
    return outcome.channel;
  }
}
