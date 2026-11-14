/// Canonical generic effect-CAS corpus replay (`#lzeffectcas`), against the pure
/// [EffectCasCore] and every reactive shell this binding ships (single-threaded
/// [EffectCas], run-to-completion [ThreadSafeEffectCas], [AsyncEffectCas]).
///
/// Mirrors `lazily-rs/tests/effect_cas_conformance.rs`: every step's returned
/// outcome is compared against `returns`, and after each scenario the per-key
/// projection is compared against `final` in both directions (map equality, so
/// a key the run grew and a key the fixture adds each fail).
///
/// Vacuity guards: scenarios come from [scenariosOf], which books each one in
/// the scenario ledger only when its payload is read; steps and scenarios are
/// counted inside the loops and compared EXACTLY against what was loaded; an
/// unknown op throws; and a missing fixture fails rather than skips. Each shell
/// additionally proves its reader invalidates on a state change and stays warm
/// on a no-op (a stale-generation receipt changes no reader version).
library;

import 'dart:convert';
import 'dart:io';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

const _fixtureName = 'effect_cas.json';

typedef _Core = EffectCasCore<String, int, String, String, String>;

Map<String, dynamic> _fixture() {
  final file = File('${specFamilyDir('egress').path}/$_fixtureName');
  expect(file.existsSync(), isTrue,
      reason: 'canonical effect-CAS fixture is required');
  return attributeFixture(jsonDecode(file.specReadAsStringSync()))
      as Map<String, dynamic>;
}

/// One flavor under replay. `projection` is a core or shell exposing the same
/// method names; `snapshot()` is the reader the shell projects.
abstract interface class _Model {
  dynamic get projection;
  EffectCasSnapshot<String, int, String, String, String> snapshot();
}

final class _CoreModel implements _Model {
  _CoreModel(int generation) : projection = _Core(generation);
  @override
  final _Core projection;
  @override
  EffectCasSnapshot<String, int, String, String, String> snapshot() =>
      projection.snapshot();
}

final class _SyncModel implements _Model {
  _SyncModel(int generation)
      : projection = EffectCas<String, int, String, String, String>(
            Context(), generation);
  @override
  final EffectCas<String, int, String, String, String> projection;
  @override
  EffectCasSnapshot<String, int, String, String, String> snapshot() =>
      projection.snapshot();
}

final class _ThreadSafeModel implements _Model {
  _ThreadSafeModel(int generation)
      : projection = ThreadSafeEffectCas<String, int, String, String, String>(
            ThreadSafeContext(), generation);
  @override
  final ThreadSafeEffectCas<String, int, String, String, String> projection;
  @override
  EffectCasSnapshot<String, int, String, String, String> snapshot() =>
      projection.snapshot();
}

final class _AsyncModel implements _Model {
  _AsyncModel(int generation)
      : projection = AsyncEffectCas<String, int, String, String, String>(
            AsyncContext(), generation);
  @override
  final AsyncEffectCas<String, int, String, String, String> projection;
  @override
  EffectCasSnapshot<String, int, String, String, String> snapshot() =>
      projection.snapshot();
}

/// The core returns `(change, outcome)`; the shells return the outcome.
Object _outcome(Object result) => result is Record
    ? switch (result) {
        (EffectCasChange _, Object outcome) => outcome,
        _ => result
      }
    : result;

Map<String, dynamic> _upsertWire(EffectCasUpsert outcome) => switch (outcome) {
      EffectCasUpsertAccepted() => {'upsert': 'accepted'},
      EffectCasUpsertUnchanged() => {'upsert': 'unchanged'},
      EffectCasUpsertAlreadyApplied(:final appliedThrough) => {
          'upsert': 'already_applied',
          'applied_through': appliedThrough,
        },
      EffectCasUpsertStaleEpoch(:final current) => {
          'upsert': 'stale_epoch',
          'current': current,
        },
      EffectCasUpsertEpochConflict() => {'upsert': 'epoch_conflict'},
    };

Map<String, dynamic> _appliedWire(EffectCasApplied outcome) =>
    switch (outcome) {
      EffectCasStepApplied(:final nextStep) => {
          'applied': 'step_applied',
          'next_step': nextStep,
        },
      EffectCasCompleted(:final appliedThrough) => {
          'applied': 'completed',
          'applied_through': appliedThrough,
        },
      EffectCasAppliedSuperseded() => {'applied': 'superseded'},
      EffectCasAppliedDuplicate() => {'applied': 'duplicate'},
      EffectCasAppliedUnknownAttempt() => {'applied': 'unknown_attempt'},
      EffectCasAppliedStaleGeneration(:final current) => {
          'applied': 'stale_generation',
          'current': current,
        },
    };

Map<String, dynamic> _failureWire(EffectCasFailure outcome) =>
    switch (outcome) {
      EffectCasFailureSuperseded() => {'failure': 'superseded'},
      EffectCasFailureRetrying(:final retryAt) => {
          'failure': 'retrying',
          'retry_at': retryAt,
        },
      EffectCasFailureRejected() => {'failure': 'rejected'},
      EffectCasFailureUnknownAttempt() => {'failure': 'unknown_attempt'},
      EffectCasFailureStaleGeneration(:final current) => {
          'failure': 'stale_generation',
          'current': current,
        },
    };

Map<String, dynamic> _reconnectWire(EffectCasReconnect outcome) =>
    switch (outcome) {
      EffectCasReconnectAdvanced(
        :final generation,
        :final requeued,
        :final superseded
      ) =>
        {
          'reconnect': 'advanced',
          'generation': generation,
          'requeued': requeued,
          'superseded': superseded,
        },
      EffectCasReconnectUnchanged(:final generation) => {
          'reconnect': 'unchanged',
          'generation': generation,
        },
      EffectCasReconnectStaleGeneration(:final current) => {
          'reconnect': 'stale_generation',
          'current': current,
        },
    };

Map<String, dynamic> _claimWire(
        EffectCasClaim<String, int, String, String> outcome) =>
    switch (outcome) {
      EffectCasClaimed(:final attempt) => {
          'claim': 'claimed',
          'identity': attempt.identity.effect.value,
          'step': attempt.identity.step,
          'attempt': attempt.identity.attempt,
          'expected': attempt.expected,
          'payload': attempt.payload,
        },
      EffectCasClaimEmpty() => {'claim': 'empty'},
      EffectCasClaimBusy() => {'claim': 'busy'},
      EffectCasClaimWaiting(:final retryAt) => {
          'claim': 'waiting',
          'retry_at': retryAt,
        },
      EffectCasClaimStaleGeneration(:final current) => {
          'claim': 'stale_generation',
          'current': current,
        },
    };

Map<String, dynamic> _runStep(
  _Model model,
  Map<String, EffectAttemptIdentity> attempts,
  Map<String, dynamic> step,
  String where,
) {
  final op = step['op'] as Map<String, dynamic>;
  final dynamic p = model.projection;
  String key() => op['key'] as String;
  EffectAttemptIdentity attempt() {
    final label = op['attempt'] as String;
    final saved = attempts[label];
    if (saved == null) fail('$where: no saved attempt `$label`');
    return saved;
  }

  switch (op['type']) {
    case 'upsert':
      return _upsertWire(_outcome(p.upsertDesired(
        EffectIntent<String, int, String>(
          identity: EffectIdentity(op['identity'] as String),
          epoch: op['epoch'] as int,
          key: key(),
          expected: op['expected'] as int,
          plan: EffectPlan<String>((op['plan'] as List).cast<String>()),
        ),
      )) as EffectCasUpsert);
    case 'claim':
      final claim =
          _outcome(p.claim(key(), op['generation'] as int, op['now'] as int))
              as EffectCasClaim<String, int, String, String>;
      final label = step['save'];
      if (label != null) {
        expect(claim, isA<EffectCasClaimed<String, int, String, String>>(),
            reason: '$where: a saved claim must succeed');
        attempts[label as String] =
            (claim as EffectCasClaimed<String, int, String, String>)
                .attempt
                .identity;
      }
      return _claimWire(claim);
    case 'applied':
      return _appliedWire(_outcome(p.recordApplied(
          key(),
          attempt(),
          op['receipt'] as String,
          op['authority'] as int)) as EffectCasApplied);
    case 'superseded':
      // The adapter's compare mismatch mutated nothing: the fixture's backend
      // authority is identical on both sides of the call.
      expect(op['backend_after'], equals(op['backend_before']),
          reason: '$where: a compare mismatch must have zero backend mutation');
      return _failureWire(
          _outcome(p.recordSuperseded(key(), attempt(), op['observed'] as int))
              as EffectCasFailure);
    case 'retryable':
      return _failureWire(_outcome(p.recordRetryable(
              key(), attempt(), op['error'] as String, op['retry_at'] as int))
          as EffectCasFailure);
    case 'rejected':
      return _failureWire(
          _outcome(p.recordRejected(key(), attempt(), op['error'] as String))
              as EffectCasFailure);
    case 'reconnect':
      return _reconnectWire(
          _outcome(p.reconnect(op['generation'] as int)) as EffectCasReconnect);
    case final other:
      throw StateError('$where: unknown effect-CAS op `$other`');
  }
}

Map<String, dynamic> _finalWire(
    EffectCasSnapshot<String, int, String, String, String> snapshot) {
  return {
    for (final MapEntry(:key, value: state) in snapshot.keys.entries)
      key: {
        'pending_identity': state.pending?.intent.identity.value,
        'inflight_identity': state.inflight?.identity.effect.value,
        'applied_through': state.appliedThrough,
        'terminal': state.terminal?.kind.wireName,
        'receipt_count': state.terminal?.receipts.length ?? 0,
        'retry_at': state.retry?.retryAt,
      },
  };
}

void main() {
  final flavors = <String, _Model Function(int)>{
    'core': _CoreModel.new,
    'single-threaded': _SyncModel.new,
    'thread-safe': _ThreadSafeModel.new,
    'async': _AsyncModel.new,
  };

  test('the effect-CAS corpus is present and non-trivial', () {
    final fixture = _fixture();
    expect(fixture['kind'], 'EffectCas');
    expect(fixture['model'], 'EffectCasCore');
    final scenarios = fixture['scenarios'] as List;
    expect(scenarios, isNotEmpty);
    for (final raw in scenarios) {
      expect(((raw as Map)['steps'] as List), isNotEmpty,
          reason: '${raw['id']}: a scenario with no steps is vacuous');
    }
  });

  for (final MapEntry(key: name, value: create) in flavors.entries) {
    test('$name replays EffectCasCore conformance exactly', () {
      final fixture = _fixture();
      expect(fixture['model'], 'EffectCasCore');
      final loadedScenarios = (fixture['scenarios'] as List).length;
      final loadedSteps = (fixture['scenarios'] as List)
          .fold<int>(0, (n, s) => n + ((s as Map)['steps'] as List).length);
      var scenarios = 0;
      var steps = 0;
      for (final scenario in scenariosOf(fixture)) {
        final id = scenario['id'] as String;
        final model = create(scenario['generation'] as int);
        final attempts = <String, EffectAttemptIdentity>{};
        final rawSteps =
            (scenario['steps'] as List).cast<Map<String, dynamic>>();
        for (var i = 0; i < rawSteps.length; i++) {
          final step = rawSteps[i];
          final where = '$name $id step $i (${step['op']['type']})';
          expect(
              _runStep(model, attempts, step, where), equals(step['returns']),
              reason: '$where: returned outcome');
          steps++;
        }
        expect(_finalWire(model.snapshot()), equals(scenario['final']),
            reason: '$name $id: final state');
        scenarios++;
      }
      expect(scenarios, loadedScenarios,
          reason: '$name: loaded $loadedScenarios scenarios, replayed '
              '$scenarios');
      expect(steps, loadedSteps,
          reason: '$name: loaded $loadedSteps steps, executed $steps');
      expect(steps, greaterThan(0));
    });
  }

  group('reader invalidation', () {
    EffectIntent<String, int, String> intent(String id, int epoch) =>
        EffectIntent(
          identity: EffectIdentity(id),
          epoch: epoch,
          key: 'doc',
          expected: 0,
          plan: EffectPlan.single('write'),
        );

    test('single-threaded: a change dirties the snapshot, a no-op does not',
        () {
      final ctx = Context();
      final cas = EffectCas<String, int, String, String, String>(ctx, 3);
      cas.snapshot();
      expect(ctx.contains(cas.stateHandle), isTrue);
      cas.upsertDesired(intent('e', 1));
      expect(ctx.contains(cas.stateHandle), isFalse);
      final claimed = cas.claim('doc', 3, 0)
          as EffectCasClaimed<String, int, String, String>;
      cas.reconnect(4);
      cas.snapshot();
      expect(cas.recordApplied('doc', claimed.attempt.identity, 'late', 1),
          const EffectCasAppliedStaleGeneration(4));
      expect(ctx.contains(cas.stateHandle), isTrue,
          reason: 'a stale receipt changes no reader version');
    });

    test('thread-safe: a change dirties the snapshot, a no-op does not', () {
      final ctx = ThreadSafeContext();
      final cas =
          ThreadSafeEffectCas<String, int, String, String, String>(ctx, 1);
      cas.snapshot();
      cas.upsertDesired(intent('e', 1));
      expect(ctx.context.contains(cas.stateHandle), isFalse);
      cas.snapshot();
      expect(cas.claim('doc', 9, 0),
          const EffectCasClaimStaleGeneration<String, int, String, String>(1));
      expect(ctx.context.contains(cas.stateHandle), isTrue);
    });

    test('async: a change dirties the snapshot, a no-op does not', () {
      final ctx = AsyncContext();
      final cas = AsyncEffectCas<String, int, String, String, String>(ctx, 1);
      cas.snapshot();
      cas.upsertDesired(intent('e', 1));
      expect(ctx.isSet(cas.stateHandle), isFalse);
      cas.snapshot();
      expect(
          cas.upsertDesired(intent('e', 1)), const EffectCasUpsertUnchanged());
      expect(ctx.isSet(cas.stateHandle), isTrue);
    });
  });

  group('upsert admission', () {
    EffectIntent<String, int, String> intent(String id, int epoch,
            [String step = 'write']) =>
        EffectIntent(
          identity: EffectIdentity(id),
          epoch: epoch,
          key: 'doc',
          expected: 0,
          plan: EffectPlan.single(step),
        );

    test('equal epoch is idempotent or a conflict; older is stale', () {
      final core = _Core(1);
      expect(core.upsertDesired(intent('a', 2)).$2,
          const EffectCasUpsertAccepted());
      expect(core.upsertDesired(intent('a', 2)).$2,
          const EffectCasUpsertUnchanged());
      expect(core.upsertDesired(intent('a', 2, 'other')).$2,
          const EffectCasUpsertEpochConflict());
      expect(core.upsertDesired(intent('a', 1)).$2,
          const EffectCasUpsertStaleEpoch(2));
      final claimed = core.claim('doc', 1, 0).$2
          as EffectCasClaimed<String, int, String, String>;
      core.recordApplied('doc', claimed.attempt.identity, 'r', 1);
      expect(core.upsertDesired(intent('a', 2)).$2,
          const EffectCasUpsertAlreadyApplied(2));
    });

    test('retry waits for the logical clock', () {
      final core = _Core(1);
      core.upsertDesired(intent('a', 1));
      final claimed = core.claim('doc', 1, 0).$2
          as EffectCasClaimed<String, int, String, String>;
      expect(
          core.recordRetryable('doc', claimed.attempt.identity, 'busy', 9).$2,
          const EffectCasFailureRetrying(9));
      expect(core.pendingKeys(8), isEmpty);
      expect(core.claim('doc', 1, 8).$2,
          const EffectCasClaimWaiting<String, int, String, String>(9));
      expect(core.pendingKeys(9), ['doc']);
      final retried = core.claim('doc', 1, 9).$2
          as EffectCasClaimed<String, int, String, String>;
      expect(retried.attempt.identity.attempt, 2);
      expect(retried.attempt.identity.effect, claimed.attempt.identity.effect);
    });
  });

  group('durable image (#lzeffectcasdurable)', () {
    test('hydrate restores an observably identical core', () {
      final core = _Core(5);
      core.upsertDesired(EffectIntent(
        identity: EffectIdentity('plan'),
        epoch: 1,
        key: 'doc',
        expected: 10,
        plan: EffectPlan(['canonical', 'snapshot']),
      ));
      final first = core.claim('doc', 5, 0).$2
          as EffectCasClaimed<String, int, String, String>;
      core.recordApplied('doc', first.attempt.identity, 'r0', 11);
      core.claim('doc', 5, 0);
      final image = core.durableState();
      final restored = EffectCasCore.hydrate(image);
      expect(restored.snapshot(), core.snapshot());
      expect(restored.durableState(), image);
      expect(
          restored.reconnect(6).$2, const EffectCasReconnectAdvanced(6, 1, 0));
      final replay = restored.claim('doc', 6, 0).$2
          as EffectCasClaimed<String, int, String, String>;
      expect(replay.attempt.identity.effect.value, 'plan');
      expect(replay.attempt.identity.step, 1);
      expect(replay.attempt.expected, 11);
      expect(replay.attempt.priorReceipts, hasLength(1));
    });

    test('a corrupt image is refused, never repaired', () {
      final core = _Core(2);
      core.upsertDesired(EffectIntent(
        identity: EffectIdentity('e'),
        epoch: 1,
        key: 'doc',
        expected: 0,
        plan: EffectPlan.single('write'),
      ));
      core.claim('doc', 2, 0);
      final image = core.durableState();
      final key = image.keys.single;
      expect(
        () => EffectCasCore.hydrate(EffectCasDurableState(1, [key])),
        throwsA(isA<EffectCasHydrateException>().having(
            (e) => e.error, 'error', EffectCasHydrateError.futureGeneration)),
      );
      expect(
        () => EffectCasCore.hydrate(EffectCasDurableState(2, [key, key])),
        throwsA(isA<EffectCasHydrateException>().having(
            (e) => e.error, 'error', EffectCasHydrateError.duplicateKey)),
      );
      final wrongKey = EffectCasDurableKey<String, int, String, String, String>(
        key: 'other',
        inflight: key.inflight,
      );
      expect(
        () => EffectCasCore.hydrate(EffectCasDurableState(2, [wrongKey])),
        throwsA(isA<EffectCasHydrateException>().having(
            (e) => e.error, 'error', EffectCasHydrateError.keyMismatch)),
      );
    });

    test('identities and plans refuse empty values', () {
      expect(() => EffectIdentity(''), throwsArgumentError);
      expect(() => EffectPlan<String>(const []), throwsArgumentError);
    });
  });
}
