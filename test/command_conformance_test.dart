import 'dart:convert';
import 'dart:io';

import 'package:lazily/ipc.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

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

Map<String, dynamic> _load(String name) => attributeFixture(
        jsonDecode(File(_fixturePath(name)).specReadAsStringSync()))
    as Map<String, dynamic>;

List<Map<String, dynamic>> _frames(Map<String, dynamic> obj) =>
    (obj['frames'] as List).cast<Map<String, dynamic>>();

/// Fold one fixture frame into [projection]. Returns the last apply status.
CommandApplyStatus foldFrame(
    CommandProjection projection, Map<String, dynamic> frame) {
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

void _assertProjection(
    CommandProjection projection, Map<String, dynamic> expectSpec) {
  // Key set first (`#lzsubblockkeyset`), against the wire form the LIBRARY
  // produces. `CommandProjectionImage.fromWire` reads two named fields and
  // ignores the rest, so a third field added to the fixture's projection image
  // upstream would be parsed away and compared by nothing.
  final image = projection.toImage();
  final want = assertKeySet(expectSpec, 'projection', image.toWire().keys,
      reason: 'the projection image the library emits must carry exactly the '
          'fields the fixture declares');
  expect(image, CommandProjectionImage.fromWire(want),
      reason: 'projection image mismatch');
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
    expect(
        p.submit(_submitFixture('cmd-1', 99)), const CommandApplyDuplicate());
    expect(p.entry('cmd-1')!.generation, 42);
  });

  test('conflicting terminal receipts fail closed', () {
    final p = CommandProjection();
    p.submit(_submitFixture('cmd-1', 42));
    p.observeReceipt(CausalReceipt.applied(
        'rcpt-applied', 'cmd-1', 'project-controller', 42));
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
    _assertProjection(p, assertionsOf(fx['expect']));
    expect(p.terminalFor('cmd-run-1'), isNull);
  });

  test('sync tmux layout submit shared blob', () {
    final fx = _load('sync_tmux_layout_submit.json');
    final p = CommandProjection();
    for (final frame in _frames(fx)) {
      foldFrame(p, frame);
    }
    _assertProjection(p, assertionsOf(fx['expect']));
  });

  test('accepted then applied receipt is terminal only at receipt', () {
    final fx = _load('accepted_then_applied_receipt.json');
    final expectSpec = assertionsOf(fx['expect']);
    final p = CommandProjection();
    final frames = _frames(fx);
    // The first frame index at which the command reads as terminal — the
    // observable the fixture names.
    var firstTerminalAt = -1;
    for (var i = 0; i < frames.length; i++) {
      foldFrame(p, frames[i]);
      final isTerminal = p.terminalFor('cmd-run-1') != null;
      if (isTerminal && firstTerminalAt < 0) firstTerminalAt = i;
      // Terminality must be monotone once reached.
      if (firstTerminalAt >= 0 && i > firstTerminalAt) {
        expect(isTerminal, isTrue,
            reason: 'frame $i must stay terminal once terminal');
      }
    }
    assertKey(expectSpec, 'terminal_after_frame_index', firstTerminalAt);
    _assertProjection(p, expectSpec);
  });

  test('stale generation events and receipts are ignored', () {
    final fx = _load('stale_generation_ignored.json');
    final expectSpec = assertionsOf(fx['expect']);
    final p = CommandProjection();
    final frames = _frames(fx);
    final staleIndices = <int>[];
    for (var i = 0; i < frames.length; i++) {
      final status = foldFrame(p, frames[i]);
      if (status is CommandApplyStaleGeneration) staleIndices.add(i);
    }
    assertKeyWith(expectSpec, 'ignored_frame_indices', (v) {
      expect(staleIndices, (v as List).cast<int>(),
          reason: 'frames the fold reported as stale-generation');
    });
    _assertProjection(p, expectSpec);
  });

  test('terminal conflict fails closed fixture', () {
    final fx = _load('terminal_conflict_fail_closed.json');
    final expectSpec = assertionsOf(fx['expect']);
    final commandId =
        assertKeyWith(expectSpec, 'conflict_command_id', (v) => v as String);
    final p = CommandProjection();
    final frames = _frames(fx);
    var conflictAt = -1;
    for (var i = 0; i < frames.length; i++) {
      final status = foldFrame(p, frames[i]);
      if (status is CommandApplyTerminalConflict && conflictAt < 0) {
        conflictAt = i;
      }
    }
    assertKey(expectSpec, 'conflict_after_frame_index', conflictAt,
        'the frame index at which the fold raised a terminal conflict');
    assertKey(expectSpec, 'conflict', p.hasConflict(commandId),
        'fixture declares whether the fold ends in conflict');
    final imageBefore = p.toImage();
    final wantBefore = assertKeySet(
        expectSpec, 'projection_before_conflict', imageBefore.toWire().keys,
        reason: 'the projection image the library emits must carry exactly '
            'the fields the fixture declares');
    expect(imageBefore, CommandProjectionImage.fromWire(wantBefore));
  });

  test('cancel preempts nonterminal scenarios', () {
    final fx = _load('cancel_preempts_nonterminal.json');
    for (final scenario in scenariosOf(fx)) {
      final expectSpec = assertionsOf(scenario['expect']);
      // `cancel_after_applied_ignored` is the whole point of the second
      // scenario: a cancel arriving after `applied` must be IGNORED, never
      // rewrite applied into rejected. Checking only the projection would pass
      // against a fold that rejected the frame for the wrong reason.
      final p = CommandProjection();
      final frames = (scenario['frames'] as List).cast<Map<String, dynamic>>();
      // "Ignored" is a property of the FOLD, not of the returned status
      // variant: `CommandProjection.cancel` reports `Recorded` for a cancel it
      // accepted into its dedup log even when the cancel changes nothing, so
      // the status is the wrong signal. What the fixture asserts is that a
      // cancel arriving after `applied` never rewrites applied into rejected —
      // i.e. the projection is unchanged.
      final unchanged = <int>[];
      for (var i = 0; i < frames.length; i++) {
        final before = p.toImage();
        foldFrame(p, frames[i]);
        if (p.toImage() == before) unchanged.add(i);
      }
      // Against the indices the FOLD really left unchanged (`#lznullformblind`).
      // This used to be an in-range check against `scenario['frames'].length` —
      // the fixture compared to its own shape, which cannot move for a library
      // regression — while the value that drove the real comparison was read
      // raw and never routed through an assertion at all. Equality in both
      // directions: a fold that started ignoring a frame the fixture does not
      // name is as red as one that stopped ignoring the frame it does.
      assertKeyIfPresent(expectSpec, 'ignored_frame_indices', (v) {
        expect(unchanged, equals((v as List).cast<int>()),
            reason: '${scenario['name']}: the frames this fold left the '
                'projection unchanged on must be exactly the ones the fixture '
                'names as ignored');
      });
      _assertProjection(p, expectSpec);
    }
  });

  test('reconnect command projection resyncs', () {
    final fx = _load('reconnect_command_projection.json');
    final p = CommandProjection();
    for (final frame in _frames(fx)) {
      foldFrame(p, frame);
    }
    _assertProjection(p, assertionsOf(fx['expect']));
  });

  test('rpc call waits for terminal', () {
    final fx = _load('rpc_call_waits_for_terminal.json');
    final expectSpec = assertionsOf(fx['expect']);
    // DESCENDED into (`#lzsubblockkeyset`): three named sub-fields were read
    // off a raw map, so a fourth added upstream drove nothing.
    final rpc = subKey(expectSpec, 'rpc');
    final commandId =
        assertKeyWith<String>(rpc, 'command_id', (v) => v as String);
    final resolvesAt =
        assertKeyWith<int>(rpc, 'resolves_after_frame_index', (v) => v as int);
    final unresolved = assertKeyWith<List<int>>(
        rpc, 'unresolved_after_frame_indices', (v) => (v as List).cast<int>());
    {
      final p = CommandProjection();
      final frames = _frames(fx);
      for (var i = 0; i < frames.length; i++) {
        foldFrame(p, frames[i]);
        final terminal = p.terminalFor(commandId);
        if (unresolved.contains(i)) {
          expect(terminal, isNull, reason: 'frame $i must not resolve');
        }
        if (i == resolvesAt) {
          expect(terminal, isNotNull, reason: 'frame $i must resolve');
          // The descend found this key unconsumed (`#lzsubblockkeyset`): the
          // fixture names WHICH terminal status the call resolves to, and this
          // runner only checked that it resolved at all — an rpc that resolved
          // to `rejected` passed.
          assertKeyWith<void>(
              rpc,
              'terminal_status',
              (v) => expect(terminal!.status.wire, v,
                  reason: 'frame $i terminal status'));
        }
      }
    }
    final p = CommandProjection();
    for (final frame in _frames(fx)) {
      foldFrame(p, frame);
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
