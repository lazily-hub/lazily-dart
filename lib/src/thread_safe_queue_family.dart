/// Queue-family shells for the single-isolate [ThreadSafeContext] flavor.
///
/// Dart has no shared mutable heap between isolates. Its shipped thread-safe
/// surface is therefore a reentrant run-to-completion guard around [Context],
/// and these shells deliberately reuse the settled single-threaded algebra
/// while ensuring every operation and read runs through that guard. Each
/// instance still mints its own reader nodes on the wrapped context's graph.
library;

import 'core.dart';
import 'queue.dart';
import 'thread_safe.dart';
import 'work_queue.dart';

/// Run-to-completion reactive FIFO.
final class ThreadSafeQueueCell<T> {
  ThreadSafeQueueCell(this.ctx, QueueStorage<T> storage)
      : _inner = QueueCell<T>(ctx.context, storage);

  factory ThreadSafeQueueCell.unbounded(ThreadSafeContext ctx) =>
      ThreadSafeQueueCell<T>(ctx, VecDequeStorage<T>());

  factory ThreadSafeQueueCell.bounded(ThreadSafeContext ctx, int capacity) =>
      ThreadSafeQueueCell<T>(ctx, VecDequeStorage<T>.bounded(capacity));

  final ThreadSafeContext ctx;
  final QueueCell<T> _inner;

  QueueStorage<T> get storage => _inner.storage;

  QueuePushError? tryPush(T value) => ctx.read((_) => _inner.tryPush(value));

  QueuePopResult<T> tryPop() => ctx.read((_) => _inner.tryPop());

  void close() => ctx.withLock((_) => _inner.close());

  T? head([Compute? cx]) => ctx.read((_) => _inner.head(cx));

  int len([Compute? cx]) => ctx.read((_) => _inner.len(cx));

  bool isEmpty([Compute? cx]) => ctx.read((_) => _inner.isEmpty(cx));

  bool isFull([Compute? cx]) => ctx.read((_) => _inner.isFull(cx));

  bool isClosed([Compute? cx]) => ctx.read((_) => _inner.isClosed(cx));

  int? capacity() => ctx.read((_) => _inner.capacity());

  List<T> elements() => ctx.read((_) => _inner.elements());
}

/// Run-to-completion broadcast topic with independent cursors.
final class ThreadSafeTopicCell<T> {
  ThreadSafeTopicCell(this.ctx, [TopicSnapshot<T>? snapshot])
      : _inner = TopicCell<T>(ctx.context, snapshot);

  final ThreadSafeContext ctx;
  final TopicCell<T> _inner;

  int get baseOffset => ctx.read((_) => _inner.baseOffset);

  int get tailOffset => ctx.read((_) => _inner.tailOffset);

  TopicSubscribeOutcome subscribe(
    String subscriberId, [
    TopicDurability durability = TopicDurability.durable,
  ]) =>
      ctx.read((_) => _inner.subscribe(subscriberId, durability));

  void reconnect(String subscriberId) =>
      ctx.withLock((_) => _inner.reconnect(subscriberId));

  void disconnect(String subscriberId) =>
      ctx.withLock((_) => _inner.disconnect(subscriberId));

  int publish(T value) => ctx.read((_) => _inner.publish(value));

  List<T> readStream(String subscriberId, [Compute? cx]) =>
      ctx.read((_) => _inner.readStream(subscriberId, cx));

  T? read(String subscriberId, [Compute? cx]) =>
      ctx.read((_) => _inner.read(subscriberId, cx));

  T? advance(String subscriberId, [int count = 1]) =>
      ctx.read((_) => _inner.advance(subscriberId, count));

  int gc() => ctx.read((_) => _inner.gc());

  void restart() => ctx.withLock((_) => _inner.restart());

  List<T> elements() => ctx.read((_) => _inner.elements());

  TopicSubscriptionSnapshot? subscription(String subscriberId) =>
      ctx.read((_) => _inner.subscription(subscriberId));

  Slot<List<T>> readerHandle(String subscriberId) =>
      ctx.read((_) => _inner.readerHandle(subscriberId));

  TopicSnapshot<T> snapshot() => ctx.read((_) => _inner.snapshot());
}

/// Run-to-completion competing-consumer work queue.
final class ThreadSafeWorkQueueCell<T> {
  ThreadSafeWorkQueueCell(
    this.ctx, {
    required int visibilityTimeout,
    required int maxDeliveries,
  }) : _inner = WorkQueueCell<T>(
          ctx.context,
          visibilityTimeout: visibilityTimeout,
          maxDeliveries: maxDeliveries,
        );

  final ThreadSafeContext ctx;
  final WorkQueueCell<T> _inner;

  int get visibilityTimeout => _inner.visibilityTimeout;

  int get maxDeliveries => _inner.maxDeliveries;

  int push(T value) => ctx.read((_) => _inner.push(value));

  WorkQueueDelivery<T>? claim(String worker, int now) =>
      ctx.read((_) => _inner.claim(worker, now));

  bool ack(String worker, int deliveryId) =>
      ctx.read((_) => _inner.ack(worker, deliveryId));

  bool nack(String worker, int deliveryId) =>
      ctx.read((_) => _inner.nack(worker, deliveryId));

  int reapExpired(int now) => ctx.read((_) => _inner.reapExpired(now));

  int pendingLen([Compute? cx]) => ctx.read((_) => _inner.pendingLen(cx));

  bool isEmpty([Compute? cx]) => ctx.read((_) => _inner.isEmpty(cx));

  int inFlightLen([Compute? cx]) => ctx.read((_) => _inner.inFlightLen(cx));

  int deadLetterLen([Compute? cx]) => ctx.read((_) => _inner.deadLetterLen(cx));

  WorkQueueReaderHandles readerHandles() =>
      ctx.read((_) => _inner.readerHandles());

  List<WorkQueueItem<T>> pendingItems() =>
      ctx.read((_) => _inner.pendingItems());

  List<WorkQueueDelivery<T>> inFlightDeliveries() =>
      ctx.read((_) => _inner.inFlightDeliveries());

  List<WorkQueueDeadLetter<T>> deadLetterItems() =>
      ctx.read((_) => _inner.deadLetterItems());
}
