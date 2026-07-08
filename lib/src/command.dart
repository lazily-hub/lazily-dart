/// Command / RPC message plane (`command-plane-v1`).
///
/// An evented command message family that is an additive sibling to Snapshot /
/// Delta / CrdtSync. The one hard rule: terminal authority is the causal receipt,
/// not the event or the transport. `observed` / `accepted` / `started` events are
/// non-terminal progress; a command becomes terminal only when a terminal
/// [CausalReceipt] folds in. [CommandRpcClient] is derived behavior over the
/// [CommandProjection] reducer — a unary `call` resolves only on a terminal
/// projection.
///
/// Mirrors `lazily-kt/.../Command.kt` and the command-plane section of
/// `lazily-js/src/index.js`. Hand-rolled JSON parity with [CausalReceipt] and the
/// lazily-spec externally-tagged wire form.
library;

import 'dart:convert';

import 'causal_receipts.dart';
import 'ipc.dart' show IpcValue;

/// How duplicate submits are deduplicated.
enum DedupePolicy {
  none('none'),
  sameIdempotencyKey('same_idempotency_key'),
  sameCommandId('same_command_id');

  const DedupePolicy(this.wire);
  final String wire;

  static DedupePolicy fromWire(String v) => values.firstWhere(
        (p) => p.wire == v,
        orElse: () => throw FormatException('unknown dedupe policy: $v'),
      );
}

/// Per-command behavior policy.
class CommandPolicy {
  const CommandPolicy({
    required this.dedupe,
    required this.supersede,
    required this.cancelOnPreempt,
  });

  final DedupePolicy dedupe;
  final bool supersede;
  final bool cancelOnPreempt;

  Map<String, dynamic> toWire() => {
        'dedupe': dedupe.wire,
        'supersede': supersede,
        'cancel_on_preempt': cancelOnPreempt,
      };

  static CommandPolicy fromWire(Object? v) {
    final m = v as Map<String, dynamic>;
    return CommandPolicy(
      dedupe: DedupePolicy.fromWire(m['dedupe'] as String),
      supersede: m['supersede'] as bool,
      cancelOnPreempt: m['cancel_on_preempt'] as bool,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CommandPolicy &&
      dedupe == other.dedupe &&
      supersede == other.supersede &&
      cancelOnPreempt == other.cancelOnPreempt;
  @override
  int get hashCode => Object.hash(dedupe, supersede, cancelOnPreempt);
}

/// A submitted command frame.
class CommandSubmit {
  const CommandSubmit({
    required this.commandId,
    required this.causationId,
    required this.source,
    required this.target,
    required this.namespace,
    required this.name,
    required this.authorityGeneration,
    required this.idempotencyKey,
    required this.deadlineMs,
    required this.policy,
    required this.payloadType,
    required this.payloadHash,
    required this.payload,
    required this.requiredFeatures,
  });

  final String commandId;
  final String causationId;
  final String source;
  final String target;
  final String namespace;
  final String name;
  final int authorityGeneration;
  final String idempotencyKey;
  final int deadlineMs;
  final CommandPolicy policy;
  final String payloadType;
  final String payloadHash;
  final IpcValue payload;
  final List<String> requiredFeatures;

  Map<String, dynamic> toWire() => {
        'command_id': commandId,
        'causation_id': causationId,
        'source': source,
        'target': target,
        'namespace': namespace,
        'name': name,
        'authority_generation': authorityGeneration,
        'idempotency_key': idempotencyKey,
        'deadline_ms': deadlineMs,
        'policy': policy.toWire(),
        'payload_type': payloadType,
        'payload_hash': payloadHash,
        'payload': payload.toWire(),
        'required_features': List<String>.from(requiredFeatures),
      };

  static CommandSubmit fromWire(Object? v) {
    final m = v as Map<String, dynamic>;
    return CommandSubmit(
      commandId: m['command_id'] as String,
      causationId: m['causation_id'] as String,
      source: m['source'] as String,
      target: m['target'] as String,
      namespace: m['namespace'] as String,
      name: m['name'] as String,
      authorityGeneration: m['authority_generation'] as int,
      idempotencyKey: m['idempotency_key'] as String,
      deadlineMs: m['deadline_ms'] as int,
      policy: CommandPolicy.fromWire(m['policy']),
      payloadType: m['payload_type'] as String,
      payloadHash: m['payload_hash'] as String,
      payload: IpcValue.fromWire(m['payload']),
      requiredFeatures:
          (m['required_features'] as List).cast<String>().toList(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CommandSubmit &&
      commandId == other.commandId &&
      causationId == other.causationId &&
      source == other.source &&
      target == other.target &&
      namespace == other.namespace &&
      name == other.name &&
      authorityGeneration == other.authorityGeneration &&
      idempotencyKey == other.idempotencyKey &&
      deadlineMs == other.deadlineMs &&
      policy == other.policy &&
      payloadType == other.payloadType &&
      payloadHash == other.payloadHash &&
      payload == other.payload &&
      _listEquals(requiredFeatures, other.requiredFeatures);
  @override
  int get hashCode => Object.hash(
      commandId,
      causationId,
      source,
      target,
      namespace,
      name,
      authorityGeneration,
      idempotencyKey,
      deadlineMs,
      policy,
      payloadType,
      payloadHash,
      payload,
      Object.hashAll(requiredFeatures));
}

/// A cancel frame for a previously-submitted command.
class CommandCancel {
  const CommandCancel({
    required this.commandId,
    required this.causationId,
    required this.source,
    required this.authorityGeneration,
    this.reason,
  });

  final String commandId;
  final String causationId;
  final String source;
  final int authorityGeneration;
  final String? reason;

  Map<String, dynamic> toWire() => {
        'command_id': commandId,
        'causation_id': causationId,
        'source': source,
        'authority_generation': authorityGeneration,
        'reason': reason,
      };

  static CommandCancel fromWire(Object? v) {
    final m = v as Map<String, dynamic>;
    return CommandCancel(
      commandId: m['command_id'] as String,
      causationId: m['causation_id'] as String,
      source: m['source'] as String,
      authorityGeneration: m['authority_generation'] as int,
      reason: m['reason'] as String?,
    );
  }
}

/// The kind of a progress event. Terminal-flavored event kinds
/// (cancelled/superseded/timed_out) do not themselves make a command terminal —
/// only the terminal receipt does.
enum CommandEventKind {
  observed('observed'),
  accepted('accepted'),
  started('started'),
  progress('progress'),
  cancelled('cancelled'),
  superseded('superseded'),
  timedOut('timed_out');

  const CommandEventKind(this.wire);
  final String wire;

  static CommandEventKind fromWire(String v) => values.firstWhere(
        (k) => k.wire == v,
        orElse: () => throw FormatException('unknown command event kind: $v'),
      );
}

/// A single command progress event.
class CommandEvent {
  const CommandEvent({
    required this.eventId,
    required this.commandId,
    required this.kind,
    required this.generation,
    this.detail,
  });

  final String eventId;
  final String commandId;
  final CommandEventKind kind;
  final int generation;
  final String? detail;

  Map<String, dynamic> toWire() => {
        'event_id': eventId,
        'command_id': commandId,
        'kind': kind.wire,
        'generation': generation,
        'detail': detail,
      };

  static CommandEvent fromWire(Object? v) {
    final m = v as Map<String, dynamic>;
    return CommandEvent(
      eventId: m['event_id'] as String,
      commandId: m['command_id'] as String,
      kind: CommandEventKind.fromWire(m['kind'] as String),
      generation: m['generation'] as int,
      detail: m['detail'] as String?,
    );
  }
}

/// A batch of command events.
class CommandEvents {
  const CommandEvents(this.events);
  final List<CommandEvent> events;

  Map<String, dynamic> toWire() => {
        'events': events.map((e) => e.toWire()).toList(),
      };

  static CommandEvents fromWire(Object? v) {
    final m = v as Map<String, dynamic>;
    return CommandEvents(
      (m['events'] as List).map(CommandEvent.fromWire).toList(),
    );
  }
}

/// The folded lifecycle status of a command.
enum CommandStatus {
  submitted('submitted'),
  accepted('accepted'),
  running('running'),
  applied('applied'),
  rejected('rejected'),
  cancelled('cancelled'),
  superseded('superseded'),
  timedOut('timed_out');

  const CommandStatus(this.wire);
  final String wire;

  /// Whether this status is terminal (no further transitions expected).
  bool get isTerminal =>
      this == CommandStatus.applied ||
      this == CommandStatus.rejected ||
      this == CommandStatus.cancelled ||
      this == CommandStatus.superseded ||
      this == CommandStatus.timedOut;

  static CommandStatus fromWire(String v) => values.firstWhere(
        (s) => s.wire == v,
        orElse: () => throw FormatException('unknown command status: $v'),
      );
}

/// One command's folded projection entry.
class CommandProjectionEntry {
  const CommandProjectionEntry({
    required this.commandId,
    required this.status,
    required this.terminal,
    required this.generation,
    this.reason,
    this.terminalReceiptId,
    this.lastEventId,
  });

  final String commandId;
  final CommandStatus status;
  final bool terminal;
  final int generation;
  final String? reason;
  final String? terminalReceiptId;
  final String? lastEventId;

  CommandProjectionEntry copyWith({
    String? commandId,
    CommandStatus? status,
    bool? terminal,
    int? generation,
    String? reason,
    String? terminalReceiptId,
    String? lastEventId,
  }) =>
      CommandProjectionEntry(
        commandId: commandId ?? this.commandId,
        status: status ?? this.status,
        terminal: terminal ?? this.terminal,
        generation: generation ?? this.generation,
        reason: reason ?? this.reason,
        terminalReceiptId: terminalReceiptId ?? this.terminalReceiptId,
        lastEventId: lastEventId ?? this.lastEventId,
      );

  Map<String, dynamic> toWire() => {
        'command_id': commandId,
        'status': status.wire,
        'terminal': terminal,
        'generation': generation,
        'reason': reason,
        'terminal_receipt_id': terminalReceiptId,
        'last_event_id': lastEventId,
      };

  static CommandProjectionEntry fromWire(Object? v) {
    final m = v as Map<String, dynamic>;
    return CommandProjectionEntry(
      commandId: m['command_id'] as String,
      status: CommandStatus.fromWire(m['status'] as String),
      terminal: m['terminal'] as bool,
      generation: m['generation'] as int,
      reason: m['reason'] as String?,
      terminalReceiptId: m['terminal_receipt_id'] as String?,
      lastEventId: m['last_event_id'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CommandProjectionEntry &&
      commandId == other.commandId &&
      status == other.status &&
      terminal == other.terminal &&
      generation == other.generation &&
      reason == other.reason &&
      terminalReceiptId == other.terminalReceiptId &&
      lastEventId == other.lastEventId;
  @override
  int get hashCode => Object.hash(
      commandId, status, terminal, generation, reason, terminalReceiptId, lastEventId);
}

/// A whole projection image (a checkpoint / reconnect snapshot).
class CommandProjectionImage {
  const CommandProjectionImage({
    required this.generation,
    required this.commands,
  });

  final int generation;
  final List<CommandProjectionEntry> commands;

  Map<String, dynamic> toWire() => {
        'generation': generation,
        'commands': commands.map((c) => c.toWire()).toList(),
      };

  static CommandProjectionImage fromWire(Object? v) {
    final m = v as Map<String, dynamic>;
    return CommandProjectionImage(
      generation: m['generation'] as int,
      commands: (m['commands'] as List)
          .map(CommandProjectionEntry.fromWire)
          .toList(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CommandProjectionImage &&
      generation == other.generation &&
      _listEquals(commands, other.commands);
  @override
  int get hashCode => Object.hash(generation, Object.hashAll(commands));
}

/// The externally-tagged command message envelope.
sealed class CommandMessage {
  const CommandMessage();

  /// Wire form: a single-key object tagging the variant.
  Map<String, dynamic> toWire();

  /// Encode to a JSON byte string (parity with sibling bindings).
  String encodeJson() => jsonEncode(toWire());

  static CommandMessage decodeJson(String data) =>
      fromWire(jsonDecode(data));

  static CommandMessage fromWire(Object? v) {
    final m = v as Map<String, dynamic>;
    if (m.length != 1) {
      throw FormatException('CommandMessage must be externally tagged: $v');
    }
    final tag = m.keys.single;
    final body = m[tag];
    switch (tag) {
      case 'CommandSubmit':
        return CommandMessageSubmit(CommandSubmit.fromWire(body));
      case 'CommandCancel':
        return CommandMessageCancel(CommandCancel.fromWire(body));
      case 'CommandEvents':
        return CommandMessageEvents(CommandEvents.fromWire(body));
      case 'CommandProjection':
        return CommandMessageProjection(CommandProjectionImage.fromWire(body));
      default:
        throw FormatException('unknown CommandMessage variant: $tag');
    }
  }
}

final class CommandMessageSubmit extends CommandMessage {
  const CommandMessageSubmit(this.submit);
  final CommandSubmit submit;

  @override
  Map<String, dynamic> toWire() => {'CommandSubmit': submit.toWire()};

  @override
  bool operator ==(Object other) =>
      other is CommandMessageSubmit && submit == other.submit;
  @override
  int get hashCode => Object.hash('CommandSubmit', submit);
}

final class CommandMessageCancel extends CommandMessage {
  const CommandMessageCancel(this.cancel);
  final CommandCancel cancel;

  @override
  Map<String, dynamic> toWire() => {'CommandCancel': cancel.toWire()};
}

final class CommandMessageEvents extends CommandMessage {
  const CommandMessageEvents(this.events);
  final CommandEvents events;

  @override
  Map<String, dynamic> toWire() => {'CommandEvents': events.toWire()};
}

final class CommandMessageProjection extends CommandMessage {
  const CommandMessageProjection(this.image);
  final CommandProjectionImage image;

  @override
  Map<String, dynamic> toWire() => {'CommandProjection': image.toWire()};
}

/// The outcome of applying a frame to the projection reducer.
sealed class CommandApplyStatus {
  const CommandApplyStatus();
}

class CommandApplyRecorded extends CommandApplyStatus {
  const CommandApplyRecorded();
  @override
  bool operator ==(Object other) => other is CommandApplyRecorded;
  @override
  int get hashCode => 'Recorded'.hashCode;
}

class CommandApplyDuplicate extends CommandApplyStatus {
  const CommandApplyDuplicate();
  @override
  bool operator ==(Object other) => other is CommandApplyDuplicate;
  @override
  int get hashCode => 'Duplicate'.hashCode;
}

class CommandApplyUnknown extends CommandApplyStatus {
  const CommandApplyUnknown();
  @override
  bool operator ==(Object other) => other is CommandApplyUnknown;
  @override
  int get hashCode => 'Unknown'.hashCode;
}

class CommandApplyStaleGeneration extends CommandApplyStatus {
  const CommandApplyStaleGeneration(this.expected, this.actual);
  final int expected;
  final int actual;
  @override
  bool operator ==(Object other) =>
      other is CommandApplyStaleGeneration &&
      expected == other.expected &&
      actual == other.actual;
  @override
  int get hashCode => Object.hash('StaleGeneration', expected, actual);
}

class CommandApplyTerminalConflict extends CommandApplyStatus {
  const CommandApplyTerminalConflict(this.commandId, this.existing, this.incoming);
  final String commandId;
  final CommandStatus existing;
  final CommandStatus incoming;
  @override
  bool operator ==(Object other) =>
      other is CommandApplyTerminalConflict &&
      commandId == other.commandId &&
      existing == other.existing &&
      incoming == other.incoming;
  @override
  int get hashCode => Object.hash('TerminalConflict', commandId, existing, incoming);
}

/// Map a terminal receipt outcome + reason to a folded [CommandStatus].
CommandStatus _terminalStatusOf(ReceiptOutcome outcome, String? reason) {
  switch (outcome) {
    case ReceiptOutcome.applied:
      return CommandStatus.applied;
    case ReceiptOutcome.rejected:
      switch (reason) {
        case 'cancelled':
          return CommandStatus.cancelled;
        case 'superseded':
          return CommandStatus.superseded;
        case 'timed_out':
          return CommandStatus.timedOut;
        default:
          return CommandStatus.rejected;
      }
    // Non-terminal outcomes never reach here (guarded by isTerminal).
    case ReceiptOutcome.observed:
    case ReceiptOutcome.accepted:
      return CommandStatus.accepted;
  }
}

CommandStatus? _progressStatusOf(CommandEventKind kind) {
  switch (kind) {
    case CommandEventKind.observed:
    case CommandEventKind.accepted:
      return CommandStatus.accepted;
    case CommandEventKind.started:
    case CommandEventKind.progress:
      return CommandStatus.running;
    case CommandEventKind.cancelled:
    case CommandEventKind.superseded:
    case CommandEventKind.timedOut:
      return null;
  }
}

int _phaseRank(CommandStatus status) {
  switch (status) {
    case CommandStatus.submitted:
      return 0;
    case CommandStatus.accepted:
      return 1;
    case CommandStatus.running:
      return 2;
    default:
      return 3;
  }
}

/// The folded command projection reducer. Mirrors the Rust `CommandProjection`.
class CommandProjection {
  int _generation = 0;
  final Map<String, CommandProjectionEntry> _entries = {};
  final Set<String> _seenEventIds = {};
  final Set<String> _seenReceiptIds = {};
  final Set<String> _seenCancelIds = {};
  final Set<String> _conflicts = {};

  /// The current authority generation.
  int get generation => _generation;

  CommandApplyStatus applyMessage(CommandMessage message) {
    return switch (message) {
      CommandMessageSubmit() => submit(message.submit),
      CommandMessageCancel() => cancel(message.cancel),
      CommandMessageEvents() => message.events.events.fold<CommandApplyStatus>(
          const CommandApplyUnknown(), (_, e) => event(e)),
      CommandMessageProjection() => applyProjection(message.image),
    };
  }

  CommandApplyStatus submit(CommandSubmit submit) {
    if (_entries.containsKey(submit.commandId)) {
      return const CommandApplyDuplicate();
    }
    if (_generation < submit.authorityGeneration) {
      _generation = submit.authorityGeneration;
    }
    _entries[submit.commandId] = CommandProjectionEntry(
      commandId: submit.commandId,
      status: CommandStatus.submitted,
      terminal: false,
      generation: submit.authorityGeneration,
    );
    return const CommandApplyRecorded();
  }

  CommandApplyStatus event(CommandEvent event) {
    if (_seenEventIds.contains(event.eventId)) {
      return const CommandApplyDuplicate();
    }
    final entry = _entries[event.commandId];
    if (entry == null) return const CommandApplyUnknown();
    if (event.generation != entry.generation) {
      return CommandApplyStaleGeneration(entry.generation, event.generation);
    }
    _seenEventIds.add(event.eventId);
    var updated = entry.copyWith(lastEventId: event.eventId);
    final next = _progressStatusOf(event.kind);
    if (!updated.terminal &&
        next != null &&
        _phaseRank(next) >= _phaseRank(updated.status)) {
      updated = updated.copyWith(status: next);
    }
    _entries[event.commandId] = updated;
    return const CommandApplyRecorded();
  }

  CommandApplyStatus cancel(CommandCancel cancel) {
    if (_seenCancelIds.contains(cancel.causationId)) {
      return const CommandApplyDuplicate();
    }
    final entry = _entries[cancel.commandId];
    if (entry == null) return const CommandApplyUnknown();
    if (cancel.authorityGeneration != entry.generation) {
      return CommandApplyStaleGeneration(
          entry.generation, cancel.authorityGeneration);
    }
    _seenCancelIds.add(cancel.causationId);
    // A cancel is non-terminal by itself; the rejected receipt makes it terminal.
    return const CommandApplyRecorded();
  }

  CommandApplyStatus observeReceipt(CausalReceipt receipt) {
    if (_seenReceiptIds.contains(receipt.receiptId)) {
      return const CommandApplyDuplicate();
    }
    final entry = _entries[receipt.causationId];
    if (entry == null) return const CommandApplyUnknown();
    if (receipt.generation != entry.generation) {
      return CommandApplyStaleGeneration(entry.generation, receipt.generation);
    }
    if (!receipt.outcome.isTerminal) {
      _seenReceiptIds.add(receipt.receiptId);
      if (!entry.terminal &&
          _phaseRank(CommandStatus.accepted) >= _phaseRank(entry.status)) {
        _entries[receipt.causationId] =
            entry.copyWith(status: CommandStatus.accepted);
      }
      return const CommandApplyRecorded();
    }
    final incoming = _terminalStatusOf(receipt.outcome, receipt.reason);
    if (entry.terminal) {
      if (entry.status == incoming) {
        _seenReceiptIds.add(receipt.receiptId);
        return const CommandApplyRecorded();
      }
      _conflicts.add(receipt.causationId);
      return CommandApplyTerminalConflict(
          receipt.causationId, entry.status, incoming);
    }
    _seenReceiptIds.add(receipt.receiptId);
    _entries[receipt.causationId] = entry.copyWith(
      terminal: true,
      status: incoming,
      reason: receipt.reason,
      terminalReceiptId: receipt.receiptId,
    );
    return const CommandApplyRecorded();
  }

  CommandApplyStatus applyProjection(CommandProjectionImage image) {
    if (_generation < image.generation) {
      _generation = image.generation;
    }
    for (final entry in image.commands) {
      _entries[entry.commandId] = entry;
      if (entry.lastEventId != null) _seenEventIds.add(entry.lastEventId!);
      if (entry.terminalReceiptId != null) {
        _seenReceiptIds.add(entry.terminalReceiptId!);
      }
    }
    return const CommandApplyRecorded();
  }

  /// The entry for [commandId], or `null` if unseen.
  CommandProjectionEntry? entry(String commandId) => _entries[commandId];

  /// The terminal entry for [commandId], or `null` if not yet terminal.
  CommandProjectionEntry? terminalFor(String commandId) {
    final e = _entries[commandId];
    return (e != null && e.terminal) ? e : null;
  }

  /// Whether [commandId] has a terminal conflict.
  bool hasConflict(String commandId) => _conflicts.contains(commandId);

  /// The whole projection image (entries sorted by command id).
  CommandProjectionImage toImage() => CommandProjectionImage(
        generation: _generation,
        commands: _entries.values.toList()..sort((a, b) =>
            a.commandId.compareTo(b.commandId)),
      );
}

/// Transport used by [CommandRpcClient] to emit command-plane frames.
abstract class CommandTransport {
  void send(CommandMessage message);
}

/// Resolution state of an RPC `call`.
sealed class CallState {
  const CallState();
}

class CallStatePending extends CallState {
  const CallStatePending();
  @override
  bool operator ==(Object other) => other is CallStatePending;
  @override
  int get hashCode => 'Pending'.hashCode;
}

class CallStateResolved extends CallState {
  const CallStateResolved(this.entry);
  final CommandProjectionEntry entry;
  @override
  bool operator ==(Object other) =>
      other is CallStateResolved && entry == other.entry;
  @override
  int get hashCode => Object.hash('Resolved', entry);
}

class CallStateConflict extends CallState {
  const CallStateConflict();
  @override
  bool operator ==(Object other) => other is CallStateConflict;
  @override
  int get hashCode => 'Conflict'.hashCode;
}

/// RPC facade over the command plane. `submit` builds and sends CommandSubmit;
/// incoming frames and receipts are folded via `ingest*`; a unary `call` resolves
/// only when the projection reaches a terminal outcome — never on an ACK or an
/// `accepted` event.
class CommandRpcClient {
  CommandRpcClient(this._transport);

  final CommandTransport _transport;
  final CommandProjection projection = CommandProjection();

  /// Build, send, and fold a CommandSubmit. Returns the command id.
  String submit(CommandSubmit submit) {
    final message = CommandMessageSubmit(submit);
    _transport.send(message);
    projection.applyMessage(message);
    return submit.commandId;
  }

  /// Build, send, and fold a CommandCancel.
  void cancel(CommandCancel cancel) {
    final message = CommandMessageCancel(cancel);
    _transport.send(message);
    projection.applyMessage(message);
  }

  /// Fold an incoming command message.
  CommandApplyStatus ingestCommand(CommandMessage message) =>
      projection.applyMessage(message);

  /// Fold an incoming causal receipt.
  CommandApplyStatus ingestReceipt(CausalReceipt receipt) =>
      projection.observeReceipt(receipt);

  /// Poll the resolution state of [commandId].
  CallState pollCall(String commandId) {
    if (projection.hasConflict(commandId)) return const CallStateConflict();
    final entry = projection.terminalFor(commandId);
    if (entry != null) return CallStateResolved(entry);
    return const CallStatePending();
  }
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
