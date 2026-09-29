library;

import 'dart:convert';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

const _fixturePath = 'simulation/consumer_testkit.json';

final class _World implements SimConsumerWorldEvidence {
  @override
  final Object identity = Object();

  @override
  int steps = 0;

  final List<SimConsumerTraceEntry> _trace = [];

  @override
  List<SimConsumerTraceEntry> get trace => List.unmodifiable(_trace);

  void execute(SimConsumerAction action, void Function() reducer) {
    reducer();
    steps++;
    _trace.add(
      SimConsumerTraceEntry(actionId: action.id, kind: 'action_accepted'),
    );
  }
}

final class _AdapterState {
  int value = 0;
  int probes = 0;
  int resets = 0;
  int applications = 0;
  _World? world;
  final List<SimConsumerAction> history = [];
}

void main() {
  test('replays the canonical consumer simulation testkit corpus', () {
    final fixture = attributeFixture(jsonDecode(specReadFixture(_fixturePath)))!
        as Map<String, dynamic>;
    expect(fixture['schema_version'], 1);
    expect(fixture['kind'], 'ConsumerSimulationTestkit');

    final generated = _scenario(fixture);
    var index = 0;
    for (final scenarioFixture in scenariosOf(fixture)) {
      final id = scenarioIdOf(scenarioFixture, index++);
      final states = <String, _AdapterState>{};
      final adapters = <SimConsumerAdapter>[
        for (final raw in scenarioFixture['adapters'] as List)
          _adapter((raw as Map).cast<String, dynamic>(), fixture, states),
      ];
      final kit = SimConsumerTestkit(
        SimConsumerTestkitSpec(
          simulationAdapterId:
              scenarioFixture['simulation_adapter_id'] as String,
          requiredRealAdapters: [
            for (final raw in scenarioFixture['required_real_adapters'] as List)
              _adapterKind(raw as String),
          ],
          requiredExternalProcesses: [
            for (final raw
                in scenarioFixture['required_external_processes'] as List)
              SimConsumerExternalProcessSelection(
                adapterId: (raw as Map)['adapter_id'] as String,
                port: _externalPort(raw['port'] as String),
              ),
          ],
          adapters: adapters,
        ),
      );
      final expected = assertionsOf(
        scenarioFixture['expected'],
        '$_fixturePath scenario $id expected',
      );
      final outcome = expected['outcome'] as String;

      switch (outcome) {
        case 'success':
          final result = kit.run(generated);
          assertKey(expected, 'outcome', 'success');
          assertKey(expected, 'adapter_ids', result.adapterIds);
          assertKey(
            expected,
            'checkpoint_steps',
            result.checkpoints.map((checkpoint) => checkpoint.step).toList(),
          );
          assertKey(expected, 'checkpoint_values', const [1, 3, 6]);
          expect(result.scenarioDigest, isNotEmpty);
          assertKeyIfPresent(expected, 'checkpoint_action_ids', (want) {
            expect(
              result.checkpoints
                  .map((checkpoint) => checkpoint.actionId)
                  .toList(),
              want,
            );
          });
          assertKeyIfPresent(expected, 'observation_relation', (want) {
            expect(want, 'all_equal_at_every_checkpoint');
            for (final checkpoint in result.checkpoints) {
              expect(
                checkpoint.observationDigests.values.toSet(),
                hasLength(1),
              );
            }
          });
          assertKeyIfPresent(
            expected,
            'materialized_history_relation',
            (want) => expect(want, 'exact_prefix_at_every_checkpoint'),
          );
          assertKeyIfPresent(expected, 'probe_relation', (want) {
            expect(want, 'every_real_adapter_once');
            expect(
              states.entries
                  .where((entry) => entry.key != 'memory')
                  .every((entry) => entry.value.probes == 1),
              isTrue,
            );
          });
          SimConsumerAdapterEvidence? selectedEvidence;
          assertKeyIfPresent(expected, 'external_adapter_id', (want) {
            selectedEvidence = result.adapterEvidence.singleWhere(
              (evidence) => evidence.adapterId == want,
            );
            expect(selectedEvidence!.adapterId, want);
          });
          if (selectedEvidence case final evidence?) {
            assertKey(
              expected,
              'external_port',
              evidence.externalPort!.wireName,
            );
            assertKey(expected, 'external_protocol_id', evidence.protocolId);
            assertKey(expected, 'external_reducer_id', evidence.reducerId);
            assertKey(
              expected,
              'external_production_reducer_id',
              evidence.productionReducerId,
            );
          }
        case 'observation_divergence':
          final error = _capture<SimConsumerDivergenceError>(
            () => kit.run(generated),
          );
          assertKey(expected, 'outcome', 'observation_divergence');
          assertKey(expected, 'step', error.step);
          assertKey(expected, 'action_id', error.actionId);
          assertKey(expected, 'adapter_id', error.adapterId);
          assertKey(expected, 'observation_id', error.observationId);
        case 'materialized_history_mismatch':
          final error = _capture<SimConsumerHistoryMismatchError>(
            () => kit.run(generated),
          );
          assertKey(expected, 'outcome', 'materialized_history_mismatch');
          assertKey(expected, 'step', error.step);
          assertKey(expected, 'action_id', error.actionId);
          assertKey(expected, 'adapter_id', error.adapterId);
          assertKey(
            expected,
            'expected_prefix_length',
            error.expectedPrefixLength,
          );
          assertKey(expected, 'actual_prefix_length', error.actualPrefixLength);
        case 'simulation_world_bypass':
          final error = _capture<SimConsumerWorldBypassError>(
            () => kit.run(generated),
          );
          assertKey(expected, 'outcome', 'simulation_world_bypass');
          assertKey(expected, 'step', error.step);
          assertKey(expected, 'action_id', error.actionId);
          assertKey(expected, 'adapter_id', error.adapterId);
        default:
          fail('unknown canonical consumer-testkit outcome $outcome');
      }
    }
  });

  test('rejects invalid construction before invoking callbacks', () {
    var callbacks = 0;
    final memory = _minimalAdapter(
      id: 'memory',
      kind: SimConsumerAdapterKind.inMemory,
      stubDeterministicPort: true,
      callback: () => callbacks++,
    );
    final postgres = _minimalAdapter(
      id: 'postgres.integration',
      kind: SimConsumerAdapterKind.postgres,
      callback: () => callbacks++,
    );
    expect(
      () => SimConsumerTestkit(
        SimConsumerTestkitSpec(
          simulationAdapterId: 'memory',
          requiredRealAdapters: const [SimConsumerAdapterKind.postgres],
          adapters: [memory, postgres],
        ),
      ),
      throwsA(isA<SimConsumerConformanceError>()),
    );
    expect(callbacks, 0);
  });

  test('rejects an invalid generated scenario before invoking callbacks', () {
    var callbacks = 0;
    final kit = SimConsumerTestkit(
      SimConsumerTestkitSpec(
        simulationAdapterId: 'memory',
        requiredRealAdapters: const [SimConsumerAdapterKind.postgres],
        adapters: [
          _minimalAdapter(
            id: 'memory',
            kind: SimConsumerAdapterKind.inMemory,
            callback: () => callbacks++,
          ),
          _minimalAdapter(
            id: 'postgres.integration',
            kind: SimConsumerAdapterKind.postgres,
            callback: () => callbacks++,
          ),
        ],
      ),
    );
    expect(
      () => kit.run(
        SimGeneratedScenario(
          generatorName: 'consumer.scenario',
          generatorVersion: '1',
          seedHex: 'not-a-seed',
          actions: const [
            SimGeneratedAction(
              command: 'increment',
              action: SimConsumerAction(
                id: 'increment.0',
                actorId: 'consumer',
                kind: 'counter.increment',
                version: '1',
                payload: 1,
              ),
            ),
          ],
        ),
      ),
      throwsA(isA<SimConsumerConformanceError>()),
    );
    expect(callbacks, 0);
  });
}

T _capture<T extends Object>(void Function() run) {
  try {
    run();
  } catch (error) {
    expect(error, isA<T>());
    return error as T;
  }
  fail('expected $T');
}

SimGeneratedScenario _scenario(Map<String, dynamic> fixture) {
  final generator = (fixture['generator'] as Map).cast<String, dynamic>();
  return SimGeneratedScenario(
    generatorName: 'consumer.scenario',
    generatorVersion: generator['version'] as String,
    seedHex: fixture['seed'] as String,
    actions: [
      for (final raw in fixture['actions'] as List)
        SimGeneratedAction(
          command: 'increment',
          action: _action((raw as Map).cast<String, dynamic>()),
        ),
    ],
  );
}

SimConsumerAction _action(Map<String, dynamic> raw) => SimConsumerAction(
      id: raw['id'] as String,
      actorId: raw['actor_id'] as String,
      kind: raw['kind'] as String,
      version: raw['version'] as String,
      payload: raw['payload'],
      causeId: (raw['cause_id'] as String?) ?? '',
    );

SimConsumerAdapter _adapter(
  Map<String, dynamic> raw,
  Map<String, dynamic> fixture,
  Map<String, _AdapterState> states,
) {
  final id = raw['id'] as String;
  final kind = _adapterKind(raw['kind'] as String);
  final bias = raw['delta_bias'] as int;
  final historyMode = raw['history_mode'] as String;
  final executionMode = raw['execution_mode'] as String;
  final state = _AdapterState();
  states[id] = state;
  final ports = <SimConsumerPort>[
    for (final portRaw in fixture['ports'] as List)
      SimConsumerPort(
        id: (portRaw as Map)['id'] as String,
        kind: portRaw['kind'] as String,
        determinism: _determinism(portRaw['determinism'] as String),
        stubbed: kind == SimConsumerAdapterKind.inMemory &&
            portRaw['determinism'] == 'nondeterministic',
      ),
  ];
  return SimConsumerAdapter(
    id: id,
    kind: kind,
    serviceId: raw['service_id'] as String,
    reducerId: raw['reducer_id'] as String,
    productionReducerId: raw['production_reducer_id'] as String,
    protocolId: raw['protocol_id'] as String,
    externalPort: raw.containsKey('external_port')
        ? _externalPort(raw['external_port'] as String)
        : null,
    ports: ports,
    probe: kind.isReal ? () => state.probes++ : null,
    simulationWorld:
        kind == SimConsumerAdapterKind.inMemory ? () => state.world : null,
    reset: () {
      state
        ..value = 0
        ..resets += 1
        ..applications = 0
        ..history.clear();
      if (kind == SimConsumerAdapterKind.inMemory) state.world = _World();
    },
    apply: (action) {
      void reduce() {
        state.value += action.payload! as int;
        state.applications++;
      }

      if (kind == SimConsumerAdapterKind.inMemory &&
          executionMode == 'sim_world') {
        state.world!.execute(action, reduce);
      } else {
        reduce();
      }
      if (kind.isReal) {
        state.value += bias;
        if (historyMode == 'exact') state.history.add(action);
      }
    },
    observe: () => {'consumer.value': state.value},
    materializedHistory: kind.isReal
        ? () => historyMode == 'empty'
            ? const []
            : List<SimConsumerAction>.of(state.history)
        : null,
  );
}

SimConsumerAdapter _minimalAdapter({
  required String id,
  required SimConsumerAdapterKind kind,
  required void Function() callback,
  bool stubDeterministicPort = false,
}) {
  final world = _World();
  final history = <SimConsumerAction>[];
  return SimConsumerAdapter(
    id: id,
    kind: kind,
    serviceId: kind.isReal ? '$id.service' : '',
    reducerId: 'counter.reducer.v1',
    productionReducerId: 'counter.reducer.v1',
    protocolId: 'counter.protocol.v1',
    ports: [
      SimConsumerPort(
        id: 'state.store',
        kind: 'storage',
        determinism: SimConsumerPortDeterminism.deterministic,
        stubbed: stubDeterministicPort,
      ),
    ],
    probe: kind.isReal ? callback : null,
    simulationWorld:
        kind == SimConsumerAdapterKind.inMemory ? () => world : null,
    reset: callback,
    apply: (action) => callback(),
    observe: () => const {'consumer.value': 0},
    materializedHistory: kind.isReal ? () => history : null,
  );
}

SimConsumerAdapterKind _adapterKind(String wireName) =>
    SimConsumerAdapterKind.values.singleWhere(
      (kind) => kind.wireName == wireName,
      orElse: () => throw StateError('unknown adapter kind $wireName'),
    );

SimConsumerExternalPortKind _externalPort(String wireName) =>
    SimConsumerExternalPortKind.values.singleWhere(
      (kind) => kind.wireName == wireName,
      orElse: () => throw StateError('unknown external port $wireName'),
    );

SimConsumerPortDeterminism _determinism(String wireName) =>
    SimConsumerPortDeterminism.values.singleWhere(
      (kind) => kind.wireName == wireName,
      orElse: () => throw StateError('unknown determinism $wireName'),
    );
