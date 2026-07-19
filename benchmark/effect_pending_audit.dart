// Pending/scheduled-effect scan audit (`#lzspecedgeindex`).
//
// Companion to `edge_index_load.dart`, which is *blind* to this defect class:
// it drives pull-based reads through computed slots and never constructs an
// `Effect`, so no rung of it ever touches the pending-effect collection.
//
// The defect under audit is the one fixed in `lazily-rs`/`lazily-cpp`
// (`run_effect`) and `lazily-kt` (`disposeEffect`): a linear scan of the
// pending/scheduled effect collection for an id that cannot be there, costing
// O(W^2) per publish or per teardown at fan-out width W.
//
// Method (mirrors `lazily-rs examples/edge_audit.rs`):
//
//   * **Total work is held fixed.** Every rung runs exactly `totalEffects`
//     effect bodies, varying only the fan-out width. A flat ns/effect column is
//     therefore the *only* correct result; any upward slope is the quadratic.
//   * **Control arm at equal node count.** The fan-out-2 arm builds the same
//     number of effects over `total/2` sources. We assert on the wide/control
//     *ratio*, never on absolute growth, which is unsound under load.
//   * **One process per rung.** Invoke with `--rung=<n>`; the driver
//     (`--drive`) forks a fresh process per rung so a tracing GC cannot smear
//     one rung's heap into the next.
//   * **Forced-naive arm.** Compile with `-Dlazily.naive_pending_scan=true` to
//     put the scan back on both paths. A flat column from the fixed build only
//     means something if the *same harness* reports a large slope for the naive
//     build — otherwise "flat" is indistinguishable from "blind".
//
// Usage:
//   dart run benchmark/effect_pending_audit.dart --drive
//   dart run -Dlazily.naive_pending_scan=true \
//       benchmark/effect_pending_audit.dart --drive

import 'dart:io';

import 'package:lazily/lazily.dart';

const int totalEffects = 65536;
const List<int> widths = [64, 256, 1024, 4096, 16384, 65536];

/// Publish arm: `width` effects subscribed to one source cell; publishing that
/// cell schedules and flushes all `width` of them. Repeated `totalEffects /
/// width` times so every rung runs the same number of effect bodies.
double publishArm(int width) {
  final rounds = totalEffects ~/ width;
  final ctx = Context();
  final source = Cell<int>(ctx, 0);
  var seen = 0;
  final effects = <Effect>[];
  for (var i = 0; i < width; i++) {
    effects.add(Effect(ctx, (_) {
      seen += source.value;
      return null;
    }));
  }
  final sw = Stopwatch()..start();
  for (var r = 1; r <= rounds; r++) {
    source.value = r;
  }
  sw.stop();
  if (seen < rounds) {
    throw StateError('publish arm did not run: seen=$seen');
  }
  for (final e in effects) {
    e.dispose();
  }
  return sw.elapsedMicroseconds * 1000.0 / totalEffects;
}

/// Control arm at equal node count: the same `totalEffects` effect bodies, but
/// spread over `width / 2`-free fan-out-2 sources. Cost here is independent of
/// the wide arm's fan-out, so wide/control isolates the width term.
double publishControlArm(int width) {
  final rounds = totalEffects ~/ width;
  final ctx = Context();
  final sources = <Cell<int>>[];
  final effects = <Effect>[];
  for (var i = 0; i < width ~/ 2; i++) {
    final s = Cell<int>(ctx, 0);
    sources.add(s);
    for (var k = 0; k < 2; k++) {
      effects.add(Effect(ctx, (_) {
        return null;
      }));
    }
  }
  var body = 0;
  final probes = <Effect>[];
  for (final s in sources) {
    probes.add(Effect(ctx, (_) {
      body += s.value;
      return null;
    }));
  }
  final sw = Stopwatch()..start();
  for (var r = 1; r <= rounds; r++) {
    for (final s in sources) {
      s.value = r;
    }
  }
  sw.stop();
  if (body < 0) throw StateError('unreachable');
  for (final e in effects) {
    e.dispose();
  }
  for (final e in probes) {
    e.dispose();
  }
  final bodies = rounds * (width ~/ 2);
  return sw.elapsedMicroseconds * 1000.0 / bodies;
}

/// Teardown arm, quiescent: dispose `width` effects *after* the flush drained
/// the pending list. This is the realistic teardown path and the direct
/// analogue of the `lazily-kt` `disposeEffect` case.
double teardownQuiescentArm(int width) {
  final rounds = totalEffects ~/ width;
  var total = 0;
  for (var r = 0; r < rounds; r++) {
    final ctx = Context();
    final source = Cell<int>(ctx, 0);
    final effects = <Effect>[];
    for (var i = 0; i < width; i++) {
      effects.add(Effect(ctx, (_) {
        source.value;
        return null;
      }));
    }
    source.value = 1; // schedule + flush, leaving the pending list drained
    final sw = Stopwatch()..start();
    for (final e in effects) {
      e.dispose();
    }
    sw.stop();
    total += sw.elapsedMicroseconds;
  }
  return total * 1000.0 / totalEffects;
}

/// Teardown arm, saturated: dispose `width` effects while the pending
/// collection is genuinely full.
///
/// A batch does *not* achieve this — `_cellChanged` only records the cell while
/// `_batchDepth > 0` and defers the cascade to `_flushBatch`, so the pending
/// list is still empty inside the batch body. The list is only populated
/// *during* a flush, so this arm disposes the cohort from inside the first
/// effect's body, which runs with all `width` entries queued behind it. That is
/// also a realistic shape: an effect tearing down a subtree it owns.
///
/// This is the arm that proves the harness can *see* a teardown scan at all;
/// the quiescent arm alone cannot distinguish "no scan" from "scan over an
/// empty list".
double teardownSaturatedArm(int width) {
  final rounds = totalEffects ~/ width;
  var total = 0;
  for (var r = 0; r < rounds; r++) {
    final ctx = Context();
    final source = Cell<int>(ctx, 0);
    final effects = <Effect>[];
    var armed = false;
    final sw = Stopwatch();
    effects.add(Effect(ctx, (_) {
      source.value;
      if (!armed) return null;
      armed = false;
      sw.start();
      for (var i = 1; i < effects.length; i++) {
        effects[i].dispose();
      }
      sw.stop();
      return null;
    }));
    for (var i = 1; i < width; i++) {
      effects.add(Effect(ctx, (_) {
        source.value;
        return null;
      }));
    }
    armed = true;
    source.value = 1; // flush: effect 0 runs with width-1 entries still queued
    total += sw.elapsedMicroseconds;
    effects[0].dispose();
  }
  return total * 1000.0 / totalEffects;
}

String f(double v) => v.toStringAsFixed(1);

void runRung(int width) {
  final publish = publishArm(width);
  final control = publishControlArm(width);
  final quiescent = teardownQuiescentArm(width);
  final saturated = teardownSaturatedArm(width);
  stdout.writeln('RUNG $width ${f(publish)} ${f(control)} '
      '${f(quiescent)} ${f(saturated)}');
}

Future<void> drive(List<String> args) async {
  final naive = Context.naivePendingScan;
  stdout.writeln('lazily-dart pending/scheduled-effect scan audit '
      '(#lzspecedgeindex)');
  stdout.writeln('build: ${naive ? "FORCED-NAIVE" : "current (fixed)"}   '
      'total effect bodies per rung: $totalEffects');
  stdout.writeln(Platform.isLinux
      ? 'loadavg: ${File('/proc/loadavg').readAsStringSync().trim()}'
      : '');
  stdout.writeln('');
  stdout.writeln('  width   publish/ea  control/ea  teardown-q  teardown-sat'
      '   (ns per effect)');

  final rows = <int, List<double>>{};
  for (final w in widths) {
    final flags = <String>[
      if (naive) '-Dlazily.naive_pending_scan=true',
    ];
    final r = await Process.run(Platform.resolvedExecutable, [
      'run',
      ...flags,
      Platform.script.toFilePath(),
      '--rung=$w',
    ]);
    if (r.exitCode != 0) {
      stderr.writeln('rung $w failed: ${r.stderr}');
      exitCode = 1;
      return;
    }
    final line = (r.stdout as String)
        .split('\n')
        .firstWhere((l) => l.startsWith('RUNG '), orElse: () => '');
    if (line.isEmpty) {
      stderr.writeln('rung $w produced no result');
      exitCode = 1;
      return;
    }
    final parts = line.split(RegExp(r'\s+'));
    final vals = [
      double.parse(parts[2]),
      double.parse(parts[3]),
      double.parse(parts[4]),
      double.parse(parts[5]),
    ];
    rows[w] = vals;
    stdout.writeln('${w.toString().padLeft(7)}'
        '${f(vals[0]).padLeft(13)}'
        '${f(vals[1]).padLeft(12)}'
        '${f(vals[2]).padLeft(12)}'
        '${f(vals[3]).padLeft(14)}');
  }

  stdout.writeln('');
  final lo = widths.first;
  final hi = widths.last;
  final names = ['publish', 'control', 'teardown-quiescent', 'teardown-sat'];
  for (var c = 0; c < 4; c++) {
    final ratio = rows[hi]![c] / rows[lo]![c];
    stdout.writeln('${names[c].padRight(20)} '
        'width $lo -> $hi: ${ratio.toStringAsFixed(1)}x');
  }
  final wideOverControl = (rows[hi]![0] / rows[hi]![1]) /
      (rows[lo]![0] / rows[lo]![1]);
  stdout.writeln('publish wide/control ratio, $lo -> $hi: '
      '${wideOverControl.toStringAsFixed(1)}x');
}

Future<void> main(List<String> args) async {
  final rung = args.where((a) => a.startsWith('--rung=')).toList();
  if (rung.isNotEmpty) {
    runRung(int.parse(rung.first.substring('--rung='.length)));
    return;
  }
  await drive(args);
}
