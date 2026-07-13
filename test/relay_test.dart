// RelayCell Phases 2–6 spike (#relaycell) for lazily-dart. Mirrors the lazily-rs
// / lazily-kt / lazily-js relay tests: converged egress independent of drain
// schedule (relay_converges), overflow behaviour, reactive readers,
// spill_lossless / spill_replay_idempotent, transport_independent, Outbox/Inbox
// roles, and the Phase-6 policies.

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

RelayCell<int> _relay(
  Context ctx,
  MergePolicy<int> policy, {
  int highWater = 1000000,
  Overflow overflow = Overflow.conflate,
}) =>
    RelayCell<int>(
      ctx,
      BackpressurePolicy(ctx, BoundDim.count, highWater, highWater ~/ 2, overflow),
      policy,
    );

int _flat(List<int> ops, MergePolicy<int> policy) =>
    ops.reduce((a, b) => policy.merge(a, b));

void main() {
  group('Phase 2: RelayCell core', () {
    test('converged egress independent of drain schedule', () {
      for (final policy in [sum(), max()]) {
        const ops = [3, 1, 4, 1, 5, 9, 2, 6];
        final flat = _flat(ops, policy);

        // Drain-every-op schedule.
        final ctxA = Context();
        final rA = _relay(ctxA, policy);
        int? accA;
        for (final op in ops) {
          rA.ingress(op);
          final d = rA.drain();
          if (d == null) continue;
          accA = accA == null ? d : policy.merge(accA, d);
        }
        expect(accA, flat, reason: '${policy.name}: drain-every');

        // Drain-once-at-end schedule.
        final ctxB = Context();
        final rB = _relay(ctxB, policy);
        for (final op in ops) {
          rB.ingress(op);
        }
        expect(rB.drain(), flat, reason: '${policy.name}: drain-once');
      }
    });

    test('reactive depth / isFull / isEmpty readers', () {
      final ctx = Context();
      final r = _relay(ctx, sum(), highWater: 3);
      expect(r.isEmpty(), isTrue);
      expect(r.depth(), 0);
      expect(r.isFull(), isFalse);

      r.ingress(1);
      r.ingress(1);
      expect(r.isEmpty(), isFalse);
      expect(r.depth(), 2);
      expect(r.isFull(), isFalse);

      r.ingress(1);
      expect(r.depth(), 3);
      expect(r.isFull(), isTrue);

      r.drain();
      expect(r.isEmpty(), isTrue);
      expect(r.depth(), 0);
    });

    test('Block overflow refuses ingress', () {
      final ctx = Context();
      final r = _relay(ctx, sum(), highWater: 2, overflow: Overflow.block);
      expect(r.ingress(1), IngressOutcome.accepted);
      expect(r.ingress(1), IngressOutcome.conflated);
      expect(r.ingress(1), IngressOutcome.blocked); // at high water
      expect(r.drain(), 2); // the blocked op was not merged
    });

    test('DropNewest and DropOldest', () {
      final ctxN = Context();
      final rn = _relay(ctxN, sum(), highWater: 2, overflow: Overflow.dropNewest);
      rn.ingress(1);
      rn.ingress(1);
      expect(rn.ingress(9), IngressOutcome.dropped);
      expect(rn.drain(), 2);

      final ctxO = Context();
      final ro = _relay(ctxO, sum(), highWater: 2, overflow: Overflow.dropOldest);
      ro.ingress(1);
      ro.ingress(1);
      expect(ro.ingress(9), IngressOutcome.dropped);
      expect(ro.drain(), 9); // window reset to the incoming op
    });

    test('construction rejects Conflate for RawFifo', () {
      final ctx = Context();
      expect(
        () => RelayCell<List<int>>(
          ctx,
          BackpressurePolicy(ctx, BoundDim.count, 4, 2, Overflow.conflate),
          rawFifo<int>(),
        ),
        throwsA(isA<RelayConfigException>()),
      );
    });
  });

  group('Phase 3: SpillStore', () {
    test('spill lossless both modes', () {
      for (final mode in [SpillMode.compactOnWrite, SpillMode.appendCompact]) {
        final store = SpillStore<int>(mode, 2, sum());
        const windows = [1, 2, 3, 4, 5];
        for (final w in windows) {
          store.spill(w, 1);
        }
        const hot = 10;
        final flat = [...windows, hot].reduce((a, b) => a + b);
        expect(store.reconstruct(0, hot), flat, reason: mode.name);
      }
    });

    test('spill replay idempotent for idempotent policy', () {
      final store = SpillStore<int>(SpillMode.appendCompact, 1, max());
      for (final w in [3, 7, 5]) {
        store.spill(w, 1);
      }
      final once = store.replayUnacked(0);
      final twice = store.replayUnacked(once);
      expect(once, twice);
      expect(once, 7);
    });

    test('CompactOnWrite bounds pages and ack reclaims', () {
      final store = SpillStore<int>(SpillMode.compactOnWrite, 2, sum());
      for (var i = 0; i < 5; i++) {
        store.spill(1, 1); // 5 ops, page size 2 → 3 pages
      }
      expect(store.pageCount(), 3);
      final ids = [for (final m in store.manifest()) m.$1];
      store.ackThrough(ids[0]);
      expect(store.pendingPages().length, 2);
      store.reclaim();
      expect(store.pageCount(), 2);
    });
  });

  group('Phase 4: Transport', () {
    test('transport independent across framing', () {
      for (final policy in [sum(), max(), keepLatest<int>()]) {
        const ops = [3, 1, 4, 1, 5, 9];
        final flat = _flat(ops, policy);

        final transports = <RelayTransport<int>>[
          InProcTransport<int>(),
          FramedTransport<int>(2),
          FramedTransport<int>(3),
        ];
        for (final transport in transports) {
          for (final op in ops) {
            transport.deliver(op);
          }
          final ctx = Context();
          final r = _relay(ctx, policy);
          while (transport.hasPending()) {
            for (final op in transport.poll()) {
              r.ingress(op);
            }
          }
          expect(r.drain(), flat, reason: policy.name);
        }
      }
    });
  });

  group('Phase 5: Outbox / Inbox roles', () {
    test('Outbox conflates state broadcast', () {
      final ctx = Context();
      final out = Outbox<int>(ctx, 8, keepLatest<int>());
      out.send(1);
      out.send(2);
      out.send(3);
      expect(out.drain(), 3); // keep-latest conflation
    });

    test('Inbox credit meters the remote', () {
      final ctx = Context();
      final inbox = Inbox<int>(ctx, 100, 2, sum());
      expect(inbox.ready(), isTrue);
      inbox.receive(5);
      inbox.receive(5);
      expect(inbox.ready(), isFalse); // credits exhausted
      final out = inbox.consume(2);
      expect(out, 10);
      expect(inbox.ready(), isTrue); // replenished
    });

    test('Outbox → Inbox link converges', () {
      final ctx = Context();
      final out = Outbox<int>(ctx, 64, sum());
      final inbox = Inbox<int>(ctx, 64, 64, sum());
      final transport = InProcTransport<int>();
      const ops = [1, 2, 3, 4];
      for (final op in ops) {
        out.send(op);
      }
      transport.deliver(out.drain()!);
      while (transport.hasPending()) {
        for (final frame in transport.poll()) {
          inbox.receive(frame);
        }
      }
      expect(inbox.consume(64), ops.reduce((a, b) => a + b));
    });
  });

  group('Phase 6: policies', () {
    test('RatePolicy token bucket', () {
      final rate = RatePolicy(2, 1);
      expect(rate.tryEgress(), isTrue);
      expect(rate.tryEgress(), isTrue);
      expect(rate.tryEgress(), isFalse); // empty
      rate.tick();
      expect(rate.tryEgress(), isTrue);
    });

    test('WindowPolicy flush on fill and tick preserves sum', () {
      final window = WindowPolicy(3);
      expect(window.onIngress(), isFalse);
      expect(window.onIngress(), isFalse);
      expect(window.onIngress(), isTrue); // full → flush
      expect(window.onIngress(), isFalse);
      expect(window.tick(), isTrue); // interval boundary flushes remainder
      expect(window.tick(), isFalse); // nothing pending
    });

    test('ExpiryPolicy drops aged', () {
      final expiry = ExpiryPolicy(5);
      expiry.advance(10);
      final batch = [(3, 'old'), (7, 'fresh'), (10, 'now')];
      expect(expiry.retainLive(batch), ['fresh', 'now']);
    });

    test('PriorityStorage pops highest first, FIFO within', () {
      final pq = PriorityStorage<String>();
      pq.push(1, 'low');
      pq.push(3, 'highA');
      pq.push(2, 'mid');
      pq.push(3, 'highB');
      expect(pq.pop(), 'highA');
      expect(pq.pop(), 'highB'); // FIFO within priority 3
      expect(pq.pop(), 'mid');
      expect(pq.pop(), 'low');
      expect(pq.pop(), isNull);
    });

    test('KeyedRelay shards per key', () {
      final ctx = Context();
      final keyed = KeyedRelay<String, int>(ctx, 64, Overflow.conflate, sum());
      keyed.ingress('a', 1);
      keyed.ingress('b', 10);
      keyed.ingress('a', 2);
      expect(keyed.drain('a'), 3);
      expect(keyed.drain('b'), 10);
      expect(keyed.keys(), {'a', 'b'});
    });
  });
}
