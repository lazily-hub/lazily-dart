/// `ThreadSafeIngressCell` — the run-to-completion flavor of the
/// transport-agnostic reactive ingress family (`#designimplementtransport`).
///
/// Spec: `lazily-spec/docs/transport-ingress.md`.
/// Rust reference: `lazily-rs/src/thread_safe_ingress.rs`.
///
/// DART RUNTIME PREMISE (the same one `thread_safe_queue_family.dart` states).
/// Dart isolates have **no shared mutable heap**, and synchronous code inside an
/// isolate runs to completion without yielding, so it already serializes access
/// to the reactive graph. The shipped "thread-safe" surface is therefore a
/// reentrant run-to-completion guard around [Context] rather than an OS mutex,
/// and this shell — exactly like [ThreadSafeQueueCell] and
/// [ThreadSafeWorkQueueCell] — reuses the settled single-threaded admission
/// algebra while routing every operation and every read through that guard.
///
/// **The lock-discipline invariant still holds, and for the same reason.** In
/// Rust the shell must release the core lock before touching the context,
/// because a reader's compute takes context→core while an op takes core→context.
/// Here the equivalent is structural: [IngressCell] computes the whole
/// [IngressChange] from the core *before* calling `Context.invalidateSlots`, so
/// no invalidation ever runs while the admission algebra is mid-transition. The
/// guard is reentrant, so a reader's compute closure entering [ThreadSafeContext.read]
/// from inside an op's invalidation cascade nests instead of deadlocking.
///
/// **Multi-root invalidation is one frontier walk.** One admission can dirty a
/// scope's value, readiness, authority, and retry plus a receipt channel;
/// clearing them one at a time is one frontier walk each, and a downstream
/// [Effect] would then run twice and could observe the new value with the old
/// authority — precisely the partial fan-out a generation handoff must never
/// expose. `Context.invalidateSlots` takes the whole root set and flushes
/// effects once, which is Dart's spelling of the Rust shell's `batch()`.
library;

import 'core.dart';
import 'ingress.dart';
import 'ingress_core.dart';
import 'merge.dart';
import 'thread_safe.dart';

/// Run-to-completion keyed, lifecycle-scoped reactive ingress.
final class ThreadSafeIngressCell<K, T> {
  ThreadSafeIngressCell(
    this.ctx, {
    required IngressPolicy policy,
    required MergePolicy<T> mergePolicy,
    IngressTransportKind transport = IngressTransportKind.eventChannel,
    int pollInterval = 25,
  }) : _inner = ctx.read(
          (raw) => IngressCell<K, T>(
            raw,
            policy: policy,
            mergePolicy: mergePolicy,
            transport: transport,
            pollInterval: pollInterval,
          ),
        );

  /// The guarded graph this ingress mints its readers on.
  final ThreadSafeContext ctx;
  final IngressCell<K, T> _inner;

  // -- Operations -------------------------------------------------------------

  /// Open (or reopen) a keyed scope at [generation].
  void open(K key, int generation) =>
      ctx.withLock((_) => _inner.open(key, generation));

  /// Admit one decoded envelope.
  IngressAdmission admit(IngressEnvelope<K, T> envelope) =>
      ctx.read((_) => _inner.admit(envelope));

  /// Suspend a scope, retaining its watermark.
  ReplayRequest? suspend(K key) => ctx.read((_) => _inner.suspend(key));

  /// Reconnect a scope at [generation], clearing its error streak.
  ReplayRequest reconnect(K key, int generation) =>
      ctx.read((_) => _inner.reconnect(key, generation));

  /// Close a scope. It admits nothing and claims no authority until reopened.
  void close(K key) => ctx.withLock((_) => _inner.close(key));

  /// Record a transport/decode failure, deepening the scope's backoff.
  void fail(K key, IngressError error) =>
      ctx.withLock((_) => _inner.fail(key, error));

  /// Advance logical time.
  void tick(int now) => ctx.withLock((_) => _inner.tick(now));

  /// Drain a scope's coalesced window.
  T? drain(K key) => ctx.read((_) => _inner.drain(key));

  /// Admit everything [transport] has decoded, then ask it to replay any gap
  /// still open.
  List<IngressAdmission> pump(IngressTransport<K, T> transport) =>
      ctx.read((_) => _inner.pump(transport));

  // -- Reactive reads ---------------------------------------------------------

  /// Reactive read: the coalesced window awaiting drain.
  T? value(K key, [Compute? cx]) => ctx.read((_) => _inner.value(key, cx));

  /// Reactive read: derived readiness.
  IngressReadiness readiness(K key, [Compute? cx]) =>
      ctx.read((_) => _inner.readiness(key, cx));

  /// Reactive read: derived authority.
  IngressAuthority? authority(K key, [Compute? cx]) =>
      ctx.read((_) => _inner.authority(key, cx));

  /// Reactive read: derived retry decision.
  IngressRetry? retry(K key, [Compute? cx]) =>
      ctx.read((_) => _inner.retry(key, cx));

  /// Reactive read: accepted receipts, oldest first.
  List<IngressReceipt<K>> accepted([Compute? cx]) =>
      ctx.read((_) => _inner.accepted(cx));

  /// Reactive read: dropped receipts, oldest first.
  List<IngressReceipt<K>> dropped([Compute? cx]) =>
      ctx.read((_) => _inner.dropped(cx));

  /// Reactive read: error receipts, oldest first.
  List<IngressReceipt<K>> errors([Compute? cx]) =>
      ctx.read((_) => _inner.errors(cx));

  /// Reactive read: the derived delivery schedule.
  IngressSchedule schedule([Compute? cx]) =>
      ctx.read((_) => _inner.schedule(cx));

  /// The four reader nodes for one scope.
  IngressScopeReaders<T> readers(K key) => ctx.read((_) => _inner.readers(key));

  /// Handle for the accepted-receipt reader.
  Slot<List<IngressReceipt<K>>> get acceptedHandle => _inner.acceptedHandle;

  /// Handle for the dropped-receipt reader.
  Slot<List<IngressReceipt<K>>> get droppedHandle => _inner.droppedHandle;

  /// Handle for the error-receipt reader.
  Slot<List<IngressReceipt<K>>> get errorsHandle => _inner.errorsHandle;

  /// Handle for the schedule reader.
  Slot<IngressSchedule> get scheduleHandle => _inner.scheduleHandle;

  /// Retune the transport live.
  void setTransport(IngressTransportKind kind) =>
      ctx.withLock((_) => _inner.setTransport(kind));

  /// Retune the poll bound live.
  void setPollInterval(int interval) =>
      ctx.withLock((_) => _inner.setPollInterval(interval));

  // -- Non-reactive projections ----------------------------------------------

  /// Non-reactive projection of a scope.
  ScopeView? view(K key) => ctx.read((_) => _inner.view(key));

  /// The bounds in force.
  IngressPolicy get policy => _inner.policy;

  /// The associative `⊕` the hot window folds under.
  MergePolicy<T> get mergePolicy => _inner.mergePolicy;

  /// Every known scope key.
  List<K> scopeKeys() => ctx.read((_) => _inner.scopeKeys());
}
