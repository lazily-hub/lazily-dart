/// `IngressCell` — the single-threaded flavor of the transport-agnostic reactive
/// ingress family (`#designimplementtransport`).
///
/// Spec: `lazily-spec/docs/transport-ingress.md`.
/// Rust reference: `lazily-rs/src/ingress.rs`.
///
/// The admission algebra lives in the flavor-neutral [IngressCore]; this shell
/// adds only the reactivity — four reader nodes per keyed scope plus three
/// receipt readers and a derived schedule, minted on *this* context's graph.
///
/// ## Readiness, authority, and retry are derives, not refresh calls
///
/// The point of the family: nothing here polls a connection to find out whether
/// it is healthy. [IngressCell.readiness], [IngressCell.authority], and
/// [IngressCell.retry] are reader nodes over scope state, so a consumer that
/// reads readiness is a graph dependent of exactly the transitions that can
/// change it — and a transition that cannot (a buffered out-of-order envelope,
/// a tick inside the freshness horizon) invalidates nothing. [IngressCore]
/// returns the invalidation set for every transition, and this shell clears
/// precisely that set.
///
/// ## Why four reader kinds per scope and not one
///
/// Collapsing them into one reader would make an error deepen a backoff *and*
/// re-render a value that did not change. The four boundaries are distinct in
/// the algebra ([IngressScopeChange]), so they are distinct here.
///
/// ## No observers — only reader nodes
///
/// There is no listener list, subscription set, or observer registry anywhere in
/// this family. Anything that survived an invalidation would not be a graph
/// edge; the per-scope readers are ordinary [Slot]s, and `Context.invalidateSlots`
/// clears the whole dirtied set in **one** frontier walk, so no reader ever
/// observes "new value, old authority" — the partial fan-out a generation
/// handoff must never expose.
library;

import 'core.dart';
import 'ingress_core.dart';
import 'merge.dart';

/// The four reader kinds one keyed scope exposes.
final class IngressScopeReaders<T> {
  const IngressScopeReaders({
    required this.value,
    required this.readiness,
    required this.authority,
    required this.retry,
  });

  /// The coalesced window awaiting drain.
  final Slot<T?> value;

  /// Derived readiness.
  final Slot<IngressReadiness> readiness;

  /// Derived authority.
  final Slot<IngressAuthority?> authority;

  /// Derived retry decision.
  final Slot<IngressRetry?> retry;
}

/// A keyed, lifecycle-scoped reactive ingress: one admission plane per key, with
/// readiness, authority, and retry as derives rather than calls.
final class IngressCell<K, T> {
  IngressCell(
    this.ctx, {
    required IngressPolicy policy,
    required MergePolicy<T> mergePolicy,
    IngressTransportKind transport = IngressTransportKind.eventChannel,
    int pollInterval = 25,
  }) : _core = IngressCore<K, T>(policy, mergePolicy) {
    _accepted = _receiptReader(IngressReceiptChannel.accepted);
    _dropped = _receiptReader(IngressReceiptChannel.dropped);
    _errors = _receiptReader(IngressReceiptChannel.error);
    _transportKind = Source<IngressTransportKind>(ctx, transport);
    _pollInterval = Source<int>(ctx, pollInterval);
    _schedule = Slot<IngressSchedule>(
      ctx,
      (cx) => IngressSchedule.forKind(
        cx.get(_transportKind),
        cx.get(_pollInterval),
      ),
    );
  }

  /// The graph this ingress mints its readers on.
  final Context ctx;

  final IngressCore<K, T> _core;
  final Map<K, IngressScopeReaders<T>> _scopes = {};
  late final Slot<List<IngressReceipt<K>>> _accepted;
  late final Slot<List<IngressReceipt<K>>> _dropped;
  late final Slot<List<IngressReceipt<K>>> _errors;
  late final Source<IngressTransportKind> _transportKind;
  late final Source<int> _pollInterval;
  late final Slot<IngressSchedule> _schedule;

  Slot<List<IngressReceipt<K>>> _receiptReader(IngressReceiptChannel channel) =>
      Slot<List<IngressReceipt<K>>>(ctx, (_) => _core.receipts(channel));

  /// Mint (or return) one scope's four readers. Idempotent, so a consumer may
  /// hold a handle for a key that has not opened yet.
  IngressScopeReaders<T> readers(K key) => _scopes.putIfAbsent(
        key,
        () => IngressScopeReaders<T>(
          value: Slot<T?>(ctx, (_) => _core.peek(key)),
          readiness: Slot<IngressReadiness>(ctx, (_) => _core.readiness(key)),
          authority: Slot<IngressAuthority?>(ctx, (_) => _core.authority(key)),
          retry: Slot<IngressRetry?>(ctx, (_) => _core.retry(key)),
        ),
      );

  /// Apply one core-reported invalidation set. Every affected reader is cleared
  /// in a single frontier walk, so no reader observes a partial fan-out — a
  /// generation handoff must not be visible as "new value, old authority".
  void _apply(IngressChange<K> change) {
    if (change.isEmpty) return;
    final roots = <Slot>[];
    for (final (key, scopeChange) in change.scopes) {
      final scopeReaders = readers(key);
      if (scopeChange.value) roots.add(scopeReaders.value);
      if (scopeChange.readiness) roots.add(scopeReaders.readiness);
      if (scopeChange.authority) roots.add(scopeReaders.authority);
      if (scopeChange.retry) roots.add(scopeReaders.retry);
    }
    if (change.acceptedReceipts) roots.add(_accepted);
    if (change.droppedReceipts) roots.add(_dropped);
    if (change.errorReceipts) roots.add(_errors);
    if (roots.isNotEmpty) ctx.invalidateSlots(roots);
  }

  // -- Operations -------------------------------------------------------------

  /// Open (or reopen) a keyed scope at [generation].
  void open(K key, int generation) => _apply(_core.open(key, generation));

  /// Admit one decoded envelope.
  IngressAdmission admit(IngressEnvelope<K, T> envelope) {
    final (change, admission) = _core.admit(envelope);
    _apply(change);
    return admission;
  }

  /// Suspend a scope, retaining its watermark. Returns the replay request a
  /// reconnect will need.
  ReplayRequest? suspend(K key) {
    final (change, request) = _core.suspend(key);
    _apply(change);
    return request;
  }

  /// Reconnect a scope at [generation], clearing its error streak.
  ReplayRequest reconnect(K key, int generation) {
    final (change, request) = _core.reconnect(key, generation);
    _apply(change);
    return request;
  }

  /// Close a scope. It admits nothing and claims no authority until reopened.
  void close(K key) => _apply(_core.close(key));

  /// Record a transport/decode failure, deepening the scope's backoff.
  void fail(K key, IngressError error) => _apply(_core.fail(key, error));

  /// Advance logical time. Only scopes that crossed the freshness horizon are
  /// invalidated.
  void tick(int now) => _apply(_core.tick(now));

  /// Drain a scope's coalesced window.
  T? drain(K key) {
    final (change, value) = _core.drain(key);
    _apply(change);
    return value;
  }

  /// Admit everything [transport] has decoded, then ask it to replay any gap
  /// still open. Returns the admission outcomes in arrival order.
  ///
  /// This is the only method that touches a transport, and it makes no decision
  /// of its own: the gap it replays is the one the algebra reports.
  List<IngressAdmission> pump(IngressTransport<K, T> transport) {
    final batch = transport.drain();
    final outcomes = <IngressAdmission>[];
    final touched = <K>[];
    for (final envelope in batch) {
      outcomes.add(admit(envelope));
      if (!touched.contains(envelope.key)) touched.add(envelope.key);
    }
    for (final key in touched) {
      final view = _core.view(key);
      if (view != null && view.hasGap) {
        transport.requestReplay(
          key,
          ReplayRequest(view.generation, view.resumeFrom),
        );
      }
    }
    return outcomes;
  }

  // -- Reactive reads ---------------------------------------------------------

  /// Reactive read: the coalesced window awaiting drain.
  T? value(K key, [Compute? cx]) {
    final reader = readers(key).value;
    return cx == null ? reader() : cx.get(reader);
  }

  /// Reactive read: derived readiness.
  IngressReadiness readiness(K key, [Compute? cx]) {
    final reader = readers(key).readiness;
    return cx == null ? reader() : cx.get(reader);
  }

  /// Reactive read: derived authority.
  IngressAuthority? authority(K key, [Compute? cx]) {
    final reader = readers(key).authority;
    return cx == null ? reader() : cx.get(reader);
  }

  /// Reactive read: derived retry decision.
  IngressRetry? retry(K key, [Compute? cx]) {
    final reader = readers(key).retry;
    return cx == null ? reader() : cx.get(reader);
  }

  /// Reactive read: accepted receipts, oldest first.
  List<IngressReceipt<K>> accepted([Compute? cx]) =>
      cx == null ? _accepted() : cx.get(_accepted);

  /// Reactive read: dropped receipts, oldest first.
  List<IngressReceipt<K>> dropped([Compute? cx]) =>
      cx == null ? _dropped() : cx.get(_dropped);

  /// Reactive read: error receipts, oldest first.
  List<IngressReceipt<K>> errors([Compute? cx]) =>
      cx == null ? _errors() : cx.get(_errors);

  /// Reactive read: the derived delivery schedule.
  IngressSchedule schedule([Compute? cx]) =>
      cx == null ? _schedule() : cx.get(_schedule);

  /// Handle for the accepted-receipt reader.
  Slot<List<IngressReceipt<K>>> get acceptedHandle => _accepted;

  /// Handle for the dropped-receipt reader.
  Slot<List<IngressReceipt<K>>> get droppedHandle => _dropped;

  /// Handle for the error-receipt reader.
  Slot<List<IngressReceipt<K>>> get errorsHandle => _errors;

  /// Handle for the schedule reader.
  Slot<IngressSchedule> get scheduleHandle => _schedule;

  /// Retune the transport live: falling back from an event channel to bounded
  /// polling is a cell write, so every schedule dependent reacts.
  void setTransport(IngressTransportKind kind) => _transportKind.set(kind);

  /// Retune the poll bound live.
  void setPollInterval(int interval) => _pollInterval.set(interval);

  // -- Non-reactive projections ----------------------------------------------

  /// Non-reactive projection of a scope, for assertions and diagnostics.
  ScopeView? view(K key) => _core.view(key);

  /// The bounds in force.
  IngressPolicy get policy => _core.policy;

  /// The associative `⊕` the hot window folds under.
  MergePolicy<T> get mergePolicy => _core.mergePolicy;

  /// Every known scope key.
  List<K> scopeKeys() => _core.scopeKeys();
}
