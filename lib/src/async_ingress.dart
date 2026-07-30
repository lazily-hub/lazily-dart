/// `AsyncIngressCell` — the [AsyncContext] flavor of the transport-agnostic
/// reactive ingress family (`#designimplementtransport`).
///
/// Spec: `lazily-spec/docs/transport-ingress.md`.
/// Rust reference: `lazily-rs/src/async_ingress.rs`.
///
/// **Admission is not async-coloured.** Whether an envelope is admissible is a
/// function of the fence, the watermark, the reorder buffer, and the observed
/// clock — state the graph does not own and nothing has to await. This flavor
/// therefore uses [AsyncContext.computed] (a *synchronous* memoized derivation
/// living on the async graph) and returns plain values, exactly like the other
/// two shells, with no `settle` step anywhere. Awaiting belongs to the
/// transport, and the transport is outside the primitive by construction. It is
/// the same finding the queue family recorded for `AsyncQueueCell`.
///
/// Multi-root invalidation goes through [AsyncContext.clearSlots], which clears
/// the whole dirtied set in one frontier walk so a downstream observer cannot
/// run between a scope's value and its authority becoming dirty.
library;

import 'async_context.dart';
import 'ingress_core.dart';
import 'merge.dart';

/// The four reader kinds one keyed scope exposes on the async graph.
final class AsyncIngressScopeReaders<T> {
  const AsyncIngressScopeReaders({
    required this.value,
    required this.readiness,
    required this.authority,
    required this.retry,
  });

  /// The coalesced window awaiting drain.
  final AsyncSlotHandle<T?> value;

  /// Derived readiness.
  final AsyncSlotHandle<IngressReadiness> readiness;

  /// Derived authority.
  final AsyncSlotHandle<IngressAuthority?> authority;

  /// Derived retry decision.
  final AsyncSlotHandle<IngressRetry?> retry;
}

/// Async-graph keyed, lifecycle-scoped reactive ingress with synchronous
/// admission.
final class AsyncIngressCell<K, T> {
  AsyncIngressCell(
    this.ctx, {
    required IngressPolicy policy,
    required MergePolicy<T> mergePolicy,
    IngressTransportKind transport = IngressTransportKind.eventChannel,
    int pollInterval = 25,
  }) : _core = IngressCore<K, T>(policy, mergePolicy) {
    _accepted = _receiptReader(IngressReceiptChannel.accepted);
    _dropped = _receiptReader(IngressReceiptChannel.dropped);
    _errors = _receiptReader(IngressReceiptChannel.error);
    _transportKind = ctx.cell<IngressTransportKind>(transport);
    _pollInterval = ctx.cell<int>(pollInterval);
    _schedule = ctx.computed<IngressSchedule>(
      (cx) => IngressSchedule.forKind(
        cx.getCell(_transportKind),
        cx.getCell(_pollInterval),
      ),
    );
  }

  /// The async graph this ingress mints its readers on.
  final AsyncContext ctx;

  final IngressCore<K, T> _core;
  final Map<K, AsyncIngressScopeReaders<T>> _scopes = {};
  late final AsyncSlotHandle<List<IngressReceipt<K>>> _accepted;
  late final AsyncSlotHandle<List<IngressReceipt<K>>> _dropped;
  late final AsyncSlotHandle<List<IngressReceipt<K>>> _errors;
  late final AsyncCellHandle<IngressTransportKind> _transportKind;
  late final AsyncCellHandle<int> _pollInterval;
  late final AsyncSlotHandle<IngressSchedule> _schedule;

  AsyncSlotHandle<List<IngressReceipt<K>>> _receiptReader(
    IngressReceiptChannel channel,
  ) =>
      ctx.computed<List<IngressReceipt<K>>>((_) => _core.receipts(channel));

  /// Mint (or return) one scope's four readers. Idempotent, so a consumer may
  /// hold a handle for a key that has not opened yet.
  AsyncIngressScopeReaders<T> readers(K key) => _scopes.putIfAbsent(
        key,
        () => AsyncIngressScopeReaders<T>(
          value: ctx.computed<T?>((_) => _core.peek(key)),
          readiness:
              ctx.computed<IngressReadiness>((_) => _core.readiness(key)),
          authority:
              ctx.computed<IngressAuthority?>((_) => _core.authority(key)),
          retry: ctx.computed<IngressRetry?>((_) => _core.retry(key)),
        ),
      );

  /// Apply one core-reported invalidation set in a single frontier walk.
  void _apply(IngressChange<K> change) {
    if (change.isEmpty) return;
    final roots = <AsyncSlotHandle<dynamic>>[];
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
    if (roots.isNotEmpty) ctx.clearSlots(roots);
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

  /// Suspend a scope, retaining its watermark.
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

  /// Advance logical time.
  void tick(int now) => _apply(_core.tick(now));

  /// Drain a scope's coalesced window.
  T? drain(K key) {
    final (change, value) = _core.drain(key);
    _apply(change);
    return value;
  }

  /// Admit everything [transport] has decoded, then ask it to replay any gap
  /// still open.
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
  T? value(K key, [AsyncComputeContext? cx]) {
    final reader = readers(key).value;
    return cx == null ? ctx.get(reader) : cx.get(reader);
  }

  /// Reactive read: derived readiness.
  IngressReadiness readiness(K key, [AsyncComputeContext? cx]) {
    final reader = readers(key).readiness;
    return cx == null ? ctx.get(reader) : cx.get(reader);
  }

  /// Reactive read: derived authority.
  IngressAuthority? authority(K key, [AsyncComputeContext? cx]) {
    final reader = readers(key).authority;
    return cx == null ? ctx.get(reader) : cx.get(reader);
  }

  /// Reactive read: derived retry decision.
  IngressRetry? retry(K key, [AsyncComputeContext? cx]) {
    final reader = readers(key).retry;
    return cx == null ? ctx.get(reader) : cx.get(reader);
  }

  /// Reactive read: accepted receipts, oldest first.
  List<IngressReceipt<K>> accepted([AsyncComputeContext? cx]) =>
      cx == null ? ctx.get(_accepted) : cx.get(_accepted);

  /// Reactive read: dropped receipts, oldest first.
  List<IngressReceipt<K>> dropped([AsyncComputeContext? cx]) =>
      cx == null ? ctx.get(_dropped) : cx.get(_dropped);

  /// Reactive read: error receipts, oldest first.
  List<IngressReceipt<K>> errors([AsyncComputeContext? cx]) =>
      cx == null ? ctx.get(_errors) : cx.get(_errors);

  /// Reactive read: the derived delivery schedule.
  IngressSchedule schedule([AsyncComputeContext? cx]) =>
      cx == null ? ctx.get(_schedule) : cx.get(_schedule);

  /// Handle for the accepted-receipt reader.
  AsyncSlotHandle<List<IngressReceipt<K>>> get acceptedHandle => _accepted;

  /// Handle for the dropped-receipt reader.
  AsyncSlotHandle<List<IngressReceipt<K>>> get droppedHandle => _dropped;

  /// Handle for the error-receipt reader.
  AsyncSlotHandle<List<IngressReceipt<K>>> get errorsHandle => _errors;

  /// Handle for the schedule reader.
  AsyncSlotHandle<IngressSchedule> get scheduleHandle => _schedule;

  /// Retune the transport live.
  void setTransport(IngressTransportKind kind) =>
      ctx.setCell(_transportKind, kind);

  /// Retune the poll bound live.
  void setPollInterval(int interval) => ctx.setCell(_pollInterval, interval);

  // -- Non-reactive projections ----------------------------------------------

  /// Non-reactive projection of a scope.
  ScopeView? view(K key) => _core.view(key);

  /// The bounds in force.
  IngressPolicy get policy => _core.policy;

  /// The associative `⊕` the hot window folds under.
  MergePolicy<T> get mergePolicy => _core.mergePolicy;

  /// Every known scope key.
  List<K> scopeKeys() => _core.scopeKeys();
}
