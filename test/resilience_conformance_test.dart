import 'dart:convert';
import 'dart:io';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

/// Cross-language conformance tests for the fault-tolerance primitives
/// (`#lzresilience`, `lazily-spec/conformance/resilience/`). Each primitive
/// projects its salient reader (breaker state / retry delay / bulkhead in-use /
/// timeout edge) onto a reactive [Cell]; a [Slot] wrapping that cell lets us
/// observe invalidation via `ctx.contains` — the reader stays cached unless the
/// projected value actually changed.
///
/// Fixtures mirror `lazily-spec/conformance/resilience/` byte-identically; when
/// that source tree is reachable on disk (sibling repo) it is preferred so this
/// harness also guards against fixture drift across the family.

final _specDir = Directory('../lazily-spec/conformance/resilience');

Map<String, dynamic> _loadFixture(String name) {
  final src = _specDir.existsSync()
      ? File(_specDir.resolveSymbolicLinksSync() + '/$name').specReadAsStringSync()
      : File('test/conformance/resilience/$name').specReadAsStringSync();
  return attributeFixture(jsonDecode(src)) as Map<String, dynamic>;
}

/// Observe a cell through a slot; returns the slot primed (cached).
Slot<Object?> _observe(Context ctx, Cell cell) {
  final slot = Slot<Object?>(ctx, (cx) => cx.get(cell));
  slot();
  return slot;
}

/// Read the slot, returning whether the read triggered a recompute (i.e. the
/// reader had been invalidated).
bool _invalidated(Context ctx, Slot slot) {
  final wasCached = ctx.contains(slot);
  slot();
  return !wasCached;
}

BreakerState _breakerState(String label) {
  switch (label) {
    case 'Closed':
      return BreakerState.closed;
    case 'Open':
      return BreakerState.open;
    case 'HalfOpen':
      return BreakerState.halfOpen;
    default:
      throw ArgumentError('unknown breaker state $label');
  }
}

void main() {
  test('CircuitBreakerCell', () {
    final fx = _loadFixture('circuit_breaker.json');
    final ctx = Context();
    final c = fx['config'] as Map<String, dynamic>;
    final cb = CircuitBreakerCell(
      ctx,
      c['window'] as int,
      c['failure_threshold'] as int,
      c['reset_timeout'] as int,
    );
    final observed = _observe(ctx, cb.stateCell);

    for (final step in (fx['steps'] as List).cast<Map<String, dynamic>>()) {
      final op = step['op'] as Map<String, dynamic>;
      final expected = assertionsOf(step['expected']);
      if (op['type'] == 'record') {
        cb.record(op['success'] as bool, op['now'] as int);
      } else if (op['type'] == 'allow') {
        expect(cb.allow(op['now'] as int), equals(step['returns']),
            reason: 'allow');
      }
      assertKeyWith(expected, 'state', (v) {
        expect(cb.state(), equals(_breakerState(v as String)), reason: 'state');
      });
      assertKeyWith(expected, 'invalidates', (v) {
        expect(_invalidated(ctx, observed), equals((v as Map)['state']),
            reason: 'state invalidation');
      });
    }
  });

  test('RetryPolicyCell', () {
    final fx = _loadFixture('retry.json');
    final ctx = Context();
    final config = fx['config'] as Map<String, dynamic>;
    final r = RetryPolicyCell(ctx, config['base'] as int, config['cap'] as int);
    final observed = _observe(ctx, r.delayCell);

    for (final step in (fx['steps'] as List).cast<Map<String, dynamic>>()) {
      final expected = assertionsOf(step['expected']);
      expect(r.nextDelay(), equals(step['returns']), reason: 'delay');
      assertKey(expected, 'delay', r.delay());
      assertKeyWith(expected, 'invalidates', (v) {
        expect(_invalidated(ctx, observed), equals((v as Map)['delay']),
            reason: 'delay invalidation');
      });
    }
  });

  test('BulkheadCell', () {
    final fx = _loadFixture('bulkhead.json');
    final ctx = Context();
    final config = fx['config'] as Map<String, dynamic>;
    final b = BulkheadCell(ctx, config['capacity'] as int);
    final observed = _observe(ctx, b.inUseCell);

    for (final step in (fx['steps'] as List).cast<Map<String, dynamic>>()) {
      final op = step['op'] as Map<String, dynamic>;
      final expected = assertionsOf(step['expected']);
      if (op['type'] == 'acquire') {
        expect(b.acquire(), equals(step['returns']));
      } else {
        b.release();
      }
      assertKey(expected, 'in_use', b.permitsInUse());
      assertKeyWith(expected, 'invalidates', (v) {
        expect(_invalidated(ctx, observed), equals((v as Map)['in_use']),
            reason: 'in_use invalidation');
      });
    }
  });

  test('TimeoutCell', () {
    final fx = _loadFixture('timeout.json');
    final ctx = Context();
    final t = TimeoutCell(ctx);
    final observed = _observe(ctx, t.timedOutCell);

    for (final step in (fx['steps'] as List).cast<Map<String, dynamic>>()) {
      final op = step['op'] as Map<String, dynamic>;
      final expected = assertionsOf(step['expected']);
      bool edge;
      if (op['type'] == 'arm') {
        t.arm(op['now'] as int, op['timeout'] as int);
        edge = false;
      } else {
        edge = t.tick(op['now'] as int);
      }
      expect(edge, equals(step['returns']), reason: 'edge');
      assertKey(expected, 'is_timed_out', t.isTimedOut());
      assertKeyWith(expected, 'invalidates', (v) {
        expect(_invalidated(ctx, observed), equals((v as Map)['is_timed_out']),
            reason: 'is_timed_out invalidation');
      });
    }
  });
}
