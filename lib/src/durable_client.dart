import 'dart:async';
import 'dart:typed_data';

const int durableClientProtocolVersion = 1;

enum DurableCapabilityTier {
  core,
  client,
  durableHost,
  distributedHost,
  acceleratedHost
}

final class DurableTierDeclaration {
  const DurableTierDeclaration();
  bool get core => true;
  bool get client => true;
  bool get durableHost => false;
  bool get distributedHost => false;
  bool get acceleratedHost => false;
}

/// Exact durable-envelope-v1 shape; it carries no owner authority or broker metadata.
final class DurableEnvelope {
  DurableEnvelope({
    this.protocolVersion = durableClientProtocolVersion,
    required this.messageId,
    required this.schemaVersion,
    required this.codecVersion,
    required List<int> payload,
  }) : payload = Uint8List.fromList(payload);

  final int protocolVersion;
  final String messageId;
  final int schemaVersion;
  final int codecVersion;
  final Uint8List payload;

  EnvelopeValidation validate() {
    if (protocolVersion != durableClientProtocolVersion) {
      return EnvelopeValidation.unsupportedProtocolVersion;
    }
    if (messageId.isEmpty) return EnvelopeValidation.invalidMessageId;
    if (schemaVersion <= 0 || schemaVersion > 0xffffffff) {
      return EnvelopeValidation.invalidSchemaVersion;
    }
    if (codecVersion <= 0 || codecVersion > 0xffffffff) {
      return EnvelopeValidation.invalidCodecVersion;
    }
    return EnvelopeValidation.accepted;
  }

  bool sameContent(DurableEnvelope other) =>
      protocolVersion == other.protocolVersion &&
      schemaVersion == other.schemaVersion &&
      codecVersion == other.codecVersion &&
      _bytesEqual(payload, other.payload);
}

enum EnvelopeValidation {
  accepted,
  unsupportedProtocolVersion,
  invalidMessageId,
  invalidSchemaVersion,
  invalidCodecVersion,
}

enum DeliveryClassification { first, duplicate, conflict }

final class DurableDeduplicator {
  final Map<String, DurableEnvelope> _seen = {};

  DeliveryClassification classify(DurableEnvelope envelope) {
    final prior = _seen[envelope.messageId];
    if (prior == null) {
      _seen[envelope.messageId] = envelope;
      return DeliveryClassification.first;
    }
    return prior.sameContent(envelope)
        ? DeliveryClassification.duplicate
        : DeliveryClassification.conflict;
  }
}

/// Preserves broker observation order without inventing durable-owner order.
final class DurableObservationOrder {
  final List<String> _messageIds = [];
  void observe(DurableEnvelope envelope) => _messageIds.add(envelope.messageId);
  List<String> get messageIds => List.unmodifiable(_messageIds);
  bool get ownerOrderInferred => false;
}

final class BrokerPubAck {
  const BrokerPubAck(this.stream, this.sequence, {this.duplicate = false});
  final String stream;
  final int sequence;
  final bool duplicate;
}

enum DurableReceiptOutcome { committed, duplicate, conflict, rejected }

final class DurableHostReceipt {
  const DurableHostReceipt({
    this.protocolVersion = durableClientProtocolVersion,
    required this.receiptId,
    required this.messageId,
    required this.outcome,
    required this.ownerPosition,
  });
  final int protocolVersion;
  final String receiptId;
  final String messageId;
  final DurableReceiptOutcome outcome;
  final int ownerPosition;
  bool get transportAckEquivalent => false;
}

final class ProjectionFingerprint {
  const ProjectionFingerprint(
    this.projectionId,
    this.sourcePosition,
    this.fingerprint, [
    this.completeness = ProjectionCapability.completeHistory,
  ]);
  final String projectionId;
  final int sourcePosition;
  final String fingerprint;
  final ProjectionCapability completeness;
  bool equivalentTo(ProjectionFingerprint other) =>
      projectionId == other.projectionId &&
      sourcePosition == other.sourcePosition &&
      fingerprint == other.fingerprint &&
      completeness == other.completeness;
  bool get mayAuthorizeTransition => false;
}

enum ProjectionCapability { completeHistory, latestStateOnly }

enum ProjectionDeliveryClassification { buffered, applied, duplicate, conflict }

/// Orders advisory projection observations without treating broker order as owner order.
final class AdvisoryProjectionOrder {
  int _appliedThrough = 0;
  final Map<int, String> _pending = {};
  final Map<int, String> _applied = {};
  final List<int> _appliedPositions = [];

  ProjectionDeliveryClassification observe(
      int sourcePosition, String fingerprint) {
    final appliedFingerprint = _applied[sourcePosition];
    if (appliedFingerprint != null) {
      return appliedFingerprint == fingerprint
          ? ProjectionDeliveryClassification.duplicate
          : ProjectionDeliveryClassification.conflict;
    }
    final pendingFingerprint = _pending[sourcePosition];
    if (pendingFingerprint != null) {
      return pendingFingerprint == fingerprint
          ? ProjectionDeliveryClassification.duplicate
          : ProjectionDeliveryClassification.conflict;
    }
    if (sourcePosition > _appliedThrough + 1) {
      _pending[sourcePosition] = fingerprint;
      return ProjectionDeliveryClassification.buffered;
    }
    if (sourcePosition <= _appliedThrough) {
      return ProjectionDeliveryClassification.conflict;
    }
    _apply(sourcePosition, fingerprint);
    while (true) {
      final nextPosition = _appliedThrough + 1;
      final next = _pending.remove(nextPosition);
      if (next == null) break;
      _apply(nextPosition, next);
    }
    return ProjectionDeliveryClassification.applied;
  }

  void _apply(int position, String fingerprint) {
    _appliedThrough = position;
    _applied[position] = fingerprint;
    _appliedPositions.add(position);
  }

  List<int> get appliedPositions => List.unmodifiable(_appliedPositions);
  bool get brokerOrderAuthoritative => false;
  bool get mayAuthorizeTransition => false;
}

final class DurableProjectionUpdate<T> {
  const DurableProjectionUpdate({
    required this.fingerprint,
    required this.projectionVersion,
    required this.capability,
    required this.value,
  });
  final ProjectionFingerprint fingerprint;
  final int projectionVersion;
  final ProjectionCapability capability;
  final T value;
  bool get mayAuthorizeTransition => false;
}

abstract interface class NatsDurableClientTransport {
  Future<BrokerPubAck> publish(String subject, DurableEnvelope envelope);
  Stream<DurableEnvelope> subscribe(String subject);
}

/// Typed codec facade over an injected NATS-compatible transport.
final class DurableClient<TIngress, TProjection> {
  DurableClient(this._transport, this._encode, this._decode);

  final NatsDurableClientTransport _transport;
  final Uint8List Function(TIngress) _encode;
  final TProjection Function(Uint8List) _decode;
  final DurableDeduplicator deduplicator = DurableDeduplicator();
  final DurableObservationOrder observationOrder = DurableObservationOrder();
  bool get mayAuthorizeTransition => false;

  Future<BrokerPubAck> publish(
    String subject,
    String messageId,
    int schemaVersion,
    int codecVersion,
    TIngress value,
  ) {
    final envelope = DurableEnvelope(
      messageId: messageId,
      schemaVersion: schemaVersion,
      codecVersion: codecVersion,
      payload: _encode(value),
    );
    if (envelope.validate() != EnvelopeValidation.accepted) {
      throw ArgumentError('invalid durable envelope');
    }
    return _transport.publish(subject, envelope);
  }

  /// Validates protocol and identity/version fields before payload decode.
  (EnvelopeValidation, DeliveryClassification?, TProjection?) decode(
    DurableEnvelope envelope,
  ) {
    final validation = envelope.validate();
    if (validation != EnvelopeValidation.accepted) {
      return (validation, null, null);
    }
    observationOrder.observe(envelope);
    final classification = deduplicator.classify(envelope);
    if (classification != DeliveryClassification.first) {
      return (EnvelopeValidation.accepted, classification, null);
    }
    return (
      EnvelopeValidation.accepted,
      classification,
      _decode(envelope.payload),
    );
  }

  StreamSubscription<DurableEnvelope> subscribe(String subject) =>
      _transport.subscribe(subject).listen(decode);
}

bool _bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}
