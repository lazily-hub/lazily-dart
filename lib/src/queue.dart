/// Reactive queue: [QueueCell] + pluggable [QueueStorage] backend (`#lzqueue`).
///
/// A [QueueCell] is a FIFO collection composed of reactive cells — not a new
/// cell kind — that adds queue semantics (push to tail, pop from head) to the
/// reactive graph. It is specified as a **single-producer, single-consumer
/// (SPSC)** primitive; **MPSC** (multi-producer) is a *usage rule* on the same
/// primitive — multiple producers push inside a [Context.batch] boundary, and
/// the batch serializes the pushes into a deterministic order. There is no
/// separate MPSC type (`lazily-spec/cell-model.md` § "QueueCell — SPSC
/// primitive with MPSC usage rule").
///
/// ## Shell vs storage
///
/// The reactive shell owns the reader-kind version cells (`head` / `len` /
/// `is_empty` / `is_full` / `closed`) and the invalidation logic; it is
/// storage-agnostic. The storage backend owns the actual FIFO data structure
/// and is pluggable via [QueueStorage]. The default [VecDequeStorage] is an
/// unbounded deque; a bounded variant exposes reactive backpressure via
/// `is_full`. A distributed backend (`RaftQueueStorage`, future work per the
/// distributed-queue PRD) or an external-broker adapter (`KafkaStorage`, etc.)
/// plugs into the same reactive shell.
///
/// ## Reader-kind invalidation
///
/// Invalidation is scoped to **reader kind**, not to individual positions. A
/// push invalidates `len` / `is_empty` readers (and `head` when transitioning
/// from empty, and `is_full` when transitioning onto capacity); a pop
/// invalidates `head` / `len` / `is_empty` readers (and `is_full` when
/// transitioning off capacity). The head reader observes the *current* head
/// value — after a pop, the head reader sees the next element (or `null`), not
/// a stale value.
///
/// This reader-kind independence is implemented for free by the existing `!=`
/// guard on [Cell.value]'s setter: after each op the shell re-derives each
/// reader-kind cell from the storage and writes it back, and a cell whose
/// value did not change is not invalidated.
///
/// Mirrors `lazily-spec/cell-model.md` § "Reactive queues" and
/// `lazily-formal/LazilyFormal/QueueCell.lean`.
library;

import 'dart:collection';

import 'core.dart';

/// Sentinel stored in the head reader-kind cell when the queue is empty.
class _NoHead {
  const _NoHead();
}

/// The singleton sentinel instance.
const _noHead = _NoHead();

// ---------------------------------------------------------------------------
// Error sentinels
// ---------------------------------------------------------------------------

/// Failure modes for [QueueStorage.tryPush] / [QueueCell.tryPush].
///
/// `Full` and `Closed` are the two observable rejection reasons distinguished
/// by the shell's contract (`lazily-spec/cell-model.md` § "Storage backend
/// contract"). Neither changes queue state, so neither invalidates any reader.
sealed class QueuePushError {
  const QueuePushError._();

  /// The label matching the cross-language conformance fixture `returns` field.
  String get label;

  /// Bounded backend at capacity (reject policy on the default backend).
  static const full = _QueuePushFull();

  /// Queue is closed; push is rejected regardless of capacity. Terminal.
  static const closed = _QueuePushClosed();
}

final class _QueuePushFull extends QueuePushError {
  const _QueuePushFull() : super._();
  @override
  String get label => 'Full';
  @override
  bool operator ==(Object other) => other is _QueuePushFull;
  @override
  int get hashCode => 0x46754C; // 'FuLL'
}

final class _QueuePushClosed extends QueuePushError {
  const _QueuePushClosed() : super._();
  @override
  String get label => 'Closed';
  @override
  bool operator ==(Object other) => other is _QueuePushClosed;
  @override
  int get hashCode => 0xC105D; // 'CLoSed'
}

/// Failure modes for [QueueStorage.tryPop] / [QueueCell.tryPop].
///
/// `Empty` and `Closed` are distinct observable signals: `Empty` means "try
/// again later," `Closed` means "the producer is done and the queue is
/// drained."
sealed class QueuePopError {
  const QueuePopError._();

  /// The label matching the cross-language conformance fixture `returns` field.
  String get label;

  /// The queue is open but contains no elements.
  static const empty = _QueuePopEmpty();

  /// The queue is closed and empty — the producer is done and all buffered
  /// elements have been consumed. Pop on a closed *non-empty* queue still
  /// drains (returns the next element); only closed+empty yields [closed].
  static const closed = _QueuePopClosed();
}

final class _QueuePopEmpty extends QueuePopError {
  const _QueuePopEmpty() : super._();
  @override
  String get label => 'Empty';
  @override
  bool operator ==(Object other) => other is _QueuePopEmpty;
  @override
  int get hashCode => 0x2D705; // 'EmPtY'
}

final class _QueuePopClosed extends QueuePopError {
  const _QueuePopClosed() : super._();
  @override
  String get label => 'Closed';
  @override
  bool operator ==(Object other) => other is _QueuePopClosed;
  @override
  int get hashCode => 0xC105E; // 'CLoSed pop'
}

/// Outcome of [QueueCell.tryPop] / [QueueStorage.tryPop]: either a popped
/// [QueuePopValue] or a [QueuePopFailed] carrying the distinguishing
/// [QueuePopError].
sealed class QueuePopResult<T> {
  const QueuePopResult();
}

/// A successfully popped element.
final class QueuePopValue<T> extends QueuePopResult<T> {
  /// The popped element.
  final T value;
  const QueuePopValue(this.value);
}

/// Pop failed — the queue is [QueuePopError.empty] or [QueuePopError.closed].
final class QueuePopFailed<T> extends QueuePopResult<T> {
  /// The distinguishing error.
  final QueuePopError error;
  const QueuePopFailed(this.error);
}

// ---------------------------------------------------------------------------
// QueueStorage interface
// ---------------------------------------------------------------------------

/// Pluggable FIFO storage backend for a [QueueCell].
///
/// The shell / storage split (`lazily-spec/cell-model.md` § "Reactive shell vs
/// storage backend") keeps the reactive shell storage-agnostic: the shell owns
/// the reader-kind version cells and invalidation logic, the backend owns the
/// actual FIFO data structure. The default backend is [VecDequeStorage]
/// (unbounded deque); future backends include `RaftQueueStorage` (embedded
/// consensus, per the distributed-queue PRD) and `KafkaStorage` /
/// `RedisStreamStorage` / `SqsStorage` (external-broker adapters).
///
/// Conformance:
///
/// 1. **FIFO order** — [tryPop] returns elements in [tryPush] order.
/// 2. **Cardinality compatibility** — its native producer/consumer shape is a
///    superset of the shell's required shape (SPSC shell = any backend; MPSC
///    usage requires a multi-writer backend).
/// 3. **Bounded contract (optional)** — a bounded backend exposes [capacity]
///    as a non-null value and [tryPush] returns [QueuePushError.full] at
///    capacity. The overflow policy is a backend property.
/// 4. **Position identity** — invalidation is phrased over reader kind, not
///    storage indices. The shell layers its own logical version counters (the
///    reader-kind cells) above the storage.
abstract class QueueStorage<T> {
  /// Append [value] to the tail. Returns [QueuePushError.full] if bounded and
  /// at capacity, or [QueuePushError.closed] if the queue is closed. Returns
  /// `null` on success. On error the queue state is unchanged.
  QueuePushError? tryPush(T value);

  /// Remove and return the head element. Returns [QueuePopValue] on success,
  /// or [QueuePopFailed] carrying [QueuePopError.empty] if open and empty, or
  /// [QueuePopError.closed] if closed and empty. Pop on a closed *non-empty*
  /// queue drains (returns the next element).
  QueuePopResult<T> tryPop();

  /// **Optional capability.** Peek the current head element without removing
  /// it, `null` when empty. The default returns `null` — a backend that cannot
  /// peek (a raw channel) is fully conforming and simply has no `head` reader.
  T? peek() => null;

  /// Current number of buffered elements. **Required.**
  int len();

  /// **Optional capability.** Bounded capacity, or `null` for an unbounded
  /// backend (the default). When non-null, the shell exposes `is_full` as a
  /// reactive read.
  int? capacity() => null;

  /// Whether the queue has been closed. Close is terminal — once true, it
  /// stays true.
  bool isClosed();

  /// Close the queue. Idempotent — closing an already-closed queue is a
  /// no-op. After close, [tryPush] returns [QueuePushError.closed]; [tryPop]
  /// continues to drain and returns [QueuePopError.closed] only once empty.
  void close();
}

// ---------------------------------------------------------------------------
// VecDequeStorage — the reference unbounded/bounded backend
// ---------------------------------------------------------------------------

/// The reference [QueueStorage] backend: a [ListQueue]-backed FIFO, optionally
/// bounded.
///
/// The unbounded form (the default) is what [QueueCell.new] uses; the bounded
/// form ([VecDequeStorage.bounded]) exposes reactive backpressure via the
/// shell's `is_full` reader. The overflow policy is **reject** — [tryPush] at
/// capacity returns [QueuePushError.full] (elements are never silently
/// dropped); other backends may choose block / drop-oldest / drop-newest.
///
/// Serializes as a JSON array (element order = FIFO order) for conformance
/// fixture purposes, matching `lazily-spec/cell-model.md` § "Wire and snapshot
/// shape".
class VecDequeStorage<T> implements QueueStorage<T> {
  final ListQueue<T> _elements = ListQueue<T>();
  final int? _capacity;
  bool _closed = false;

  /// Create an unbounded storage (no capacity limit).
  VecDequeStorage() : _capacity = null;

  /// Create a bounded storage that rejects pushes once it holds [capacity]
  /// elements.
  ///
  /// Throws [ArgumentError] if [capacity] <= 0.
  VecDequeStorage.bounded(int capacity) : _capacity = capacity {
    if (capacity <= 0) {
      throw ArgumentError('VecDequeStorage capacity must be > 0');
    }
  }

  /// Create a storage from an initial snapshot (for fixture seeding / serde).
  VecDequeStorage.from({
    List<T>? elements,
    int? capacity,
    bool closed = false,
  })  : _capacity = capacity,
        _closed = closed {
    if (capacity != null && capacity <= 0) {
      throw ArgumentError('VecDequeStorage capacity must be > 0');
    }
    if (elements != null) _elements.addAll(elements);
  }

  @override
  QueuePushError? tryPush(T value) {
    if (_closed) return QueuePushError.closed;
    if (_capacity != null && _elements.length >= _capacity) {
      return QueuePushError.full;
    }
    _elements.addLast(value);
    return null;
  }

  @override
  QueuePopResult<T> tryPop() {
    if (_elements.isNotEmpty) {
      return QueuePopValue<T>(_elements.removeFirst());
    }
    return QueuePopFailed<T>(
      _closed ? QueuePopError.closed : QueuePopError.empty,
    );
  }

  @override
  T? peek() => _elements.isNotEmpty ? _elements.first : null;

  @override
  int len() => _elements.length;

  @override
  int? capacity() => _capacity;

  @override
  bool isClosed() => _closed;

  @override
  void close() {
    _closed = true;
  }

  /// Snapshot the buffered elements in FIFO order. Non-reactive — for
  /// debugging, snapshot/serde, and conformance-fixture verification.
  List<T> toList() => _elements.toList();
}

// ---------------------------------------------------------------------------
// QueueCell — the reactive shell
// ---------------------------------------------------------------------------

/// A reactive FIFO queue — SPSC primitive with an MPSC usage rule
/// (`#lzqueue`).
///
/// The reactive shell wraps a pluggable [QueueStorage] backend (default
/// [VecDequeStorage]); the shell owns the reader-kind version cells (`head` /
/// `len` / `is_empty` / `is_full` / `closed`) and invalidates by reader kind —
/// a push to a non-empty queue does NOT invalidate the `head` reader, a pop
/// does.
///
/// Construct via [QueueCell.unbounded] / [QueueCell.bounded] or the primary
/// constructor with a custom [QueueStorage] backend. Cheap to share — the same
/// [QueueCell] reference can be handed to producer and consumer closures.
///
/// Example::
///
///     final ctx = Context();
///     final q = QueueCell<String>.unbounded(ctx);
///     q.tryPush('a');
///     q.tryPush('b');
///     print(q.head());   // a
///     print(q.len());    // 2
///     final pop = q.tryPop();
///     print((pop as QueuePopValue).value); // a
class QueueCell<T> {
  /// Creates a reactive queue backed by [storage], bound to [ctx].
  QueueCell(this.ctx, this.storage) {
    final s = storage;
    _capacity = s.capacity();
    final cap = _capacity;
    // Demand-driven reader-kinds: memoized Slots deriving from storage (were
    // eagerly-Set Cells). Each re-derives on first read after invalidation; the
    // shell invalidates only the ones that provably changed on an op (see
    // [_invalidateReaders]). `closed` stays a Cell (a direct input, set by
    // [close]). The head Slot holds either [_noHead] (empty / no peek) or a real
    // element (typed `Object` because a Slot value here is never null).
    _headSlot = Slot<Object>(ctx, (_) => s.peek() ?? _noHead);
    _lenSlot = Slot<int>(ctx, (_) => s.len());
    _isEmptySlot = Slot<bool>(ctx, (_) => s.len() == 0);
    _isFullSlot = Slot<bool>(ctx, (_) => cap != null && s.len() >= cap);
    _closedCell = Cell<bool>(ctx, s.isClosed());
  }

  /// Create an unbounded queue (the default reference backend).
  factory QueueCell.unbounded(Context ctx) =>
      QueueCell<T>(ctx, VecDequeStorage<T>());

  /// Create a bounded queue with [capacity]. Exposes reactive backpressure
  /// via [isFull]: a pop that transitions full → not-full invalidates
  /// `is_full` readers.
  ///
  /// Throws [ArgumentError] if [capacity] <= 0.
  factory QueueCell.bounded(Context ctx, int capacity) =>
      QueueCell<T>(ctx, VecDequeStorage<T>.bounded(capacity));

  /// The context this queue belongs to.
  final Context ctx;

  /// The backing storage (exposed for storage-specific extensions like
  /// [VecDequeStorage.toList]).
  final QueueStorage<T> storage;

  // Demand-driven reader-kinds — memoized Slots deriving from storage. `closed`
  // stays a Cell (a direct input). See the constructor.
  late final Slot<Object> _headSlot;
  late final Slot<int> _lenSlot;
  late final Slot<bool> _isEmptySlot;
  late final Slot<bool> _isFullSlot;
  late final Cell<bool> _closedCell;

  // `capacity` is an optional, fixed backend capability — cached once.
  late final int? _capacity;

  /// Invalidate exactly the reader-kind Slots whose derived value provably
  /// changed on a successful op that took the queue from [lenBefore] to
  /// [lenAfter], in one atomic pass so an observer never sees a partial state.
  /// No reader value is derived here — invalidating a Slot only evicts its cache
  /// and cascades to dependents (each re-derives lazily on its next read), so an
  /// unobserved reader pays effectively nothing. [headChanged] is passed by the
  /// caller because head depends on op *direction*, not just `len` (a pop always
  /// changes head; a push changes it only from empty) — so no `peek` is needed.
  /// `closed` is never touched here: it changes only via [close].
  void _invalidateReaders(int lenBefore, int lenAfter, bool headChanged) {
    final changed = <Slot>[_lenSlot]; // len always changes on a successful op
    if ((lenBefore == 0) != (lenAfter == 0)) changed.add(_isEmptySlot);
    final cap = _capacity;
    if (cap != null && (lenBefore >= cap) != (lenAfter >= cap)) {
      changed.add(_isFullSlot);
    }
    if (headChanged) changed.add(_headSlot);
    ctx.invalidateSlots(changed);
  }

  /// Append [value] to the tail of the queue.
  ///
  /// Returns [QueuePushError.full] if bounded and at capacity (reject policy —
  /// the default [VecDequeStorage] never silently drops), or
  /// [QueuePushError.closed] if the queue is closed. Returns `null` on
  /// success. On error the queue state is unchanged and no reader is
  /// invalidated.
  ///
  /// Invalidates `head` (only when transitioning from empty), `len`, and
  /// `is_empty` readers as appropriate; `is_full` when transitioning onto
  /// capacity. Does not touch `closed`.
  QueuePushError? tryPush(T value) {
    final lenBefore = storage.len();
    final err = storage.tryPush(value);
    // Head changes on a push only when the queue was empty.
    if (err == null)
      _invalidateReaders(lenBefore, lenBefore + 1, lenBefore == 0);
    return err;
  }

  /// Remove and return the head element.
  ///
  /// Returns [QueuePopValue] on success, or [QueuePopFailed] carrying
  /// [QueuePopError.empty] if open and empty, or [QueuePopError.closed] if
  /// closed and empty. Pop on a closed *non-empty* queue drains (returns the
  /// next element).
  ///
  /// Invalidates `head` (always — the head value changes), `len`, and
  /// `is_empty` (when transitioning to empty) readers as appropriate;
  /// `is_full` when transitioning off capacity.
  QueuePopResult<T> tryPop() {
    final lenBefore = storage.len();
    final result = storage.tryPop();
    // A successful pop always advances head and decrements len.
    if (result is QueuePopValue<T>) {
      _invalidateReaders(lenBefore, lenBefore - 1, true);
    }
    return result;
  }

  /// Close the queue. Idempotent — closing an already-closed queue is a no-op
  /// (no invalidation). Terminal — once closed, a queue cannot be reopened.
  /// After close, [tryPush] returns [QueuePushError.closed]; [tryPop]
  /// continues to drain and returns [QueuePopError.closed] only once empty.
  ///
  /// Invalidates the `closed` reader only on the false → true transition.
  void close() {
    if (storage.isClosed()) return;
    storage.close();
    _closedCell.value = true;
  }

  // -- Reactive reader-kind reads -------------------------------------------

  /// Reactive read of the current head value. `null` when the queue is empty.
  /// A reader is invalidated when the head value *changes* — every pop, and a
  /// push only when transitioning from empty.
  T? head() {
    final v = _headSlot();
    return identical(v, _noHead) ? null : v as T;
  }

  /// Reactive read of the number of buffered elements. Invalidated whenever
  /// the count changes (every successful push/pop).
  int len() => _lenSlot();

  /// Reactive emptiness check. Invalidated only on the empty ↔ non-empty
  /// transition.
  bool isEmpty() => _isEmptySlot();

  /// Reactive fullness check (only meaningful when the backend is bounded).
  /// Invalidated on the full ↔ not-full transition — this is the backpressure
  /// signal: a producer observes [isFull] and backs off; a consumer's pop that
  /// transitions full → not-full invalidates the producer's [isFull]
  /// subscription and the producer resumes. For an unbounded backend this is
  /// always `false` and never invalidates.
  bool isFull() => _isFullSlot();

  /// Reactive read of the closed flag. Invalidated only on the open → closed
  /// transition.
  bool isClosed() => _closedCell.value;

  // -- Non-reactive storage access ------------------------------------------

  /// The backend's capacity, or `null` if unbounded. Cached at construction.
  int? capacity() => _capacity;

  /// Snapshot the buffered elements in FIFO order. Non-reactive — for
  /// debugging, snapshot/serde, and conformance-fixture verification. There
  /// is no reactive random-access `queue[N]` reader; per-position reactivity
  /// is the domain of [CellMap], not [QueueCell].
  ///
  /// Only [VecDequeStorage]-backed queues support this method; custom backends
  /// should expose their own snapshot via the public [storage] property.
  List<T> elements() {
    final s = storage;
    if (s is VecDequeStorage<T>) return s.toList();
    throw UnsupportedError(
      'elements() requires VecDequeStorage; use queue.storage directly for '
      'custom backends',
    );
  }
}

// ---------------------------------------------------------------------------
// TopicCell — broadcast log with independent subscriber cursors (`#lztopiccell`).
// ---------------------------------------------------------------------------

/// Whether a topic subscription survives disconnect and participates in GC.
enum TopicDurability { durable, ephemeral }

/// Result of subscribing a stable subscriber id.
enum TopicSubscribeOutcome { subscribed, reconnected, alreadySubscribed }

/// Serializable state for one topic subscriber.
final class TopicSubscriptionSnapshot {
  const TopicSubscriptionSnapshot({
    required this.subscriberId,
    required this.cursor,
    required this.durability,
    required this.connected,
  });

  final String subscriberId;
  final int cursor;
  final TopicDurability durability;
  final bool connected;
}

/// Serializable retained log and stable subscription table.
final class TopicSnapshot<T> {
  const TopicSnapshot({
    required this.baseOffset,
    required this.elements,
    required this.subscriptions,
  });

  final int baseOffset;
  final List<T> elements;
  final List<TopicSubscriptionSnapshot> subscriptions;
}

final class _TopicSubscription {
  _TopicSubscription(this.cursor, this.durability, this.connected);

  int cursor;
  final TopicDurability durability;
  bool connected;
}

/// Broadcast topic whose subscribers read and advance independent cursors.
///
/// Durable subscriptions keep their absolute cursor while offline. Ephemeral
/// subscriptions are removed on disconnect. [gc] drops only the prefix below
/// the slowest durable cursor and therefore invalidates no reader.
final class TopicCell<T> {
  TopicCell(this.ctx, [TopicSnapshot<T>? snapshot]) {
    if (snapshot != null) {
      if (snapshot.baseOffset < 0) {
        throw ArgumentError('topic base offset must be non-negative');
      }
      _baseOffset = snapshot.baseOffset;
      _elements.addAll(snapshot.elements);
      final tail = tailOffset;
      for (final saved in snapshot.subscriptions) {
        if (saved.cursor < _baseOffset || saved.cursor > tail) {
          throw ArgumentError(
              'topic subscription cursor is outside retained log');
        }
        if (saved.durability == TopicDurability.ephemeral && !saved.connected) {
          throw ArgumentError(
              'disconnected ephemeral topic subscription must be removed');
        }
        _subscriptions[saved.subscriberId] = _TopicSubscription(
          saved.cursor,
          saved.durability,
          saved.connected,
        );
        _ensureReader(saved.subscriberId);
      }
    }
  }

  final Context ctx;
  int _baseOffset = 0;
  final List<T> _elements = <T>[];
  final Map<String, _TopicSubscription> _subscriptions = {};
  final Map<String, Slot<List<T>>> _readers = {};

  int get baseOffset => _baseOffset;
  int get tailOffset => _baseOffset + _elements.length;

  Slot<List<T>> _ensureReader(String subscriberId) => _readers.putIfAbsent(
        subscriberId,
        () => Slot<List<T>>(ctx, (_) => readUntracked(subscriberId)),
      );

  void _invalidate(Iterable<String> subscriberIds) {
    final changed = <Slot>[];
    for (final id in subscriberIds) {
      final reader = _readers[id];
      if (reader != null) changed.add(reader);
    }
    if (changed.isNotEmpty) ctx.invalidateSlots(changed);
  }

  /// Start at the current tail or resume an offline durable cursor.
  TopicSubscribeOutcome subscribe(
    String subscriberId, [
    TopicDurability durability = TopicDurability.durable,
  ]) {
    final existing = _subscriptions[subscriberId];
    if (existing != null) {
      if (existing.connected) return TopicSubscribeOutcome.alreadySubscribed;
      if (existing.durability != TopicDurability.durable) {
        throw StateError('only durable subscriptions can reconnect');
      }
      existing.connected = true;
      _invalidate([subscriberId]);
      return TopicSubscribeOutcome.reconnected;
    }
    _subscriptions[subscriberId] =
        _TopicSubscription(tailOffset, durability, true);
    _ensureReader(subscriberId);
    return TopicSubscribeOutcome.subscribed;
  }

  void reconnect(String subscriberId) {
    final subscription = _subscriptions[subscriberId];
    if (subscription == null ||
        subscription.durability != TopicDurability.durable) {
      throw StateError('durable subscription not found');
    }
    if (!subscription.connected) {
      subscription.connected = true;
      _invalidate([subscriberId]);
    }
  }

  void disconnect(String subscriberId) {
    final subscription = _subscriptions[subscriberId];
    if (subscription == null || !subscription.connected) return;
    subscription.connected = false;
    if (subscription.durability == TopicDurability.ephemeral) {
      _subscriptions.remove(subscriberId);
    }
    _invalidate([subscriberId]);
  }

  /// Append a value and independently invalidate every connected reader.
  int publish(T value) {
    final offset = tailOffset;
    _elements.add(value);
    _invalidate(
      _subscriptions.entries
          .where((entry) => entry.value.connected)
          .map((entry) => entry.key),
    );
    return offset;
  }

  List<T> readUntracked(String subscriberId) {
    final subscription = _subscriptions[subscriberId];
    if (subscription == null || !subscription.connected) {
      return List<T>.unmodifiable(const []);
    }
    final start = subscription.cursor - _baseOffset;
    return List<T>.unmodifiable(_elements.sublist(start));
  }

  /// Reactively read the retained suffix at this subscriber's cursor.
  List<T> readStream(String subscriberId) => _ensureReader(subscriberId)();

  T? read(String subscriberId) {
    final stream = readStream(subscriberId);
    return stream.isEmpty ? null : stream.first;
  }

  int advance(String subscriberId, [int count = 1]) {
    final subscription = _subscriptions[subscriberId];
    if (subscription == null || count < 0) {
      throw StateError('invalid topic cursor advance');
    }
    if (!subscription.connected || subscription.cursor == tailOffset) {
      return subscription.cursor;
    }
    if (subscription.cursor + count > tailOffset) {
      throw StateError('invalid topic cursor advance');
    }
    if (count > 0) {
      subscription.cursor += count;
      _invalidate([subscriberId]);
    }
    return subscription.cursor;
  }

  /// Remove the prefix below all durable cursors without invalidating readers.
  int gc() {
    var frontier = tailOffset;
    for (final subscription in _subscriptions.values) {
      if (subscription.durability == TopicDurability.durable &&
          subscription.cursor < frontier) {
        frontier = subscription.cursor;
      }
    }
    final removed = frontier - _baseOffset;
    _elements.removeRange(0, removed);
    _baseOffset = frontier;
    return removed;
  }

  /// Model a process restart; persisted state and reader values are stable.
  void restart() {}

  List<T> elements() => List<T>.unmodifiable(_elements);

  TopicSubscriptionSnapshot? subscription(String subscriberId) {
    final subscription = _subscriptions[subscriberId];
    if (subscription == null) return null;
    return TopicSubscriptionSnapshot(
      subscriberId: subscriberId,
      cursor: subscription.cursor,
      durability: subscription.durability,
      connected: subscription.connected,
    );
  }

  Slot<List<T>> readerHandle(String subscriberId) =>
      _ensureReader(subscriberId);

  TopicSnapshot<T> snapshot() => TopicSnapshot<T>(
        baseOffset: _baseOffset,
        elements: List<T>.unmodifiable(_elements),
        subscriptions: List<TopicSubscriptionSnapshot>.unmodifiable(
          _subscriptions.entries.map(
            (entry) => TopicSubscriptionSnapshot(
              subscriberId: entry.key,
              cursor: entry.value.cursor,
              durability: entry.value.durability,
              connected: entry.value.connected,
            ),
          ),
        ),
      );
}

// `WorkQueueCell` — N consumers compete for elements from a shared FIFO;
//   each element is delivered to exactly one consumer (exclusive handoff).
//   This requires an authority (designated leader peer) to serialize
//   pop-assignment — pure CRDT cannot provide it. Lands with the
//   distributed-queue PRD Phase 2 (consensus core). Formal stub:
//   `lazily-formal/LazilyFormal/WorkQueueCell.lean`.
