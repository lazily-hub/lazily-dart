import 'dart:collection';

import 'core.dart';

/// A stable logical item. [attempts] is the number of completed claims.
final class WorkQueueItem<T> {
  const WorkQueueItem(this.itemId, this.value, this.attempts);

  final int itemId;
  final T value;
  final int attempts;
}

/// One exclusive leased delivery of an item to a worker.
final class WorkQueueDelivery<T> {
  const WorkQueueDelivery({
    required this.deliveryId,
    required this.itemId,
    required this.value,
    required this.worker,
    required this.attempt,
    required this.deadline,
  });

  final int deliveryId;
  final int itemId;
  final T value;
  final String worker;
  final int attempt;
  final int deadline;
}

enum WorkQueueDeadLetterReason { nack, expired }

final class WorkQueueDeadLetter<T> {
  const WorkQueueDeadLetter({
    required this.itemId,
    required this.value,
    required this.attempts,
    required this.reason,
  });

  final int itemId;
  final T value;
  final int attempts;
  final WorkQueueDeadLetterReason reason;
}

final class WorkQueueReaderHandles {
  const WorkQueueReaderHandles({
    required this.pendingLen,
    required this.isEmpty,
    required this.inFlightLen,
    required this.deadLetterLen,
  });

  final Slot<int> pendingLen;
  final Slot<bool> isEmpty;
  final Slot<int> inFlightLen;
  final Slot<int> deadLetterLen;
}

/// Process-local competing-consumer queue with leased exclusive claims.
///
/// Items keep their ids across retries while every claim gets a new delivery
/// id. Failed deliveries requeue at the tail until [maxDeliveries] is reached,
/// then move to the dead-letter list. A lease remains live at its deadline and
/// expires only when `deadline < now`.
///
/// This object is a local serialization point. Distributed/HA deployments must
/// place a consensus-backed leader or adapter in front of it.
final class WorkQueueCell<T> {
  WorkQueueCell(
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
    _pendingLen = Slot<int>(ctx, (_) => _pending.length);
    _isEmpty = Slot<bool>(ctx, (_) => _pending.isEmpty);
    _inFlightLen = Slot<int>(ctx, (_) => _inFlight.length);
    _deadLetterLen = Slot<int>(ctx, (_) => _deadLetters.length);
  }

  final Context ctx;
  final int visibilityTimeout;
  final int maxDeliveries;
  final Queue<WorkQueueItem<T>> _pending = Queue<WorkQueueItem<T>>();
  final Map<int, WorkQueueDelivery<T>> _inFlight = {};
  final List<WorkQueueDeadLetter<T>> _deadLetters = [];
  int _nextItemId = 0;
  int _nextDeliveryId = 0;
  late final Slot<int> _pendingLen;
  late final Slot<bool> _isEmpty;
  late final Slot<int> _inFlightLen;
  late final Slot<int> _deadLetterLen;

  (int, int, int) _counts() =>
      (_pending.length, _inFlight.length, _deadLetters.length);

  void _invalidate((int, int, int) before) {
    final changed = <Slot>[];
    if (before.$1 != _pending.length) changed.add(_pendingLen);
    if ((before.$1 == 0) != _pending.isEmpty) changed.add(_isEmpty);
    if (before.$2 != _inFlight.length) changed.add(_inFlightLen);
    if (before.$3 != _deadLetters.length) changed.add(_deadLetterLen);
    if (changed.isNotEmpty) ctx.invalidateSlots(changed);
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

  int pendingLen() => _pendingLen();
  bool isEmpty() => _isEmpty();
  int inFlightLen() => _inFlightLen();
  int deadLetterLen() => _deadLetterLen();

  WorkQueueReaderHandles readerHandles() => WorkQueueReaderHandles(
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
