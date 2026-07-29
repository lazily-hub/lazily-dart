// NDJSON test adapter for the cross-binding Lazily interoperability suite.
//
// Operations and frames are built with package:lazily's production IPC types,
// and all ordering/dedup decisions are delegated to CrdtPlaneRuntime.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lazily/ipc.dart';
import 'package:lazily/stdlib.dart' as lazily;

const int _protocolVersion = 1;

class _InteropPeer {
  int? _peerId;
  int _logical = 0;
  CrdtPlaneRuntime? _runtime;
  final Map<String, _StdlibFeature> _stdlib = {};

  Map<String, Object?> handle(Map<String, Object?> request) {
    switch (request['cmd']) {
      case 'hello':
        return _hello(request);
      case 'local_set':
        return _localSet(request);
      case 'deliver':
        return _deliver(request);
      case 'snapshot':
        return _snapshot();
      case 'feature_reset':
        return _featureReset(request);
      case 'feature_step':
        return _featureStep(request);
      case 'feature_observe':
        return _featureObserve(request);
      case 'bye':
        return {'ok': true};
      case 'link_open':
      case 'link_send':
      case 'link_recv':
      case 'link_close':
      case 'link_stats':
        return {
          'ok': false,
          'error': 'unsupported channel',
          'unsupported': true,
        };
      default:
        return {'ok': false, 'error': 'unknown command'};
    }
  }

  Map<String, Object?> _hello(Map<String, Object?> request) {
    if (request['protocol_version'] != _protocolVersion) {
      return {'ok': false, 'error': 'unsupported protocol_version'};
    }
    final assigned = request['peer'];
    if (assigned is! int) {
      return {'ok': false, 'error': 'hello requires integer peer'};
    }
    _peerId = assigned;
    _logical = 0;
    _runtime = CrdtPlaneRuntime(assigned);
    _stdlib.clear();
    return {
      'ok': true,
      'binding': 'lazily-dart',
      'version': '0.27.1',
      'protocol_version': _protocolVersion,
      'features': [
        'distributed_crdt',
        'stdlib_timer_v1',
        'stdlib_timeout_v1',
        'stdlib_revision_barrier_v1',
      ],
      'codecs': ['json'],
      'channels': <Object?>[],
      'channel_variants': <String, Object?>{},
      'platform_profile': 'portable',
      'carve_outs': ['msgpack', 'transport_links'],
    };
  }

  Map<String, Object?> _featureReset(Map<String, Object?> request) {
    final feature = request['feature'];
    if (feature is! String || !_supportedFeature(feature)) {
      return {
        'ok': false,
        'error': 'unsupported feature $feature',
        'unsupported': true,
      };
    }
    _stdlib[feature] = _StdlibFeature(feature);
    return {'ok': true, 'feature': feature};
  }

  Map<String, Object?> _featureStep(Map<String, Object?> request) {
    final feature = request['feature'];
    if (feature is! String) {
      throw const FormatException('feature_step requires string feature');
    }
    final state = _stdlib[feature];
    if (state == null) {
      throw StateError('feature $feature must be reset before stepping');
    }
    final step = request['step'];
    if (step is! Map) {
      throw const FormatException('feature_step requires object step');
    }
    final observation = state.step(step.cast<String, Object?>());
    return {
      'ok': true,
      'feature': feature,
      'observation': observation,
    };
  }

  Map<String, Object?> _featureObserve(Map<String, Object?> request) {
    final feature = request['feature'];
    if (feature is! String) {
      throw const FormatException('feature_observe requires string feature');
    }
    final state = _stdlib[feature];
    if (state == null) {
      throw StateError('feature $feature must be reset before observation');
    }
    final observation = state.last;
    if (observation == null) {
      throw StateError('feature $feature has no observation');
    }
    return {
      'ok': true,
      'feature': feature,
      'observation': observation,
    };
  }

  Map<String, Object?> _localSet(Map<String, Object?> request) {
    final (runtime, assigned) = _ready();
    final node = request['node'];
    final at = request['at'];
    final key = request['key'];
    if (node is! int || at is! int) {
      throw const FormatException('local_set requires integer node and at');
    }
    if (key != null && key is! String) {
      throw const FormatException('local_set key must be a string or null');
    }
    _logical++;
    final op = CrdtOp(
      node: node,
      key: key == null ? null : NodeKey(key as String),
      stamp: WireStamp(
        wallTime: at,
        logical: _logical,
        peer: assigned,
      ),
      state: IpcValue.fromWire(request['state']),
    );
    if (runtime.ingest(CrdtSync(ops: [op]), at) != 1) {
      throw StateError('production runtime rejected fresh local op');
    }
    final message = IpcMessage.ofCrdtSync(
      CrdtSync(
        frontier: [
          for (final entry in runtime.frontierEntries())
            StampFrontierEntry(entry.key, entry.value),
        ],
        ops: [op],
      ),
    );
    // Exercise the production streaming encoder before returning the frame.
    final frame = jsonDecode(utf8.decode(message.encodeJsonStreaming()));
    return {'ok': true, 'frame': frame};
  }

  Map<String, Object?> _deliver(Map<String, Object?> request) {
    final (runtime, _) = _ready();
    final message = IpcMessage.decodeJson(jsonEncode(request['frame']));
    final sync = message.crdtSync;
    if (sync == null) {
      throw const FormatException('deliver requires CrdtSync');
    }
    final at = request['at'];
    if (at is! int) {
      throw const FormatException('deliver requires integer at');
    }
    return {'ok': true, 'applied': runtime.ingest(sync, at)};
  }

  Map<String, Object?> _snapshot() {
    final (runtime, _) = _ready();
    return {
      'ok': true,
      'cells': [
        for (final entry in runtime.converged())
          {
            'node': entry.node,
            'key': entry.key,
            'state': entry.state,
          },
      ],
    };
  }

  (CrdtPlaneRuntime, int) _ready() {
    final runtime = _runtime;
    final assigned = _peerId;
    if (runtime == null || assigned == null) {
      throw StateError('hello must run first');
    }
    return (runtime, assigned);
  }
}

bool _supportedFeature(String feature) =>
    feature == 'stdlib_timer_v1' ||
    feature == 'stdlib_timeout_v1' ||
    feature == 'stdlib_revision_barrier_v1';

BigInt _logicalUint(Object? value, String name) {
  if (value is int) return BigInt.from(value);
  if (value is double && value.isFinite && value == value.truncateToDouble()) {
    return BigInt.parse(value.toStringAsFixed(0));
  }
  if (value is String) return BigInt.parse(value);
  throw FormatException('$name requires an unsigned integer');
}

lazily.TimeoutCancellation _cancellation(Object? value) {
  switch (value) {
    case 'pending':
      return lazily.TimeoutCancellation.pending;
    case 'cancelled':
      return lazily.TimeoutCancellation.cancelled;
    case 'unavailable':
      return lazily.TimeoutCancellation.unavailable;
    default:
      return lazily.TimeoutCancellation.unavailable;
  }
}

class _StdlibFeature {
  _StdlibFeature(this.name);

  final String name;
  lazily.Timer? timer;
  lazily.Timeout<String>? timeout;
  lazily.RevisionBarrier? barrier;
  Map<String, Object?>? last;

  Map<String, Object?> step(Map<String, Object?> step) {
    final observation = switch (name) {
      'stdlib_timer_v1' => _timerStep(step),
      'stdlib_timeout_v1' => _timeoutStep(step),
      'stdlib_revision_barrier_v1' => _barrierStep(step),
      _ => throw StateError('unsupported feature $name'),
    };
    last = observation;
    return observation;
  }

  Map<String, Object?> _timerStep(Map<String, Object?> step) {
    switch (step['op']) {
      case 'start':
        try {
          final value = lazily.Timer(
            _logicalUint(step['now'], 'now'),
            _logicalUint(step['duration'], 'duration'),
          );
          timer = value;
          return value.initial.toJson();
        } on lazily.StdlibUnavailable catch (error) {
          timer = null;
          return {'outcome': 'unavailable', 'reason': error.reason};
        }
      case 'observe':
        final value = timer;
        if (value == null) throw StateError('timer feature is not started');
        return value.observe(_logicalUint(step['now'], 'now')).toJson();
      default:
        throw FormatException('unsupported timer feature step ${step['op']}');
    }
  }

  Map<String, Object?> _timeoutStep(Map<String, Object?> step) {
    switch (step['op']) {
      case 'start':
        try {
          final value = lazily.Timeout<String>(
            _logicalUint(step['now'], 'now'),
            _logicalUint(step['duration'], 'duration'),
          );
          timeout = value;
          return value.initial.toJson();
        } on lazily.StdlibUnavailable catch (error) {
          timeout = null;
          return {'outcome': 'unavailable', 'reason': error.reason};
        }
      case 'poll':
        final value = timeout;
        if (value == null) throw StateError('timeout feature is not started');
        var operationCalls = 0;
        var cancellationCalls = 0;
        final observation = value.poll(
          _logicalUint(step['now'], 'now'),
          () {
            operationCalls++;
            return switch (step['operation']) {
              'pending' => const lazily.TimeoutOperation<String>.pending(),
              'completed' => lazily.TimeoutOperation<String>.completed(
                  step['value'] as String,
                ),
              _ => const lazily.TimeoutOperation<String>.unavailable(),
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
        throw FormatException('unsupported timeout feature step ${step['op']}');
    }
  }

  Map<String, Object?> _barrierStep(Map<String, Object?> step) {
    var cancellationCalls = 0;
    late lazily.RevisionBarrierObservation observation;
    switch (step['op']) {
      case 'start':
        final deadline = step['deadline'];
        final value = lazily.RevisionBarrier(
          revision: _logicalUint(step['revision'], 'revision'),
          requiredRevision: _logicalUint(
            step['required_revision'],
            'required_revision',
          ),
          deadline:
              deadline == null ? null : _logicalUint(deadline, 'deadline'),
        );
        barrier = value;
        observation = value.initial;
        break;
      case 'observe':
        final value = barrier;
        if (value == null) throw StateError('barrier feature is not started');
        observation = value.observe(
          _logicalUint(step['now'], 'now'),
          step['predicate'] as bool,
          () {
            cancellationCalls++;
            return _cancellation(step['cancellation']);
          },
        );
        break;
      case 'register_recheck':
        final value = barrier;
        if (value == null) throw StateError('barrier feature is not started');
        observation = value.registerRecheck(
          _logicalUint(step['now'], 'now'),
          _logicalUint(step['observed_revision'], 'observed_revision'),
          step['predicate'] as bool,
        );
        break;
      case 'advance':
        final value = barrier;
        if (value == null) throw StateError('barrier feature is not started');
        observation = value.advance(
          _logicalUint(step['revision'], 'revision'),
          step['predicate'] as bool,
        );
        break;
      case 'dispose':
        final value = barrier;
        if (value == null) throw StateError('barrier feature is not started');
        observation = value.dispose();
        break;
      case 'receipt':
        final value = barrier;
        if (value == null) throw StateError('barrier feature is not started');
        observation = value.receipt(step['key'] as String);
        break;
      default:
        throw FormatException(
          'unsupported revision barrier feature step ${step['op']}',
        );
    }
    return {
      ...observation.toJson(),
      if (step['op'] == 'observe') 'cancellation_calls': cancellationCalls,
    };
  }
}

void _selfCheck() {
  final peer = _InteropPeer();
  if (peer.handle({
        'cmd': 'hello',
        'peer': 1,
        'protocol_version': _protocolVersion,
      })['ok'] !=
      true) {
    throw StateError('hello self-check failed');
  }
  final local = peer.handle({
    'cmd': 'local_set',
    'node': 7,
    'key': null,
    'state': {
      'Inline': [65],
    },
    'at': 10,
  });
  final frame = local['frame']! as Map<String, dynamic>;
  final sync = frame['CrdtSync']! as Map<String, dynamic>;
  final ops = sync['ops']! as List<dynamic>;
  if ((ops.single as Map<String, dynamic>)['key'] != null) {
    throw StateError('null key self-check failed');
  }
  if (peer.handle({
        'cmd': 'deliver',
        'frame': frame,
        'at': 11,
      })['applied'] !=
      0) {
    throw StateError('duplicate self-check failed');
  }
  final featureCases = <(String, List<Map<String, Object?>>, String)>[
    (
      'stdlib_timer_v1',
      [
        {'op': 'start', 'now': 0, 'duration': 0},
        {'op': 'observe', 'now': 0},
      ],
      'fired',
    ),
    (
      'stdlib_timeout_v1',
      [
        {'op': 'start', 'now': 0, 'duration': 1},
        {
          'op': 'poll',
          'now': 0,
          'operation': 'completed',
          'value': 'ok',
          'cancellation': 'pending',
        },
      ],
      'completed',
    ),
    (
      'stdlib_revision_barrier_v1',
      [
        {
          'op': 'start',
          'revision': 1,
          'required_revision': 1,
          'deadline': null,
        },
        {
          'op': 'observe',
          'now': 0,
          'predicate': true,
          'cancellation': 'pending',
        },
      ],
      'satisfied',
    ),
  ];
  for (final (feature, steps, outcome) in featureCases) {
    final reset = peer.handle({
      'cmd': 'feature_reset',
      'feature': feature,
    });
    if (reset['ok'] != true) {
      throw StateError('$feature reset self-check failed');
    }
    for (final step in steps) {
      peer.handle({
        'cmd': 'feature_step',
        'feature': feature,
        'step': step,
      });
    }
    final observed = peer.handle({
      'cmd': 'feature_observe',
      'feature': feature,
    });
    final observation = observed['observation']! as Map<String, Object?>;
    if (observation['outcome'] != outcome) {
      throw StateError('$feature self-check failed: $observation');
    }
  }
}

Future<void> main(List<String> arguments) async {
  if (arguments.contains('--self-check')) {
    _selfCheck();
    stderr.writeln('lazily-dart interop peer self-check: ok');
    return;
  }

  final peer = _InteropPeer();
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    Map<String, Object?>? request;
    Map<String, Object?> response;
    try {
      request = (jsonDecode(line) as Map).cast<String, Object?>();
      response = peer.handle(request);
    } on Object catch (error) {
      response = {'ok': false, 'error': error.toString()};
    }
    stdout.writeln(jsonEncode(response));
    await stdout.flush();
    if (request?['cmd'] == 'bye') break;
  }
}
