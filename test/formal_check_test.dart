import 'dart:io';

import 'package:test/test.dart';

// Wires the sibling `lazily-formal` Lean 4 model into the Dart test suite.
//
// Each property/fixture test in this suite names a Lean theorem it mirrors
// (from `LazilyFormal.StateChart` / `StateMachine` / `Reactive` / `Collection` /
// `Tree` / `Reconciliation` / `AsyncSlotState`). Those theorems are only
// trustworthy if the model compiles. This test runs `tool/formal_check.dart`,
// which builds `lazily-formal` via `lake build` when the submodule + Lean
// toolchain are present (full repo checkout / CI), and SKIPs gracefully
// otherwise (pub.dev consumer, shallow clone) so the Dart-only tests still
// run. CI uses a full checkout + elan, so the proofs are verified for real
// there.

void main() {
  test('lazily-formal Lean proofs compile (or SKIP when submodule/toolchain absent)', () async {
  final dart = Platform.resolvedExecutable;
  // `dart test` runs with CWD at the package root.
  final script = File('${Directory.current.path}/tool/formal_check.dart');
  assert(
    script.existsSync(),
    'tool/formal_check.dart not found at ${script.path} '
    '(CWD=${Directory.current.path})',
  );

  final result = await Process.run(
    dart,
    ['run', script.path],
    runInShell: false,
  );

  // Surface the tool's own output for visibility in the test report.
  final out = result.stdout.toString().trim();
  final err = result.stderr.toString().trim();
  if (out.isNotEmpty) {
    // ignore: avoid_print
    print('--- formal_check stdout ---\n$out');
  }
  if (err.isNotEmpty) {
    // ignore: avoid_print
    print('--- formal_check stderr ---\n$err');
  }

  expect(
    result.exitCode,
    0,
    reason:
        'formal_check failed (exit ${result.exitCode}). A Lean proof in '
        'lazily-formal broke, or the tool could not run. See output above.',
  );

  // Distinguish a real verification from a SKIP so the run summary is honest.
  final ranLean = out.contains('OK —');
  final skipped = out.contains('SKIP —');
  expect(
    ranLean ^ skipped,
    isTrue,
    reason:
        'formal_check neither clearly OK-ed nor SKIP-ed. Output:\n$out\n$err',
  );
  if (skipped) {
    // ignore: avoid_print
    print(
      '[formal] proofs NOT verified in this run (submodule or `lake` absent). '
      'CI verifies them under a full checkout.',
    );
  }
  });
}
