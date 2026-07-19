// Observer copy-on-write tradeoff audit (`#lzdartobservercow`).
//
// `Cell._observers` is a copy-on-write immutable list. That is a deliberate
// trade, not a defect:
//
//   * `subscribe`     — `[..._observers, observer]`, O(W) per call, O(W^2) to
//                       build W observers.
//   * unsubscribe     — `indexOf` O(W) + `List.of` copy O(W), O(W^2) to tear
//                       down W.
//   * `_notifyObservers` — reads the field as an already-stable snapshot and
//                       runs a plain indexed loop: O(W), zero allocation.
//
// It buys allocation-free, reentrancy-safe publishes at the price of linear
// subscribe/unsubscribe. The question this harness answers is which side of
// that trade real usage lands on, and whether the alternative (mutable list +
// generation counter, snapshotting only when the observer set changed between
// notifications) wins on one arm without losing the other.
//
// Method (mirrors `effect_pending_audit.dart` / `lazily-rs examples/edge_audit.rs`):
//
//   * **Two arms, both measured.** A change that helps churn must be shown not
//     to hurt publish. This is the trap the eager-index variant fell into in
//     `lazily-cpp` (`ba9ba34`): it fixed teardown and silently regressed wide
//     notify ~1.5x.
//   * **Total work is held fixed.** Every rung of the churn arm performs
//     exactly `totalChurnOps` subscribe+unsubscribe pairs; every rung of the
//     publish arm drives exactly `totalNotifications` observer invocations.
//     Only the fan-out width W varies. A flat per-op column is the only correct
//     result for a non-quadratic structure.
//   * **Control arm at equal op count.** The narrow rung (W=2) does the same
//     total work over many more cells. We assert on the wide/narrow *ratio*,
//     never on absolute growth, which is unsound under load (it picks up cache
//     and GC slopes).
//   * **One process per rung *and per arm*.** Invoke with `--rung=<n> --arm=<churn|publish>`;
//     the driver (`--drive`) forks a fresh process for each pair so a tracing
//     GC cannot smear one rung's heap into the next. Running both arms in one
//     process is not sufficient: the churn arm allocates very differently under
//     the two observer shapes, and leaves that heap state behind for whichever
//     arm runs second. RSS across in-process rungs is likewise not a memory
//     measurement under a tracing GC.
//
// To A/B against the previous copy-on-write shape, run this same harness in a
// worktree checked out before the `#lzdartobservercow` commit and interleave
// the two, comparing wide/narrow *ratios*:
//
//   git worktree add /tmp/cow-head <commit>^ --detach
//   cp benchmark/observer_cow_audit.dart /tmp/cow-head/benchmark/
//   * **Liveness counters, not careful writing.** Each arm returns an observed
//     invocation count and the harness asserts it against the expected total.
//     An arm that silently fails to exercise the path reports a flat column
//     that is indistinguishable from a fixed one.
//
// Usage:
//   dart run benchmark/observer_cow_audit.dart --drive
//   dart run -Dlazily.mutable_observers=true \
//       benchmark/observer_cow_audit.dart --drive

import 'dart:io';

import 'package:lazily/lazily.dart';

/// Subscribe+unsubscribe pairs performed by every rung of the churn arm.
///
/// Deliberately smaller than [totalNotifications]: under copy-on-write the
/// churn arm is quadratic in W, so the widest rung already costs ~5e8 element
/// copies at this budget. Raising it does not change the *ratio*, which is what
/// we assert on.
const int totalChurnOps = 32768;

/// Width and cycle count of the churn arm's pre-timing warmup.
const int warmupChurnWidth = 64;
const int warmupChurnCycles = 512;

/// Observer invocations driven by every rung of the publish arm.
///
/// Large enough that the widest rung still performs many publishes, so
/// per-publish fixed cost is resolvable and the timed region is steady state.
const int totalNotifications = 4194304;

/// Observer invocations driven before the publish arm starts timing.
const int warmupNotifications = 1048576;

const List<int> widths = [64, 256, 1024, 4096, 16384];

/// Width of the narrow control rung, used as the ratio denominator.
const int controlWidth = 2;

/// Churn arm: repeatedly build and tear down `width` observers on one cell.
///
/// Total subscribe/unsubscribe work is fixed at [totalChurnOps] pairs, so the
/// per-op column is flat iff subscribe and unsubscribe are O(1) amortised.
/// Under copy-on-write both are O(W), so this column rises linearly in W.
///
/// Returns the observed observer-invocation count. One publish is driven per
/// cycle while the observers are live (proving `subscribe` registered them) and
/// one after teardown (proving the disposers actually removed them — that
/// second publish must contribute nothing).
({int elapsedUs, int invocations}) churnArm(int width) {
  final cycles = totalChurnOps ~/ width;
  var invocations = 0;
  final ctx = Context();
  final cell = Cell<int>(ctx, 0);
  void observer(int value) => invocations++;

  // Warm up subscribe/dispose/notify before timing. Done at a fixed narrow
  // width because the code paths are width-independent, and warming at the
  // rung width would cost a full quadratic cycle under copy-on-write. Without
  // this the widest rungs time JIT tier-up: at W=16384 the timed region is only
  // two cycles.
  {
    final warmCell = Cell<int>(Context(), 0);
    for (var c = 0; c < warmupChurnCycles; c++) {
      final disposers = [
        for (var i = 0; i < warmupChurnWidth; i++) warmCell.subscribe(observer),
      ];
      warmCell.value = warmCell.peek + 1;
      for (final dispose in disposers) {
        dispose();
      }
      warmCell.value = warmCell.peek + 1;
    }
  }
  invocations = 0;

  final sw = Stopwatch()..start();
  for (var cycle = 0; cycle < cycles; cycle++) {
    final disposers = <void Function()>[];
    for (var i = 0; i < width; i++) {
      disposers.add(cell.subscribe(observer));
    }
    // Live publish: must fire exactly `width` times.
    cell.value = cell.peek + 1;
    for (var i = 0; i < width; i++) {
      disposers[i]();
    }
    // Post-teardown publish: must fire zero times. If unsubscribe were inert
    // this count would blow past the expected total and trip the assertion.
    cell.value = cell.peek + 1;
  }
  sw.stop();
  return (elapsedUs: sw.elapsedMicroseconds, invocations: invocations);
}

/// Publish arm: a stable set of `width` observers, many notifications.
///
/// Total observer invocations are fixed at [totalNotifications], so the
/// per-invocation column is flat iff notification is O(W) with no per-publish
/// allocation. A structure that snapshots the observer list on every publish
/// shows up here as a rising column.
({int elapsedUs, int invocations}) publishArm(int width) {
  final publishes = totalNotifications ~/ width;
  var invocations = 0;
  final ctx = Context();
  final cell = Cell<int>(ctx, 0);
  void observer(int value) => invocations++;

  for (var i = 0; i < width; i++) {
    cell.subscribe(observer);
  }

  // Warm up the notification path before timing. Without this the wide rungs
  // are warmup-starved: at W=16384 the timed region is only 16 publishes, so
  // JIT tier-up lands *inside* the measurement and the column reports compile
  // time rather than steady-state notify cost. Warmup invocations are excluded
  // from the returned count.
  for (var w = 0; w < warmupNotifications ~/ width; w++) {
    cell.value = cell.peek + 1;
  }
  invocations = 0;

  final sw = Stopwatch()..start();
  for (var p = 0; p < publishes; p++) {
    cell.value = cell.peek + 1;
  }
  sw.stop();
  return (elapsedUs: sw.elapsedMicroseconds, invocations: invocations);
}

void runRung(int width, String arm) {
  if (arm == 'churn') {
    final churn = churnArm(width);
    // Liveness assertion. The churn arm drives one live publish per cycle over
    // `width` observers; the post-teardown publish must add nothing.
    final expected = (totalChurnOps ~/ width) * width;
    if (churn.invocations != expected) {
      stderr.writeln(
        'INERT ARM: churn width=$width observed ${churn.invocations} '
        'invocations, expected $expected',
      );
      exit(2);
    }
    stdout.writeln(
      'RUNG\t$width\t${(churn.elapsedUs * 1000 / expected).toStringAsFixed(2)}',
    );
    return;
  }
  final publish = publishArm(width);
  final expected = (totalNotifications ~/ width) * width;
  if (publish.invocations != expected) {
    stderr.writeln(
      'INERT ARM: publish width=$width observed ${publish.invocations} '
      'invocations, expected $expected',
    );
    exit(2);
  }
  stdout.writeln(
    'RUNG\t$width\t${(publish.elapsedUs * 1000 / expected).toStringAsFixed(2)}',
  );
}

Future<void> drive(List<String> args) async {
  final script = Platform.script.toFilePath();
  final defines = <String>[
    for (final a in Platform.executableArguments)
      if (a.startsWith('-D')) a,
  ];
  final rungs = <int>[controlWidth, ...widths];
  final churnByWidth = <int, double>{};
  final publishByWidth = <int, double>{};

  Future<double> runOne(int width, String arm) async {
    final result = await Process.run(
      Platform.executable,
      [...defines, script, '--rung=$width', '--arm=$arm'],
    );
    if (result.exitCode != 0) {
      stderr.writeln('rung $width/$arm failed: ${result.stderr}');
      exit(result.exitCode);
    }
    for (final line in (result.stdout as String).split('\n')) {
      if (line.startsWith('RUNG\t')) return double.parse(line.split('\t')[2]);
    }
    stderr.writeln('rung $width/$arm produced no result');
    exit(3);
  }

  stdout.writeln('load average: ${await _loadAverage()}');
  stdout.writeln(
    'width\tchurn ns/op\tpublish ns/invocation',
  );
  for (final width in rungs) {
    churnByWidth[width] = await runOne(width, 'churn');
    publishByWidth[width] = await runOne(width, 'publish');
    stdout.writeln(
      '$width\t${churnByWidth[width]!.toStringAsFixed(2)}'
      '\t${publishByWidth[width]!.toStringAsFixed(2)}',
    );
  }

  final churnControl = churnByWidth[controlWidth]!;
  final publishControl = publishByWidth[controlWidth]!;
  final widest = widths.last;
  stdout.writeln('');
  stdout.writeln('load average: ${await _loadAverage()}');
  stdout.writeln(
    'churn   wide/narrow ratio (W=$widest / W=$controlWidth): '
    '${(churnByWidth[widest]! / churnControl).toStringAsFixed(1)}x',
  );
  stdout.writeln(
    'publish wide/narrow ratio (W=$widest / W=$controlWidth): '
    '${(publishByWidth[widest]! / publishControl).toStringAsFixed(1)}x',
  );
}

Future<String> _loadAverage() async {
  try {
    final raw = await File('/proc/loadavg').readAsString();
    return raw.split(' ').take(3).join(' ');
  } catch (_) {
    return 'unavailable';
  }
}

Future<void> main(List<String> args) async {
  final rungArg = args.where((a) => a.startsWith('--rung=')).firstOrNull;
  if (rungArg != null) {
    final armArg = args.where((a) => a.startsWith('--arm=')).firstOrNull;
    runRung(
      int.parse(rungArg.substring('--rung='.length)),
      armArg == null ? 'churn' : armArg.substring('--arm='.length),
    );
    return;
  }
  await drive(args);
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
