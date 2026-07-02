// Lazily-formal proof verification hook for the lazily-dart test suite.
//
// The Dart state-chart / reactive / collection modules are accompanied by a
// Lean 4 formal model in the sibling `lazily-formal` submodule
// (`LazilyFormal.StateChart` / `StateMachine` / `Reactive` / `Collection` /
// `Tree` / `Reconciliation` / `AsyncSlotState`). The Dart tests in
// `test/statechart_properties_test.dart` and `test/reactive_properties_test.dart`
// name the universal theorems they mirror; this script makes those theorems
// *executable* by building the Lean model. If a proof breaks, the test suite
// fails.
//
// Behavior:
//   - If `lazily-formal` is a sibling of this package (full repo checkout /
//     submodule present) and `lake` is on PATH, run `lake build` and propagate
//     its exit status.
//   - If either is missing (pub.dev consumer, shallow clone, no Lean
//     toolchain), print a clear SKIP notice and exit 0 so the Dart-only tests
//     still run. CI uses a full checkout, so the formal model is verified
//     there.
//
// Run standalone:
//   dart run tool/formal_check.dart
//
// Or as part of the test suite (`dart test` invokes it via
// `test/formal_check_test.dart`).

import 'dart:io';

Future<int> main(List<String> args) async {
  final here = File(Platform.script.toFilePath()).parent;
  final candidates = <String>[
    // Explicit override wins (CI sets this to a sibling checkout path).
    if (Platform.environment['LAZILY_FORMAL_PATH'] case final path? when path.isNotEmpty)
      path,
    // Layout: <pkg>/tool/formal_check.dart and <superproject>/src/lazily-formal.
    // From the published package root, `../lazily-formal` covers the in-repo
    // submodule layout (`src/lazily-dart` ↔ `src/lazily-formal`).
    here.parent.parent.childDir('lazily-formal'),
    here.parent.childDir('lazily-formal'),
  ];

  final formalDir = resolveFormalDir(candidates);
  if (formalDir == null) {
    stdout.writeln(
      '[formal-check] SKIP — lazily-formal submodule not present. '
      'Clone with --recurse-submodules to enable Lean proof verification.',
    );
    return 0;
  }

  if (!hasLake()) {
    stdout.writeln(
      '[formal-check] SKIP — `lake` (Lean toolchain) not on PATH. '
      'Install Lean via elan (https://lean-lang.org/lean4/doc/setup.html) '
      'to enable proof verification.',
    );
    return 0;
  }

  stdout.writeln('[formal-check] building lazily-formal at $formalDir ...');

  final result = await Process.run(
    'lake',
    ['build'],
    workingDirectory: formalDir,
    runInShell: true,
  );

  stdout.write(result.stdout);
  stderr.write(result.stderr);

  if (result.exitCode != 0) {
    stderr.writeln('[formal-check] FAIL — `lake build` exited ${result.exitCode}.');
    return result.exitCode;
  }

  stdout.writeln('[formal-check] OK — all Lean proofs in lazily-formal compile.');
  return 0;
}

String? resolveFormalDir(List<String> candidates) {
  for (final candidate in candidates) {
    final dir = Directory(candidate);
    if (!dir.existsSync()) continue;
    try {
      final resolved = dir.resolveSymbolicLinksSync();
      // A real lazily-formal checkout ships these markers.
      final lakefile = File(_join(resolved, 'lakefile.lean'));
      final lazilyFormal = Directory(_join(resolved, 'LazilyFormal'));
      if (lakefile.existsSync() && lazilyFormal.existsSync()) return resolved;
    } catch (_) {
      // resolveSymbolicLinks may fail on a broken/empty submodule entry — keep scanning.
    }
  }
  return null;
}

bool hasLake() {
  try {
    return Process.runSync('lake', ['--version'], runInShell: true).exitCode == 0;
  } catch (_) {
    return false;
  }
}

String _join(String parent, String child) =>
    parent.endsWith('/') || parent.endsWith('\\') ? '$parent$child' : '$parent/$child';

extension on FileSystemEntity {
  String childDir(String name) => _join(path, name);
}
