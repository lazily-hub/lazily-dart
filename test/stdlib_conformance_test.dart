import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lazily/stdlib.dart' as stdlib;
import 'package:test/test.dart';

import 'conformance_manifest.dart';

final _specDir = Directory('../lazily-spec/conformance/stdlib');

Map<String, dynamic> _fixture(String name) {
  final source = File('${_specDir.path}/$name').specReadAsStringSync();
  return jsonDecode(source) as Map<String, dynamic>;
}

BigInt _logicalUint(Object? value) {
  if (value is int) return BigInt.from(value);
  if (value is double && value.isFinite && value == value.truncateToDouble()) {
    return BigInt.parse(value.toStringAsFixed(0));
  }
  if (value is String) return BigInt.parse(value);
  throw FormatException('expected logical uint64, got $value');
}

stdlib.TimeoutCancellation _cancellation(Object? value) => switch (value) {
      'pending' => stdlib.TimeoutCancellation.pending,
      'cancelled' => stdlib.TimeoutCancellation.cancelled,
      _ => stdlib.TimeoutCancellation.unavailable,
    };

Map<String, Object?> _timerStep(
  Map<String, dynamic> step,
  List<stdlib.Timer?> holder,
) {
  switch (step['op']) {
    case 'start':
      try {
        final timer = stdlib.Timer(
          _logicalUint(step['now']),
          _logicalUint(step['duration']),
        );
        holder[0] = timer;
        return timer.initial.toJson();
      } on stdlib.StdlibUnavailable catch (error) {
        holder[0] = null;
        return {'outcome': 'unavailable', 'reason': error.reason};
      }
    case 'observe':
      return holder.single!.observe(_logicalUint(step['now'])).toJson();
    default:
      throw StateError('unknown timer step ${step['op']}');
  }
}

Map<String, Object?> _timeoutStep(
  Map<String, dynamic> step,
  List<stdlib.Timeout<String>?> holder,
) {
  switch (step['op']) {
    case 'start':
      try {
        final timeout = stdlib.Timeout<String>(
          _logicalUint(step['now']),
          _logicalUint(step['duration']),
        );
        holder[0] = timeout;
        return timeout.initial.toJson();
      } on stdlib.StdlibUnavailable catch (error) {
        holder[0] = null;
        return {'outcome': 'unavailable', 'reason': error.reason};
      }
    case 'poll':
      var operationCalls = 0;
      var cancellationCalls = 0;
      final observation = holder.single!.poll(
        _logicalUint(step['now']),
        () {
          operationCalls++;
          return switch (step['operation']) {
            'pending' => const stdlib.TimeoutOperation<String>.pending(),
            'completed' => stdlib.TimeoutOperation<String>.completed(
                step['value'] as String,
              ),
            _ => const stdlib.TimeoutOperation<String>.unavailable(),
          };
        },
        () {
          cancellationCalls++;
          return _cancellation(step['cancellation']);
        },
      ).toJson();
      return {
        ...observation,
        'operation_calls': operationCalls,
        'cancellation_calls': cancellationCalls,
      };
    default:
      throw StateError('unknown timeout step ${step['op']}');
  }
}

Map<String, Object?> _barrierStep(
  Map<String, dynamic> step,
  List<stdlib.RevisionBarrier?> holder,
) {
  var cancellationCalls = 0;
  late stdlib.RevisionBarrierObservation observation;
  switch (step['op']) {
    case 'start':
      final deadline = step['deadline'];
      final barrier = stdlib.RevisionBarrier(
        revision: _logicalUint(step['revision']),
        requiredRevision: _logicalUint(step['required_revision']),
        deadline: deadline == null ? null : _logicalUint(deadline),
      );
      holder[0] = barrier;
      observation = barrier.initial;
      break;
    case 'observe':
      observation = holder.single!.observe(
        _logicalUint(step['now']),
        step['predicate'] as bool,
        () {
          cancellationCalls++;
          return _cancellation(step['cancellation']);
        },
      );
      break;
    case 'register_recheck':
      observation = holder.single!.registerRecheck(
        _logicalUint(step['now']),
        _logicalUint(step['observed_revision']),
        step['predicate'] as bool,
      );
      break;
    case 'advance':
      observation = holder.single!.advance(
        _logicalUint(step['revision']),
        step['predicate'] as bool,
      );
      break;
    case 'dispose':
      observation = holder.single!.dispose();
      break;
    case 'receipt':
      observation = holder.single!.receipt(step['key'] as String);
      break;
    default:
      throw StateError('unknown barrier step ${step['op']}');
  }
  return {
    ...observation.toJson(),
    if (step['op'] == 'observe') 'cancellation_calls': cancellationCalls,
  };
}

void main() {
  if (!_specDir.existsSync()) {
    test(
      'portable stdlib canonical fixtures',
      () {},
      skip: '${_specDir.path} absent - clone the lazily-spec sibling',
    );
    return;
  }

  test('Timer replays stdlib/timer.json', () {
    final fixture = _fixture('timer.json');
    for (final scenario
        in (fixture['scenarios'] as List).cast<Map<String, dynamic>>()) {
      final holder = <stdlib.Timer?>[null];
      for (final step
          in (scenario['steps'] as List).cast<Map<String, dynamic>>()) {
        expect(
          _timerStep(step, holder),
          equals(step['expect']),
          reason: scenario['id'] as String,
        );
      }
    }
  });

  test('Timeout replays stdlib/timeout.json', () {
    final fixture = _fixture('timeout.json');
    for (final scenario
        in (fixture['scenarios'] as List).cast<Map<String, dynamic>>()) {
      final holder = <stdlib.Timeout<String>?>[null];
      for (final step
          in (scenario['steps'] as List).cast<Map<String, dynamic>>()) {
        expect(
          _timeoutStep(step, holder),
          equals(step['expect']),
          reason: scenario['id'] as String,
        );
      }
    }
  });

  test('RevisionBarrier replays stdlib/revision_barrier.json', () {
    final fixture = _fixture('revision_barrier.json');
    for (final scenario
        in (fixture['scenarios'] as List).cast<Map<String, dynamic>>()) {
      final holder = <stdlib.RevisionBarrier?>[null];
      for (final step
          in (scenario['steps'] as List).cast<Map<String, dynamic>>()) {
        expect(
          _barrierStep(step, holder),
          equals(step['expect']),
          reason: scenario['id'] as String,
        );
      }
    }
  });

  test('checked uint64 clock boundaries stay exact', () {
    final timer = stdlib.Timer(stdlib.maxUint64 - BigInt.one, BigInt.one);
    expect(timer.initial.deadline, stdlib.maxUint64);
    expect(timer.observe(stdlib.maxUint64).firedAt, stdlib.maxUint64);
    expect(
      () => stdlib.Timer(stdlib.maxUint64, BigInt.one),
      throwsA(
        isA<stdlib.StdlibUnavailable>().having(
          (error) => error.reason,
          'reason',
          'deadline_overflow',
        ),
      ),
    );
  });

  test('browser-safe JSON projection preserves uint64 precision', () {
    final timer = stdlib.Timer(stdlib.maxUint64 - BigInt.one, BigInt.one);
    final pending = timer.initial.toJson();
    expect(pending['deadline'], stdlib.maxUint64.toString());
    expect(
      (jsonDecode(jsonEncode(pending)) as Map)['deadline'],
      stdlib.maxUint64.toString(),
    );
    final fired = timer.observe(stdlib.maxUint64).toJson();
    expect(fired['fired_at'], stdlib.maxUint64.toString());

    final barrier = stdlib.RevisionBarrier(
      revision: stdlib.maxUint64,
      requiredRevision: stdlib.maxUint64,
    );
    expect(
      barrier.initial.toJson()['revision'],
      stdlib.maxUint64.toString(),
    );

    // Canonical fixture-sized values remain JSON numbers.
    expect(
      stdlib.Timer(BigInt.zero, BigInt.one).initial.toJson()['deadline'],
      1,
    );
  });

  test('RevisionBarrier rejects regression without counter/callback mutation',
      () {
    final barrier = stdlib.RevisionBarrier(
      revision: BigInt.zero,
      requiredRevision: BigInt.from(3),
    );
    var initialCancellationCalls = 0;
    expect(
      barrier.observe(BigInt.from(5), false, () {
        initialCancellationCalls++;
        return stdlib.TimeoutCancellation.pending;
      }).outcome,
      'pending',
    );
    expect(initialCancellationCalls, 1);
    expect(barrier.advance(BigInt.one, false).generation, BigInt.one);

    var regressionCancellationCalls = 0;
    final regressed = barrier.observe(BigInt.from(4), true, () {
      regressionCancellationCalls++;
      return stdlib.TimeoutCancellation.cancelled;
    });
    expect(
      regressed.toJson(),
      {
        'outcome': 'unavailable',
        'revision': 1,
        'generation': 1,
        'reason': 'clock_regression',
      },
    );
    expect(regressionCancellationCalls, 0);

    final registerRegression = barrier.registerRecheck(
      BigInt.from(3),
      BigInt.from(9),
      true,
    );
    expect(registerRegression.toJson(), regressed.toJson());

    // Neither regression advanced the hidden clock nor accepted a revision;
    // the typed unavailable result is terminal.
    final latched = barrier.registerRecheck(
      BigInt.from(5),
      BigInt.from(3),
      true,
    );
    expect(latched.toJson(), regressed.toJson());
  });

  test('RevisionBarrier first register establishes its clock frontier', () {
    final barrier = stdlib.RevisionBarrier(
      revision: BigInt.zero,
      requiredRevision: BigInt.from(2),
    );
    expect(
      barrier.registerRecheck(BigInt.from(7), BigInt.one, false).outcome,
      'pending',
    );
    var cancellationCalls = 0;
    final regressed = barrier.observe(BigInt.from(6), false, () {
      cancellationCalls++;
      return stdlib.TimeoutCancellation.pending;
    });
    expect(regressed.reason, 'clock_regression');
    expect(regressed.revision, BigInt.one);
    expect(regressed.generation, BigInt.one);
    expect(cancellationCalls, 0);
  });

  test('RevisionBarrier sync cancellation preserves reentrant terminal', () {
    final barrier = stdlib.RevisionBarrier(
      revision: BigInt.zero,
      requiredRevision: BigInt.one,
    );
    final result = barrier.observe(BigInt.zero, false, () {
      expect(barrier.dispose().outcome, 'disposed');
      return stdlib.TimeoutCancellation.cancelled;
    });
    expect(result.outcome, 'disposed');
    expect(
      barrier.initial.toJson(),
      {'outcome': 'disposed', 'revision': 0, 'generation': 0},
    );
  });

  test('RevisionBarrier Future cancellation preserves earlier terminal',
      () async {
    final barrier = stdlib.RevisionBarrier(
      revision: BigInt.zero,
      requiredRevision: BigInt.one,
    );
    final cancellation = Completer<stdlib.TimeoutCancellation>();
    final pending = barrier.observeFuture(
      BigInt.zero,
      false,
      () => cancellation.future,
    );
    expect(barrier.dispose().outcome, 'disposed');
    cancellation.complete(stdlib.TimeoutCancellation.cancelled);
    expect((await pending).outcome, 'disposed');
  });

  test('Timer Future wait seam is caller-driven and terminal-latched',
      () async {
    final timer = stdlib.Timer(BigInt.zero, BigInt.from(5));
    var calls = 0;
    final fired = await timer.wait((deadline) async {
      calls++;
      expect(deadline, BigInt.from(5));
      return deadline;
    });
    expect(fired.toJson(), {'outcome': 'fired', 'fired_at': 5});
    await timer.wait((_) {
      calls++;
      return BigInt.from(99);
    });
    expect(calls, 1);
  });

  test('Timeout Future adapters preserve exactly-once precedence', () async {
    final timeout = stdlib.Timeout<String>(BigInt.zero, BigInt.from(10));
    var operationCalls = 0;
    var cancellationCalls = 0;
    final result = await timeout.pollFuture(
      BigInt.one,
      () async {
        operationCalls++;
        return const stdlib.TimeoutOperation.completed('winner');
      },
      () async {
        cancellationCalls++;
        return stdlib.TimeoutCancellation.cancelled;
      },
    );
    expect(result.toJson(), {'outcome': 'completed', 'value': 'winner'});
    expect(operationCalls, 1);
    expect(cancellationCalls, 1);
  });

  test('RevisionBarrier Future cancellation seam honors early exits', () async {
    final satisfied = stdlib.RevisionBarrier(
      revision: BigInt.one,
      requiredRevision: BigInt.one,
    );
    var cancellationCalls = 0;
    expect(
      (await satisfied.observeFuture(BigInt.zero, true, () async {
        cancellationCalls++;
        return stdlib.TimeoutCancellation.cancelled;
      }))
          .outcome,
      'satisfied',
    );
    expect(cancellationCalls, 0);

    final cancelled = stdlib.RevisionBarrier(
      revision: BigInt.zero,
      requiredRevision: BigInt.one,
    );
    expect(
      (await cancelled.observeFuture(BigInt.zero, false, () async {
        cancellationCalls++;
        return stdlib.TimeoutCancellation.cancelled;
      }))
          .outcome,
      'cancelled',
    );
    expect(cancellationCalls, 1);
  });
}
