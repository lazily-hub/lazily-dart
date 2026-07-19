import 'dart:convert';
import 'dart:io';

import 'package:lazily/ipc.dart';
import 'package:test/test.dart';

/// Replay the shared `lazily-spec/conformance/message-passing` fixtures through
/// the Dart [CommandProjection] reducer and RPC facade, mirroring the Kotlin
/// [CommandConformanceTest] so both bindings agree fixture-by-fixture.
///
/// The one hard rule under test: terminal authority is the causal receipt, not
/// the event or the transport. `observed` / `accepted` / `started` events are
/// non-terminal progress; a command becomes terminal only when a terminal
/// [CausalReceipt] folds in.

final _localDir = Directory('test/conformance/message-passing');
final _specDir = Directory('../lazily-spec/conformance/message-passing');

// Fixture resolution is SIBLING-FIRST (`#lzspecconf`): the canonical
// lazily-spec checkout wins whenever it is present, and the mirrored copy under
// `test/conformance/` is a fallback for a checkout without the sibling — never
// an authority. The reverse order silently shadowed the canonical fixture with
// a stale mirror, so CI cloned lazily-spec and then tested the local copy and
// still reported green. `conformance_fixture_drift_test.dart` byte-compares the
// two whenever both exist, so a stale mirror fails loudly instead of hiding.
String _fixturePath(String name) {
  if (_specDir.existsSync()) {
    final sibling = _specDir.resolveSymbolicLinksSync() + '/$name';
    if (File(sibling).existsSync()) return sibling;
  }
  if (_localDir.existsSync()) {
    final local = _localDir.resolveSymbolicLinksSync() + '/$name';
    if (File(local).existsSync()) return local;
  }
  throw StateError('message-passing fixture not found: $name');
}

Map<String, dynamic> _load(String name) =>
    jsonDecode(File(_fixturePath(name)).readAsStringSync()) as Map<String, dynamic>;

List<Map<String, dynamic>> _frames(Map<String, dynamic> obj) =>
    (obj['frames'] as List).cast<Map<String, dynamic>>();

/// Fold one fixture frame into [projection]. Returns the last apply status.
CommandApplyStatus foldFrame(CommandProjection projection, Map<String, dynamic> frame) {
  final schema = frame['schema'] as String;
  final wire = frame['wire'];
  switch (schema) {
    case 'message-passing':
      return projection.applyMessage(CommandMessage.fromWire(wire));
    case 'receipts':
      // Wire envelope: {"CausalReceipts": {"receipts": [...]}}.
      final env = wire as Map<String, dynamic>;
      final body = env['CausalReceipts'] as Map<String, dynamic>;
      final batch = CausalReceipts.fromWire(body);
      CommandApplyStatus last = const CommandApplyUnknown();
      for (final r in batch.receipts) {
        last = projection.observeReceipt(r);
      }
      return last;
    default:
      throw StateError('unknown frame schema: $schema');
  }
}

void _assertProjection(CommandProjection projection, Map<String, dynamic> expectSpec) {
  final want = CommandProjectionImage.fromWire(expectSpec['projection']);
  expect(projection.toImage(), want, reason: 'projection image mismatch');
}

/// A canonical submit frame builder (mirrors the kt `submitFixture`).
CommandSubmit _submitFixture(String commandId, int generation) => CommandSubmit(
      commandId: commandId,
      causationId: commandId,
      source: 'vscode-plugin',
      target: 'project-controller',
      namespace: 'agent-doc',
      name: 'editor_route',
      authorityGeneration: generation,
      idempotencyKey: 'project-root:plan.md:run',
      deadlineMs: 120000,
      policy: const CommandPolicy(
        dedupe: DedupePolicy.sameIdempotencyKey,
        supersede: false,
        cancelOnPreempt: true,
      ),
      payloadType: 'agent-doc.editor_route.v1',
      payloadHash: 'sha256:deadbeef',
      payload: IpcValueInline([1, 2, 3]),
      requiredFeatures: ['causal-receipts'],
    );

void main() {
  // --- unit tests mirroring the Rust / kt reducer ---

  test('command status terminality is explicit', () {
    expect(CommandStatus.submitted.isTerminal, isFalse);
    expect(CommandStatus.accepted.isTerminal, isFalse);
    expect(CommandStatus.running.isTerminal, isFalse);
    expect(CommandStatus.applied.isTerminal, isTrue);
    expect(CommandStatus.cancelled.isTerminal, isTrue);
    expect(CommandStatus.timedOut.isTerminal, isTrue);
  });

  test('command message round trips through JSON', () {
    final message = CommandMessageSubmit(_submitFixture('cmd-1', 42));
    final decoded = CommandMessage.decodeJson(message.encodeJson());
    expect(decoded, message);
  });

  test('accepted progress is not terminal', () {
    final p = CommandProjection();
    p.submit(_submitFixture('cmd-1', 42));
    p.event(CommandEvent(
      eventId: 'ev-1',
      commandId: 'cmd-1',
      kind: CommandEventKind.accepted,
      generation: 42,
      detail: 'queued',
    ));
    final entry = p.entry('cmd-1')!;
    expect(entry.terminal, isFalse);
    expect(entry.status, CommandStatus.accepted);
    expect(p.terminalFor('cmd-1'), isNull);
  });

  test('duplicate submit is idempotent', () {
    final p = CommandProjection();
    expect(p.submit(_submitFixture('cmd-1', 42)), const CommandApplyRecorded());
    expect(p.submit(_submitFixture('cmd-1', 99)), const CommandApplyDuplicate());
    expect(p.entry('cmd-1')!.generation, 42);
  });

  test('conflicting terminal receipts fail closed', () {
    final p = CommandProjection();
    p.submit(_submitFixture('cmd-1', 42));
    p.observeReceipt(
        CausalReceipt.applied('rcpt-applied', 'cmd-1', 'project-controller', 42));
    final status = p.observeReceipt(CausalReceipt.rejected(
        'rcpt-rejected', 'cmd-1', 'project-controller', 42, 'conflict'));
    expect(status, isA<CommandApplyTerminalConflict>());
    expect(p.hasConflict('cmd-1'), isTrue);
    expect(p.entry('cmd-1')!.status, CommandStatus.applied);
  });

  // --- fixture replay ---

  test('editor_route submit is nonterminal', () {
    final fx = _load('editor_route_submit.json');
    final p = CommandProjection();
    for (final frame in _frames(fx)) {
      foldFrame(p, frame);
    }
    _assertProjection(p, fx['expect'] as Map<String, dynamic>);
    expect(p.terminalFor('cmd-run-1'), isNull);
  });

  test('sync tmux layout submit shared blob', () {
    final fx = _load('sync_tmux_layout_submit.json');
    final p = CommandProjection();
    for (final frame in _frames(fx)) {
      foldFrame(p, frame);
    }
    _assertProjection(p, fx['expect'] as Map<String, dynamic>);
  });

  test('accepted then applied receipt is terminal only at receipt', () {
    final fx = _load('accepted_then_applied_receipt.json');
    final expectSpec = fx['expect'] as Map<String, dynamic>;
    final terminalAt = expectSpec['terminal_after_frame_index'] as int;
    final p = CommandProjection();
    final frames = _frames(fx);
    for (var i = 0; i < frames.length; i++) {
      foldFrame(p, frames[i]);
      final isTerminal = p.terminalFor('cmd-run-1') != null;
      if (i < terminalAt) {
        expect(isTerminal, isFalse, reason: 'frame $i must be non-terminal');
      } else {
        expect(isTerminal, isTrue, reason: 'frame $i must be terminal');
      }
    }
    _assertProjection(p, expectSpec);
  });

  test('stale generation events and receipts are ignored', () {
    final fx = _load('stale_generation_ignored.json');
    final expectSpec = fx['expect'] as Map<String, dynamic>;
    final ignored =
        (expectSpec['ignored_frame_indices'] as List).cast<int>().toList();
    final p = CommandProjection();
    final frames = _frames(fx);
    for (var i = 0; i < frames.length; i++) {
      final status = foldFrame(p, frames[i]);
      if (ignored.contains(i)) {
        expect(status, isA<CommandApplyStaleGeneration>(),
            reason: 'frame $i should be stale-generation');
      }
    }
    _assertProjection(p, expectSpec);
  });

  test('terminal conflict fails closed fixture', () {
    final fx = _load('terminal_conflict_fail_closed.json');
    final expectSpec = fx['expect'] as Map<String, dynamic>;
    final conflictAt = expectSpec['conflict_after_frame_index'] as int;
    final commandId = expectSpec['conflict_command_id'] as String;
    final p = CommandProjection();
    final frames = _frames(fx);
    for (var i = 0; i < frames.length; i++) {
      final status = foldFrame(p, frames[i]);
      if (i == conflictAt) {
        expect(status, isA<CommandApplyTerminalConflict>(),
            reason: 'frame $i should raise a terminal conflict');
      }
    }
    expect(p.hasConflict(commandId), isTrue);
    final before = CommandProjectionImage.fromWire(
        expectSpec['projection_before_conflict']);
    expect(p.toImage(), before);
  });

  test('cancel preempts nonterminal scenarios', () {
    final fx = _load('cancel_preempts_nonterminal.json');
    for (final scenarioEl in (fx['scenarios'] as List)) {
      final scenario = scenarioEl as Map<String, dynamic>;
      final p = CommandProjection();
      for (final frame in (scenario['frames'] as List)) {
        foldFrame(p, frame as Map<String, dynamic>);
      }
      _assertProjection(p, scenario['expect'] as Map<String, dynamic>);
    }
  });

  test('reconnect command projection resyncs', () {
    final fx = _load('reconnect_command_projection.json');
    final p = CommandProjection();
    for (final frame in _frames(fx)) {
      foldFrame(p, frame);
    }
    _assertProjection(p, fx['expect'] as Map<String, dynamic>);
  });

  test('rpc call waits for terminal', () {
    final fx = _load('rpc_call_waits_for_terminal.json');
    final expectSpec = fx['expect'] as Map<String, dynamic>;
    final rpc = expectSpec['rpc'] as Map<String, dynamic>;
    final commandId = rpc['command_id'] as String;
    final resolvesAt = rpc['resolves_after_frame_index'] as int;
    final unresolved =
        (rpc['unresolved_after_frame_indices'] as List).cast<int>().toList();
    final p = CommandProjection();
    final frames = _frames(fx);
    for (var i = 0; i < frames.length; i++) {
      foldFrame(p, frames[i]);
      final resolved = p.terminalFor(commandId) != null;
      if (unresolved.contains(i)) {
        expect(resolved, isFalse, reason: 'frame $i must not resolve');
      }
      if (i == resolvesAt) {
        expect(resolved, isTrue, reason: 'frame $i must resolve');
      }
    }
    _assertProjection(p, expectSpec);
  });

  test('rpc facade resolves only on terminal receipt', () {
    final sent = <CommandMessage>[];
    final client = CommandRpcClient(_CollectorTransport(sent));
    final id = client.submit(_submitFixture('cmd-1', 42));
    client.ingestCommand(CommandMessageEvents(CommandEvents([
      CommandEvent(
          eventId: 'ev-1',
          commandId: id,
          kind: CommandEventKind.accepted,
          generation: 42,
          detail: 'queued'),
      CommandEvent(
          eventId: 'ev-2',
          commandId: id,
          kind: CommandEventKind.started,
          generation: 42),
    ])));
    expect(client.pollCall(id), const CallStatePending());
    client.ingestReceipt(
        CausalReceipt.applied('rcpt-1', id, 'project-controller', 42));
    final state = client.pollCall(id);
    expect(state, isA<CallStateResolved>());
    expect((state as CallStateResolved).entry.status, CommandStatus.applied);
    expect(sent.length, 1);
  });
}

class _CollectorTransport implements CommandTransport {
  _CollectorTransport(this.sent);
  final List<CommandMessage> sent;
  @override
  void send(CommandMessage message) => sent.add(message);
}
