// NDJSON test adapter for the cross-binding Lazily interoperability suite.
//
// Operations and frames are built with package:lazily's production IPC types,
// and all ordering/dedup decisions are delegated to CrdtPlaneRuntime.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lazily/ipc.dart';

const int _protocolVersion = 1;

class _InteropPeer {
  int? _peerId;
  int _logical = 0;
  CrdtPlaneRuntime? _runtime;

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
    return {
      'ok': true,
      'binding': 'lazily-dart',
      'version': '0.27.1',
      'protocol_version': _protocolVersion,
      'features': ['distributed_crdt'],
      'codecs': ['json'],
      'channels': <Object?>[],
      'channel_variants': <String, Object?>{},
      'platform_profile': 'portable',
      'carve_outs': ['msgpack', 'transport_links'],
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
