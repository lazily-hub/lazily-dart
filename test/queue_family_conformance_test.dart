import 'dart:convert';
import 'dart:io';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

const _queueFixtures = [
  'queuecell_spsc_push_pop.json',
  'queuecell_popped_head_observation.json',
  'queuecell_mpsc_multi_writer.json',
  'queuecell_bounded_backpressure.json',
  'queuecell_closure_lifecycle.json',
];

const _topicFixtures = [
  'topiccell_broadcast_cursor_isolation.json',
  'topiccell_durable_replay_gc.json',
  'topiccell_ephemeral_lifecycle.json',
  'topiccell_offline_tail_bounds.json',
];

const _workFixtures = [
  'workqueue_competing_delivery.json',
  'workqueue_lease_deadletter.json',
];

enum _Flavor { singleThreaded, threadSafe, async }

extension on _Flavor {
  String get label => switch (this) {
        _Flavor.singleThreaded => 'single-threaded',
        _Flavor.threadSafe => 'thread-safe',
        _Flavor.async => 'async',
      };
}

const _ledger = <({String primitive, _Flavor flavor, String marker})>[
  (
    primitive: 'QueueCell',
    flavor: _Flavor.singleThreaded,
    marker: 'class QueueCell',
  ),
  (
    primitive: 'QueueCell',
    flavor: _Flavor.threadSafe,
    marker: 'class ThreadSafeQueueCell',
  ),
  (
    primitive: 'QueueCell',
    flavor: _Flavor.async,
    marker: 'class AsyncQueueCell',
  ),
  (
    primitive: 'TopicCell',
    flavor: _Flavor.singleThreaded,
    marker: 'class TopicCell',
  ),
  (
    primitive: 'TopicCell',
    flavor: _Flavor.threadSafe,
    marker: 'class ThreadSafeTopicCell',
  ),
  (
    primitive: 'TopicCell',
    flavor: _Flavor.async,
    marker: 'class AsyncTopicCell',
  ),
  (
    primitive: 'WorkQueueCell',
    flavor: _Flavor.singleThreaded,
    marker: 'class WorkQueueCell',
  ),
  (
    primitive: 'WorkQueueCell',
    flavor: _Flavor.threadSafe,
    marker: 'class ThreadSafeWorkQueueCell',
  ),
  (
    primitive: 'WorkQueueCell',
    flavor: _Flavor.async,
    marker: 'class AsyncWorkQueueCell',
  ),
];

/// Corpus slice this runner replays. Root resolution — the
/// `LAZILY_SPEC_CONFORMANCE_DIR` override, the sibling-first-then-mirror
/// ordering, and the fail-closed behaviour when an explicit override cannot be
/// read — lives in `conformance_manifest.dart` (#lzoverrideallrunners). An
/// absent corpus still throws: a skipped flavor replay would report a false
/// green.
Directory _fixtureDir() => specFamilyDir('collections');

Map<String, dynamic> _fixture(String name) {
  final file = File('${_fixtureDir().path}/$name');
  expect(file.existsSync(), isTrue, reason: '$name is declared but absent');
  return attributeFixture(jsonDecode(file.specReadAsStringSync()))
      as Map<String, dynamic>;
}

String _sources() {
  final out = StringBuffer();
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      out.write(entity.specReadAsStringSync());
    }
  }
  return out.toString();
}

List<Map<String, dynamic>> _steps(Map<String, dynamic> fixture, String name) {
  final steps = (fixture['steps'] as List).cast<Map<String, dynamic>>();
  expect(steps, isNotEmpty,
      reason: '$name has zero steps; loading it is not a replay');
  for (var i = 0; i < steps.length; i++) {
    final step = steps[i];
    expect(step.containsKey('invalidates'), isFalse,
        reason: '$name step $i puts invalidates at step level; the canonical '
            'location is expected.invalidates');
    expect(
      assertionsOf(step['expected']).containsKey('invalidates'),
      isTrue,
      reason: '$name step $i has no invalidation matrix',
    );
  }
  return steps;
}

final class _QueueHarness {
  _QueueHarness(this.flavor, Map<String, dynamic> initial) {
    QueueStorage<String> storage() => VecDequeStorage<String>.from(
          elements: (initial['elements'] as List?)?.cast<String>() ?? const [],
          capacity: initial['capacity'] as int?,
          closed: (initial['closed'] as bool?) ?? false,
        );

    switch (flavor) {
      case _Flavor.singleThreaded:
        final context = Context();
        ctx = context;
        queue = QueueCell<String>(context, storage());
        readers = {
          'head': Slot<Object?>(context, (cx) => queue.head(cx)),
          'len': Slot<int>(context, (cx) => queue.len(cx)),
          'is_empty': Slot<bool>(context, (cx) => queue.isEmpty(cx)),
          'is_full': Slot<bool>(context, (cx) => queue.isFull(cx)),
          'closed': Slot<bool>(context, (cx) => queue.isClosed(cx)),
        };
      case _Flavor.threadSafe:
        final context = ThreadSafeContext();
        ctx = context;
        queue = ThreadSafeQueueCell<String>(context, storage());
        readers = context.read((raw) => {
              'head': Slot<Object?>(raw, (cx) => queue.head(cx)),
              'len': Slot<int>(raw, (cx) => queue.len(cx)),
              'is_empty': Slot<bool>(raw, (cx) => queue.isEmpty(cx)),
              'is_full': Slot<bool>(raw, (cx) => queue.isFull(cx)),
              'closed': Slot<bool>(raw, (cx) => queue.isClosed(cx)),
            });
      case _Flavor.async:
        final context = AsyncContext();
        ctx = context;
        queue = AsyncQueueCell<String>(context, storage());
        readers = {
          'head': context.computed<Object?>((cx) => queue.head(cx)),
          'len': context.computed<int>((cx) => queue.len(cx)),
          'is_empty': context.computed<bool>((cx) => queue.isEmpty(cx)),
          'is_full': context.computed<bool>((cx) => queue.isFull(cx)),
          'closed': context.computed<bool>((cx) => queue.isClosed(cx)),
        };
    }
  }

  final _Flavor flavor;
  late final dynamic ctx;
  late final dynamic queue;
  late final Map<String, dynamic> readers;

  void prime() {
    for (final reader in readers.values) {
      if (flavor == _Flavor.async) {
        ctx.get(reader);
      } else {
        reader();
      }
    }
  }

  bool warm(String kind) {
    final reader = readers[kind];
    return switch (flavor) {
      _Flavor.singleThreaded => (ctx as Context).contains(reader as Slot),
      _Flavor.threadSafe =>
        (ctx as ThreadSafeContext).context.contains(reader as Slot),
      _Flavor.async =>
        (ctx as AsyncContext).isSet(reader as AsyncSlotHandle<dynamic>),
    };
  }

  Object? apply(Map<String, dynamic> op) {
    switch (op['type'] as String) {
      case 'push':
      case 'try_push':
        final QueuePushError? error = queue.tryPush(op['value'] as String);
        return error?.label ?? 'Ok';
      case 'pop':
      case 'try_pop':
        final QueuePopResult<String> result = queue.tryPop();
        return switch (result) {
          QueuePopValue<String>(:final value) => value,
          QueuePopFailed<String>(:final error) => error.label,
        };
      case 'close':
        queue.close();
        return null;
      case 'batch':
        void pushAll() {
          for (final raw in op['ops'] as List) {
            final inner = raw as Map<String, dynamic>;
            expect(inner['type'], 'push');
            expect(queue.tryPush(inner['value'] as String), isNull);
          }
        }

        switch (flavor) {
          case _Flavor.singleThreaded:
            (ctx as Context).batch(pushAll);
          case _Flavor.threadSafe:
            (ctx as ThreadSafeContext).batch(pushAll);
          case _Flavor.async:
            (ctx as AsyncContext).batch(pushAll);
        }
        return null;
      default:
        throw StateError('unknown queue op ${op['type']}');
    }
  }
}

int _replayQueue(_Flavor flavor, String name) {
  final fixture = _fixture(name);
  final harness =
      _QueueHarness(flavor, fixture['initial'] as Map<String, dynamic>);
  final steps = _steps(fixture, name);
  for (var i = 0; i < steps.length; i++) {
    final step = steps[i];
    final op = step['op'] as Map<String, dynamic>;
    final expected = assertionsOf(step['expected']);
    harness.prime();
    final returns = harness.apply(op);

    if (step.containsKey('returns')) {
      expect(returns, step['returns'],
          reason: '${flavor.label} $name step $i returns');
    }
    assertKeysOf(expected, 'invalidates', harness.readers.keys, (reader, want) {
      expect(harness.warm(reader), !(want as bool),
          reason: '${flavor.label} $name step $i invalidates.$reader');
    });
    assertKeyIfPresent(expected, 'elements', (v) {
      expect(harness.queue.elements(), v,
          reason: '${flavor.label} $name step $i elements');
    });
    assertKeyIfPresent(expected, 'head', (v) {
      expect(harness.queue.head(), v,
          reason: '${flavor.label} $name step $i head');
    });
    assertKeyIfPresent(expected, 'len', (v) {
      expect(harness.queue.len(), v,
          reason: '${flavor.label} $name step $i len');
    });
    assertKeyIfPresent(expected, 'is_empty', (v) {
      expect(harness.queue.isEmpty(), v,
          reason: '${flavor.label} $name step $i is_empty');
    });
    assertKeyIfPresent(expected, 'is_full', (v) {
      expect(harness.queue.isFull(), v,
          reason: '${flavor.label} $name step $i is_full');
    });
    assertKeyIfPresent(expected, 'closed', (v) {
      expect(harness.queue.isClosed(), v,
          reason: '${flavor.label} $name step $i closed');
    });
  }
  return steps.length;
}

/// Decode the corpus's `durability` word.
///
/// `durable` is an EXPLICIT arm (`#lzscenariobodyskip`). Every one of the three
/// call sites spelled this as `x == 'ephemeral' ? ephemeral : durable`, so any
/// word the corpus might add — or a typo — silently became `durable`. On the
/// EXPECTATION side that is worse than a skip: the assertion then compares the
/// observed durability against a value the fixture never named, and passes.
TopicDurability _durability(Object? raw) => switch (raw) {
      'ephemeral' => TopicDurability.ephemeral,
      'durable' => TopicDurability.durable,
      final other => fail('unknown topic durability `$other`'),
    };

TopicSnapshot<String> _topicSnapshot(Map<String, dynamic> initial) {
  final subscriptions =
      (initial['subscriptions'] as Map<String, dynamic>? ?? const {})
          .entries
          .map((entry) {
    final value = entry.value as Map<String, dynamic>;
    return TopicSubscriptionSnapshot(
      subscriberId: entry.key,
      cursor: value['cursor'] as int,
      durability: _durability(value['durability']),
      connected: value['connected'] as bool,
    );
  }).toList();
  return TopicSnapshot<String>(
    baseOffset: initial['base_offset'] as int,
    elements: (initial['elements'] as List).cast<String>(),
    subscriptions: subscriptions,
  );
}

final class _TopicHarness {
  _TopicHarness(this.flavor, Map<String, dynamic> initial) {
    final snapshot = _topicSnapshot(initial);
    switch (flavor) {
      case _Flavor.singleThreaded:
        final context = Context();
        ctx = context;
        topic = TopicCell<String>(context, snapshot);
      case _Flavor.threadSafe:
        final context = ThreadSafeContext();
        ctx = context;
        topic = ThreadSafeTopicCell<String>(context, snapshot);
      case _Flavor.async:
        final context = AsyncContext();
        ctx = context;
        topic = AsyncTopicCell<String>(context, snapshot);
    }
  }

  final _Flavor flavor;
  late final dynamic ctx;
  late final dynamic topic;
  final Map<String, dynamic> readers = {};

  void prime(Iterable<String> ids) {
    for (final id in ids) {
      final reader = readers.putIfAbsent(id, () {
        return switch (flavor) {
          _Flavor.singleThreaded => Slot<List<String>>(
              ctx as Context,
              (cx) => topic.readStream(id, cx),
            ),
          _Flavor.threadSafe => (ctx as ThreadSafeContext).read(
              (raw) => Slot<List<String>>(
                raw,
                (cx) => topic.readStream(id, cx),
              ),
            ),
          _Flavor.async => (ctx as AsyncContext).computed<List<String>>(
              (cx) => topic.readStream(id, cx),
            ),
        };
      });
      if (flavor == _Flavor.async) {
        (ctx as AsyncContext).get(reader as AsyncSlotHandle<List<String>>);
      } else {
        (reader as Slot<List<String>>)();
      }
    }
  }

  bool warm(String id) {
    final reader = readers[id];
    expect(reader, isNotNull,
        reason: '${flavor.label}: no reader was primed for $id');
    return switch (flavor) {
      _Flavor.singleThreaded => (ctx as Context).contains(reader as Slot),
      _Flavor.threadSafe =>
        (ctx as ThreadSafeContext).context.contains(reader as Slot),
      _Flavor.async =>
        (ctx as AsyncContext).isSet(reader as AsyncSlotHandle<dynamic>),
    };
  }

  Object? apply(Map<String, dynamic> op) {
    switch (op['type'] as String) {
      case 'subscribe':
        final durability = _durability(op['durability']);
        return topic.subscribe(op['subscriber'] as String, durability);
      case 'reconnect':
        topic.reconnect(op['subscriber'] as String);
        return null;
      case 'disconnect':
        topic.disconnect(op['subscriber'] as String);
        return null;
      case 'publish':
        return topic.publish(op['value'] as String);
      case 'advance':
        return topic.advance(op['subscriber'] as String);
      case 'gc':
        return topic.gc();
      case 'restart':
        topic.restart();
        return null;
      default:
        throw StateError('unknown topic op ${op['type']}');
    }
  }
}

Set<String> _topicIds(Map<String, dynamic> fixture) {
  final ids = <String>{};
  void addKeys(Object? value) {
    if (value is Map<String, dynamic>) ids.addAll(value.keys);
  }

  addKeys((fixture['initial'] as Map<String, dynamic>)['subscriptions']);
  for (final raw in fixture['steps'] as List) {
    final step = raw as Map<String, dynamic>;
    final op = step['op'] as Map<String, dynamic>;
    final subscriber = op['subscriber'];
    if (subscriber is String) ids.add(subscriber);
  }
  return ids;
}

int _replayTopic(_Flavor flavor, String name) {
  final fixture = _fixture(name);
  final harness =
      _TopicHarness(flavor, fixture['initial'] as Map<String, dynamic>);
  final ids = _topicIds(fixture);
  final steps = _steps(fixture, name);

  for (var i = 0; i < steps.length; i++) {
    final step = steps[i];
    final op = step['op'] as Map<String, dynamic>;
    final expected = assertionsOf(step['expected']);
    harness.prime(ids);
    final returns = harness.apply(op);

    if (step.containsKey('returns')) {
      expect(returns, step['returns'],
          reason: '${flavor.label} $name step $i returns');
    }
    assertKeysOf(expected, 'invalidates', ids, (id, want) {
      expect(harness.warm(id), !(want as bool),
          reason: '${flavor.label} $name step $i invalidates.$id');
    });
    assertKeyWith(expected, 'base_offset', (v) {
      expect(harness.topic.baseOffset, v,
          reason: '${flavor.label} $name step $i base_offset');
    });
    assertKeyWith(expected, 'elements', (v) {
      expect(harness.topic.elements(), v,
          reason: '${flavor.label} $name step $i elements');
    });

    // A subscription's own record is descended into too (`#lzsubblockkeyset`):
    // reading `cursor` / `connected` / `durability` by name off a raw map is
    // the same field-by-field shape one level further down, and a fourth field
    // added to the record upstream would be compared by nothing.
    final wantSubscriptions =
        subKey(expected, 'subscriptions', '$name step $i subscriptions');
    final unknownSubscribers = wantSubscriptions.keys
        .where((id) => !ids.contains(id))
        .toList()
      ..sort();
    expect(unknownSubscribers, isEmpty,
        reason: '${flavor.label} $name step $i: `subscriptions` names '
            '$unknownSubscribers, which no initial subscription and no op in '
            'this fixture ever introduced');
    for (final id in ids) {
      final actual = harness.topic.subscription(id);
      if (!wantSubscriptions.keys.contains(id)) {
        expect(actual, isNull,
            reason: '${flavor.label} $name step $i subscription $id');
        continue;
      }
      final want =
          subKey(wantSubscriptions, id, '$name step $i subscription $id');
      expect(actual, isNotNull);
      assertKey(want, 'cursor', actual.cursor,
          '${flavor.label} $name step $i cursor $id');
      assertKey(want, 'connected', actual.connected,
          '${flavor.label} $name step $i connected $id');
      assertKeyWith<void>(
          want,
          'durability',
          (v) => expect(actual.durability, _durability(v),
              reason: '${flavor.label} $name step $i durability $id'));
    }

    assertKeysOf(expected, 'reads', ids, (id, want) {
      expect(harness.topic.readStream(id), want,
          reason: '${flavor.label} $name step $i reads.$id');
    });
  }
  return steps.length;
}

final class _WorkHarness {
  _WorkHarness(
    this.flavor, {
    required int visibilityTimeout,
    required int maxDeliveries,
  }) {
    switch (flavor) {
      case _Flavor.singleThreaded:
        final context = Context();
        ctx = context;
        queue = WorkQueueCell<String>(
          context,
          visibilityTimeout: visibilityTimeout,
          maxDeliveries: maxDeliveries,
        );
        readers = {
          'pending_len': Slot<int>(context, (cx) => queue.pendingLen(cx)),
          'is_empty': Slot<bool>(context, (cx) => queue.isEmpty(cx)),
          'in_flight_len': Slot<int>(context, (cx) => queue.inFlightLen(cx)),
          'dead_letter_len':
              Slot<int>(context, (cx) => queue.deadLetterLen(cx)),
        };
      case _Flavor.threadSafe:
        final context = ThreadSafeContext();
        ctx = context;
        queue = ThreadSafeWorkQueueCell<String>(
          context,
          visibilityTimeout: visibilityTimeout,
          maxDeliveries: maxDeliveries,
        );
        readers = context.read((raw) => {
              'pending_len': Slot<int>(raw, (cx) => queue.pendingLen(cx)),
              'is_empty': Slot<bool>(raw, (cx) => queue.isEmpty(cx)),
              'in_flight_len': Slot<int>(raw, (cx) => queue.inFlightLen(cx)),
              'dead_letter_len':
                  Slot<int>(raw, (cx) => queue.deadLetterLen(cx)),
            });
      case _Flavor.async:
        final context = AsyncContext();
        ctx = context;
        queue = AsyncWorkQueueCell<String>(
          context,
          visibilityTimeout: visibilityTimeout,
          maxDeliveries: maxDeliveries,
        );
        readers = {
          'pending_len': context.computed<int>((cx) => queue.pendingLen(cx)),
          'is_empty': context.computed<bool>((cx) => queue.isEmpty(cx)),
          'in_flight_len': context.computed<int>((cx) => queue.inFlightLen(cx)),
          'dead_letter_len':
              context.computed<int>((cx) => queue.deadLetterLen(cx)),
        };
    }
  }

  final _Flavor flavor;
  late final dynamic ctx;
  late final dynamic queue;
  late final Map<String, dynamic> readers;

  void prime() {
    for (final reader in readers.values) {
      if (flavor == _Flavor.async) {
        (ctx as AsyncContext).get(reader as AsyncSlotHandle<dynamic>);
      } else {
        (reader as Slot<dynamic>)();
      }
    }
  }

  bool warm(String kind) {
    final reader = readers[kind];
    if (reader == null) throw StateError('unknown work reader $kind');
    return switch (flavor) {
      _Flavor.singleThreaded => (ctx as Context).contains(reader as Slot),
      _Flavor.threadSafe =>
        (ctx as ThreadSafeContext).context.contains(reader as Slot),
      _Flavor.async =>
        (ctx as AsyncContext).isSet(reader as AsyncSlotHandle<dynamic>),
    };
  }

  Object? apply(Map<String, dynamic> op) {
    switch (op['type'] as String) {
      case 'push':
        return queue.push(op['value'] as String);
      case 'claim':
        final WorkQueueDelivery<String>? delivery =
            queue.claim(op['worker'] as String, op['now'] as int);
        return delivery == null
            ? null
            : {
                'delivery_id': delivery.deliveryId,
                'item_id': delivery.itemId,
                'value': delivery.value,
                'worker': delivery.worker,
                'attempt': delivery.attempt,
                'deadline': delivery.deadline,
              };
      case 'ack':
        return queue.ack(
          op['worker'] as String,
          op['delivery_id'] as int,
        );
      case 'nack':
        return queue.nack(
          op['worker'] as String,
          op['delivery_id'] as int,
        );
      case 'reap_expired':
        return queue.reapExpired(op['now'] as int);
      default:
        throw StateError('unknown work queue op ${op['type']}');
    }
  }
}

List<Map<String, Object?>> _pending(dynamic queue) =>
    (queue.pendingItems() as List<WorkQueueItem<String>>)
        .map((item) => {
              'item_id': item.itemId,
              'value': item.value,
              'attempts': item.attempts,
            })
        .toList();

List<Map<String, Object?>> _inFlight(dynamic queue) =>
    (queue.inFlightDeliveries() as List<WorkQueueDelivery<String>>)
        .map((delivery) => {
              'delivery_id': delivery.deliveryId,
              'item_id': delivery.itemId,
              'value': delivery.value,
              'worker': delivery.worker,
              'attempt': delivery.attempt,
              'deadline': delivery.deadline,
            })
        .toList();

List<Map<String, Object?>> _deadLetters(dynamic queue) =>
    (queue.deadLetterItems() as List<WorkQueueDeadLetter<String>>)
        .map((dead) => {
              'item_id': dead.itemId,
              'value': dead.value,
              'attempts': dead.attempts,
              'reason': dead.reason.name,
            })
        .toList();

int _replayWork(_Flavor flavor, String name) {
  final fixture = _fixture(name);
  final initial = fixture['initial'] as Map<String, dynamic>;
  expect(initial['pending'], isEmpty);
  expect(initial['in_flight'], isEmpty);
  expect(initial['dead_letters'], isEmpty);
  final harness = _WorkHarness(
    flavor,
    visibilityTimeout: initial['visibility_timeout'] as int,
    maxDeliveries: initial['max_deliveries'] as int,
  );
  final steps = _steps(fixture, name);

  for (var i = 0; i < steps.length; i++) {
    final step = steps[i];
    final op = step['op'] as Map<String, dynamic>;
    final expected = assertionsOf(step['expected']);
    harness.prime();
    final returns = harness.apply(op);
    if (step.containsKey('returns')) {
      expect(returns, step['returns'],
          reason: '${flavor.label} $name step $i returns');
    }
    assertKeysOf(expected, 'invalidates', harness.readers.keys, (reader, want) {
      expect(harness.warm(reader), !(want as bool),
          reason: '${flavor.label} $name step $i invalidates.$reader');
    });
    assertKeyWith(expected, 'pending', (v) {
      expect(_pending(harness.queue), v,
          reason: '${flavor.label} $name step $i pending');
    });
    assertKeyWith(expected, 'in_flight', (v) {
      expect(_inFlight(harness.queue), v,
          reason: '${flavor.label} $name step $i in_flight');
    });
    assertKeyWith(expected, 'dead_letters', (v) {
      expect(_deadLetters(harness.queue), v,
          reason: '${flavor.label} $name step $i dead_letters');
    });

    final reads = subKey(expected, 'reads', '$name step $i reads');
    assertKey(reads, 'pending_len', harness.queue.pendingLen());
    assertKey(reads, 'is_empty', harness.queue.isEmpty());
    assertKey(reads, 'in_flight_len', harness.queue.inFlightLen());
    assertKey(reads, 'dead_letter_len', harness.queue.deadLetterLen());
  }
  return steps.length;
}

void main() {
  test('queue-family ledger names nine shipped source types', () {
    final sources = _sources();
    expect(sources, isNotEmpty,
        reason: 'source ledger read nothing and would be vacuous');
    expect(_ledger.length, 9,
        reason: 'ledger must cover three primitives × three flavors');
    for (final row in _ledger) {
      expect(sources.contains(row.marker), isTrue,
          reason: '${row.primitive}/${row.flavor.label} is recorded as shipped '
              'but ${row.marker} is absent');
    }
  });

  for (final flavor in _Flavor.values) {
    test('QueueCell canonical corpus (${flavor.label})', () {
      var steps = 0;
      for (final fixture in _queueFixtures) {
        steps += _replayQueue(flavor, fixture);
      }
      expect(steps, greaterThan(0),
          reason: '${flavor.label} QueueCell replayed zero steps');
    });

    test('TopicCell canonical corpus (${flavor.label})', () {
      var steps = 0;
      for (final fixture in _topicFixtures) {
        steps += _replayTopic(flavor, fixture);
      }
      expect(steps, greaterThan(0),
          reason: '${flavor.label} TopicCell replayed zero steps');
    });

    test('WorkQueueCell canonical corpus (${flavor.label})', () {
      var steps = 0;
      for (final fixture in _workFixtures) {
        steps += _replayWork(flavor, fixture);
      }
      expect(steps, greaterThan(0),
          reason: '${flavor.label} WorkQueueCell replayed zero steps');
    });
  }
}
