/// Queue-family shells on [AsyncContext].
///
/// Queue storage, cursors, and lease decisions are already local and
/// synchronous, so the Core API is deliberately not coloured with `Future`.
/// Reader kinds use [AsyncContext.computed]: synchronous memoized derivations
/// living on the async graph, cleared atomically with
/// [AsyncContext.clearSlots].
library;

import 'dart:collection';

import 'async_context.dart';
import 'queue.dart';
import 'work_queue.dart';

/// Reader nodes owned by an [AsyncQueueCell].
final class AsyncQueueReaderHandles<T> {
  const AsyncQueueReaderHandles({
    required this.head,
    required this.len,
    required this.isEmpty,
    required this.isFull,
    required this.isClosed,
  });

  final AsyncSlotHandle<T?> head;
  final AsyncSlotHandle<int> len;
  final AsyncSlotHandle<bool> isEmpty;
  final AsyncSlotHandle<bool> isFull;
  final AsyncCellHandle<bool> isClosed;
}

/// Async-graph reactive FIFO with synchronous queue operations.
final class AsyncQueueCell<T> {
  AsyncQueueCell(this.ctx, this.storage) {
    _capacity = storage.capacity();
    final cap = _capacity;
    _head = ctx.computed<T?>((_) => storage.peek());
    _len = ctx.computed<int>((_) => storage.len());
    _isEmpty = ctx.computed<bool>((_) => storage.len() == 0);
    _isFull = ctx.computed<bool>((_) => cap != null && storage.len() >= cap);
    _isClosed = ctx.cell<bool>(storage.isClosed());
  }

  factory AsyncQueueCell.unbounded(AsyncContext ctx) =>
      AsyncQueueCell<T>(ctx, VecDequeStorage<T>());

  factory AsyncQueueCell.bounded(AsyncContext ctx, int capacity) =>
      AsyncQueueCell<T>(ctx, VecDequeStorage<T>.bounded(capacity));

  final AsyncContext ctx;
  final QueueStorage<T> storage;

  late final int? _capacity;
  late final AsyncSlotHandle<T?> _head;
  late final AsyncSlotHandle<int> _len;
  late final AsyncSlotHandle<bool> _isEmpty;
  late final AsyncSlotHandle<bool> _isFull;
  late final AsyncCellHandle<bool> _isClosed;

  void _invalidateReaders(int before, int after, bool headChanged) {
    final changed = <AsyncSlotHandle<dynamic>>[_len];
    if ((before == 0) != (after == 0)) changed.add(_isEmpty);
    final cap = _capacity;
    if (cap != null && (before >= cap) != (after >= cap)) {
      changed.add(_isFull);
    }
    if (headChanged) changed.add(_head);
    ctx.clearSlots(changed);
  }

  QueuePushError? tryPush(T value) {
    final before = storage.len();
    final error = storage.tryPush(value);
    if (error == null) {
      _invalidateReaders(before, before + 1, before == 0);
    }
    return error;
  }

  QueuePopResult<T> tryPop() {
    final before = storage.len();
    final result = storage.tryPop();
    if (result is QueuePopValue<T>) {
      _invalidateReaders(before, before - 1, true);
    }
    return result;
  }

  void close() {
    if (storage.isClosed()) return;
    storage.close();
    ctx.setCell(_isClosed, true);
  }

  T? head([AsyncComputeContext? cx]) =>
      cx == null ? ctx.get(_head) : cx.get(_head);

  int len([AsyncComputeContext? cx]) =>
      cx == null ? ctx.get(_len) : cx.get(_len);

  bool isEmpty([AsyncComputeContext? cx]) =>
      cx == null ? ctx.get(_isEmpty) : cx.get(_isEmpty);

  bool isFull([AsyncComputeContext? cx]) =>
      cx == null ? ctx.get(_isFull) : cx.get(_isFull);

  bool isClosed([AsyncComputeContext? cx]) =>
      cx == null ? ctx.getCell(_isClosed) : cx.getCell(_isClosed);

  int? capacity() => _capacity;

  List<T> elements() {
    final current = storage;
    if (current is VecDequeStorage<T>) return current.toList();
    throw UnsupportedError(
      'elements() requires VecDequeStorage; use queue.storage directly for '
      'custom backends',
    );
  }

  AsyncQueueReaderHandles<T> readerHandles() => AsyncQueueReaderHandles<T>(
        head: _head,
        len: _len,
        isEmpty: _isEmpty,
        isFull: _isFull,
        isClosed: _isClosed,
      );
}

final class _AsyncTopicSubscription {
  _AsyncTopicSubscription(this.cursor, this.durability, this.connected);

  int cursor;
  final TopicDurability durability;
  bool connected;
}

/// Async-graph broadcast topic with independent absolute cursors.
final class AsyncTopicCell<T> {
  AsyncTopicCell(this.ctx, [TopicSnapshot<T>? snapshot]) {
    if (snapshot == null) return;
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
          'disconnected ephemeral topic subscription must be removed',
        );
      }
      _subscriptions[saved.subscriberId] = _AsyncTopicSubscription(
        saved.cursor,
        saved.durability,
        saved.connected,
      );
      _ensureReader(saved.subscriberId);
    }
  }

  final AsyncContext ctx;
  int _baseOffset = 0;
  final List<T> _elements = <T>[];
  final Map<String, _AsyncTopicSubscription> _subscriptions = {};
  final Map<String, AsyncSlotHandle<List<T>>> _readers = {};

  int get baseOffset => _baseOffset;
  int get tailOffset => _baseOffset + _elements.length;

  AsyncSlotHandle<List<T>> _ensureReader(String subscriberId) =>
      _readers.putIfAbsent(
        subscriberId,
        () => ctx.computed<List<T>>((_) => readUntracked(subscriberId)),
      );

  void _invalidate(Iterable<String> subscriberIds) {
    final changed = <AsyncSlotHandle<dynamic>>[];
    for (final id in subscriberIds) {
      final reader = _readers[id];
      if (reader != null) changed.add(reader);
    }
    ctx.clearSlots(changed);
  }

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
        _AsyncTopicSubscription(tailOffset, durability, true);
    _ensureReader(subscriberId);
    _invalidate([subscriberId]);
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
    return List<T>.unmodifiable(
      _elements.sublist(subscription.cursor - _baseOffset),
    );
  }

  List<T> readStream(
    String subscriberId, [
    AsyncComputeContext? cx,
  ]) {
    final reader = _ensureReader(subscriberId);
    return cx == null ? ctx.get(reader) : cx.get(reader);
  }

  T? read(String subscriberId, [AsyncComputeContext? cx]) {
    final stream = readStream(subscriberId, cx);
    return stream.isEmpty ? null : stream.first;
  }

  T? advance(String subscriberId, [int count = 1]) {
    final subscription = _subscriptions[subscriberId];
    if (subscription == null || count < 0) {
      throw StateError('invalid topic cursor advance');
    }
    if (count == 0 ||
        !subscription.connected ||
        subscription.cursor == tailOffset) {
      return null;
    }
    if (subscription.cursor + count > tailOffset) {
      throw StateError('invalid topic cursor advance');
    }
    final value = _elements[subscription.cursor - _baseOffset];
    subscription.cursor += count;
    _invalidate([subscriberId]);
    return value;
  }

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

  AsyncSlotHandle<List<T>> readerHandle(String subscriberId) =>
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

/// Reader nodes owned by an [AsyncWorkQueueCell].
final class AsyncWorkQueueReaderHandles {
  const AsyncWorkQueueReaderHandles({
    required this.pendingLen,
    required this.isEmpty,
    required this.inFlightLen,
    required this.deadLetterLen,
  });

  final AsyncSlotHandle<int> pendingLen;
  final AsyncSlotHandle<bool> isEmpty;
  final AsyncSlotHandle<int> inFlightLen;
  final AsyncSlotHandle<int> deadLetterLen;
}

/// Async-graph competing-consumer work queue.
final class AsyncWorkQueueCell<T> {
  AsyncWorkQueueCell(
    this.ctx, {
    required this.visibilityTimeout,
    required this.maxDeliveries,
  }) {
    if (visibilityTimeout <= 0) {
      throw ArgumentError.value(
        visibilityTimeout,
        'visibilityTimeout',
        'must be positive',
      );
    }
    if (maxDeliveries < 1) {
      throw ArgumentError.value(
        maxDeliveries,
        'maxDeliveries',
        'must be at least one',
      );
    }
    _pendingLen = ctx.computed<int>((_) => _pending.length);
    _isEmpty = ctx.computed<bool>((_) => _pending.isEmpty);
    _inFlightLen = ctx.computed<int>((_) => _inFlight.length);
    _deadLetterLen = ctx.computed<int>((_) => _deadLetters.length);
  }

  final AsyncContext ctx;
  final int visibilityTimeout;
  final int maxDeliveries;
  final Queue<WorkQueueItem<T>> _pending = Queue<WorkQueueItem<T>>();
  final Map<int, WorkQueueDelivery<T>> _inFlight = {};
  final List<WorkQueueDeadLetter<T>> _deadLetters = [];
  int _nextItemId = 0;
  int _nextDeliveryId = 0;
  late final AsyncSlotHandle<int> _pendingLen;
  late final AsyncSlotHandle<bool> _isEmpty;
  late final AsyncSlotHandle<int> _inFlightLen;
  late final AsyncSlotHandle<int> _deadLetterLen;

  (int, int, int) _counts() =>
      (_pending.length, _inFlight.length, _deadLetters.length);

  void _invalidate((int, int, int) before) {
    final changed = <AsyncSlotHandle<dynamic>>[];
    if (before.$1 != _pending.length) changed.add(_pendingLen);
    if ((before.$1 == 0) != _pending.isEmpty) changed.add(_isEmpty);
    if (before.$2 != _inFlight.length) changed.add(_inFlightLen);
    if (before.$3 != _deadLetters.length) changed.add(_deadLetterLen);
    ctx.clearSlots(changed);
  }

  int push(T value) {
    final before = _counts();
    final itemId = _nextItemId++;
    _pending.addLast(WorkQueueItem<T>(itemId, value, 0));
    _invalidate(before);
    return itemId;
  }

  WorkQueueDelivery<T>? claim(String worker, int now) {
    if (now < 0) throw ArgumentError.value(now, 'now', 'must be non-negative');
    if (_pending.isEmpty) return null;
    final before = _counts();
    final item = _pending.removeFirst();
    final delivery = WorkQueueDelivery<T>(
      deliveryId: _nextDeliveryId++,
      itemId: item.itemId,
      value: item.value,
      worker: worker,
      attempt: item.attempts + 1,
      deadline: now + visibilityTimeout,
    );
    _inFlight[delivery.deliveryId] = delivery;
    _invalidate(before);
    return delivery;
  }

  bool ack(String worker, int deliveryId) {
    final delivery = _inFlight[deliveryId];
    if (delivery == null || delivery.worker != worker) return false;
    final before = _counts();
    _inFlight.remove(deliveryId);
    _invalidate(before);
    return true;
  }

  void _fail(
    WorkQueueDelivery<T> delivery,
    WorkQueueDeadLetterReason reason,
  ) {
    if (delivery.attempt >= maxDeliveries) {
      _deadLetters.add(
        WorkQueueDeadLetter<T>(
          itemId: delivery.itemId,
          value: delivery.value,
          attempts: delivery.attempt,
          reason: reason,
        ),
      );
    } else {
      _pending.addLast(
        WorkQueueItem<T>(delivery.itemId, delivery.value, delivery.attempt),
      );
    }
  }

  bool nack(String worker, int deliveryId) {
    final delivery = _inFlight[deliveryId];
    if (delivery == null || delivery.worker != worker) return false;
    final before = _counts();
    _inFlight.remove(deliveryId);
    _fail(delivery, WorkQueueDeadLetterReason.nack);
    _invalidate(before);
    return true;
  }

  int reapExpired(int now) {
    if (now < 0) throw ArgumentError.value(now, 'now', 'must be non-negative');
    final expired = _inFlight.values
        .where((delivery) => delivery.deadline < now)
        .map((delivery) => delivery.deliveryId)
        .toList()
      ..sort();
    if (expired.isEmpty) return 0;
    final before = _counts();
    for (final deliveryId in expired) {
      _fail(
        _inFlight.remove(deliveryId)!,
        WorkQueueDeadLetterReason.expired,
      );
    }
    _invalidate(before);
    return expired.length;
  }

  int pendingLen([AsyncComputeContext? cx]) =>
      cx == null ? ctx.get(_pendingLen) : cx.get(_pendingLen);

  bool isEmpty([AsyncComputeContext? cx]) =>
      cx == null ? ctx.get(_isEmpty) : cx.get(_isEmpty);

  int inFlightLen([AsyncComputeContext? cx]) =>
      cx == null ? ctx.get(_inFlightLen) : cx.get(_inFlightLen);

  int deadLetterLen([AsyncComputeContext? cx]) =>
      cx == null ? ctx.get(_deadLetterLen) : cx.get(_deadLetterLen);

  AsyncWorkQueueReaderHandles readerHandles() => AsyncWorkQueueReaderHandles(
        pendingLen: _pendingLen,
        isEmpty: _isEmpty,
        inFlightLen: _inFlightLen,
        deadLetterLen: _deadLetterLen,
      );

  List<WorkQueueItem<T>> pendingItems() => List.unmodifiable(_pending);

  List<WorkQueueDelivery<T>> inFlightDeliveries() {
    final deliveries = _inFlight.values.toList()
      ..sort((a, b) => a.deliveryId.compareTo(b.deliveryId));
    return List.unmodifiable(deliveries);
  }

  List<WorkQueueDeadLetter<T>> deadLetterItems() =>
      List.unmodifiable(_deadLetters);
}
