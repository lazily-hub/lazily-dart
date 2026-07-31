/// Unit tests for the transport-agnostic reactive ingress family
/// (`#designimplementtransport`): the flavor-neutral [IngressCore] admission
/// algebra, then the reactivity each shell adds on top of it.
///
/// Mirrors the Rust unit tests in `lazily-rs/src/ingress_core.rs`,
/// `ingress.rs`, `thread_safe_ingress.rs`, and `async_ingress.rs`. Every test
/// name is an invariant; the cross-language *schedules* live in the conformance
/// corpus and are replayed by `ingress_family_conformance_test.dart`.
library;

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

IngressCore<String, int> _core(
  IngressPolicy policy, [
  MergePolicy<int>? merge,
]) =>
    IngressCore<String, int>(policy, merge ?? sum());

IngressEnvelope<String, int> _env(
  String key,
  int generation,
  int sequence,
  int stampedAt,
  int payload,
) =>
    IngressEnvelope<String, int>(key, generation, sequence, stampedAt, payload);

void main() {
  group('IngressCore — construction', () {
    test('conflate is rejected for a non-conflating algebra', () {
      expect(
        () => IngressCore<String, List<int>>(
          const IngressPolicy(overflow: Overflow.conflate),
          rawFifo<int>(),
        ),
        throwsA(isA<IngressConfigException>().having(
          (e) => e.error,
          'error',
          IngressConfigError.conflateNotBounding,
        )),
      );
    });

    test('zero receipt capacity is rejected', () {
      expect(
        () => _core(const IngressPolicy(receiptCapacity: 0)),
        throwsA(isA<IngressConfigException>().having(
          (e) => e.error,
          'error',
          IngressConfigError.zeroReceiptCapacity,
        )),
      );
    });
  });

  group('IngressCore — admission algebra', () {
    test('in-order delivery conflates and receipts', () {
      final core = _core(const IngressPolicy());
      final (change, admission) = core.admit(_env('a', 1, 0, 0, 5));
      expect(admission, const IngressAccepted(0));
      expect(change.acceptedReceipts, isTrue);
      expect(change.scopes, [('a', const IngressScopeChange.all())]);

      final (_, second) = core.admit(_env('a', 1, 1, 0, 7));
      expect(second, const IngressConflated(1));
      expect(core.peek('a'), 12);
      expect(core.receipts(IngressReceiptChannel.accepted).length, 2);
      expect(core.receipts(IngressReceiptChannel.dropped), isEmpty);
    });

    test('reorder buffers then flushes in one invalidation', () {
      final core = _core(const IngressPolicy());
      final (first, buffered) = core.admit(_env('a', 1, 2, 0, 4));
      expect(buffered, const IngressBuffered(0));
      // A buffered envelope mints no receipt and moves no value. The scope's
      // first appearance does move it off `unknown`, and saying so is the
      // difference between a sound invalidation set and a reader stuck on
      // `unknown` forever.
      expect(first.acceptedReceipts, isFalse);
      expect(first.droppedReceipts, isFalse);
      expect(first.scopes, [('a', const IngressScopeChange.creation())]);
      expect(core.peek('a'), isNull);

      final (second, stillBuffered) = core.admit(_env('a', 1, 1, 0, 2));
      expect(stillBuffered, const IngressBuffered(0));
      // Now the scope exists, so a second buffered envelope really is invisible.
      expect(second.isEmpty, isTrue);

      final (_, flushed) = core.admit(_env('a', 1, 0, 0, 1));
      // Three ops coalesced, so the delivery reports conflated even though the
      // window it started from was empty.
      expect(flushed, const IngressConflated(2));
      expect(core.peek('a'), 7); // 1 ⊕ 2 ⊕ 4 — one window.
      expect(core.view('a')!.buffered, 0);
      expect(core.receipts(IngressReceiptChannel.accepted).length, 1);
    });

    test('duplicates are dropped after delivery and while buffered', () {
      final core = _core(const IngressPolicy());
      core.admit(_env('a', 1, 0, 0, 1));
      expect(core.admit(_env('a', 1, 0, 0, 1)).$2,
          const IngressDropped(IngressDropReason.duplicateSequence));
      core.admit(_env('a', 1, 5, 0, 1));
      expect(core.admit(_env('a', 1, 5, 0, 1)).$2,
          const IngressDropped(IngressDropReason.duplicateBuffered));
      expect(core.peek('a'), 1);
    });

    test('reorder window overflow drops rather than growing', () {
      final core = _core(const IngressPolicy(reorderWindow: 2));
      core.admit(_env('a', 1, 1, 0, 1));
      core.admit(_env('a', 1, 2, 0, 1));
      expect(core.admit(_env('a', 1, 3, 0, 1)).$2,
          const IngressDropped(IngressDropReason.reorderWindowOverflow));
      expect(core.view('a')!.buffered, 2);
    });

    test('a zero reorder window drops every gap immediately', () {
      final core = _core(const IngressPolicy(reorderWindow: 0));
      expect(core.admit(_env('a', 1, 1, 0, 1)).$2,
          const IngressDropped(IngressDropReason.reorderWindowOverflow));
    });

    test('a stale generation is fenced before its sequence is consulted', () {
      final core = _core(const IngressPolicy());
      core.admit(_env('a', 2, 0, 0, 1));
      // Sequence 0 would be a duplicate; generation 1 is stale. The fence wins,
      // which is what makes a zombie producer distinguishable from a retry.
      expect(core.admit(_env('a', 1, 0, 0, 9)).$2,
          const IngressDropped(IngressDropReason.staleGeneration));
      expect(core.peek('a'), 1);
    });

    test('a newer generation hands off and resets the sequence space', () {
      final core = _core(const IngressPolicy());
      core.admit(_env('a', 1, 0, 0, 1));
      core.admit(_env('a', 1, 7, 0, 1));
      expect(core.admit(_env('a', 2, 0, 0, 4)).$2,
          const IngressGenerationHandoff(1, 2));
      final view = core.view('a')!;
      expect(view.generation, 2);
      expect(view.deliveredThrough, 0);
      // The old generation's buffered successor is not replayed under the new
      // fence — its sequence numbers mean something else now.
      expect(view.buffered, 0);
      // Nor is its undrained window folded into the new baseline.
      expect(core.peek('a'), 4);
    });

    test('a handoff that buffers still reports the baseline reset', () {
      // The case the formal model caught: a NEWER generation arriving out of
      // order resets the fence, the watermark, AND the window before parking the
      // envelope. Reporting that as "buffered, nothing changed" would leave
      // every reader showing the superseded generation's value forever.
      final core = _core(const IngressPolicy());
      core.admit(_env('a', 1, 0, 0, 5));
      final (change, admission) = core.admit(_env('a', 2, 3, 0, 9));
      expect(admission, const IngressBuffered(0));
      expect(change.scopes, [
        (
          'a',
          const IngressScopeChange(
            value: true,
            readiness: true,
            authority: true,
          ),
        ),
      ]);
      expect(core.peek('a'), isNull);
      final view = core.view('a')!;
      expect(view.generation, 2);
      expect(view.deliveredThrough, isNull);
      expect(view.buffered, 1);
      // A buffered envelope under the SAME generation is still invisible.
      expect(core.admit(_env('a', 2, 4, 0, 1)).$1.isEmpty, isTrue);
    });

    test('an expired envelope never occupies a reorder slot', () {
      final core = _core(
        const IngressPolicy(freshnessHorizon: 10, reorderWindow: 1),
      );
      core.tick(100);
      expect(core.admit(_env('a', 1, 3, 50, 1)).$2,
          const IngressDropped(IngressDropReason.expired));
      // A refused envelope leaves no scope behind: an expired message for an
      // untracked key is not an admission plane.
      expect(core.view('a'), isNull);
      // The slot is still free for a fresh out-of-order envelope.
      expect(core.admit(_env('a', 1, 3, 95, 1)).$2, const IngressBuffered(0));
    });

    test('block overflow refuses without losing the window', () {
      final core = _core(
        const IngressPolicy(highWater: 1, overflow: Overflow.block),
        keepLatest<int>(),
      );
      core.admit(_env('a', 1, 0, 0, 5));
      final (change, admission) = core.admit(_env('a', 1, 1, 0, 9));
      expect(admission, const IngressBlocked());
      expect(change.droppedReceipts, isTrue);
      expect(core.peek('a'), 5);
      // The blocked envelope did not advance the watermark, so a producer retry
      // after a drain is still in order rather than a duplicate.
      expect(core.view('a')!.deliveredThrough, 0);
      core.drain('a');
      expect(core.admit(_env('a', 1, 1, 0, 9)).$2, const IngressAccepted(1));
    });

    test('drop-oldest restarts the window at the incoming op', () {
      final core = _core(
          const IngressPolicy(highWater: 2, overflow: Overflow.dropOldest));
      core.admit(_env('a', 1, 0, 0, 1));
      core.admit(_env('a', 1, 1, 0, 2));
      expect(core.admit(_env('a', 1, 2, 0, 30)).$2, const IngressAccepted(2));
      expect(core.peek('a'), 30);
    });

    test('drop-newest keeps the window and receipts the drop', () {
      final core = _core(
          const IngressPolicy(highWater: 1, overflow: Overflow.dropNewest));
      core.admit(_env('a', 1, 0, 0, 5));
      final (change, admission) = core.admit(_env('a', 1, 1, 0, 9));
      expect(admission, const IngressDropped(IngressDropReason.backpressure));
      expect(change.droppedReceipts, isTrue);
      expect(core.peek('a'), 5);
    });

    test('out-of-order arrival converges to the in-order fold', () {
      // The reordering tax is paid by the buffer, not by the algebra: for any
      // arrival permutation of a contiguous run, the drained window equals the
      // in-order fold. This is `reorder_needs_no_commutativity`.
      const permutations = [
        [0, 1, 2, 3],
        [3, 2, 1, 0],
        [1, 0, 3, 2],
        [2, 0, 1, 3],
        [0, 3, 1, 2],
      ];
      for (final order in permutations) {
        final core = _core(const IngressPolicy());
        for (final seq in order) {
          core.admit(_env('a', 1, seq, 0, 1 << seq));
        }
        expect(core.peek('a'), 1 + 2 + 4 + 8, reason: 'order $order');
        expect(core.view('a')!.deliveredThrough, 3, reason: 'order $order');
      }
    });
  });

  group('IngressCore — lifecycle and derives', () {
    test('readiness derives from lifecycle and freshness', () {
      final core = _core(const IngressPolicy(freshnessHorizon: 10));
      expect(core.readiness('a'), IngressReadiness.unknown);
      core.open('a', 1);
      expect(core.readiness('a'), IngressReadiness.warming);
      core.admit(_env('a', 1, 0, 0, 1));
      expect(core.readiness('a'), IngressReadiness.ready);

      // Crossing the horizon is a readiness-only transition.
      final change = core.tick(50);
      expect(change.scopes, [('a', const IngressScopeChange.readinessOnly())]);
      expect(core.readiness('a'), IngressReadiness.stale);
      // A further tick inside the same readiness dirties nothing.
      expect(core.tick(60).isEmpty, isTrue);
    });

    test('suspend retains the watermark and reconnect replays the gap', () {
      final core = _core(const IngressPolicy());
      core.admit(_env('a', 1, 0, 0, 1));
      core.admit(_env('a', 1, 1, 0, 1));
      expect(core.suspend('a').$2, const ReplayRequest(1, 2));
      expect(core.readiness('a'), IngressReadiness.suspended);
      // The coalesced window survives a disconnect; only readiness changed.
      expect(core.peek('a'), 2);
      // Suspending twice is idempotent and dirties nothing.
      final (change, request) = core.suspend('a');
      expect(change.isEmpty, isTrue);
      expect(request, isNull);

      expect(core.reconnect('a', 1).$2, const ReplayRequest(1, 2));
      expect(core.readiness('a'), IngressReadiness.ready);
    });

    test('reconnect at a higher generation discards the stale window', () {
      final core = _core(const IngressPolicy());
      core.admit(_env('a', 1, 0, 0, 5));
      core.suspend('a');
      final (change, request) = core.reconnect('a', 3);
      expect(request, const ReplayRequest(3, 0));
      expect(
          change.scopes.any((row) => row.$2.value && row.$2.authority), isTrue);
      expect(core.peek('a'), isNull);
    });

    test('errors deepen backoff and a delivery clears it', () {
      final core = _core(const IngressPolicy(retryBase: 10, retryCeiling: 25));
      core.open('a', 1);
      expect(core.retry('a'), isNull);

      core.fail('a', IngressError.transportClosed);
      expect(core.retry('a'),
          const IngressRetry(attempt: 1, backoff: 10, resumeFrom: 0));
      core.fail('a', IngressError.transportClosed);
      expect(core.retry('a')!.backoff, 20);
      // Clamped, not doubled past the ceiling.
      core.fail('a', IngressError.transportClosed);
      expect(core.retry('a')!.backoff, 25);
      expect(core.receipts(IngressReceiptChannel.error).length, 3);

      core.admit(_env('a', 1, 0, 0, 1));
      expect(core.retry('a'), isNull);
    });

    test('a reconnect clears the error streak without a delivery', () {
      final core = _core(const IngressPolicy());
      core.open('a', 1);
      core.fail('a', IngressError.authorityLost);
      final (change, _) = core.reconnect('a', 1);
      expect(change.scopes.any((row) => row.$2.retry), isTrue);
      expect(core.retry('a'), isNull);
    });

    test('closed scopes admit nothing and claim no authority', () {
      final core = _core(const IngressPolicy());
      core.admit(_env('a', 1, 0, 0, 1));
      core.close('a');
      expect(core.authority('a'), isNull);
      expect(core.admit(_env('a', 1, 1, 0, 1)).$2,
          const IngressDropped(IngressDropReason.scopeClosed));
      // Reopening a closed scope restarts its sequence space.
      core.open('a', 1);
      expect(core.admit(_env('a', 1, 0, 0, 4)).$2, const IngressAccepted(0));
    });

    test('scopes are independent', () {
      final core = _core(const IngressPolicy());
      core.admit(_env('a', 1, 0, 0, 1));
      final (change, _) = core.admit(_env('b', 1, 0, 0, 2));
      expect(change.scopes.length, 1);
      expect(change.scopes.first.$1, 'b');
      core.close('b');
      expect(core.readiness('a'), IngressReadiness.ready);
      expect(core.peek('a'), 1);
    });

    test('receipts are bounded and offsets stay monotone', () {
      final core = _core(const IngressPolicy(receiptCapacity: 2));
      for (var seq = 0; seq < 4; seq++) {
        core.admit(_env('a', 1, seq, 0, 1));
      }
      final accepted = core.receipts(IngressReceiptChannel.accepted);
      expect(accepted.length, 2);
      expect(accepted.map((r) => r.offset), [2, 3]);
    });

    test('a drain is a value-only egress and empty drains dirty nothing', () {
      final core = _core(const IngressPolicy());
      core.admit(_env('a', 1, 0, 0, 3));
      final (change, value) = core.drain('a');
      expect(value, 3);
      expect(change.scopes, [('a', const IngressScopeChange.valueOnly())]);
      final (again, empty) = core.drain('a');
      expect(empty, isNull);
      expect(again.isEmpty, isTrue);
      // Draining does not move the watermark: a drain is an egress, not an ack.
      expect(core.view('a')!.deliveredThrough, 0);
    });

    test('a schedule offers a poll interval only without event delivery', () {
      expect(
          IngressSchedule.forKind(IngressTransportKind.eventChannel, 50)
              .pollInterval,
          isNull);
      expect(
          IngressSchedule.forKind(IngressTransportKind.rpcTriggered, 50)
              .pollInterval,
          isNull);
      expect(
          IngressSchedule.forKind(IngressTransportKind.boundedPolling, 50)
              .pollInterval,
          50);
      // A zero interval would be an unbounded refresh loop.
      expect(
          IngressSchedule.forKind(IngressTransportKind.boundedPolling, 0)
              .pollInterval,
          1);
    });
  });

  group('IngressCell — single-threaded reactivity', () {
    IngressCell<String, int> cell(
      Context ctx, [
      IngressPolicy policy = const IngressPolicy(),
    ]) =>
        IngressCell<String, int>(ctx, policy: policy, mergePolicy: sum());

    test('delivery is visible through the value reader', () {
      final ctx = Context();
      final ingress = cell(ctx);
      expect(ingress.value('a'), isNull);
      ingress.admit(_env('a', 1, 0, 0, 5));
      expect(ingress.value('a'), 5);
      ingress.admit(_env('a', 1, 1, 0, 7));
      expect(ingress.value('a'), 12);
      expect(ingress.drain('a'), 12);
      expect(ingress.value('a'), isNull);
    });

    test('readiness and authority are derives of the same transitions', () {
      final ctx = Context();
      final ingress = cell(ctx, const IngressPolicy(freshnessHorizon: 10));
      expect(ingress.readiness('a'), IngressReadiness.unknown);
      expect(ingress.authority('a'), isNull);

      ingress.open('a', 4);
      expect(ingress.readiness('a'), IngressReadiness.warming);
      expect(
        ingress.authority('a'),
        const IngressAuthority(
            generation: 4, deliveredThrough: null, stampedAt: 0),
      );

      ingress.admit(_env('a', 4, 0, 5, 1));
      expect(ingress.readiness('a'), IngressReadiness.ready);
      expect(
        ingress.authority('a'),
        const IngressAuthority(
            generation: 4, deliveredThrough: 0, stampedAt: 5),
      );

      ingress.tick(100);
      expect(ingress.readiness('a'), IngressReadiness.stale);
    });

    test('a buffered envelope reruns no effect', () {
      final ctx = Context();
      final ingress = cell(ctx);
      ingress.open('a', 1);

      final reader = ingress.readers('a').value;
      var runs = 0;
      final observed = <int?>[];
      final effect = Effect(ctx, (cx) {
        runs++;
        observed.add(cx.get(reader));
        return null;
      });
      expect(runs, 1);

      // Out of order: nothing observable moved, so the value effect must not run.
      ingress.admit(_env('a', 1, 2, 0, 4));
      ingress.admit(_env('a', 1, 1, 0, 2));
      expect(runs, 1);

      // The delivery that closes the gap flushes all three as ONE value change.
      ingress.admit(_env('a', 1, 0, 0, 1));
      expect(runs, 2);
      expect(observed, [null, 7]);
      effect.dispose();
    });

    test('a tick inside the horizon reruns no readiness effect', () {
      final ctx = Context();
      final ingress = cell(ctx, const IngressPolicy(freshnessHorizon: 100));
      ingress.admit(_env('a', 1, 0, 0, 1));

      final reader = ingress.readers('a').readiness;
      var runs = 0;
      final effect = Effect(ctx, (cx) {
        runs++;
        cx.get(reader);
        return null;
      });
      expect(runs, 1);

      ingress.tick(50);
      expect(runs, 1, reason: 'a tick inside the horizon is not a change');
      ingress.tick(500);
      expect(runs, 2, reason: 'crossing the horizon is a change');
      effect.dispose();
    });

    test('an error moves retry without touching the value', () {
      final ctx = Context();
      final ingress = cell(ctx);
      ingress.admit(_env('a', 1, 0, 0, 9));

      final reader = ingress.readers('a').value;
      var runs = 0;
      final effect = Effect(ctx, (cx) {
        runs++;
        cx.get(reader);
        return null;
      });
      ingress.fail('a', IngressError.transportClosed);
      expect(runs, 1);
      expect(ingress.retry('a')!.attempt, 1);
      expect(ingress.value('a'), 9);
      effect.dispose();
    });

    test('receipt channels are independent readers', () {
      final ctx = Context();
      final ingress = cell(ctx);
      ingress.admit(_env('a', 2, 0, 0, 1));
      expect(ingress.accepted().length, 1);
      expect(ingress.dropped(), isEmpty);
      expect(ingress.errors(), isEmpty);

      // A fenced zombie shows up only on the dropped channel.
      ingress.admit(_env('a', 1, 0, 0, 1));
      expect(ingress.accepted().length, 1);
      final dropped = ingress.dropped();
      expect(dropped.length, 1);
      expect(dropped.first.outcome,
          const IngressDroppedReceipt(IngressDropReason.staleGeneration));

      ingress.fail('a', IngressError.decodeFailed);
      expect(ingress.errors().length, 1);
      expect(ingress.dropped().length, 1);
    });

    test('the schedule derives from the transport and retunes live', () {
      final ctx = Context();
      final ingress = cell(ctx);
      expect(ingress.schedule().pollInterval, isNull);

      ingress.setTransport(IngressTransportKind.boundedPolling);
      expect(ingress.schedule().pollInterval, 25);
      ingress.setPollInterval(200);
      expect(ingress.schedule().pollInterval, 200);

      ingress.setTransport(IngressTransportKind.rpcTriggered);
      expect(ingress.schedule().pollInterval, isNull);
    });

    test('pump admits a batch and requests replay for a surviving gap', () {
      final ctx = Context();
      final ingress = cell(ctx);
      final transport =
          InProcIngress<String, int>(IngressTransportKind.eventChannel)
            ..push(_env('a', 1, 0, 0, 1))
            ..push(_env('a', 1, 2, 0, 4));

      final outcomes = ingress.pump(transport);
      expect(outcomes.length, 2);
      expect(outcomes[0].isDelivered, isTrue);
      expect(outcomes[1], const IngressBuffered(1));
      expect(transport.replays, [('a', const ReplayRequest(1, 1))]);

      // The replay closes the gap, and a second pump asks for nothing more.
      transport.push(_env('a', 1, 1, 0, 2));
      ingress.pump(transport);
      expect(ingress.value('a'), 7);
      expect(transport.replays.length, 1);
    });

    test('a polling transport cannot serve a replay', () {
      final ctx = Context();
      final ingress = cell(ctx);
      final transport =
          InProcIngress<String, int>(IngressTransportKind.boundedPolling)
            ..push(_env('a', 1, 3, 0, 1));
      ingress.pump(transport);
      expect(transport.replays, isEmpty);
    });

    test('a generation handoff lands value and authority in one frontier walk',
        () {
      // THE FRONTIER-WALK GATE. One admission that dirties several reader kinds
      // must clear them in ONE walk: clearing them one at a time reruns the
      // effect once per kind and exposes `new value, old authority` — the
      // partial fan-out a generation handoff must never show.
      final ctx = Context();
      final ingress = cell(ctx);
      ingress.admit(_env('a', 1, 0, 0, 5));

      final valueReader = ingress.readers('a').value;
      final authorityReader = ingress.readers('a').authority;
      var runs = 0;
      final seen = <(int?, int?)>[];
      final effect = Effect(ctx, (cx) {
        runs++;
        final value = cx.get(valueReader);
        final authority = cx.get(authorityReader);
        seen.add((value, authority?.generation));
        return null;
      });
      expect(runs, 1);

      ingress.admit(_env('a', 2, 0, 0, 9));
      expect(runs, 2,
          reason: 'one admission is one effect run, not one per reader kind');
      expect(seen, [(5, 1), (9, 2)]);
      effect.dispose();
    });

    test('scopes do not invalidate each other', () {
      final ctx = Context();
      final ingress = cell(ctx);
      ingress.admit(_env('a', 1, 0, 0, 1));

      final reader = ingress.readers('a').value;
      var runs = 0;
      final effect = Effect(ctx, (cx) {
        runs++;
        cx.get(reader);
        return null;
      });
      expect(runs, 1);
      ingress.admit(_env('b', 1, 0, 0, 2));
      ingress.close('b');
      expect(runs, 1);
      expect(ingress.value('a'), 1);
      effect.dispose();
    });

    test('suspend and reconnect move readiness and report the gap', () {
      final ctx = Context();
      final ingress = cell(ctx);
      ingress.admit(_env('a', 1, 0, 0, 1));
      ingress.admit(_env('a', 1, 1, 0, 1));

      expect(ingress.suspend('a'), const ReplayRequest(1, 2));
      expect(ingress.readiness('a'), IngressReadiness.suspended);
      expect(ingress.value('a'), 2);

      expect(ingress.reconnect('a', 1).fromSequence, 2);
      expect(ingress.readiness('a'), IngressReadiness.ready);
    });
  });

  group('ThreadSafeIngressCell — run-to-completion reactivity', () {
    ThreadSafeIngressCell<String, int> cell(
      ThreadSafeContext ctx, [
      IngressPolicy policy = const IngressPolicy(),
    ]) =>
        ThreadSafeIngressCell<String, int>(
          ctx,
          policy: policy,
          mergePolicy: sum(),
        );

    test('delivery, drain, and the derives obey the same contract', () {
      final ctx = ThreadSafeContext();
      final ingress = cell(ctx, const IngressPolicy(freshnessHorizon: 10));
      expect(ingress.readiness('a'), IngressReadiness.unknown);
      ingress.open('a', 3);
      expect(ingress.readiness('a'), IngressReadiness.warming);
      ingress.admit(_env('a', 3, 0, 5, 1));
      expect(ingress.readiness('a'), IngressReadiness.ready);
      expect(
        ingress.authority('a'),
        const IngressAuthority(
            generation: 3, deliveredThrough: 0, stampedAt: 5),
      );
      ingress.admit(_env('a', 3, 1, 5, 7));
      expect(ingress.value('a'), 8);
      expect(ingress.drain('a'), 8);
      expect(ingress.value('a'), isNull);
      ingress.tick(100);
      expect(ingress.readiness('a'), IngressReadiness.stale);
    });

    test('a generation handoff lands value and authority in one frontier walk',
        () {
      // The Rust shell needs `batch()` for this because it clears one root at a
      // time otherwise; Dart's `Context.invalidateSlots` takes the whole root
      // set and flushes effects once, which is the same guarantee.
      final ctx = ThreadSafeContext();
      final ingress = cell(ctx);
      ingress.admit(_env('a', 1, 0, 0, 5));

      final readers = ingress.readers('a');
      var runs = 0;
      final seen = <(int?, int?)>[];
      final effect = ctx.read((raw) => Effect(raw, (cx) {
            runs++;
            final value = cx.get(readers.value);
            final authority = cx.get(readers.authority);
            seen.add((value, authority?.generation));
            return null;
          }));
      expect(runs, 1);

      ingress.admit(_env('a', 2, 0, 0, 9));
      expect(runs, 2,
          reason: 'one admission is one effect run, not one per reader kind');
      expect(seen, [(5, 1), (9, 2)]);
      effect.dispose();
    });

    test('a buffered envelope and an in-horizon tick invalidate nothing', () {
      final ctx = ThreadSafeContext();
      final ingress = cell(ctx, const IngressPolicy(freshnessHorizon: 100));
      ingress.admit(_env('a', 1, 0, 0, 1));

      final readers = ingress.readers('a');
      var runs = 0;
      final effect = ctx.read((raw) => Effect(raw, (cx) {
            runs++;
            cx.get(readers.value);
            cx.get(readers.readiness);
            return null;
          }));
      expect(runs, 1);

      ingress.admit(_env('a', 1, 3, 0, 8));
      ingress.tick(50);
      expect(runs, 1);

      ingress.tick(500);
      expect(runs, 2, reason: 'the horizon crossing shows');
      effect.dispose();
    });

    test('receipt channels are independent readers', () {
      final ctx = ThreadSafeContext();
      final ingress = cell(ctx);
      ingress.admit(_env('a', 2, 0, 0, 1));
      ingress.admit(_env('a', 1, 0, 0, 1));
      ingress.fail('a', IngressError.decodeFailed);
      expect(ingress.accepted().length, 1);
      expect(ingress.dropped().length, 1);
      expect(ingress.dropped().first.outcome,
          const IngressDroppedReceipt(IngressDropReason.staleGeneration));
      expect(ingress.errors().length, 1);
    });

    test('the schedule derives from the transport and retunes live', () {
      final ctx = ThreadSafeContext();
      final ingress = cell(ctx);
      expect(ingress.schedule().pollInterval, isNull);
      ingress.setTransport(IngressTransportKind.boundedPolling);
      expect(ingress.schedule().pollInterval, 25);
      ingress.setPollInterval(200);
      expect(ingress.schedule().pollInterval, 200);
    });

    test('pump admits a batch and requests replay for a surviving gap', () {
      final ctx = ThreadSafeContext();
      final ingress = cell(ctx);
      final transport =
          InProcIngress<String, int>(IngressTransportKind.eventChannel)
            ..push(_env('a', 1, 0, 0, 1))
            ..push(_env('a', 1, 2, 0, 4));
      final outcomes = ingress.pump(transport);
      expect(outcomes[0].isDelivered, isTrue);
      expect(outcomes[1], const IngressBuffered(1));
      expect(transport.replays, [('a', const ReplayRequest(1, 1))]);
    });

    test('independent scopes converge under interleaved producers', () {
      // Distinct keys are distinct admission planes, so N producers need no
      // coordination — and the shared receipt log still totals correctly. Dart
      // has no shared-heap threads, so "concurrent" here is the interleaving a
      // run-to-completion isolate can actually produce.
      final ctx = ThreadSafeContext();
      final ingress = ThreadSafeIngressCell<String, int>(
        ctx,
        policy: const IngressPolicy(),
        mergePolicy: sum(),
      );
      for (var sequence = 0; sequence < 8; sequence++) {
        for (var key = 0; key < 4; key++) {
          ingress.admit(_env('k$key', 1, sequence, 0, 1));
        }
      }
      for (var key = 0; key < 4; key++) {
        expect(ingress.value('k$key'), 8, reason: 'key $key');
        expect(ingress.view('k$key')!.deliveredThrough, 7);
      }
      expect(ingress.accepted().length, 32);
    });
  });

  group('AsyncIngressCell — async-graph reactivity', () {
    AsyncIngressCell<String, int> cell(
      AsyncContext ctx, [
      IngressPolicy policy = const IngressPolicy(),
    ]) =>
        AsyncIngressCell<String, int>(
          ctx,
          policy: policy,
          mergePolicy: sum(),
        );

    test('admission is not async-coloured: every read returns a plain value',
        () {
      final ctx = AsyncContext();
      final ingress = cell(ctx, const IngressPolicy(freshnessHorizon: 10));
      expect(ingress.value('a'), isNull);
      expect(ingress.readiness('a'), IngressReadiness.unknown);
      ingress.admit(_env('a', 1, 0, 5, 5));
      expect(ingress.value('a'), 5);
      expect(ingress.readiness('a'), IngressReadiness.ready);
      ingress.admit(_env('a', 1, 1, 5, 7));
      expect(ingress.value('a'), 12);
      expect(ingress.drain('a'), 12);
      expect(ingress.value('a'), isNull);
      ingress.tick(100);
      expect(ingress.readiness('a'), IngressReadiness.stale);
    });

    test('one admission clears every dirtied reader and no other', () {
      final ctx = AsyncContext();
      final ingress = cell(ctx);
      ingress.admit(_env('a', 1, 0, 0, 5));
      final readers = ingress.readers('a');

      // Warm every reader, then admit a buffered envelope: nothing observable
      // moved, so nothing may be cleared.
      ingress
        ..value('a')
        ..readiness('a')
        ..authority('a')
        ..retry('a');
      ingress.admit(_env('a', 1, 5, 0, 1));
      expect(ctx.isSet(readers.value), isTrue);
      expect(ctx.isSet(readers.readiness), isTrue);
      expect(ctx.isSet(readers.authority), isTrue);
      expect(ctx.isSet(readers.retry), isTrue);

      // A handoff moves all four.
      ingress.admit(_env('a', 2, 0, 0, 9));
      expect(ctx.isSet(readers.value), isFalse);
      expect(ctx.isSet(readers.readiness), isFalse);
      expect(ctx.isSet(readers.authority), isFalse);
      expect(ctx.isSet(readers.retry), isFalse);
      expect(ingress.value('a'), 9);
      expect(ingress.authority('a')!.generation, 2);
    });

    test('a generation handoff lands value and authority in one frontier walk',
        () async {
      // The async frontier-walk gate. An async effect body is awaited, so a
      // second clear arriving while the first run is in flight is coalesced into
      // exactly one extra run — which is why the count, not the ordering, is
      // what discriminates: clearing one root at a time yields TWO runs for one
      // admission.
      final ctx = AsyncContext();
      final ingress = cell(ctx);
      ingress.admit(_env('a', 1, 0, 0, 5));

      final readers = ingress.readers('a');
      var runs = 0;
      final seen = <(int?, int?)>[];
      final effect = ctx.effectAsync((cx) async {
        runs++;
        final value = cx.get(readers.value);
        final authority = cx.get(readers.authority);
        seen.add((value, authority?.generation));
        return null;
      });
      await pumpMicrotasks();
      expect(runs, 1);

      ingress.admit(_env('a', 2, 0, 0, 9));
      await pumpMicrotasks();
      expect(runs, 2,
          reason: 'one admission is one effect run, not one per reader kind');
      expect(seen, [(5, 1), (9, 2)]);
      await effect.disposeAsync();
    });

    test('receipt channels are independent readers', () {
      final ctx = AsyncContext();
      final ingress = cell(ctx);
      ingress.admit(_env('a', 2, 0, 0, 1));
      ingress.admit(_env('a', 1, 0, 0, 1));
      ingress.fail('a', IngressError.decodeFailed);
      expect(ingress.accepted().length, 1);
      expect(ingress.dropped().length, 1);
      expect(ingress.errors().length, 1);
    });

    test('the schedule derives from the transport and retunes live', () {
      final ctx = AsyncContext();
      final ingress = cell(ctx);
      expect(ingress.schedule().pollInterval, isNull);
      ingress.setTransport(IngressTransportKind.boundedPolling);
      expect(ingress.schedule().pollInterval, 25);
      ingress.setPollInterval(200);
      expect(ingress.schedule().pollInterval, 200);
      ingress.setTransport(IngressTransportKind.eventChannel);
      expect(ingress.schedule().pollInterval, isNull);
    });

    test('pump admits a batch and requests replay for a surviving gap', () {
      final ctx = AsyncContext();
      final ingress = cell(ctx);
      final transport =
          InProcIngress<String, int>(IngressTransportKind.eventChannel)
            ..push(_env('a', 1, 0, 0, 1))
            ..push(_env('a', 1, 2, 0, 4));
      final outcomes = ingress.pump(transport);
      expect(outcomes[0].isDelivered, isTrue);
      expect(outcomes[1], const IngressBuffered(1));
      expect(transport.replays, [('a', const ReplayRequest(1, 1))]);
    });
  });
}

/// Drain the microtask queue so awaited async-effect bodies have run.
Future<void> pumpMicrotasks() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
