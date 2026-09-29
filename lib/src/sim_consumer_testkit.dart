/// Cross-adapter consumer simulation conformance testkit.
library;

import 'dart:typed_data';

import 'replay.dart';

/// Execution boundary behind a consumer conformance adapter.
enum SimConsumerAdapterKind {
  inMemory('in_memory'),
  postgres('postgres'),
  nats('nats'),
  externalProcess('external_process');

  const SimConsumerAdapterKind(this.wireName);

  final String wireName;

  bool get isReal => this != inMemory;
  bool get isLegacyReal => this == postgres || this == nats;
}

/// Public integration boundary used to reach an external consumer process.
enum SimConsumerExternalPortKind {
  cli('cli'),
  filesystem('filesystem'),
  localSocket('local_socket'),
  editorReplica('editor_replica');

  const SimConsumerExternalPortKind(this.wireName);

  final String wireName;
}

enum SimConsumerPortDeterminism {
  deterministic('deterministic'),
  nondeterministic('nondeterministic');

  const SimConsumerPortDeterminism(this.wireName);

  final String wireName;
}

final class SimConsumerPort {
  const SimConsumerPort({
    required this.id,
    required this.kind,
    required this.determinism,
    this.stubbed = false,
  });

  final String id;
  final String kind;
  final SimConsumerPortDeterminism determinism;
  final bool stubbed;
}

final class SimConsumerExternalProcessSelection {
  const SimConsumerExternalProcessSelection({
    required this.adapterId,
    required this.port,
  });

  final String adapterId;
  final SimConsumerExternalPortKind port;
}

/// One trace entry exposed by a deterministic world to prove execution.
final class SimConsumerTraceEntry {
  const SimConsumerTraceEntry({required this.actionId, required this.kind});

  final String actionId;
  final String kind;
}

/// Narrow evidence seam for a deterministic simulation world.
///
/// The testkit deliberately does not prescribe a scheduler. It needs only a
/// stable identity, a monotonic step count, and append-only action trace
/// evidence.
abstract interface class SimConsumerWorldEvidence {
  Object get identity;
  int get steps;
  List<SimConsumerTraceEntry> get trace;
}

final class SimConsumerAction implements ReplayEncodable {
  const SimConsumerAction({
    required this.id,
    required this.actorId,
    required this.kind,
    required this.version,
    required this.payload,
    this.causeId = '',
  });

  final String id;
  final String actorId;
  final String kind;
  final String version;
  final Object? payload;
  final String causeId;

  @override
  Object? get replayCanonicalForm => <String, Object?>{
        'id': id,
        'actor_id': actorId,
        'kind': kind,
        'version': version,
        'payload': payload,
        'cause_id': causeId,
      };
}

final class SimGeneratedAction implements ReplayEncodable {
  const SimGeneratedAction({required this.command, required this.action});

  final String command;
  final SimConsumerAction action;

  @override
  Object? get replayCanonicalForm => <String, Object?>{
        'command': command,
        'action': action,
      };
}

final class SimGeneratedScenario implements ReplayEncodable {
  SimGeneratedScenario({
    required this.generatorName,
    required this.generatorVersion,
    required this.seedHex,
    required Iterable<SimGeneratedAction> actions,
  }) : actions = List<SimGeneratedAction>.unmodifiable(actions);

  final String generatorName;
  final String generatorVersion;
  final String seedHex;
  final List<SimGeneratedAction> actions;

  @override
  Object? get replayCanonicalForm => <String, Object?>{
        'generator_name': generatorName,
        'generator_version': generatorVersion,
        'seed_hex': seedHex,
        'actions': actions,
      };
}

typedef SimConsumerProbe = void Function();
typedef SimConsumerReset = void Function();
typedef SimConsumerApply = void Function(SimConsumerAction action);
typedef SimConsumerObserve = Map<String, Object?> Function();
typedef SimConsumerMaterializedHistory = List<SimConsumerAction> Function();
typedef SimConsumerSimulationWorld = SimConsumerWorldEvidence? Function();

final class SimConsumerAdapter {
  SimConsumerAdapter({
    required this.id,
    required this.kind,
    this.productionReducerId = '',
    required this.protocolId,
    required this.reducerId,
    this.serviceId = '',
    this.externalPort,
    required Iterable<SimConsumerPort> ports,
    this.probe,
    this.simulationWorld,
    this.reset,
    this.apply,
    this.observe,
    this.materializedHistory,
  }) : ports = List<SimConsumerPort>.unmodifiable(ports);

  final String id;
  final SimConsumerAdapterKind kind;
  final String productionReducerId;
  final String protocolId;
  final String reducerId;
  final String serviceId;
  final SimConsumerExternalPortKind? externalPort;
  final List<SimConsumerPort> ports;
  final SimConsumerProbe? probe;
  final SimConsumerSimulationWorld? simulationWorld;
  final SimConsumerReset? reset;
  final SimConsumerApply? apply;
  final SimConsumerObserve? observe;
  final SimConsumerMaterializedHistory? materializedHistory;
}

final class SimConsumerTestkitSpec {
  SimConsumerTestkitSpec({
    required this.simulationAdapterId,
    Iterable<SimConsumerAdapterKind> requiredRealAdapters = const [],
    Iterable<SimConsumerExternalProcessSelection> requiredExternalProcesses =
        const [],
    required Iterable<SimConsumerAdapter> adapters,
  })  : requiredRealAdapters = List<SimConsumerAdapterKind>.unmodifiable(
          requiredRealAdapters,
        ),
        requiredExternalProcesses =
            List<SimConsumerExternalProcessSelection>.unmodifiable(
          requiredExternalProcesses,
        ),
        adapters = List<SimConsumerAdapter>.unmodifiable(adapters);

  final String simulationAdapterId;
  final List<SimConsumerAdapterKind> requiredRealAdapters;
  final List<SimConsumerExternalProcessSelection> requiredExternalProcesses;
  final List<SimConsumerAdapter> adapters;
}

final class SimConsumerAdapterEvidence {
  const SimConsumerAdapterEvidence({
    required this.adapterId,
    required this.kind,
    required this.serviceId,
    required this.externalPort,
    required this.protocolId,
    required this.reducerId,
    required this.productionReducerId,
  });

  final String adapterId;
  final SimConsumerAdapterKind kind;
  final String serviceId;
  final SimConsumerExternalPortKind? externalPort;
  final String protocolId;
  final String reducerId;
  final String productionReducerId;
}

final class SimConsumerCheckpoint {
  SimConsumerCheckpoint({
    required this.step,
    required this.actionId,
    required Map<String, String> observationDigests,
  }) : observationDigests = Map<String, String>.unmodifiable(
          observationDigests,
        );

  final int step;
  final String actionId;
  final Map<String, String> observationDigests;
}

final class SimConsumerRunResult {
  SimConsumerRunResult({
    required this.scenarioDigest,
    required Iterable<String> adapterIds,
    required Iterable<SimConsumerAdapterEvidence> adapterEvidence,
    required Iterable<SimConsumerCheckpoint> checkpoints,
  })  : adapterIds = List<String>.unmodifiable(adapterIds),
        adapterEvidence = List<SimConsumerAdapterEvidence>.unmodifiable(
          adapterEvidence,
        ),
        checkpoints = List<SimConsumerCheckpoint>.unmodifiable(checkpoints);

  final String scenarioDigest;
  final List<String> adapterIds;
  final List<SimConsumerAdapterEvidence> adapterEvidence;
  final List<SimConsumerCheckpoint> checkpoints;
}

class SimConsumerConformanceError implements Exception {
  const SimConsumerConformanceError(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'consumer simulation conformance failed: $message';
}

final class SimConsumerDivergenceError extends SimConsumerConformanceError {
  SimConsumerDivergenceError({
    required this.step,
    required this.actionId,
    required this.baselineAdapterId,
    required this.adapterId,
    required this.observationId,
    required this.divergenceKind,
  }) : super(
          "step $step action '$actionId' adapter '$adapterId' differs from "
          "'$baselineAdapterId': $divergenceKind"
          "${observationId.isEmpty ? '' : " observation '$observationId'"}",
        );

  final int step;
  final String actionId;
  final String baselineAdapterId;
  final String adapterId;
  final String observationId;
  final String divergenceKind;
}

final class SimConsumerHistoryMismatchError
    extends SimConsumerConformanceError {
  SimConsumerHistoryMismatchError({
    required this.step,
    required this.actionId,
    required this.adapterId,
    required this.expectedPrefixLength,
    required this.actualPrefixLength,
  }) : super(
          "step $step action '$actionId' adapter '$adapterId' materialized "
          'history contains $actualPrefixLength actions, want exact prefix of '
          '$expectedPrefixLength',
        );

  final int step;
  final String actionId;
  final String adapterId;
  final int expectedPrefixLength;
  final int actualPrefixLength;
}

final class SimConsumerWorldBypassError extends SimConsumerConformanceError {
  SimConsumerWorldBypassError({
    required this.step,
    required this.actionId,
    required this.adapterId,
  }) : super(
          "step $step action '$actionId' adapter '$adapterId' did not execute "
          'through its simulation world',
        );

  final int step;
  final String actionId;
  final String adapterId;
}

/// Runs a generated history through one simulation baseline and selected real
/// adapters, failing at the first unsupported or unequal checkpoint.
final class SimConsumerTestkit {
  SimConsumerTestkit(SimConsumerTestkitSpec input) {
    final normalized = _validateAndNormalize(input);
    _spec = normalized.$1;
    _baselineIndex = normalized.$2;
  }

  late final SimConsumerTestkitSpec _spec;
  late final int _baselineIndex;

  SimConsumerRunResult run(SimGeneratedScenario scenario) {
    _validateScenario(scenario);
    final scenarioDigest = canonicalDigest(scenario);

    for (final adapter in _spec.adapters) {
      try {
        if (adapter.kind.isReal) adapter.probe!();
        adapter.reset!();
      } on SimConsumerConformanceError {
        rethrow;
      } catch (error) {
        throw SimConsumerConformanceError(
          "prepare adapter '${adapter.id}'",
          error,
        );
      }
      if (adapter.kind == SimConsumerAdapterKind.inMemory &&
          adapter.simulationWorld!() == null) {
        _fail(
          "reset adapter '${adapter.id}' did not create its simulation world",
        );
      }
      if (adapter.kind.isReal) _validateHistory(adapter, const [], 0, '');
    }

    final checkpoints = <SimConsumerCheckpoint>[];
    for (var actionIndex = 0;
        actionIndex < scenario.actions.length;
        actionIndex++) {
      final step = actionIndex + 1;
      final action = scenario.actions[actionIndex].action;
      final observed = List<Map<String, Object?>>.filled(
        _spec.adapters.length,
        const {},
      );
      final digests = <String, String>{};

      for (var adapterIndex = 0;
          adapterIndex < _spec.adapters.length;
          adapterIndex++) {
        final adapter = _spec.adapters[adapterIndex];
        final beforeWorld = adapter.kind == SimConsumerAdapterKind.inMemory
            ? adapter.simulationWorld!()
            : null;
        final beforeSteps = beforeWorld?.steps ?? 0;
        final beforeTrace = beforeWorld?.trace.length ?? 0;

        try {
          adapter.apply!(_cloneAction(action));
        } catch (error) {
          throw SimConsumerConformanceError(
            "step $step action '${action.id}' apply adapter '${adapter.id}'",
            error,
          );
        }

        if (beforeWorld != null) {
          final afterWorld = adapter.simulationWorld!();
          final executed = afterWorld != null &&
              identical(afterWorld.identity, beforeWorld.identity) &&
              afterWorld.steps > beforeSteps &&
              afterWorld.trace.skip(beforeTrace).any(
                    (entry) =>
                        entry.actionId == action.id &&
                        entry.kind.startsWith('action_'),
                  );
          if (!executed) {
            throw SimConsumerWorldBypassError(
              step: step,
              actionId: action.id,
              adapterId: adapter.id,
            );
          }
        }
        if (adapter.kind.isReal) {
          _validateHistory(
            adapter,
            scenario.actions.take(actionIndex + 1).toList(growable: false),
            step,
            action.id,
          );
        }

        late final Map<String, Object?> values;
        try {
          values = adapter.observe!();
        } catch (error) {
          throw SimConsumerConformanceError(
            "step $step action '${action.id}' observe adapter '${adapter.id}'",
            error,
          );
        }
        if (values.isEmpty) {
          _fail(
            "step $step action '${action.id}' adapter '${adapter.id}' "
            'returned no observations',
          );
        }
        final frozen = _freezeObservation(values);
        observed[adapterIndex] = frozen;
        digests[adapter.id] = canonicalDigest(frozen);
      }

      final baseline = observed[_baselineIndex];
      final baselineId = _spec.adapters[_baselineIndex].id;
      for (var adapterIndex = 0;
          adapterIndex < _spec.adapters.length;
          adapterIndex++) {
        if (adapterIndex != _baselineIndex) {
          final adapter = _spec.adapters[adapterIndex];
          _compareObservations(
            step,
            action.id,
            baselineId,
            adapter.id,
            baseline,
            observed[adapterIndex],
          );
        }
      }
      checkpoints.add(
        SimConsumerCheckpoint(
          step: step,
          actionId: action.id,
          observationDigests: digests,
        ),
      );
    }

    return SimConsumerRunResult(
      scenarioDigest: scenarioDigest,
      adapterIds: _spec.adapters.map((adapter) => adapter.id),
      adapterEvidence: _spec.adapters.map(
        (adapter) => SimConsumerAdapterEvidence(
          adapterId: adapter.id,
          kind: adapter.kind,
          serviceId: adapter.serviceId,
          externalPort: adapter.externalPort,
          protocolId: adapter.protocolId,
          reducerId: adapter.reducerId,
          productionReducerId: adapter.productionReducerId,
        ),
      ),
      checkpoints: checkpoints,
    );
  }

  static void _validateHistory(
    SimConsumerAdapter adapter,
    List<SimGeneratedAction> expected,
    int step,
    String actionId,
  ) {
    late final List<SimConsumerAction> history;
    try {
      history = adapter.materializedHistory!();
    } catch (error) {
      throw SimConsumerConformanceError(
        "read materialized history for '${adapter.id}'",
        error,
      );
    }
    if (history.length != expected.length) {
      throw SimConsumerHistoryMismatchError(
        step: step,
        actionId: actionId,
        adapterId: adapter.id,
        expectedPrefixLength: expected.length,
        actualPrefixLength: history.length,
      );
    }
    for (var index = 0; index < expected.length; index++) {
      if (!_bytesEqual(
        canonicalBytes(expected[index].action),
        canonicalBytes(history[index]),
      )) {
        throw SimConsumerHistoryMismatchError(
          step: step,
          actionId: actionId,
          adapterId: adapter.id,
          expectedPrefixLength: expected.length,
          actualPrefixLength: history.length,
        );
      }
    }
  }

  static (SimConsumerTestkitSpec, int) _validateAndNormalize(
    SimConsumerTestkitSpec spec,
  ) {
    if (!_validId(spec.simulationAdapterId)) {
      _fail('simulation adapter needs a stable id');
    }
    if (spec.requiredRealAdapters.isEmpty &&
        spec.requiredExternalProcesses.isEmpty) {
      _fail(
        'select at least one real Postgres/NATS adapter or external process',
      );
    }
    if (spec.adapters.length < 2) {
      _fail('testkit needs an in-memory adapter and at least one real adapter');
    }

    final required = <SimConsumerAdapterKind>{};
    for (final kind in spec.requiredRealAdapters) {
      if (!kind.isLegacyReal) {
        _fail(
          "required adapter kind '${kind.wireName}' is not Postgres or NATS",
        );
      }
      if (!required.add(kind)) {
        _fail("duplicate required real adapter kind '${kind.wireName}'");
      }
    }
    final requiredExternal = <String, SimConsumerExternalPortKind>{};
    for (final selection in spec.requiredExternalProcesses) {
      if (!_validId(selection.adapterId)) {
        _fail('external-process selection needs a stable adapter id');
      }
      if (requiredExternal.containsKey(selection.adapterId)) {
        _fail(
          "duplicate required external-process adapter '${selection.adapterId}'",
        );
      }
      requiredExternal[selection.adapterId] = selection.port;
    }

    final adapters = List<SimConsumerAdapter>.of(spec.adapters)
      ..sort((left, right) => left.id.compareTo(right.id));
    final seenIds = <String>{};
    final presentKinds = <SimConsumerAdapterKind>{};
    var productionReducerId = '';
    var protocolId = '';
    List<String>? portContract;
    for (final adapter in adapters) {
      _validateAdapter(adapter);
      if (!seenIds.add(adapter.id))
        _fail("duplicate adapter id '${adapter.id}'");
      presentKinds.add(adapter.kind);
      final selectedExternal = requiredExternal[adapter.id];
      if (selectedExternal != null &&
          adapter.kind != SimConsumerAdapterKind.externalProcess) {
        _fail(
          "external-process selection '${adapter.id}' refers to adapter kind "
          "'${adapter.kind.wireName}'",
        );
      }
      if (adapter.kind.isLegacyReal && !required.contains(adapter.kind)) {
        _fail(
          "real adapter '${adapter.id}' kind '${adapter.kind.wireName}' was not "
          'explicitly selected',
        );
      } else if (adapter.kind == SimConsumerAdapterKind.externalProcess &&
          selectedExternal == null) {
        _fail(
          "external-process adapter '${adapter.id}' was not explicitly selected",
        );
      } else if (adapter.kind == SimConsumerAdapterKind.externalProcess &&
          adapter.externalPort != selectedExternal) {
        _fail(
          "external-process adapter '${adapter.id}' uses port "
          "'${adapter.externalPort?.wireName}', selected "
          "'${selectedExternal?.wireName}'",
        );
      }
      if (adapter.kind != SimConsumerAdapterKind.externalProcess) {
        productionReducerId = productionReducerId.isEmpty
            ? adapter.productionReducerId
            : productionReducerId;
        if (adapter.productionReducerId != productionReducerId) {
          _fail(
            "adapter '${adapter.id}' does not use the shared production reducer "
            "'$productionReducerId'",
          );
        }
      }
      protocolId = protocolId.isEmpty ? adapter.protocolId : protocolId;
      if (adapter.protocolId != protocolId) {
        _fail(
          "adapter '${adapter.id}' does not use shared protocol '$protocolId'",
        );
      }
      final contract = adapter.ports
          .map(
            (port) =>
                '${port.id}\u0000${port.kind}\u0000${port.determinism.wireName}',
          )
          .toList()
        ..sort();
      if (portContract == null) {
        portContract = contract;
      } else if (!_listEqual(portContract, contract)) {
        _fail(
          "adapter '${adapter.id}' does not expose the shared narrow-port contract",
        );
      }
    }
    if (portContract == null || portContract.isEmpty) {
      _fail('consumer adapters must declare at least one narrow port');
    }
    for (final kind in required) {
      if (!presentKinds.contains(kind)) {
        _fail("required real adapter kind '${kind.wireName}' is missing");
      }
    }
    for (final adapterId in requiredExternal.keys) {
      if (!seenIds.contains(adapterId)) {
        _fail("required external-process adapter '$adapterId' is missing");
      }
    }
    final baseline = adapters.indexWhere(
      (adapter) => adapter.id == spec.simulationAdapterId,
    );
    if (baseline < 0) {
      _fail("simulation adapter '${spec.simulationAdapterId}' is missing");
    }
    if (adapters[baseline].kind != SimConsumerAdapterKind.inMemory) {
      _fail(
        "simulation adapter '${spec.simulationAdapterId}' must have kind 'in_memory'",
      );
    }
    return (
      SimConsumerTestkitSpec(
        simulationAdapterId: spec.simulationAdapterId,
        requiredRealAdapters: spec.requiredRealAdapters,
        requiredExternalProcesses: spec.requiredExternalProcesses,
        adapters: adapters,
      ),
      baseline,
    );
  }

  static void _validateAdapter(SimConsumerAdapter adapter) {
    if (!_validId(adapter.id) ||
        !_validId(adapter.protocolId) ||
        !_validId(adapter.reducerId)) {
      _fail('adapter needs stable adapter, protocol, and reducer ids');
    }
    if (adapter.reset == null ||
        adapter.apply == null ||
        adapter.observe == null) {
      _fail(
        "adapter '${adapter.id}' needs reset, apply, and observe callbacks",
      );
    }
    switch (adapter.kind) {
      case SimConsumerAdapterKind.inMemory:
        if (!_validId(adapter.productionReducerId)) {
          _fail('in-memory adapter needs a production reducer id');
        }
        if (adapter.serviceId.isNotEmpty ||
            adapter.probe != null ||
            adapter.externalPort != null ||
            adapter.materializedHistory != null) {
          _fail(
            "in-memory adapter '${adapter.id}' cannot claim a real service",
          );
        }
        if (adapter.simulationWorld == null) {
          _fail(
            "in-memory adapter '${adapter.id}' must expose its simulation world",
          );
        }
      case SimConsumerAdapterKind.postgres:
      case SimConsumerAdapterKind.nats:
        if (!_validId(adapter.productionReducerId)) {
          _fail("real adapter '${adapter.id}' needs a production reducer id");
        }
        if (adapter.reducerId != adapter.productionReducerId) {
          _fail('real adapter reducer evidence must match production reducer');
        }
        if (adapter.externalPort != null) {
          _fail(
            "real adapter '${adapter.id}' cannot claim an external-process port",
          );
        }
        _validateRealAdapter(adapter);
      case SimConsumerAdapterKind.externalProcess:
        _validateRealAdapter(adapter);
        if (adapter.externalPort == null) {
          _fail(
            "external-process adapter '${adapter.id}' needs a supported port",
          );
        }
        if (adapter.productionReducerId.isNotEmpty) {
          _fail(
            "external-process adapter '${adapter.id}' must not claim the "
            'in-memory production reducer',
          );
        }
    }
    final ports = <String>{};
    for (final port in adapter.ports) {
      if (!_validId(port.id) || !_validId(port.kind)) {
        _fail("adapter '${adapter.id}' has a port without stable id and kind");
      }
      if (!ports.add(port.id)) {
        _fail("adapter '${adapter.id}' has duplicate port '${port.id}'");
      }
      if (port.stubbed &&
          port.determinism != SimConsumerPortDeterminism.nondeterministic) {
        _fail("adapter '${adapter.id}' stubs deterministic port '${port.id}'");
      }
      if (adapter.kind.isReal && port.stubbed) {
        _fail("real adapter '${adapter.id}' cannot stub port '${port.id}'");
      }
    }
  }

  static void _validateRealAdapter(SimConsumerAdapter adapter) {
    if (!_validId(adapter.serviceId) ||
        adapter.probe == null ||
        adapter.materializedHistory == null) {
      _fail(
        "real adapter '${adapter.id}' needs a stable service id, probe, and "
        'materializedHistory',
      );
    }
    if (adapter.simulationWorld != null) {
      _fail("real adapter '${adapter.id}' cannot expose a simulation world");
    }
  }

  static final RegExp _seed = RegExp(r'^[0-9a-f]{64}$');
  static final RegExp _identifier = RegExp(r'^[a-z][a-z0-9._:-]{0,127}$');

  static void _validateScenario(SimGeneratedScenario scenario) {
    if (scenario.generatorName.trim().isEmpty ||
        scenario.generatorVersion.isEmpty) {
      _fail('scenario needs a stable generator name and version');
    }
    if (!_seed.hasMatch(scenario.seedHex)) {
      _fail('scenario seed must be exactly 32 bytes of lowercase hexadecimal');
    }
    if (scenario.actions.isEmpty) {
      _fail('scenario must contain at least one generated action');
    }
    final seen = <String>{};
    for (final generated in scenario.actions) {
      if (!_validId(generated.command)) {
        _fail(
          "scenario action '${generated.action.id}' has no stable generator command",
        );
      }
      final action = generated.action;
      if (!_validId(action.id) ||
          !_validId(action.actorId) ||
          !_validId(action.kind) ||
          action.version.isEmpty) {
        _fail('scenario contains an invalid action');
      }
      canonicalBytes(action);
      if (!seen.add(action.id)) {
        _fail("scenario has duplicate action id '${action.id}'");
      }
      if (action.causeId.isNotEmpty && !seen.contains(action.causeId)) {
        _fail(
          "scenario action '${action.id}' has unresolved cause '${action.causeId}'",
        );
      }
    }
  }

  static void _compareObservations(
    int step,
    String actionId,
    String baselineId,
    String adapterId,
    Map<String, Object?> baseline,
    Map<String, Object?> actual,
  ) {
    if (baseline.length != actual.length) {
      throw SimConsumerDivergenceError(
        step: step,
        actionId: actionId,
        baselineAdapterId: baselineId,
        adapterId: adapterId,
        observationId: '',
        divergenceKind: 'observation count',
      );
    }
    final keys = baseline.keys.toList()..sort();
    for (final key in keys) {
      if (!actual.containsKey(key)) {
        throw SimConsumerDivergenceError(
          step: step,
          actionId: actionId,
          baselineAdapterId: baselineId,
          adapterId: adapterId,
          observationId: key,
          divergenceKind: 'missing',
        );
      }
      if (!_bytesEqual(
        canonicalBytes(baseline[key]),
        canonicalBytes(actual[key]),
      )) {
        throw SimConsumerDivergenceError(
          step: step,
          actionId: actionId,
          baselineAdapterId: baselineId,
          adapterId: adapterId,
          observationId: key,
          divergenceKind: 'value mismatch',
        );
      }
    }
  }

  static SimConsumerAction _cloneAction(SimConsumerAction action) =>
      SimConsumerAction(
        id: action.id,
        actorId: action.actorId,
        kind: action.kind,
        version: action.version,
        payload: _deepCopy(action.payload),
        causeId: action.causeId,
      );

  static Map<String, Object?> _freezeObservation(Map<String, Object?> values) {
    final keys = values.keys.toList()..sort();
    return Map<String, Object?>.unmodifiable({
      for (final key in keys) key: _deepCopy(values[key]),
    });
  }

  static Object? _deepCopy(Object? value) {
    if (value is Uint8List) return Uint8List.fromList(value);
    if (value is Map) {
      return Map<Object?, Object?>.unmodifiable({
        for (final entry in value.entries)
          _deepCopy(entry.key): _deepCopy(entry.value),
      });
    }
    if (value is Set) {
      return Set<Object?>.unmodifiable(value.map(_deepCopy));
    }
    if (value is Iterable) {
      return List<Object?>.unmodifiable(value.map(_deepCopy));
    }
    return value;
  }

  static bool _validId(String id) => _identifier.hasMatch(id);

  static Never _fail(String message) =>
      throw SimConsumerConformanceError(message);
}

bool _bytesEqual(Uint8List left, Uint8List right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _listEqual<T>(List<T> left, List<T> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
