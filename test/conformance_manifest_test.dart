/// Self-tests for the scenario ledger's identity resolution
/// (`#lzscenariocoverage`, `#lzspecscenarioids`) and for the run-id stamp
/// prefix the recorder and both guards have to agree on
/// (`#lzstampprefixdrift`).
///
/// These exist rather than a comment because [scenarioIdOf] used to end its
/// `id` -> `name` resolution in a positional `#<n>` fallback. A ledger entry
/// recorded BY POSITION silently rebinds to a different scenario when the corpus
/// array is reordered, and nothing turns red: the coverage guard compares
/// "index 1 was replayed" against whatever now sits at index 1 and agrees with
/// itself. The corpus identifies every scenario now, so the fallback is a hard
/// failure — and a rule enforced only by the corpus happening to be well-formed
/// is not enforced at all.
///
/// Getting the ORDER wrong fails just as quietly in the other direction: it
/// renames every scenario of a fixture at once, so the guard reports the whole
/// fixture unreplayed and the diagnosis points at the runner instead of at this
/// function.
library;

import 'dart:io';

import 'package:test/test.dart';

import 'conformance_manifest.dart';

// ---------------------------------------------------------------------------
// The run-id stamp prefix, read from every definition of it
// (`#lzstampprefixdrift`)
// ---------------------------------------------------------------------------

/// The guards that RECOGNISE the stamp [conformanceRunIdPrefix] introduces.
///
/// THREE definitions of one string, in three languages, is the shape this
/// series keeps finding: the recorder writes [conformanceRunIdPrefix] from
/// Dart, and each file below declares its own `RUN_ID_PREFIX` in shell and in
/// Python. Two of them held together by a comment is the drift lazily-cpp found
/// in its `assertion_json` clone and lazily-rs found in scenario-id resolution;
/// three is the same shape with one more seam.
const _stampPrefixGuards = <String>[
  'scripts/check-conformance-coverage.sh',
  'scripts/check-unbound-blocks.py',
];

/// `RUN_ID_PREFIX=<quoted>` at the start of a line, in either guard's language.
///
/// ONE pattern for both, because both spell the declaration the same way modulo
/// the spaces Python's style puts around `=`. Matching the DECLARATION and
/// comparing the parsed VALUE is what keeps this test from restating the
/// literal a third time — a third spelling would only be a third place to
/// drift, which is the thing being fixed.
final _declaredStampPrefix = RegExp(
  r'''^RUN_ID_PREFIX[ \t]*=[ \t]*(["'])(.*)\1[ \t]*$''',
  multiLine: true,
);

/// The stamp prefix a guard declares, or a [StateError] naming why not.
///
/// Refuses ZERO matches and refuses DISAGREEING matches. A reader that simply
/// found nothing would make the coupling vacuous — a guard could drop its
/// constant entirely and the comparison would still pass — so absence is a
/// failure rather than a skip, and the reader is exercised against a doctored
/// source below so "no match" cannot become its permanent answer.
String stampPrefixDeclaredIn(String source, String label) {
  final values = _declaredStampPrefix
      .allMatches(source)
      .map((match) => match.group(2)!)
      .toSet();
  if (values.isEmpty) {
    throw StateError(
      '$label declares no `RUN_ID_PREFIX=<quoted string>` at the start of any '
      'line, so nothing in it is coupled to the recorder that writes the '
      'stamp. Either the guard stopped recognising the stamp, or it now spells '
      'the declaration in a form this reader cannot see — both are the drift '
      'this test exists to catch (#lzstampprefixdrift).',
    );
  }
  if (values.length > 1) {
    throw StateError(
      '$label declares `RUN_ID_PREFIX` more than once, with disagreeing '
      'values: $values. Which one the guard actually uses then depends on line '
      'order, which is not something a reader should have to work out.',
    );
  }
  return values.single;
}

/// Reads a committed guard, failing rather than skipping when it is gone.
String _guardSource(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError(
      '$path is missing (CWD=${Directory.current.path}). A guard that is not '
      'there cannot be coupled to anything, and skipping would report this '
      'test green over an absent file.',
    );
  }
  return file.readAsStringSync();
}

void main() {
  group('scenarioIdOf', () {
    test('id wins over name', () {
      expect(
        scenarioIdOf({'id': 'keep_latest', 'name': 'ignored'}, 7),
        'keep_latest',
      );
    });

    test('name is the fallback', () {
      expect(scenarioIdOf({'name': 'repair_converges'}, 7), 'repair_converges');
    });

    test('an unidentified scenario is refused', () {
      expect(
        () => scenarioIdOf({'policy': 'Sum'}, 1),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('carries neither `id` nor `name`'),
              contains('index 1'),
            ),
          ),
        ),
      );
    });

    test('a blank identifier is refused', () {
      // A blank id is not an identifier. Accepting it would file every blank-id
      // scenario in the corpus under the SAME ledger entry, which reads as
      // "replayed" the moment any one of them runs.
      expect(
        () => scenarioIdOf({'id': '  ', 'name': ''}, 2),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('the run-id stamp prefix (#lzstampprefixdrift)', () {
    // Drift here fails in the WORST available way, which is why a comment
    // holding the three spellings together is not enough. The recorder writes
    // one prefix and the guards look for another, so a perfectly FRESH evidence
    // file reads as unstamped and every run refuses — or, if only the trailing
    // space moved, the guard compares a mangled id against a good one and
    // reports a STALE MANIFEST on a green suite. Both present as the
    // stale-evidence bug `#lzstalemanifest` is about rather than as a typo in a
    // string, and the reader then goes looking at `build/`.
    test('every guard declares the prefix the recorder writes', () {
      final disagreements = <String>[];
      for (final path in _stampPrefixGuards) {
        final declared = stampPrefixDeclaredIn(_guardSource(path), path);
        if (declared != conformanceRunIdPrefix) {
          disagreements.add("$path declares '$declared'");
        }
      }
      expect(
        disagreements,
        isEmpty,
        reason: 'the recorder in test/conformance_manifest.dart stamps '
            "'$conformanceRunIdPrefix' as the first line of every evidence "
            'file; a guard looking for anything else refuses a fresh file, or '
            'compares a mangled id and calls a green run stale',
      );
    });

    test('both guards were really read', () {
      // Positive evidence that the walk above examined something. An empty
      // `_stampPrefixGuards` satisfies it having compared nothing, which is the
      // vacuous green this family's guards exist to reject.
      expect(_stampPrefixGuards, hasLength(2));
      for (final path in _stampPrefixGuards) {
        expect(_guardSource(path), contains('RUN_ID_PREFIX'));
      }
    });

    test('the reader sees a one-character drift, and an absent declaration',
        () {
      // Non-vacuity, asserted from what the reader DOES rather than from the
      // fact that it ran. A pattern that matched nothing, or one that handed
      // back the recorder's own constant, would pass the comparison above no
      // matter what the guards say.
      expect(
        stampPrefixDeclaredIn(r'RUN_ID_PREFIX="# lazily-run-Id "', '<capital>'),
        isNot(conformanceRunIdPrefix),
      );
      expect(
        stampPrefixDeclaredIn(r"RUN_ID_PREFIX = '# lazily-run-id'", '<space>'),
        isNot(conformanceRunIdPrefix),
      );
      expect(
        () => stampPrefixDeclaredIn('# no declaration here\n', '<absent>'),
        throwsA(isA<StateError>()),
      );
    });
  });
}
