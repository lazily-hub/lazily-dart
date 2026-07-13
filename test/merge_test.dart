// Phase 1 law-tests for the merge algebra (#relaycell). Every policy MUST be
// associative; commutativity/idempotency are asserted per flag. Replays the
// cross-language mergecell_algebra.json fixture — lazily-dart converges
// identically to lazily-rs / lazily-js / lazily-py / lazily-go / lazily-zig /
// lazily-kt.

import 'dart:convert';
import 'dart:io';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

String? _fixture(String name) {
  for (final path in [
    'test/conformance/collections/$name',
    '../lazily-spec/conformance/collections/$name',
  ]) {
    if (File(path).existsSync()) return File(path).readAsStringSync();
  }
  return null;
}

void main() {
  group('merge algebra', () {
    test('every policy is associative', () {
      final kl = keepLatest<int>();
      expect(kl.merge(kl.merge(5, -3), 8), kl.merge(5, kl.merge(-3, 8)));
      for (final p in [sum(), max()]) {
        expect(p.merge(p.merge(5, -3), 8), p.merge(5, p.merge(-3, 8)), reason: p.name);
      }
      final rf = rawFifo<int>();
      expect(rf.merge(rf.merge([1], [2]), [3]), rf.merge([1], rf.merge([2], [3])));
    });

    test('commutativity matches the flag', () {
      for (final p in [sum(), max()]) {
        expect(p.commutative, isTrue);
        expect(p.merge(p.merge(5, -3), 8), p.merge(p.merge(5, 8), -3), reason: p.name);
      }
      final kl = keepLatest<int>();
      expect(kl.commutative, isFalse);
      expect(kl.merge(kl.merge(0, 1), 2) != kl.merge(kl.merge(0, 2), 1), isTrue);
      expect(rawFifo<int>().commutative, isFalse);
    });

    test('idempotency matches the flag', () {
      final m = max();
      expect(m.idempotent, isTrue);
      expect(m.merge(m.merge(3, 9), 9), m.merge(3, 9));
      final s = sum();
      expect(s.idempotent, isFalse);
      expect(s.merge(s.merge(0, 5), 5) != s.merge(0, 5), isTrue);
      expect(setUnion<int>().idempotent, isTrue);
      expect(rawFifo<int>().idempotent, isFalse);
    });
  });

  group('MergeCell', () {
    test('Cell == MergeCell(KeepLatest)', () {
      final ctx = Context();
      final cell = Cell<int>(ctx, 0);
      final mc = mergeCell(ctx, 0, keepLatest<int>());
      for (final v in [3, 3, 7, 7, 1]) {
        cell.set(v);
        mc.merge(v);
        expect(cell.get(), mc.get());
      }
      expect(mc.get(), 1);
    });

    test('Sum converges regardless of order', () {
      final ctx = Context();
      const ops = [5, -3, 8, 2, -1];
      final a = mergeCell(ctx, 0, sum());
      for (final d in ops) {
        a.merge(d);
      }
      final b = mergeCell(ctx, 0, sum());
      for (final d in ops.reversed) {
        b.merge(d);
      }
      expect(a.get(), b.get());
      expect(a.get(), 11);
    });

    test('idempotent merge no-ops via the guard', () {
      final ctx = Context();
      final mc = mergeCell(ctx, 10, max());
      var runs = 0;
      Effect(ctx, (_) {
        mc.get();
        runs++;
        return null;
      });
      expect(runs, 1);
      mc.merge(5);
      mc.merge(10);
      mc.merge(0);
      expect(runs, 1); // merges at/below max fire no cascade
      mc.merge(42);
      expect(mc.get(), 42);
      expect(runs, 2);
    });
  });

  test('mergecell_algebra.json fixture', () {
    final raw = _fixture('mergecell_algebra.json');
    if (raw == null) {
      // lazily-spec sibling absent (CI baseline); the direct tests above still
      // pin the algebra.
      return;
    }
    final fixture = jsonDecode(raw) as Map<String, dynamic>;
    final byName = {'KeepLatest': keepLatest<int>(), 'Sum': sum(), 'Max': max()};
    var seen = 0;
    for (final scenarioEl in fixture['scenarios'] as List) {
      final scenario = scenarioEl as Map<String, dynamic>;
      final policy = byName[scenario['policy']]!;
      final flags = scenario['flags'] as Map<String, dynamic>;
      expect(policy.commutative, flags['commutative']);
      expect(policy.idempotent, flags['idempotent']);

      final ctx = Context();
      final mc = mergeCell(ctx, scenario['initial'] as int, policy);
      var runs = 0;
      Effect(ctx, (_) {
        mc.get();
        runs++;
        return null;
      });
      for (final stepEl in scenario['steps'] as List) {
        final step = stepEl as Map<String, dynamic>;
        final before = runs;
        mc.merge(step['merge'] as int);
        final fired = runs > before;
        final expected = step['expected'] as Map<String, dynamic>;
        expect(mc.get(), expected['value'], reason: policy.name);
        expect(fired, expected['invalidates'], reason: policy.name);
      }
      seen++;
    }
    expect(seen, 3);
  });
}
