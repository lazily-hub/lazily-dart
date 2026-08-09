import 'dart:convert';

import 'package:lazily/lazily.dart';
// rateshape is not yet re-exported from the barrel (coordinator owns that);
// import the source module directly so this harness stays independent.
import 'package:test/test.dart';

import 'conformance_manifest.dart';

/// Cross-language conformance tests for the rate-shaping source operators
/// (`#lzrateshape`, `lazily-spec/conformance/rateshape/`). Each operator
/// projects its emitted value onto a reactive [Cell]; a [Slot] wrapping that
/// cell lets us observe invalidation via `ctx.contains` — the reader stays
/// cached unless the op actually emitted (a dropped input never invalidates).
///
/// Fixtures mirror `lazily-spec/conformance/rateshape/` byte-identically; when
/// that source tree is reachable on disk (sibling repo) it is preferred so this
/// harness also guards against fixture drift across the family.

/// This runner's slice of the shared corpus. The root itself — and the
/// `LAZILY_SPEC_CONFORMANCE_DIR` override, and the sibling-first-then-mirror
/// ordering — lives in `conformance_manifest.dart` so every runner and the
/// coverage guard auditing them resolve ONE corpus (#lzoverrideallrunners).
const _family = 'rateshape';

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

/// Replay a fixture, asserting the emitted value, the projected output, and
/// that the output reader invalidates exactly on an emit.
void _replay(
  Context ctx,
  Map<String, dynamic> fx,
  RateShapeCell<String> cell,
  Object? Function(Map<String, dynamic> step) drive,
) {
  final observed = _observe(ctx, cell.outputCell);
  for (final step in (fx['steps'] as List).cast<Map<String, dynamic>>()) {
    final expected = assertionsOf(step['expected']);
    final emitted = drive(step);
    expect(emitted, equals(step['returns']), reason: 'emit');
    assertKey(expected, 'output', cell.output());
    assertKey(subKey(expected, 'invalidates'), 'output',
        _invalidated(ctx, observed), 'invalidation');
  }
}

void main() {
  test('DebounceCell', () {
    final fx = _loadFixture('debounce.json');
    final ctx = Context();
    final initial = fx['initial'] as Map<String, dynamic>;
    final cell = DebounceCell<String>(ctx, initial['quiet'] as int);
    _replay(ctx, fx, cell, (step) {
      final op = step['op'] as Map<String, dynamic>;
      // `tick` is an EXPLICIT branch (`#lzscenariobodyskip`): the bare fall-
      // through assumed the last variant, so ANY op type other than `input`
      // was replayed as a tick and the fixture's `returns` was compared
      // against an operation it never named.
      switch (op['type']) {
        case 'input':
          cell.input(op['now'] as int, op['value'] as String);
          return null;
        case 'tick':
          return cell.tick(op['now'] as int);
        default:
          fail('DebounceCell: unknown op type `${op['type']}`');
      }
    });
  });

  void throttleTest(String name, ThrottleEdge edge) {
    final fx = _loadFixture(name);
    final ctx = Context();
    final initial = fx['initial'] as Map<String, dynamic>;
    final cell = ThrottleCell<String>(ctx, edge, initial['window'] as int);
    _replay(ctx, fx, cell, (step) {
      final op = step['op'] as Map<String, dynamic>;
      // `tick` is an EXPLICIT arm (`#lzscenariobodyskip`) — the ternary's else
      // branch assumed it for every op type the fixture might name.
      return switch (op['type']) {
        'input' => cell.input(op['now'] as int, op['value'] as String),
        'tick' => cell.tick(op['now'] as int),
        final other => fail('ThrottleCell: unknown op type `$other`'),
      };
    });
  }

  test('ThrottleCell leading',
      () => throttleTest('throttle_leading.json', ThrottleEdge.leading));
  test('ThrottleCell trailing',
      () => throttleTest('throttle_trailing.json', ThrottleEdge.trailing));

  test('SampleCell count', () {
    final fx = _loadFixture('sample_count.json');
    final ctx = Context();
    final initial = fx['initial'] as Map<String, dynamic>;
    final cell = SampleCell<String>(ctx, SampleMode.count(initial['n'] as int));
    _replay(ctx, fx, cell, (step) {
      final op = step['op'] as Map<String, dynamic>;
      return cell.input(op['value'] as String);
    });
  });

  test('SampleCell time', () {
    final fx = _loadFixture('sample_time.json');
    final ctx = Context();
    final initial = fx['initial'] as Map<String, dynamic>;
    final cell =
        SampleCell<String>(ctx, SampleMode.time(initial['period'] as int));
    _replay(ctx, fx, cell, (step) {
      final op = step['op'] as Map<String, dynamic>;
      // `tick` is an EXPLICIT branch (`#lzscenariobodyskip`) — see
      // `DebounceCell` above.
      switch (op['type']) {
        case 'input':
          cell.input(op['value'] as String);
          return null;
        case 'tick':
          return cell.tick(op['now'] as int);
        default:
          fail('SampleCell time: unknown op type `${op['type']}`');
      }
    });
  });

  test('ProbabilisticSampleCell', () {
    final fx = _loadFixture('probabilistic_sample.json');
    final ctx = Context();
    final initial = fx['initial'] as Map<String, dynamic>;
    final cell = ProbabilisticSampleCell<String>(
      ctx,
      (initial['rate'] as num).toDouble(),
      Lcg(0),
    );
    _replay(ctx, fx, cell, (step) {
      final op = step['op'] as Map<String, dynamic>;
      return cell.inputWithDraw(
        op['value'] as String,
        (op['draw'] as num).toDouble(),
      );
    });
  });
}
