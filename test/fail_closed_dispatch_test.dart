import 'dart:convert';
import 'dart:io';

import 'package:lazily/ipc.dart';
import 'package:lazily/lazily.dart';
import 'package:lazily/capability.dart';
import 'package:test/test.dart';

/// Library-side fail-open audit (#failclosedsweep).
///
/// The nine-binding sweep that preceded this one only looked at conformance
/// RUNNERS, where a silent default is always a bug. This file covers the
/// LIBRARY, where it sometimes is not — so every test below is one of two
/// kinds, and which kind it is, is the point:
///
///   * a REJECTION test, proving an unknown discriminant is now refused by
///     name instead of resolving to a silent default; or
///   * a PINNING test, proving a leniency that is deliberate stays lenient and
///     stays lenient for the documented reason. An undocumented default and a
///     deliberate one are indistinguishable from outside the package; these
///     tests are what makes them distinguishable.
///
/// Every site named here carries a matching comment in `lib/` stating the
/// verdict and, for the lenient ones, the wire contract that requires it.

CommandSubmit _submit(String id, {int generation = 1}) => CommandSubmit(
      commandId: id,
      causationId: id,
      source: 'peer-a',
      target: 'peer-b',
      namespace: 'doc',
      name: 'edit',
      authorityGeneration: generation,
      idempotencyKey: id,
      deadlineMs: 1000,
      policy: const CommandPolicy(
        dedupe: DedupePolicy.sameIdempotencyKey,
        supersede: false,
        cancelOnPreempt: false,
      ),
      payloadType: 'json',
      payloadHash: 'h',
      payload: IpcValue.inline(const <int>[]),
      requiredFeatures: const <String>[],
    );

void main() {
  // -------------------------------------------------------------------------
  // FAIL CLOSED — statechart `kind`
  // -------------------------------------------------------------------------
  group('ChartDef refuses an unknown state kind', () {
    Map<String, dynamic> chartWithKind(Object? kind) => {
          'initial': 'leaf',
          'states': {
            'root': {'initial': 'leaf'},
            'leaf': {'parent': 'root', 'kind': kind},
          },
        };

    test('an unrecognised kind string is refused by name', () {
      // `kind` is a closed five-value enum in schemas/statechart.json. This
      // used to be read for one comparison (`== 'final'`) and every other
      // value fell through to inference, so a typo parsed as an atomic state
      // and the chart ran with a silently wrong structure.
      expect(
        () => ChartDef.fromJson(chartWithKind('finall')),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('finall'))
            .having((e) => e.message, 'message', contains('unknown kind'))),
      );
    });

    test('a non-string kind is refused rather than silently inferred', () {
      expect(() => ChartDef.fromJson(chartWithKind(42)),
          throwsA(isA<FormatException>()));
    });

    test('kind "history" without a history field is refused', () {
      // `history` carries the shallow/deep flag the runtime needs; `kind:
      // "history"` alone cannot say which, so accepting it would enter a
      // history pseudo-state with no recorded semantics.
      expect(
        () => ChartDef.fromJson(chartWithKind('history')),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('history'))),
      );
    });

    test('a declared kind is now honoured, not overridden by inference', () {
      // `kind: "compound"` on a state with no `initial` used to infer atomic.
      final def = ChartDef.fromJson({
        'initial': 'child',
        'states': {
          'root': {'initial': 'branch'},
          'branch': {'parent': 'root', 'kind': 'compound', 'initial': 'child'},
          'child': {'parent': 'branch', 'kind': 'atomic'},
        },
      });
      final ctx = Context();
      final chart = StateChart(ctx, def);
      // A compound branch descends to its initial child; an atomic one would
      // have stopped at `branch`.
      expect(chart.configuration().toSet(), contains('child'));
    });

    test('every schema kind value parses', () {
      for (final kind in ['atomic', 'compound', 'parallel', 'final']) {
        expect(
          () => ChartDef.fromJson({
            'initial': 'leaf',
            'states': {
              'root': {'initial': 'leaf'},
              'leaf': {'parent': 'root', 'kind': kind, 'initial': 'root'},
            },
          }),
          returnsNormally,
          reason: 'kind "$kind" is in the schema enum',
        );
      }
    });
  });

  // -------------------------------------------------------------------------
  // FAIL CLOSED — statechart state-id references
  // -------------------------------------------------------------------------
  group('ChartDef refuses an undeclared state id', () {
    test('a transition target that names no state is refused', () {
      // This used to resolve to a map miss, which `ChartDef.kind` answered
      // with `_Atomic()` — so the chart ENTERED a state that does not exist
      // and the phantom id turned up in the active configuration.
      expect(
        () => ChartDef.fromJson({
          'initial': 'a',
          'states': {
            'root': {'initial': 'a'},
            'a': {
              'parent': 'root',
              'on': {'GO': 'typo_state'}
            },
          },
        }),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('typo_state'))
            .having((e) => e.message, 'message', contains('undeclared'))),
      );
    });

    test('an initial that names no state is refused', () {
      expect(
        () => ChartDef.fromJson({
          'initial': 'a',
          'states': {
            'root': {'initial': 'ghost'},
            'a': {'parent': 'root'},
          },
        }),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('ghost'))),
      );
    });

    test('a history default that names no state is refused', () {
      expect(
        () => ChartDef.fromJson({
          'initial': 'a',
          'states': {
            'root': {'initial': 'a'},
            'a': {'parent': 'root'},
            'h': {'parent': 'root', 'history': 'shallow', 'default': 'ghost'},
          },
        }),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('ghost'))),
      );
    });

    test('ChartDef.kind throws on an id the chart never declared', () {
      final def = ChartDef.fromJson({
        'initial': 'a',
        'states': {
          'root': {'initial': 'a'},
          'a': {'parent': 'root'},
        },
      });
      expect(() => def.kind('nope'), throwsA(isA<ArgumentError>()));
      expect(def.kind('a'), isNotNull);
    });
  });

  // -------------------------------------------------------------------------
  // FAIL CLOSED — durable outbox log
  // -------------------------------------------------------------------------
  group('FileOutboxStore refuses an unreadable durable log', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('lazily-outbox-'));
    tearDown(() => dir.deleteSync(recursive: true));

    File writeLog(List<String> lines) {
      final f = File('${dir.path}/outbox.jsonl');
      f.writeAsStringSync(lines.map((l) => '$l\n').join());
      return f;
    }

    test('an unknown op is refused by name instead of silently skipped', () {
      // A Dart `switch` over `Object?` with no `default` falls through in
      // silence, so an unrecognised op was skipped exactly the way a cursor
      // mark is skipped — and the outbox under-delivered while reporting
      // success.
      final f = writeLog([
        jsonEncode({
          'op': 'put',
          'epoch': 1,
          'frame': <int>[1, 2]
        }),
        jsonEncode({'op': 'compact', 'epoch': 2}),
      ]);
      final store = FileOutboxStore(f.path);
      expect(
        () => store.scanAfter(0),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('compact'))
            .having((e) => e.message, 'message', contains('unknown op'))),
      );
    });

    test('a cursor mark stays a no-op for the frame scan', () {
      final f = writeLog([
        jsonEncode({
          'op': 'put',
          'epoch': 1,
          'frame': <int>[1]
        }),
        jsonEncode({'op': 'cursor', 'epoch': 1}),
        jsonEncode({
          'op': 'put',
          'epoch': 2,
          'frame': <int>[2]
        }),
      ]);
      final store = FileOutboxStore(f.path);
      expect(store.scanAfter(0).map((e) => e.$1).toList(), [1, 2]);
      expect(store.loadCursor(), 1);
    });

    test('a torn FINAL record is still forgiven', () {
      // `_append` writes one whole line and flushes before returning, so a
      // crash can only tear the last line. That much leniency is the recovery
      // contract and is deliberately kept.
      final f = writeLog([
        jsonEncode({
          'op': 'put',
          'epoch': 1,
          'frame': <int>[1]
        }),
      ]);
      f.writeAsStringSync('{"op":"put","epo', mode: FileMode.append);
      final store = FileOutboxStore(f.path);
      expect(store.scanAfter(0).map((e) => e.$1).toList(), [1]);
    });

    test('a corrupt INTERIOR record is refused, not dropped', () {
      // This is the one that used to vanish: a bad interior line meant a frame
      // the peer is still waiting for silently disappeared from a DURABLE log.
      final f = writeLog([
        jsonEncode({
          'op': 'put',
          'epoch': 1,
          'frame': <int>[1]
        }),
        '{"op":"put","epo',
        jsonEncode({
          'op': 'put',
          'epoch': 3,
          'frame': <int>[3]
        }),
      ]);
      final store = FileOutboxStore(f.path);
      expect(
        () => store.scanAfter(0),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('torn FINAL'))),
      );
    });
  });

  // -------------------------------------------------------------------------
  // INTENTIONAL — unknown command rejection reason
  // -------------------------------------------------------------------------
  group('CommandProjection is lenient about an unknown rejection reason', () {
    test('unknown rejection reason folds to rejected', () {
      // Wire contract: `outcome` is the closed, authoritative discriminant and
      // is already fail-closed (`ReceiptOutcome.fromWire` throws); `reason` is
      // schema-typed `OptionalString` and only REFINES a rejection. A peer may
      // mint a new reason at any time, and refusing the receipt would strand a
      // well-formed terminal command non-terminal forever.
      final p = CommandProjection();
      p.submit(_submit('cmd-1'));
      p.observeReceipt(CausalReceipt(
        receiptId: 'r-1',
        causationId: 'cmd-1',
        observer: 'peer-b',
        generation: 1,
        outcome: ReceiptOutcome.rejected,
        reason: 'quota_exhausted_v2',
      ));
      final entry = p.entry('cmd-1')!;
      expect(entry.terminal, isTrue);
      expect(entry.status, CommandStatus.rejected);
      // The unrecognised reason survives verbatim for display — the projection
      // converges, it just cannot name the cause.
      expect(entry.reason, 'quota_exhausted_v2');
    });

    test('a known reason still refines the terminal status', () {
      for (final (reason, status) in [
        ('cancelled', CommandStatus.cancelled),
        ('superseded', CommandStatus.superseded),
        ('timed_out', CommandStatus.timedOut),
      ]) {
        final p = CommandProjection();
        p.submit(_submit('cmd-x'));
        p.observeReceipt(CausalReceipt(
          receiptId: 'r-x',
          causationId: 'cmd-x',
          observer: 'peer-b',
          generation: 1,
          outcome: ReceiptOutcome.rejected,
          reason: reason,
        ));
        expect(p.entry('cmd-x')!.status, status, reason: 'reason "$reason"');
      }
    });

    test('the outcome itself stays fail-closed', () {
      expect(
        () => CausalReceipt.fromWire(<String, dynamic>{
          'receipt_id': 'r',
          'causation_id': 'c',
          'observer': 'o',
          'generation': 1,
          'outcome': 'half_applied',
          'reason': null,
          'payload_hash': null,
        }),
        throwsA(anything),
        reason: 'an unknown OUTCOME must not be lenient the way a reason is',
      );
    });
  });

  // -------------------------------------------------------------------------
  // INTENTIONAL — capability handshake absent-field defaults
  // -------------------------------------------------------------------------
  group('CapabilityHandshake.fromWire absent-field leniency', () {
    test(
        'absent optional fields decode to the documented serde-parity defaults',
        () {
      // Wire contract: the handshake is the first frame a peer sends, before
      // either side knows what the other supports. `lazily-rs` spells these
      // `#[serde(default)]`; refusing a frame a Rust peer may legitimately
      // emit would make the handshake un-negotiable rather than fail-safe.
      final h = CapabilityHandshake.fromWire(<String, Object?>{'peer_id': 9});
      expect(h.peerId, 9);
      expect(h.sessionId, '');
      // Conservative defaults: assume the peer can do LESS.
      expect(h.fragmentationSupported, isFalse);
      expect(h.features, isEmpty);
      expect(h.maxFrameSize, kDefaultMaxFrameSize);
      // Not-conservative defaults, and the cost of serde parity: an omitted
      // protocol_id / major version reads as AGREEMENT with this build.
      expect(h.protocolId, kProtocolId);
      expect(h.protocolMajorVersion, kProtocolMajorVersion);
      expect(h.orderedReliable, isTrue);
      expect(h.codec, kDefaultCodec);
    });

    test('a handshake omitting protocol_id passes the compatibility gate', () {
      // The consequence of the leniency above, stated as an assertion so it
      // cannot change silently.
      final lenient = CapabilityHandshake.fromWire(
          <String, Object?>{'peer_id': 2, 'session_id': 's'});
      expect(CapabilityHandshake.defaults(1, 's').checkCompatible(lenient).isOk,
          isTrue);
    });

    test('an omitted session_id decodes empty but fails the negotiation gate',
        () {
      final lenient =
          CapabilityHandshake.fromWire(<String, Object?>{'peer_id': 2});
      final check =
          CapabilityHandshake.defaults(1, 's').checkCompatible(lenient);
      expect(check.isOk, isFalse);
      expect(check.field, 'session_id');
    });

    test('a PRESENT but wrong protocol_id still fails closed', () {
      // Leniency is about ABSENCE only. A field that is there and disagrees is
      // refused — that is what keeps the negotiation a negotiation.
      final impostor = CapabilityHandshake.fromWire(<String, Object?>{
        'peer_id': 2,
        'protocol_id': 'not-lazily',
      });
      final check =
          CapabilityHandshake.defaults(1, 's').checkCompatible(impostor);
      expect(check.isOk, isFalse);
      expect(check.field, 'protocol_id');
    });

    test('a PRESENT field of the wrong type still throws', () {
      expect(
        () => CapabilityHandshake.fromWire(
            <String, Object?>{'peer_id': 1, 'max_frame_size': 'big'}),
        throwsA(anything),
      );
      expect(
        () => CapabilityHandshake.fromWire(
            <String, Object?>{'peer_id': 1, 'codec': 7}),
        throwsA(anything),
      );
    });

    test('a non-map frame is not lenient — the required peer_id is missing',
        () {
      expect(() => CapabilityHandshake.fromWire('nope'), throwsA(anything));
      expect(() => CapabilityHandshake.fromWire(null), throwsA(anything));
    });
  });
}
