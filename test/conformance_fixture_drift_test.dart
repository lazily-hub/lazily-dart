import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Mirror-drift guard (`#lzspecconf`).
///
/// Every conformance test in this package now resolves SIBLING-FIRST, so the
/// canonical `../lazily-spec/conformance/` checkout is what CI actually tests.
/// The mirrored copies under `test/conformance/` remain only so the suite runs
/// without the sibling — they are a fallback, never an authority.
///
/// An absence guard cannot catch the failure this replaces. Before the
/// inversion, CI cloned lazily-spec and then read the local mirror anyway: the
/// directory was present, no test skipped, and the run was green while asserting
/// against a stale copy. The positive assertion is therefore not "the sibling
/// exists" but "every mirror still agrees with its canonical source, and this
/// test actually compared some".
///
/// Drift is judged on the PARSED fixture, not the bytes: semantic equality is
/// what decides whether dart and its sibling bindings are replaying the same
/// scenario, and failing CI over reformatting would be noise the team learns to
/// suppress. Byte-level-only differences are reported on failure and listed by
/// the `mirrors are byte-identical` diagnostic below, which is informational.
const specRoot = '../lazily-spec/conformance';
const mirrorRoot = 'test/conformance';

/// One mirror file paired with its canonical counterpart.
class _Pair {
  _Pair(this.relative, this.mirror, this.canonical);

  final String relative;
  final File mirror;
  final File canonical;
}

List<_Pair> _pairs() {
  final root = Directory(mirrorRoot);
  if (!root.existsSync()) return const [];
  final out = <_Pair>[];
  for (final entity in root.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.json')) continue;
    final relative = entity.path.substring(mirrorRoot.length + 1);
    out.add(_Pair(relative, entity, File('$specRoot/$relative')));
  }
  out.sort((a, b) => a.relative.compareTo(b.relative));
  return out;
}

void main() {
  final spec = Directory(specRoot);
  if (!spec.existsSync()) {
    stderr.writeln('skipping: $specRoot absent - run with the lazily-spec sibling');
    test(
      'conformance fixture mirrors',
      () {},
      skip: '$specRoot absent - run with the lazily-spec sibling',
    );
    return;
  }

  if (!Directory(mirrorRoot).existsSync()) {
    // The mirrors are optional: with resolution sibling-first, deleting
    // $mirrorRoot entirely is a supported end state (every fixture it holds
    // also exists canonically). Nothing to guard, so skip rather than fail.
    test(
      'conformance fixture mirrors',
      () {},
      skip: '$mirrorRoot absent - resolution falls through to $specRoot',
    );
    return;
  }

  final pairs = _pairs();

  test('the mirror tree is non-empty and was actually walked', () {
    // Guards the guard: a walk that silently found nothing would let every
    // assertion below vacuously pass.
    expect(pairs, isNotEmpty,
        reason: '$mirrorRoot contains no fixtures — the drift comparison '
            'would be vacuous');
  });

  test('every mirrored fixture has a canonical counterpart', () {
    final orphans = [
      for (final pair in pairs)
        if (!pair.canonical.existsSync()) pair.relative,
    ];
    expect(orphans, isEmpty,
        reason: 'mirrored fixtures with no canonical source — either they were '
            'renamed/removed upstream, or they are dart-only fixtures that do '
            'not belong under a mirror of $specRoot');
  });

  group('mirrors agree with canonical', () {
    for (final pair in pairs) {
      test(pair.relative, () {
        if (!pair.canonical.existsSync()) {
          // Reported by the orphan test above; not double-counted here.
          return;
        }
        final mirror = jsonDecode(pair.mirror.readAsStringSync());
        final canonical = jsonDecode(pair.canonical.readAsStringSync());
        expect(mirror, canonical,
            reason: 'mirror ${pair.mirror.path} has drifted from '
                '${pair.canonical.path}. Do NOT edit either to match: the '
                'canonical fixture is the spec, so re-sync the mirror, or '
                'delete it and let resolution fall through to the sibling.');
      });
    }
  });

  test('mirrors are byte-identical to canonical (informational)', () {
    final differing = [
      for (final pair in pairs)
        if (pair.canonical.existsSync() &&
            pair.mirror.readAsStringSync() != pair.canonical.readAsStringSync())
          pair.relative,
    ];
    // Not an assertion: a byte difference with matching semantics is only
    // reformatting, and the sibling-first resolution means it cannot change a
    // test outcome. Printed so a re-sync has a work list.
    if (differing.isNotEmpty) {
      printOnFailure('mirrors differing only in formatting: $differing');
    }
    expect(pairs, isNotEmpty, reason: 'the formatting sweep walked nothing');
  });
}
