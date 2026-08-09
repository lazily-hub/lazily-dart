import 'dart:convert';
import 'dart:io';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

/// Corpus-relative fixture ids. Root resolution — the
/// `LAZILY_SPEC_CONFORMANCE_DIR` override, the sibling-first-then-mirror
/// ordering, and the fail-closed behaviour when an explicit override cannot be
/// read — lives in `conformance_manifest.dart` (#lzoverrideallrunners).
const _family = 'collections';

Map<String, dynamic> workQueueInitial(String name) {
  final path = specFixturePathOrNull('$_family/$name');
  expect(path, isNotNull, reason: '$name is declared but absent');
  final fixture =
      attributeFixture(jsonDecode(File(path!).specReadAsStringSync()))
          as Map<String, dynamic>;
  return fixture['initial'] as Map<String, dynamic>;
}

void materialize(WorkQueueCell<String> queue) {
  queue.pendingLen();
  queue.isEmpty();
  queue.inFlightLen();
  queue.deadLetterLen();
}

void expectInvalidated(
  WorkQueueCell<String> queue, {
  bool pendingLen = false,
  bool isEmpty = false,
  bool inFlightLen = false,
  bool deadLetterLen = false,
}) {
  final handles = queue.readerHandles();
  expect(handles.pendingLen.peek == null, pendingLen);
  expect(handles.isEmpty.peek == null, isEmpty);
  expect(handles.inFlightLen.peek == null, inFlightLen);
  expect(handles.deadLetterLen.peek == null, deadLetterLen);
  materialize(queue);
}

void main() {
  test('competing delivery fixture', () {
    final initial = workQueueInitial('workqueue_competing_delivery.json');
    final queue = WorkQueueCell<String>(
      Context(),
      visibilityTimeout: initial['visibility_timeout'] as int,
      maxDeliveries: initial['max_deliveries'] as int,
    );
    materialize(queue);

    expect(queue.push('a'), 0);
    expectInvalidated(queue, pendingLen: true, isEmpty: true);
    expect(queue.push('b'), 1);
    expectInvalidated(queue, pendingLen: true);

    final first = queue.claim('alpha', 100)!;
    expect(
      (
        first.deliveryId,
        first.itemId,
        first.attempt,
        first.deadline,
      ),
      (0, 0, 1, 110),
    );
    expectInvalidated(queue, pendingLen: true, inFlightLen: true);
    final second = queue.claim('beta', 100)!;
    expect(
      (
        second.deliveryId,
        second.itemId,
        second.attempt,
        second.deadline,
      ),
      (1, 1, 1, 110),
    );
    expectInvalidated(
      queue,
      pendingLen: true,
      isEmpty: true,
      inFlightLen: true,
    );
    expect(queue.claim('gamma', 100), isNull);
    expectInvalidated(queue);
    expect(queue.ack('alpha', second.deliveryId), isFalse);
    expectInvalidated(queue);
    expect(queue.ack('beta', second.deliveryId), isTrue);
    expectInvalidated(queue, inFlightLen: true);
    expect(queue.nack('alpha', first.deliveryId), isTrue);
    expectInvalidated(
      queue,
      pendingLen: true,
      isEmpty: true,
      inFlightLen: true,
    );

    final retry = queue.claim('gamma', 105)!;
    expect(
      (
        retry.deliveryId,
        retry.itemId,
        retry.attempt,
        retry.deadline,
      ),
      (2, 0, 2, 115),
    );
    expectInvalidated(
      queue,
      pendingLen: true,
      isEmpty: true,
      inFlightLen: true,
    );
    expect(queue.ack('gamma', retry.deliveryId), isTrue);
    expectInvalidated(queue, inFlightLen: true);
  });

  test('visibility timeout and dead-letter fixture', () {
    final initial = workQueueInitial('workqueue_lease_deadletter.json');
    final queue = WorkQueueCell<String>(
      Context(),
      visibilityTimeout: initial['visibility_timeout'] as int,
      maxDeliveries: initial['max_deliveries'] as int,
    );
    materialize(queue);
    queue.push('poison');
    expectInvalidated(queue, pendingLen: true, isEmpty: true);
    final first = queue.claim('worker-1', 0)!;
    expect(first.deadline, 10);
    expectInvalidated(
      queue,
      pendingLen: true,
      isEmpty: true,
      inFlightLen: true,
    );
    expect(queue.reapExpired(10), 0);
    expectInvalidated(queue);
    expect(queue.reapExpired(11), 1);
    expectInvalidated(
      queue,
      pendingLen: true,
      isEmpty: true,
      inFlightLen: true,
    );
    final second = queue.claim('worker-2', 11)!;
    expect((second.attempt, second.deadline), (2, 21));
    expectInvalidated(
      queue,
      pendingLen: true,
      isEmpty: true,
      inFlightLen: true,
    );
    expect(queue.reapExpired(21), 0);
    expectInvalidated(queue);
    expect(queue.reapExpired(22), 1);
    expectInvalidated(queue, inFlightLen: true, deadLetterLen: true);

    final dead = queue.deadLetterItems().single;
    expect(dead.itemId, 0);
    expect(dead.attempts, 2);
    expect(dead.reason, WorkQueueDeadLetterReason.expired);
    expect(queue.claim('worker-3', 22), isNull);
    expectInvalidated(queue);
  });
}
