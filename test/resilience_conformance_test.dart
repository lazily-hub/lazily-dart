import 'dart:convert';

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

/// This runner's slice of the shared corpus. The root itself — and the
/// `LAZILY_SPEC_CONFORMANCE_DIR` override, and the sibling-first-then-mirror
/// ordering — lives in `conformance_manifest.dart` so every runner and the
/// coverage guard auditing them resolve ONE corpus (#lzoverrideallrunners).
const _family = 'resilience';

Map<String, dynamic> _loadFixture(String name) {
  final src = specReadFixture('$_family/$name');
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
      // Fail closed on an unrecognised op (`#lzscenariobodyskip`): the chain
      // had no final `else`, so an op type this runner does not implement fell
      // through having recorded nothing, and the step's expectations were
      // compared against the breaker's previous state.
      switch (op['type']) {
        case 'record':
          cb.record(op['success'] as bool, op['now'] as int);
        case 'allow':
          expect(cb.allow(op['now'] as int), equals(step['returns']),
              reason: 'allow');
        default:
          fail('CircuitBreakerCell: unknown op type `${op['type']}`');
      }
      assertKeyWith(expected, 'state', (v) {
        expect(cb.state(), equals(_breakerState(v as String)), reason: 'state');
      });
      assertKey(subKey(expected, 'invalidates'), 'state',
          _invalidated(ctx, observed), 'state invalidation');
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
      assertKey(subKey(expected, 'invalidates'), 'delay',
          _invalidated(ctx, observed), 'delay invalidation');
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
      // `release` is an EXPLICIT branch (`#lzscenariobodyskip`): the bare
      // `else` assumed the last variant without checking it, so any op type
      // other than `acquire` released a permit whatever the fixture named.
      switch (op['type']) {
        case 'acquire':
          expect(b.acquire(), equals(step['returns']));
        case 'release':
          b.release();
        default:
          fail('BulkheadCell: unknown op type `${op['type']}`');
      }
      assertKey(expected, 'in_use', b.permitsInUse());
      assertKey(subKey(expected, 'invalidates'), 'in_use',
          _invalidated(ctx, observed), 'in_use invalidation');
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
      final bool edge;
      // `tick` is an EXPLICIT branch (`#lzscenariobodyskip`): the bare `else`
      // assumed the last variant, so an unrecognised op type ticked the clock
      // instead of failing.
      switch (op['type']) {
        case 'arm':
          t.arm(op['now'] as int, op['timeout'] as int);
          edge = false;
        case 'tick':
          edge = t.tick(op['now'] as int);
        default:
          fail('TimeoutCell: unknown op type `${op['type']}`');
      }
      expect(edge, equals(step['returns']), reason: 'edge');
      assertKey(expected, 'is_timed_out', t.isTimedOut());
      assertKey(subKey(expected, 'invalidates'), 'is_timed_out',
          _invalidated(ctx, observed), 'is_timed_out invalidation');
    }
  });
}
