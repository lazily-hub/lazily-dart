import 'dart:convert';
import 'dart:io';

import 'package:lazily/capability.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

const _fixtureId = 'codec/capability_handshake.json';

void _assertHandshake(
  Map<String, dynamic> block,
  CapabilityHandshake handshake,
) {
  assertKey(block, 'protocol_id', handshake.protocolId);
  assertKey(block, 'protocol_major_version', handshake.protocolMajorVersion);
  assertKey(block, 'codec', handshake.codec);
  assertKey(block, 'max_frame_size', handshake.maxFrameSize);
  assertKey(block, 'fragmentation_supported', handshake.fragmentationSupported);
  assertKey(block, 'ordered_reliable', handshake.orderedReliable);
  assertKey(block, 'peer_id', handshake.peerId);
  assertKey(block, 'session_id', handshake.sessionId);
  assertKey(block, 'features', handshake.features);
}

void main() {
  test('canonical CapabilityHandshake negotiation scenarios', () {
    final file = File('../lazily-spec/conformance/$_fixtureId');
    if (!file.existsSync()) {
      fail('canonical capability-handshake fixture is unavailable');
    }
    final fixture = attributeFixture(jsonDecode(file.specReadAsStringSync()))
        as Map<String, dynamic>;
    final root = assertionsOf(fixture, _fixtureId);
    assertKey(root, 'protocol_version', 1);
    assertKey(root, 'kind', 'CapabilityHandshake');
    excuseKey(root, 'scenarios',
        'container: scenariosOf records and replays every scenario below');

    for (final scenario in scenariosOf(fixture)) {
      final id = scenario['id'] as String;
      final tracked = assertionsOf(scenario, '$_fixtureId scenarios[$id]');
      excuseKey(tracked, 'id', 'stable scenario-ledger identifier');

      final localBlock = subKey(tracked, 'local');
      final remoteBlock = subKey(tracked, 'remote');
      final local = CapabilityHandshake.fromWire(localBlock);
      final remote = CapabilityHandshake.fromWire(remoteBlock);
      _assertHandshake(localBlock, local);
      _assertHandshake(remoteBlock, remote);

      final expected = subKey(tracked, 'expected');
      final negotiation = local.negotiate(remote);
      assertKey(expected, 'compatible', negotiation.isOk);
      if (negotiation.isOk) {
        final capabilities = negotiation.capabilities;
        expect(capabilities, isNotNull,
            reason: '$id: successful negotiation must retain capabilities');
        assertKey(
            expected, 'negotiated_max_frame_size', capabilities!.maxFrameSize);
        assertKey(expected, 'negotiated_fragmentation_supported',
            capabilities.fragmentationSupported);
      } else {
        expect(negotiation.capabilities, isNull,
            reason: '$id: failed negotiation must not retain capabilities');
        assertKey(expected, 'field', negotiation.check.field);
      }
    }
  });
}
