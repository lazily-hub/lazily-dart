library;

import 'dart:convert';
import 'dart:io';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

const _fixtureName = 'latest_durable_projection.json';

Map<String, dynamic> _fixture() {
  final file = File('${specFamilyDir('egress').path}/$_fixtureName');
  expect(file.existsSync(), isTrue,
      reason: 'canonical egress fixture is required');
  return attributeFixture(jsonDecode(file.specReadAsStringSync()))
      as Map<String, dynamic>;
}

abstract interface class _Model {
  Object operate(Map<String, dynamic> operation);
  LatestDurableSnapshot<String, String> snapshot();
}

Object _operate(
  dynamic projection,
  Map<String, dynamic> operation,
) =>
    switch (operation['type']) {
      'upsert_desired' => projection.upsertDesired(
          operation['key'] as String,
          operation['epoch'] as int,
          operation['value'] as String,
        ),
      'claim' => projection.claim(
          operation['key'] as String,
          operation['generation'] as int,
        ),
      'ack_applied' => projection.ackApplied(
          operation['key'] as String,
          operation['generation'] as int,
          operation['epoch'] as int,
        ),
      'fail_retryable' => projection.failRetryable(
          operation['key'] as String,
          operation['generation'] as int,
          operation['epoch'] as int,
        ),
      'reconnect' => projection.reconnect(operation['generation'] as int),
      final type => throw StateError('unknown latest-durable operation $type'),
    };

final class _CoreModel implements _Model {
  _CoreModel(int generation)
      : projection = LatestDurableProjectionCore<String, String>(generation);
  final LatestDurableProjectionCore<String, String> projection;

  @override
  Object operate(Map<String, dynamic> operation) =>
      _operate(projection, operation);
  @override
  LatestDurableSnapshot<String, String> snapshot() => projection.snapshot();
}

final class _SyncModel implements _Model {
  _SyncModel(int generation)
      : projection = LatestDurableProjection<String, String>(
          Context(),
          generation,
        );
  final LatestDurableProjection<String, String> projection;

  @override
  Object operate(Map<String, dynamic> operation) =>
      _operate(projection, operation);
  @override
  LatestDurableSnapshot<String, String> snapshot() => projection.snapshot();
}

final class _ThreadSafeModel implements _Model {
  _ThreadSafeModel(int generation)
      : projection = ThreadSafeLatestDurableProjection<String, String>(
          ThreadSafeContext(),
          generation,
        );
  final ThreadSafeLatestDurableProjection<String, String> projection;

  @override
  Object operate(Map<String, dynamic> operation) =>
      _operate(projection, operation);
  @override
  LatestDurableSnapshot<String, String> snapshot() => projection.snapshot();
}

final class _AsyncModel implements _Model {
  _AsyncModel(int generation)
      : projection = AsyncLatestDurableProjection<String, String>(
          AsyncContext(),
          generation,
        );
  final AsyncLatestDurableProjection<String, String> projection;

  @override
  Object operate(Map<String, dynamic> operation) =>
      _operate(projection, operation);
  @override
  LatestDurableSnapshot<String, String> snapshot() => projection.snapshot();
}

Map<String, dynamic> _wireEnvelope(
  LatestDurableEnvelope<String, String> envelope,
) =>
    {
      'generation': envelope.generation,
      'key': envelope.key,
      'epoch': envelope.epoch,
      'value': envelope.value,
    };

Map<String, dynamic> _wireOutcome(
  Map<String, dynamic> operation,
  Object outcome,
) {
  switch (outcome) {
    case LatestDurableUpsert():
      return {'upsert': outcome.wireName};
    case LatestDurableClaim<String, String>():
      return {
        'claim': outcome.kind.wireName,
        if (outcome.envelope != null)
          'envelope': _wireEnvelope(outcome.envelope!),
        if (outcome.current != null) 'current': outcome.current,
      };
    case LatestDurableAck():
      return {
        'ack': outcome.kind.wireName,
        if (outcome.durableThrough != null)
          'durable_through': outcome.durableThrough,
        if (outcome.current != null) 'current': outcome.current,
      };
    case LatestDurableFailure():
      return {
        'failure': outcome.kind.wireName,
        if (outcome.current != null) 'current': outcome.current,
      };
    case LatestDurableReconnect():
      return {
        'reconnect': outcome.kind.wireName,
        if (outcome.generation != null) 'generation': outcome.generation,
        if (outcome.current != null) 'current': outcome.current,
        if (outcome.requeued != null) 'requeued': outcome.requeued,
        if (outcome.superseded != null) 'superseded': outcome.superseded,
      };
    default:
      throw StateError(
        'unexpected result for ${operation['type']}: ${outcome.runtimeType}',
      );
  }
}

Map<String, dynamic> _wireSnapshot(
  LatestDurableSnapshot<String, String> snapshot,
) =>
    {
      'generation': snapshot.generation,
      'entries': snapshot.entries
          .map(
            (entry) => {
              'key': entry.key,
              'desired': switch (entry.desired) {
                null => null,
                final desired => {
                    'epoch': desired.epoch,
                    'value': desired.value,
                  },
              },
              'inflight': switch (entry.inflight) {
                null => null,
                final inflight => _wireEnvelope(inflight),
              },
              'durable_through': entry.durableThrough,
            },
          )
          .toList(),
    };

void main() {
  final families = <String, _Model Function(int)>{
    'core': _CoreModel.new,
    'single-threaded': _SyncModel.new,
    'thread-safe': _ThreadSafeModel.new,
    'async': _AsyncModel.new,
  };

  for (final MapEntry(key: name, value: create) in families.entries) {
    test('$name replays LatestDurableProjectionCore conformance', () {
      final fixture = _fixture();
      var steps = 0;
      for (final scenario in scenariosOf(fixture)) {
        final model = create(scenario['generation'] as int);
        for (final raw in scenario['steps'] as List) {
          final step = raw as Map<String, dynamic>;
          final operation = step['op'] as Map<String, dynamic>;
          final outcome = model.operate(operation);
          expect(
            _wireOutcome(operation, outcome),
            equals(step['returns']),
            reason: '${scenario['id']}: outcome',
          );
          assertBlock(
            step['expected'],
            _wireSnapshot(model.snapshot()),
            '${scenario['id']}: state',
          );
          steps++;
        }
      }
      expect(steps, greaterThan(0));
    });
  }

  test('rejections and retry results stay explicit', () {
    final projection = LatestDurableProjectionCore<String, String>(3);
    expect(projection.claim('doc', 2).kind,
        LatestDurableClaimKind.staleGeneration);
    expect(
        projection.upsertDesired('doc', 2, 'B'), LatestDurableUpsert.accepted);
    expect(
        projection.upsertDesired('doc', 2, 'B'), LatestDurableUpsert.unchanged);
    expect(projection.upsertDesired('doc', 2, 'different'),
        LatestDurableUpsert.epochConflict);
    expect(projection.upsertDesired('doc', 1, 'A'),
        LatestDurableUpsert.staleEpoch);
    expect(projection.claim('doc', 3).kind, LatestDurableClaimKind.claimed);
    expect(projection.failRetryable('doc', 3, 2).kind,
        LatestDurableFailureKind.pending);
  });
}
