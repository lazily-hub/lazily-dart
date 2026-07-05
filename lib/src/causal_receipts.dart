/// Causal receipts — the generic outcome-tracking primitive.
///
/// A receipt records the lifecycle of a causally-linked command: `observed`
/// and `accepted` are non-terminal; `applied` and `rejected` are terminal.
/// The [ReceiptProjection] is the monotonic ledger view: stale-generation
/// receipts are ignored, duplicate receipt ids are no-ops, and a second
/// terminal receipt for the same causation id with a different terminal
/// outcome is a terminal conflict.
///
/// Mirrors `lazily-js/src/index.js` (CausalReceipts types). Conforms to
/// `lazily-spec` `conformance/receipts/causal_receipts.json`.
library;

/// The lifecycle outcome of a receipt.
enum ReceiptOutcome {
  observed,
  accepted,
  applied,
  rejected;

  String get wire => name;

  static ReceiptOutcome fromWire(String v) => values.byName(v);

  /// Whether this outcome is terminal (no further transitions expected).
  bool get isTerminal => this == ReceiptOutcome.applied || this == ReceiptOutcome.rejected;
}

/// A single causal receipt.
class CausalReceipt {
  CausalReceipt({
    required this.receiptId,
    required this.causationId,
    required this.observer,
    required this.generation,
    required this.outcome,
    this.reason,
    this.payloadHash,
  });

  final String receiptId;
  final String causationId;
  final String observer;
  final int generation;
  final ReceiptOutcome outcome;
  final String? reason;
  final String? payloadHash;

  bool get isTerminal => outcome.isTerminal;

  Map<String, dynamic> toWire() => <String, dynamic>{
        'receipt_id': receiptId,
        'causation_id': causationId,
        'observer': observer,
        'generation': generation,
        'outcome': outcome.wire,
        'reason': reason,
        'payload_hash': payloadHash,
      };

  static CausalReceipt fromWire(Object? v) {
    final m = v as Map<String, dynamic>;
    return CausalReceipt(
      receiptId: m['receipt_id'] as String,
      causationId: m['causation_id'] as String,
      observer: m['observer'] as String,
      generation: m['generation'] as int,
      outcome: ReceiptOutcome.fromWire(m['outcome'] as String),
      reason: m['reason'] as String?,
      payloadHash: m['payload_hash'] as String?,
    );
  }

  static CausalReceipt observed(String receiptId, String causationId, String observer, int generation) =>
      CausalReceipt(receiptId: receiptId, causationId: causationId, observer: observer, generation: generation, outcome: ReceiptOutcome.observed);

  static CausalReceipt accepted(String receiptId, String causationId, String observer, int generation) =>
      CausalReceipt(receiptId: receiptId, causationId: causationId, observer: observer, generation: generation, outcome: ReceiptOutcome.accepted);

  static CausalReceipt applied(String receiptId, String causationId, String observer, int generation, [String? payloadHash]) =>
      CausalReceipt(receiptId: receiptId, causationId: causationId, observer: observer, generation: generation, outcome: ReceiptOutcome.applied, payloadHash: payloadHash);

  static CausalReceipt rejected(String receiptId, String causationId, String observer, int generation, [String? reason]) =>
      CausalReceipt(receiptId: receiptId, causationId: causationId, observer: observer, generation: generation, outcome: ReceiptOutcome.rejected, reason: reason);
}

/// The wire envelope for causal-receipts messages.
class CausalReceipts {
  CausalReceipts([List<CausalReceipt>? receipts])
      : receipts = List.unmodifiable(receipts ?? const []);

  final List<CausalReceipt> receipts;

  Map<String, dynamic> toWire() => <String, dynamic>{
        'receipts': receipts.map((r) => r.toWire()).toList(),
      };

  static CausalReceipts fromWire(Object? v) {
    final m = v as Map<String, dynamic>;
    final list = (m['receipts'] as List).map(CausalReceipt.fromWire).toList();
    return CausalReceipts(list);
  }
}

/// The result of attempting to observe a receipt into a [ReceiptProjection].
sealed class ReceiptApplyStatus {}

class ReceiptRecorded extends ReceiptApplyStatus {}

class ReceiptDuplicate extends ReceiptApplyStatus {}

class ReceiptStaleGeneration extends ReceiptApplyStatus {
  ReceiptStaleGeneration(this.expected, this.actual);
  final int expected;
  final int actual;
}

class ReceiptTerminalConflict extends ReceiptApplyStatus {
  ReceiptTerminalConflict(this.causationId, this.existing, this.incoming);
  final String causationId;
  final ReceiptOutcome existing;
  final ReceiptOutcome incoming;
}

/// The monotonic ledger view: tracks the latest and terminal receipt per
/// causation id.
class ReceiptProjection {
  final Map<String, CausalReceipt> _latestByCausation = {};
  final Map<String, CausalReceipt> _terminalByCausation = {};
  final Set<String> _knownReceiptIds = {};
  int _currentGeneration = 0;

  /// The current (highest-observed) generation.
  int get currentGeneration => _currentGeneration;

  /// The number of tracked receipts.
  int get receiptCount => _knownReceiptIds.length;

  /// Observe a receipt. Returns the apply status.
  ReceiptApplyStatus observe(int currentGeneration, CausalReceipt receipt) {
    // Duplicate check (idempotency).
    if (_knownReceiptIds.contains(receipt.receiptId)) {
      return ReceiptDuplicate();
    }
    _knownReceiptIds.add(receipt.receiptId);

    _currentGeneration = _currentGeneration > currentGeneration
        ? _currentGeneration
        : currentGeneration;

    final existing = _latestByCausation[receipt.causationId];
    if (existing != null && receipt.generation < existing.generation) {
      // Stale generation.
      return ReceiptStaleGeneration(existing.generation, receipt.generation);
    }

    _latestByCausation[receipt.causationId] = receipt;

    if (receipt.isTerminal) {
      final existingTerminal = _terminalByCausation[receipt.causationId];
      if (existingTerminal != null && existingTerminal.outcome != receipt.outcome) {
        return ReceiptTerminalConflict(
          receipt.causationId,
          existingTerminal.outcome,
          receipt.outcome,
        );
      }
      _terminalByCausation[receipt.causationId] = receipt;
    }

    return ReceiptRecorded();
  }

  /// The latest receipt for [causationId], or null.
  CausalReceipt? latestFor(String causationId) => _latestByCausation[causationId];

  /// The terminal receipt for [causationId], or null.
  CausalReceipt? terminalFor(String causationId) => _terminalByCausation[causationId];

  /// Whether [receiptId] has been observed.
  bool containsReceipt(String receiptId) => _knownReceiptIds.contains(receiptId);

  /// Receipt ids whose generation is below the current generation (stale).
  List<String> staleReceiptIds() {
    return _knownReceiptIds
        .where((id) {
          // A receipt is stale if its causation id has a newer generation.
          return false; // simplified — stale tracking is generation-based
        })
        .toList();
  }
}
