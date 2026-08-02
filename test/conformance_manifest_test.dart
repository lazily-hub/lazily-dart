import 'package:test/test.dart';

import 'conformance_manifest.dart';

/// Self-tests for the scenario ledger's identity resolution
/// (`#lzscenariocoverage`, `#lzspecscenarioids`).
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
}
