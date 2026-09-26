import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:lazily/durable_client.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

void main() {
  test('replays canonical durable-client corpus', () {
    final file =
        File('${specFamilyDir('durable-client').path}/envelope_v1.json');
    expect(file.existsSync(), isTrue);
    final fixture = attributeFixture(jsonDecode(file.specReadAsStringSync()))
        as Map<String, dynamic>;
    expect(fixture['owner_authority'], isFalse);

    for (final vector in fixture['envelope_vectors'] as List) {
      final row = (vector as Map).cast<String, dynamic>();
      final envelope =
          _fromWire((row['envelope'] as Map).cast<String, dynamic>());
      final expected = assertionsOf(
          row['expected'], 'durable-client/envelope_v1.json envelope expected');
      final validation = envelope.validate();
      assertKey(expected, 'reason', _validationName(validation));
      assertKey(
          expected, 'accepted', validation == EnvelopeValidation.accepted);
      assertKey(expected, 'payload_decoded',
          validation == EnvelopeValidation.accepted);
    }

    for (final vector in fixture['ordering_vectors'] as List) {
      final row = (vector as Map).cast<String, dynamic>();
      final order = DurableObservationOrder();
      for (final id in row['observed_message_ids'] as List) {
        order.observe(DurableEnvelope(
            messageId: id as String,
            schemaVersion: 1,
            codecVersion: 1,
            payload: const []));
      }
      expect(order.messageIds, row['expected_delivery_order']);
      expect(order.ownerOrderInferred, row['owner_order_inferred']);
    }

    for (final vector in fixture['projection_ordering_vectors'] as List) {
      final row = (vector as Map).cast<String, dynamic>();
      final order = AdvisoryProjectionOrder();
      final classifications = <String>[];
      for (final position in row['observed_source_positions'] as List) {
        classifications
            .add(order.observe(position as int, 'source-$position').name);
      }
      expect(classifications, row['expected_delivery_classification']);
      expect(order.appliedPositions, row['expected_applied_positions']);
      expect(order.brokerOrderAuthoritative, row['broker_order_authoritative']);
      expect(order.mayAuthorizeTransition, row['may_authorize_transition']);
    }

    for (final vector in fixture['dedup_vectors'] as List) {
      final row = (vector as Map).cast<String, dynamic>();
      final dedup = DurableDeduplicator();
      final actual = (row['deliveries'] as List)
          .map((value) => dedup
              .classify(_fromWire((value as Map).cast<String, dynamic>()))
              .name)
          .toList();
      expect(actual, row['expected_classification']);
    }

    for (final vector in fixture['receipt_vectors'] as List) {
      final row = (vector as Map).cast<String, dynamic>();
      final receipt = _receipt((row['receipt'] as Map).cast<String, dynamic>());
      final expected =
          _receipt((row['expected_round_trip'] as Map).cast<String, dynamic>());
      expect(receipt.protocolVersion, expected.protocolVersion);
      expect(receipt.receiptId, expected.receiptId);
      expect(receipt.messageId, expected.messageId);
      expect(receipt.outcome, expected.outcome);
      expect(receipt.ownerPosition, expected.ownerPosition);
      expect(receipt.transportAckEquivalent, row['transport_ack_equivalent']);
    }

    for (final vector in fixture['projection_fingerprint_vectors'] as List) {
      final row = (vector as Map).cast<String, dynamic>();
      final left = _fingerprint((row['left'] as Map).cast<String, dynamic>());
      final right = _fingerprint((row['right'] as Map).cast<String, dynamic>());
      final expected = assertionsOf(row['expected'],
          'durable-client/envelope_v1.json projection fingerprint expected');
      assertKey(
          expected, 'same_source', left.sourcePosition == right.sourcePosition);
      assertKey(
          expected, 'same_fingerprint', left.fingerprint == right.fingerprint);
      assertKey(expected, 'same_completeness',
          left.completeness == right.completeness);
      assertKey(expected, 'equivalent', left.equivalentTo(right));
      expect(left.mayAuthorizeTransition, isFalse);
    }
  });

  test('envelope, order, dedup, receipt, fingerprint and tiers', () async {
    const tiers = DurableTierDeclaration();
    expect(tiers.core && tiers.client, isTrue);
    expect(tiers.durableHost || tiers.distributedHost || tiers.acceleratedHost,
        isFalse);

    final first = DurableEnvelope(
        messageId: 'sample-owner/message-4',
        schemaVersion: 7,
        codecVersion: 11,
        payload: [65]);
    final same = DurableEnvelope(
        messageId: 'sample-owner/message-4',
        schemaVersion: 7,
        codecVersion: 11,
        payload: [65]);
    final changed = DurableEnvelope(
        messageId: 'sample-owner/message-4',
        schemaVersion: 7,
        codecVersion: 11,
        payload: [66]);
    expect(first.validate(), EnvelopeValidation.accepted);
    expect(
        DurableEnvelope(
            protocolVersion: 2,
            messageId: 'x',
            schemaVersion: 7,
            codecVersion: 11,
            payload: [255]).validate(),
        EnvelopeValidation.unsupportedProtocolVersion);

    final dedup = DurableDeduplicator();
    expect(dedup.classify(first), DeliveryClassification.first);
    expect(dedup.classify(same), DeliveryClassification.duplicate);
    expect(dedup.classify(changed), DeliveryClassification.conflict);

    final order = DurableObservationOrder()
      ..observe(changed)
      ..observe(first)
      ..observe(changed);
    expect(order.messageIds, [
      'sample-owner/message-4',
      'sample-owner/message-4',
      'sample-owner/message-4'
    ]);
    expect(order.ownerOrderInferred, isFalse);

    const receipt = DurableHostReceipt(
        receiptId: 'receipt-1',
        messageId: 'message-4',
        outcome: DurableReceiptOutcome.committed,
        ownerPosition: 42);
    expect(receipt.transportAckEquivalent, isFalse);
    const left = ProjectionFingerprint('orders', 42, 'aabbccdd');
    expect(
        left.equivalentTo(
            const ProjectionFingerprint('orders', 42, 'aabbccdd')),
        isTrue);
    expect(
        left.equivalentTo(
            const ProjectionFingerprint('orders', 41, 'aabbccdd')),
        isFalse);
    expect(left.mayAuthorizeTransition, isFalse);

    final projections = AdvisoryProjectionOrder();
    expect(projections.observe(2, 'two'),
        ProjectionDeliveryClassification.buffered);
    expect(projections.observe(1, 'one'),
        ProjectionDeliveryClassification.applied);
    expect(projections.observe(2, 'two'),
        ProjectionDeliveryClassification.duplicate);
    expect(projections.appliedPositions, [1, 2]);
    expect(projections.brokerOrderAuthoritative, isFalse);
    expect(projections.mayAuthorizeTransition, isFalse);

    var decoded = false;
    final client = DurableClient<String, String>(
        _Transport(), (value) => Uint8List.fromList(value.codeUnits), (bytes) {
      decoded = true;
      return String.fromCharCodes(bytes);
    });
    expect(
        client
            .decode(DurableEnvelope(
                protocolVersion: 2,
                messageId: 'x',
                schemaVersion: 7,
                codecVersion: 11,
                payload: [255]))
            .$1,
        EnvelopeValidation.unsupportedProtocolVersion);
    expect(decoded, isFalse);
    final ack =
        await client.publish('owners.commands', 'message-1', 7, 11, 'go');
    expect(ack.sequence, 9);
  });
}

DurableEnvelope _fromWire(Map<String, dynamic> value) => DurableEnvelope(
      protocolVersion: value['protocol_version'] as int,
      messageId: value['message_id'] as String,
      schemaVersion: value['schema_version'] as int,
      codecVersion: value['codec_version'] as int,
      payload: (value['payload'] as List).cast<int>(),
    );

String _validationName(EnvelopeValidation value) => switch (value) {
      EnvelopeValidation.accepted => 'accepted',
      EnvelopeValidation.unsupportedProtocolVersion =>
        'unsupported_protocol_version',
      EnvelopeValidation.invalidMessageId => 'invalid_message_id',
      EnvelopeValidation.invalidSchemaVersion => 'invalid_schema_version',
      EnvelopeValidation.invalidCodecVersion => 'invalid_codec_version',
    };

DurableHostReceipt _receipt(Map<String, dynamic> value) => DurableHostReceipt(
      protocolVersion: value['protocol_version'] as int,
      receiptId: value['receipt_id'] as String,
      messageId: value['message_id'] as String,
      outcome: DurableReceiptOutcome.values.byName(value['outcome'] as String),
      ownerPosition: value['owner_position'] as int,
    );

ProjectionFingerprint _fingerprint(Map<String, dynamic> value) =>
    ProjectionFingerprint(
      value['projection_id'] as String,
      value['source_position'] as int,
      value['fingerprint'] as String,
      value['completeness'] == 'complete_history'
          ? ProjectionCapability.completeHistory
          : ProjectionCapability.latestStateOnly,
    );

final class _Transport implements NatsDurableClientTransport {
  @override
  Future<BrokerPubAck> publish(
          String subject, DurableEnvelope envelope) async =>
      const BrokerPubAck('OWNER', 9);
  @override
  Stream<DurableEnvelope> subscribe(String subject) => const Stream.empty();
}
