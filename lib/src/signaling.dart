/// WebRTC signaling protocol — room routing + client frames.
///
/// The signaling server brokers peer discovery for the distributed CRDT plane.
/// Peers join a session, learn the roster, and exchange the WebRTC SDP/ICE
/// handshake (or relay opaque payloads). The signaling layer never interprets
/// CRDT state.
///
/// Wire contract matches `lazily-spec/conformance/signaling/frames.json` and
/// `anti_spoof_session.json` byte for byte. Tags are kebab-case; `peer` ids
/// are bare JSON numbers; `from` is always server-stamped.
library;

/// Signaling error codes.
enum SignalingErrorCode {
  badMessage('bad_message'),
  notJoined('not_joined'),
  alreadyJoined('already_joined'),
  duplicatePeer('duplicate_peer'),
  unknownTarget('unknown_target'),
  permissionDenied('permission_denied');

  const SignalingErrorCode(this.wire);
  final String wire;
}

// ---------------------------------------------------------------------------
// Client → Server messages
// ---------------------------------------------------------------------------

sealed class ClientMessage {
  Map<String, dynamic> toWire();
  String get type;

  static ClientMessage fromWire(Map<String, dynamic> wire) {
    final type = wire['type'];
    switch (type) {
      case 'join':
        _requireOnly(wire, {'type', 'peer', 'capabilities'});
        return ClientJoin(
          wire['peer'] as int,
          (wire['capabilities'] as List?)?.cast<String>(),
        );
      case 'offer':
        _requireOnly(wire, {'type', 'to', 'sdp'});
        return ClientOffer(wire['to'] as int, wire['sdp'] as String);
      case 'answer':
        _requireOnly(wire, {'type', 'to', 'sdp'});
        return ClientAnswer(wire['to'] as int, wire['sdp'] as String);
      case 'ice':
        _requireOnly(wire, {'type', 'to', 'candidate'});
        return ClientIce(wire['to'] as int, wire['candidate'] as String);
      case 'relay':
        _requireOnly(wire, {'type', 'to', 'payload'});
        return ClientRelay(wire['to'] as int, wire['payload'] as Object);
      case 'leave':
        _requireOnly(wire, {'type'});
        return ClientLeave();
      default:
        throw FormatException('unknown ClientMessage type: $type');
    }
  }
}

class ClientJoin extends ClientMessage {
  ClientJoin(this.peer, [this.capabilities]);
  final int peer;
  final List<String>? capabilities;

  @override
  String get type => 'join';

  @override
  Map<String, dynamic> toWire() {
    final m = <String, dynamic>{'type': 'join', 'peer': peer};
    if (capabilities != null) m['capabilities'] = capabilities;
    return m;
  }
}

class ClientOffer extends ClientMessage {
  ClientOffer(this.to, this.sdp);
  final int to;
  final String sdp;
  @override
  String get type => 'offer';
  @override
  Map<String, dynamic> toWire() => {'type': 'offer', 'to': to, 'sdp': sdp};
}

class ClientAnswer extends ClientMessage {
  ClientAnswer(this.to, this.sdp);
  final int to;
  final String sdp;
  @override
  String get type => 'answer';
  @override
  Map<String, dynamic> toWire() => {'type': 'answer', 'to': to, 'sdp': sdp};
}

class ClientIce extends ClientMessage {
  ClientIce(this.to, this.candidate);
  final int to;
  final String candidate;
  @override
  String get type => 'ice';
  @override
  Map<String, dynamic> toWire() =>
      {'type': 'ice', 'to': to, 'candidate': candidate};
}

class ClientRelay extends ClientMessage {
  ClientRelay(this.to, this.payload);
  final int to;
  final Object payload;
  @override
  String get type => 'relay';
  @override
  Map<String, dynamic> toWire() =>
      {'type': 'relay', 'to': to, 'payload': payload};
}

class ClientLeave extends ClientMessage {
  @override
  String get type => 'leave';
  @override
  Map<String, dynamic> toWire() => {'type': 'leave'};
}

// ---------------------------------------------------------------------------
// Server → Client messages
// ---------------------------------------------------------------------------

sealed class ServerMessage {
  Map<String, dynamic> toWire();
  String get type;

  static ServerMessage fromWire(Map<String, dynamic> wire) {
    final type = wire['type'];
    switch (type) {
      case 'welcome':
        _requireOnly(wire, {'type', 'peer', 'peers'});
        return ServerWelcome(
          wire['peer'] as int,
          (wire['peers'] as List).cast<int>(),
        );
      case 'peer-joined':
        _requireOnly(wire, {'type', 'peer'});
        return ServerPeerJoined(wire['peer'] as int);
      case 'peer-left':
        _requireOnly(wire, {'type', 'peer'});
        return ServerPeerLeft(wire['peer'] as int);
      case 'offer':
        _requireOnly(wire, {'type', 'from', 'sdp'});
        return ServerOffer(wire['from'] as int, wire['sdp'] as String);
      case 'answer':
        _requireOnly(wire, {'type', 'from', 'sdp'});
        return ServerAnswer(wire['from'] as int, wire['sdp'] as String);
      case 'ice':
        _requireOnly(wire, {'type', 'from', 'candidate'});
        return ServerIce(wire['from'] as int, wire['candidate'] as String);
      case 'relay':
        _requireOnly(wire, {'type', 'from', 'payload'});
        return ServerRelay(wire['from'] as int, wire['payload'] as Object);
      case 'error':
        _requireOnly(wire, {'type', 'code', 'message'});
        return ServerError(wire['code'] as String, wire['message'] as String);
      default:
        throw FormatException('unknown ServerMessage type: $type');
    }
  }
}

class ServerWelcome extends ServerMessage {
  ServerWelcome(this.peer, [List<int>? peers]) : peers = peers ?? const [] {
    if (this.peers.contains(peer)) {
      throw const FormatException(
        'welcome roster must exclude the joining peer',
      );
    }
  }
  final int peer;
  final List<int> peers;

  @override
  String get type => 'welcome';
  @override
  Map<String, dynamic> toWire() =>
      {'type': 'welcome', 'peer': peer, 'peers': peers};
}

class ServerPeerJoined extends ServerMessage {
  ServerPeerJoined(this.peer);
  final int peer;
  @override
  String get type => 'peer-joined';
  @override
  Map<String, dynamic> toWire() => {'type': 'peer-joined', 'peer': peer};
}

class ServerPeerLeft extends ServerMessage {
  ServerPeerLeft(this.peer);
  final int peer;
  @override
  String get type => 'peer-left';
  @override
  Map<String, dynamic> toWire() => {'type': 'peer-left', 'peer': peer};
}

class ServerOffer extends ServerMessage {
  ServerOffer(this.from, this.sdp);
  final int from;
  final String sdp;
  @override
  String get type => 'offer';
  @override
  Map<String, dynamic> toWire() => {'type': 'offer', 'from': from, 'sdp': sdp};
}

class ServerAnswer extends ServerMessage {
  ServerAnswer(this.from, this.sdp);
  final int from;
  final String sdp;
  @override
  String get type => 'answer';
  @override
  Map<String, dynamic> toWire() => {'type': 'answer', 'from': from, 'sdp': sdp};
}

class ServerIce extends ServerMessage {
  ServerIce(this.from, this.candidate);
  final int from;
  final String candidate;
  @override
  String get type => 'ice';
  @override
  Map<String, dynamic> toWire() =>
      {'type': 'ice', 'from': from, 'candidate': candidate};
}

class ServerRelay extends ServerMessage {
  ServerRelay(this.from, this.payload);
  final int from;
  final Object payload;
  @override
  String get type => 'relay';
  @override
  Map<String, dynamic> toWire() =>
      {'type': 'relay', 'from': from, 'payload': payload};
}

class ServerError extends ServerMessage {
  ServerError(this.code, this.message);
  final String code;
  final String message;
  @override
  String get type => 'error';
  @override
  Map<String, dynamic> toWire() =>
      {'type': 'error', 'code': code, 'message': message};
}

// ---------------------------------------------------------------------------
// Routed frame: (target conn, message)
// ---------------------------------------------------------------------------

class RoutedFrame {
  RoutedFrame(this.connId, this.message);
  final Object connId;
  final ServerMessage message;
}

void _requireOnly(Map<String, dynamic> wire, Set<String> allowed) {
  final unexpected = wire.keys.where((key) => !allowed.contains(key)).toList();
  if (unexpected.isNotEmpty) {
    throw FormatException('unexpected signaling field(s): $unexpected');
  }
}

/// A signaling room. Transport-agnostic — the caller drives `receive` /
/// `disconnect` and delivers the emitted [RoutedFrame]s over the transport.
class SignalingRoom {
  SignalingRoom({SignalingMode mode = SignalingMode.open}) : _mode = mode;

  final SignalingMode _mode;
  final Map<Object, int> _connToPeer = {};
  final Map<int, Object> _peerToConn = {};
  final Set<int> _joinAllowed = {};
  final Map<int, Set<int>> _signalAllowed = {};

  List<int> roster() => _peerToConn.keys.toList()..sort();
  int get size => _peerToConn.length;

  void _emit(List<RoutedFrame> out, Object connId, ServerMessage msg) {
    out.add(RoutedFrame(connId, msg));
  }

  void _error(List<RoutedFrame> out, Object connId, SignalingErrorCode code,
      String msg) {
    _emit(out, connId, ServerError(code.wire, msg));
  }

  /// Process an inbound client message. Returns the list of frames to deliver.
  List<RoutedFrame> receive(Object connId, ClientMessage message) {
    final out = <RoutedFrame>[];
    switch (message) {
      case ClientJoin(:final peer):
        _join(out, connId, peer);
      case ClientLeave():
        _leave(out, connId);
      case ClientOffer(:final to):
        _forward(
            out, connId, to, 'offer', (from) => ServerOffer(from, message.sdp));
      case ClientAnswer(:final to):
        _forward(out, connId, to, 'answer',
            (from) => ServerAnswer(from, message.sdp));
      case ClientIce(:final to):
        _forward(out, connId, to, 'ice',
            (from) => ServerIce(from, message.candidate));
      case ClientRelay(:final to):
        _forward(out, connId, to, 'relay',
            (from) => ServerRelay(from, message.payload));
    }
    return out;
  }

  void _join(List<RoutedFrame> out, Object connId, int peer) {
    if (_connToPeer.containsKey(connId)) {
      _error(out, connId, SignalingErrorCode.alreadyJoined,
          'connection already joined');
      return;
    }
    if (_mode == SignalingMode.allowlist && !_joinAllowed.contains(peer)) {
      _error(out, connId, SignalingErrorCode.permissionDenied,
          'peer $peer is not allowed to join');
      return;
    }
    if (_peerToConn.containsKey(peer)) {
      _error(out, connId, SignalingErrorCode.duplicatePeer,
          'peer $peer is already in this session');
      return;
    }
    _connToPeer[connId] = peer;
    _peerToConn[peer] = connId;

    // Welcome the joiner (roster excludes self).
    final others = roster().where((p) => p != peer).toList();
    _emit(out, connId, ServerWelcome(peer, others));

    // Notify all other peers.
    for (final otherPeer in roster()) {
      if (otherPeer == peer) continue;
      _emit(out, _peerToConn[otherPeer]!, ServerPeerJoined(peer));
    }
  }

  void _leave(List<RoutedFrame> out, Object connId) {
    final peer = _connToPeer[connId];
    if (peer == null) return;
    _connToPeer.remove(connId);
    _peerToConn.remove(peer);
    for (final otherConn in _connToPeer.keys) {
      _emit(out, otherConn, ServerPeerLeft(peer));
    }
  }

  void _forward(List<RoutedFrame> out, Object connId, int to, String kind,
      ServerMessage Function(int from) build) {
    final from = _connToPeer[connId];
    if (from == null) {
      _error(
          out, connId, SignalingErrorCode.notJoined, 'join before signaling');
      return;
    }
    if (_mode == SignalingMode.allowlist) {
      final allowed = _signalAllowed[from];
      if (allowed == null || !allowed.contains(to)) {
        _error(out, connId, SignalingErrorCode.permissionDenied,
            'peer $from is not allowed to signal peer $to');
        return;
      }
    }
    final targetConn = _peerToConn[to];
    if (targetConn == null) {
      _error(out, connId, SignalingErrorCode.unknownTarget,
          'peer $to is not in this session');
      return;
    }
    _emit(out, targetConn, build(from));
  }

  /// Handle a disconnection. Emits peer-left to all remaining peers.
  List<RoutedFrame> disconnect(Object connId) {
    final out = <RoutedFrame>[];
    _leave(out, connId);
    return out;
  }
}

/// Permission mode for a signaling room.
enum SignalingMode { open, allowlist }
