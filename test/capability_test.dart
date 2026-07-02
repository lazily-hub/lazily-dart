import 'dart:convert';

import 'package:lazily/capability.dart';
import 'package:test/test.dart';

/// Capability negotiation conformance (protocol.md § Capability Negotiation).
/// Mirrors `lazily-rs/src/ipc.rs::CapabilityHandshake` and
/// `lazily-js/test/capability-negotiation.test.js`.

void main() {
  group('CapabilityHandshake wire', () {
    test('defaults match the canonical handshake', () {
      final h = CapabilityHandshake.defaults(1, 'abc-123');
      expect(h.protocolId, kProtocolId);
      expect(h.protocolMajorVersion, kProtocolMajorVersion);
      expect(h.codec, 'json');
      expect(h.maxFrameSize, 1 << 20);
      expect(h.fragmentationSupported, isFalse);
      expect(h.orderedReliable, isTrue);
      expect(h.peerId, 1);
      expect(h.sessionId, 'abc-123');
      expect(h.features, isEmpty);
    });

    test('round-trips through JSON with all fields', () {
      final h = CapabilityHandshake.defaults(7, 's-1')
          .withCodec('msgpack')
          .withMaxFrameSize(1024)
          .withFragmentation(true)
          .withFeatures(['shared-blob', 'signaling-relay']);
      final wire = h.toWire();
      final decoded = CapabilityHandshake.fromWire(jsonDecode(jsonEncode(wire)));
      expect(decoded.protocolId, h.protocolId);
      expect(decoded.protocolMajorVersion, h.protocolMajorVersion);
      expect(decoded.codec, 'msgpack');
      expect(decoded.maxFrameSize, 1024);
      expect(decoded.fragmentationSupported, isTrue);
      expect(decoded.orderedReliable, isTrue);
      expect(decoded.peerId, 7);
      expect(decoded.sessionId, 's-1');
      expect(decoded.features, ['shared-blob', 'signaling-relay']);
    });

    test('decoder applies serde defaults when fields are absent', () {
      final decoded = CapabilityHandshake.fromWire({
        'protocol_id': 'lazily-ipc',
        'protocol_major_version': 1,
        'peer_id': 2,
        'session_id': 'x',
        'codec': 'json',
        'max_frame_size': 4096,
      });
      expect(decoded.fragmentationSupported, isFalse);
      expect(decoded.orderedReliable, isTrue);
      expect(decoded.features, isEmpty);
    });

    test('decodeJson accepts a String or List<int>', () {
      final h1 = CapabilityHandshake.decodeJson(
          jsonEncode(CapabilityHandshake.defaults(1, 's').toWire()));
      expect(h1.peerId, 1);
      final h2 = CapabilityHandshake.decodeJson(
          utf8.encode(jsonEncode(CapabilityHandshake.defaults(2, 's').toWire())));
      expect(h2.peerId, 2);
    });

    test('encodeJson produces the canonical object', () {
      final h = CapabilityHandshake.defaults(1, 'abc');
      expect(jsonDecode(h.encodeJson()), h.toWire());
    });
  });

  group('isCompatibleWith / checkCompatible', () {
    CapabilityHandshake defaults(PeerId peer) =>
        CapabilityHandshake.defaults(peer, 's');

    test('two compliant peers are compatible', () {
      expect(defaults(1).isCompatibleWith(defaults(2)), isTrue);
    });

    test('wrong protocol_id fails closed', () {
      // Construct an impostor by decoding with a custom protocol_id.
      final impostor = CapabilityHandshake.fromWire({
        'protocol_id': 'not-lazily',
        'protocol_major_version': 1,
        'codec': 'json',
        'max_frame_size': 4096,
        'peer_id': 2,
        'session_id': 's',
      });
      final check = defaults(1).checkCompatible(impostor);
      expect(check.isOk, isFalse);
      expect(check.field, 'protocol_id');
    });

    test('major version mismatch fails closed', () {
      final other = CapabilityHandshake.fromWire({
        'protocol_id': 'lazily-ipc',
        'protocol_major_version': 999,
        'codec': 'json',
        'max_frame_size': 4096,
        'peer_id': 2,
        'session_id': 's',
      });
      final check = defaults(1).checkCompatible(other);
      expect(check.isOk, isFalse);
      expect(check.field, 'protocol_major_version');
    });

    test('codec mismatch fails closed', () {
      final other = defaults(2).withCodec('msgpack');
      final check = defaults(1).checkCompatible(other);
      expect(check.isOk, isFalse);
      expect(check.field, 'codec');
    });

    test('ordered_reliable = false fails closed', () {
      final unreliable = defaults(2).withOrderedReliable(false);
      final check = defaults(1).checkCompatible(unreliable);
      expect(check.isOk, isFalse);
      expect(check.field, 'ordered_reliable');
    });

    test('a required feature not offered fails closed', () {
      final offer = defaults(2); // no features
      final check =
          defaults(1).checkCompatible(offer, requiredFeatures: ['shared-blob']);
      expect(check.isOk, isFalse);
      expect(check.field, 'features');
    });

    test('a required feature that IS offered succeeds', () {
      final offer = defaults(2).withFeatures(['shared-blob']);
      final check =
          defaults(1).checkCompatible(offer, requiredFeatures: ['shared-blob']);
      expect(check.isOk, isTrue);
    });
  });

  group('BindingCapabilities', () {
    test('advertises host ffi and every MUST layer', () {
      const caps = BindingCapabilities();
      final wire = caps.toWire();
      expect(wire['binding'], 'lazily-dart');
      expect(wire['ffi'], 'host');
      expect(wire['reactive_core'], isTrue);
      expect(wire['collections'], isTrue);
      expect(wire['state_machine'], isTrue);
      expect(wire['state_charts'], isTrue);
      expect(wire['ipc'], isTrue);
      expect(wire['crdt'], isTrue);
      expect(wire['permissions'], isTrue);
      expect(wire['capability_negotiation'], isTrue);
      expect(wire['async'], isTrue);
    });

    test('ffi capability is host (Dart has dart:ffi)', () {
      expect(BindingCapabilities.ffi, FfiCapability.host);
    });
  });
}
