// Width-ladder load test for the dependency-edge index (`#lzspecedgeindex`).
//
// Existing bench suites measure scale as *node count* and pin fan-out at 2, so
// edge-registration width was never a variable — which is exactly why the
// O(n^2) dedup scan hid there. This test makes width the independent variable.
//
// Two things make the numbers trustworthy:
//
//  1. **One process per rung.** RSS is monotonic under a tracing GC, so
//     measuring successive rungs in one process charges each rung for the
//     previous rung's uncollected garbage. Each rung is measured in a fresh
//     child process and reports its own peak RSS.
//
//  2. **A fan-out-2 control arm at the same node count.** Building N nodes
//     costs allocation, GC and cache-miss time that grows with N regardless of
//     edge width, so an absolute bound on build ns/sub cannot distinguish
//     O(n^2) dedup from a DRAM latency curve or a GC-pause slope. The control
//     builds the same N subscribers over N/2 sources, holding allocation and
//     cache behaviour fixed and varying only width. Every algorithmic claim
//     here is on the wide/control **ratio**, never on an absolute slope.
//
// Method: **climb, project, refuse.** At each rung we measure bytes/subscriber,
// project the next rung from that measurement, and refuse to climb if the
// projection would not leave `--floor` free — so the run reports a ceiling
// instead of OOM-killing the host.
//
// Manual / on-demand only — NOT part of `dart test` or CI.
//
//   dart run benchmark/edge_index_load.dart
//   dart run benchmark/edge_index_load.dart --max 10000000 --heap 24000
//   dart compile exe benchmark/edge_index_load.dart -o /tmp/load && /tmp/load
//
// Flags:
//   --max <n>      highest rung to attempt (default 1000000)
//   --floor <mb>   memory floor to keep free (default 2048)
//   --heap <mb>    --old_gen_heap_size passed to each child (default 16384)
//   --reps <n>     child processes per rung, reduced by median (default 3)
//   --narrow       low-degree regression guard (no ladder); run on both trees
//   --quick        stop at 4096 (smoke run)
//   --rung <n>     internal: measure a single rung and print one TSV line

import 'dart:io';

import 'package:lazily/lazily.dart';

/// Rung shape: dense cluster around the promote threshold so demotion thrash
/// at threshold+1 is visible, then decades out to the ceiling.
const List<int> _ladder = [
  32, 64, 96, 97, 128, 129, 160, 256, 1024, 4096, 16384, 65536,
  262144, 1000000, 4000000, 10000000,
];

class Rung {
  Rung({
    required this.width,
    required this.buildNsPerSub,
    required this.notifyNsPerSub,
    required this.bytesPerSub,
    required this.controlNsPerSub,
  });

  final int width;
  final double buildNsPerSub;
  final double notifyNsPerSub;
  final double bytesPerSub;

  /// Fan-out-1 arm: same node count, no wide edge list.
  final double controlNsPerSub;

  /// What the wide arm costs over and above ambient allocation/GC cost.
  double get edgeOverhead => buildNsPerSub / controlNsPerSub;

  String toTsv() => [
        width,
        buildNsPerSub,
        notifyNsPerSub,
        bytesPerSub,
        controlNsPerSub,
      ].join('\t');

  /// Reduce independent samples of the same rung by per-metric median.
  static Rung medianOf(int width, List<Rung> samples) => Rung(
        width: width,
        buildNsPerSub: _median([for (final s in samples) s.buildNsPerSub]),
        notifyNsPerSub: _median([for (final s in samples) s.notifyNsPerSub]),
        bytesPerSub: _median([for (final s in samples) s.bytesPerSub]),
        controlNsPerSub: _median([for (final s in samples) s.controlNsPerSub]),
      );

  static Rung fromTsv(String line) {
    final f = line.trim().split('\t');
    return Rung(
      width: int.parse(f[0]),
      buildNsPerSub: double.parse(f[1]),
      notifyNsPerSub: double.parse(f[2]),
      bytesPerSub: double.parse(f[3]),
      controlNsPerSub: double.parse(f[4]),
    );
  }
}

double _median(List<double> xs) {
  xs.sort();
  return xs[xs.length ~/ 2];
}

/// Best-effort available system memory, in bytes.
int _availableBytes() {
  try {
    for (final line in File('/proc/meminfo').readAsLinesSync()) {
      if (line.startsWith('MemAvailable:')) {
        return int.parse(line.split(RegExp(r'\s+'))[1]) * 1024;
      }
    }
  } on Object {
    // Non-Linux or unreadable — fall through to a conservative guess.
  }
  return 8 * 1024 * 1024 * 1024;
}

/// Low-degree regression guard.
///
/// The ladder's narrow rungs each do only a few hundred registrations total,
/// so run-to-run noise swamps them and they cannot answer the question the
/// threshold exists to answer: *does promoting to a hash index make ordinary,
/// low-degree nodes slower than the scan it replaced?* This mode answers it by
/// rebuilding the same narrow fan-out enough times to total ~2M registrations
/// per sample, and reporting medians.
///
/// Run it on both sides of the change and diff the columns; a threshold that
/// is too low shows up as a regression in the rows below it.
void runNarrow() {
  const widths = [2, 4, 8, 16, 32, 64, 96, 97, 128, 192, 256, 512, 1024];
  const targetRegistrations = 2000000;

  _warmup();

  stdout
    ..writeln('lazily-dart edge-index low-degree guard (#lzspecedgeindex)')
    ..writeln('promote = $edgeIndexPromoteThreshold, '
        'demote = $edgeIndexDemoteThreshold')
    ..writeln('')
    ..writeln('    width   ns/registration');

  for (final width in widths) {
    final reps = (targetRegistrations ~/ width).clamp(4, 200000);
    final samples = <double>[];
    for (var t = 0; t < 9; t++) {
      final sw = Stopwatch()..start();
      for (var r = 0; r < reps; r++) {
        final ctx = Context();
        final source = Cell<int>(ctx, 0);
        for (var i = 0; i < width; i++) {
          Slot<int>(ctx, (_) => source.value + i)();
        }
      }
      sw.stop();
      samples.add(sw.elapsedMicroseconds * 1000.0 / (reps * width));
    }
    stdout.writeln('${width.toString().padLeft(9)}  '
        '${_median(samples).toStringAsFixed(1).padLeft(16)}');
  }
}

/// Warm the JIT before any timed work. A fresh child process would otherwise
/// charge the narrow rungs for compilation of the very code being measured —
/// which reads as a 20x cost at width 32 and nothing at width 1M.
void _warmup() {
  for (var round = 0; round < 3; round++) {
    final ctx = Context();
    final source = Cell<int>(ctx, 0);
    final subs = [
      for (var i = 0; i < 512; i++) Slot<int>(ctx, (_) => source.value + i),
    ];
    for (final s in subs) {
      s();
    }
    source.value = round + 1;
    for (final s in subs) {
      s();
    }
  }
}

/// The wide arm: one source cell read by `width` slot subscribers.
Rung measureRung(int width, {int cycles = 3}) {
  final rssBefore = ProcessInfo.currentRss;

  final ctx = Context();
  final source = Cell<int>(ctx, 0);
  final subs = <Slot<int>>[];

  final sw = Stopwatch()..start();
  for (var i = 0; i < width; i++) {
    final s = Slot<int>(ctx, (_) => source.value + i);
    s(); // the first read is the edge registration under test
    subs.add(s);
  }
  sw.stop();
  final buildNsPerSub = sw.elapsedMicroseconds * 1000.0 / width;

  final bytesPerSub = (ProcessInfo.maxRss - rssBefore) / width;

  // Steady state: each publish clears the source's dependent list and each
  // subsequent read re-registers every edge. This is the oscillation path
  // where a shared promote/demote boundary thrashes.
  final notifyRuns = <double>[];
  for (var c = 0; c < cycles; c++) {
    final nsw = Stopwatch()..start();
    source.value = c + 1;
    for (var i = 0; i < width; i++) {
      subs[i]();
    }
    nsw.stop();
    notifyRuns.add(nsw.elapsedMicroseconds * 1000.0 / width);
  }

  // Every survivor must observe the final publish.
  for (var i = 0; i < width; i++) {
    final got = subs[i]();
    if (got != cycles + i) {
      throw StateError(
        'width=$width subscriber $i observed $got, expected ${cycles + i}',
      );
    }
  }

  return Rung(
    width: width,
    buildNsPerSub: buildNsPerSub,
    notifyNsPerSub: _median(notifyRuns),
    bytesPerSub: bytesPerSub,
    controlNsPerSub: _measureControl(width),
  );
}

/// The control arm: `width` subscribers spread over `width / 2` sources at
/// **fan-out 2** — the same node count and the same allocation/GC pressure as
/// the wide arm, but no edge list ever exceeds 2, so dedup is free.
///
/// This is the load test's whole basis for a claim about *algorithmic* cost.
/// An absolute "build ns/sub must not grow more than 2x from 1k to 1M" bound
/// is unsound: every phase picks up a memory-hierarchy slope once the working
/// set outgrows cache, and under Dart's tracing GC a collection-pause slope on
/// top of that — `notify`, which does no dedup work whatsoever, grows several
/// fold over the same range. Asserting the absolute form would either fail a
/// correct implementation or "fix" a DRAM latency curve. Holding node count
/// and allocation fixed and varying only width isolates the one variable under
/// test. Fan-out 2 matches the control used by the other bindings' ports, so
/// the ratios are comparable across languages.
double _measureControl(int width) {
  final ctx = Context();
  final sourceCount = (width ~/ 2).clamp(1, width);
  final sources = [for (var i = 0; i < sourceCount; i++) Cell<int>(ctx, 0)];
  final subs = <Slot<int>>[];

  final sw = Stopwatch()..start();
  for (var i = 0; i < width; i++) {
    final c = sources[i % sourceCount];
    final s = Slot<int>(ctx, (_) => c.value + i);
    s();
    subs.add(s);
  }
  sw.stop();

  if (subs.length != width) throw StateError('control arm lost subscribers');
  return sw.elapsedMicroseconds * 1000.0 / width;
}

/// Measure one rung in a fresh child process, so its RSS is its own.
Rung? runRungInChild(int width, int heapMb) {
  final script = Platform.script.toFilePath();
  final isCompiled = !script.endsWith('.dart');
  final result = Process.runSync(
    isCompiled ? script : Platform.resolvedExecutable,
    isCompiled
        ? ['--rung', '$width']
        : ['--old_gen_heap_size=$heapMb', 'run', script, '--rung', '$width'],
    environment: isCompiled ? {'DART_VM_OPTIONS': '--old_gen_heap_size=$heapMb'} : null,
  );
  if (result.exitCode != 0) {
    stdout.writeln('  rung $width FAILED (exit ${result.exitCode})');
    final err = (result.stderr as String).trim();
    if (err.isNotEmpty) stdout.writeln('  ${err.split('\n').first}');
    return null;
  }
  return Rung.fromTsv(result.stdout as String);
}

void main(List<String> args) {
  var maxWidth = 1000000;
  var floorBytes = 2048 * 1024 * 1024;
  var heapMb = 16384;
  var reps = 3;

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--rung':
        // Child mode: warm up, measure one rung, emit one TSV line, exit.
        _warmup();
        stdout.write(measureRung(int.parse(args[++i])).toTsv());
        return;
      case '--max':
        maxWidth = int.parse(args[++i]);
      case '--floor':
        floorBytes = int.parse(args[++i]) * 1024 * 1024;
      case '--heap':
        heapMb = int.parse(args[++i]);
      case '--reps':
        reps = int.parse(args[++i]);
      case '--narrow':
        runNarrow();
        return;
      case '--quick':
        maxWidth = 4096;
    }
  }

  stdout
    ..writeln('lazily-dart edge-index width ladder (#lzspecedgeindex)')
    ..writeln('promote = $edgeIndexPromoteThreshold, '
        'demote = $edgeIndexDemoteThreshold, '
        'child heap = ${heapMb}MB')
    ..writeln('available = '
        '${(_availableBytes() / (1 << 30)).toStringAsFixed(1)} GiB, '
        'floor = ${(floorBytes / (1 << 30)).toStringAsFixed(1)} GiB')
    ..writeln('')
    ..writeln('    width   build ns/sub  ctrl ns/sub  edge x  '
        'notify ns/sub   bytes/sub');

  final results = <Rung>[];
  var ceiling = 0;
  String? limitingFactor;

  for (final width in _ladder) {
    if (width > maxWidth) {
      limitingFactor ??= 'ladder capped by --max $maxWidth';
      break;
    }

    // Project from the last measurement; refuse rather than OOM.
    if (results.isNotEmpty) {
      final projected = results.last.bytesPerSub * width;
      final available = _availableBytes();
      if (projected > available - floorBytes) {
        limitingFactor =
            'projected ${(projected / (1 << 30)).toStringAsFixed(1)} GiB at '
            'width $width exceeds available '
            '${(available / (1 << 30)).toStringAsFixed(1)} GiB minus floor';
        stdout.writeln('  REFUSED width=$width: $limitingFactor');
        break;
      }
    }

    // Single runs on narrow rungs drift by ~30%, so every rung is measured in
    // `reps` independent child processes and reduced by median.
    final samples = <Rung>[];
    for (var r = 0; r < reps; r++) {
      final sample = runRungInChild(width, heapMb);
      if (sample != null) samples.add(sample);
    }
    final rung = samples.isEmpty ? null : Rung.medianOf(width, samples);
    if (rung == null) {
      limitingFactor = 'child process failed at width $width '
          '(heap ${heapMb}MB — retry with a larger --heap)';
      break;
    }
    results.add(rung);
    ceiling = width;
    stdout.writeln(
      '${width.toString().padLeft(9)}  '
      '${rung.buildNsPerSub.toStringAsFixed(1).padLeft(13)}  '
      '${rung.controlNsPerSub.toStringAsFixed(1).padLeft(11)}  '
      '${rung.edgeOverhead.toStringAsFixed(2).padLeft(6)}  '
      '${rung.notifyNsPerSub.toStringAsFixed(1).padLeft(13)}  '
      '${rung.bytesPerSub.toStringAsFixed(0).padLeft(10)}',
    );
  }

  stdout
    ..writeln('')
    ..writeln('ceiling reached: width $ceiling');
  if (limitingFactor != null) stdout.writeln('limiting factor: $limitingFactor');

  // --- assertions ---------------------------------------------------------
  final failures = <String>[];

  Rung? at(int w) {
    for (final r in results) {
      if (r.width == w) return r;
    }
    return null;
  }

  // 1. Edge-registration cost, net of ambient allocation cost, must not grow
  //    from 1k to the top of the ladder. The O(n^2) signature is ~1000x here.
  final lo = at(1024);
  final hi = results.isEmpty ? null : results.last;
  if (lo != null && hi != null && hi.width >= 65536) {
    final growth = hi.edgeOverhead / lo.edgeOverhead;
    stdout.writeln('edge overhead 1k -> ${hi.width}: '
        '${lo.edgeOverhead.toStringAsFixed(2)}x -> '
        '${hi.edgeOverhead.toStringAsFixed(2)}x '
        '(${growth.toStringAsFixed(2)}x growth)');
    if (growth >= 2.0) {
      failures.add('edge-registration overhead grew '
          '${growth.toStringAsFixed(2)}x from 1k to ${hi.width} (limit 2x)');
    }
  } else {
    stdout.writeln('edge overhead: SKIPPED (ladder did not reach 64k)');
  }

  // 2. bytes/sub flat within ~20%, over the rungs where the measurement is
  //    actually signal. RSS is quantised by the allocator and offset by a
  //    ~40 MB fixed process baseline, so a rung whose whole graph is a few MB
  //    measures that noise, not the graph — at width 160 the delta even comes
  //    out negative. Only rungs whose live set clears `_rssSignalFloor` are
  //    compared; below it the number is printed but not asserted on.
  const rssSignalFloor = 64 * 1024 * 1024;
  final wide = results
      .where((r) => r.bytesPerSub * r.width >= rssSignalFloor)
      .toList();
  if (wide.length >= 2) {
    final vals = wide.map((r) => r.bytesPerSub).toList()..sort();
    stdout.writeln('bytes/sub spread over rungs >=64MB live '
        '(widths ${wide.map((r) => r.width).join(", ")}): '
        '${vals.first.toStringAsFixed(0)}..${vals.last.toStringAsFixed(0)} '
        '(${(vals.last / vals.first).toStringAsFixed(2)}x)');
    if (vals.last / vals.first > 1.2) {
      failures.add('bytes/sub spread '
          '${(vals.last / vals.first).toStringAsFixed(2)}x exceeds 1.2x '
          'across rungs with >=64MB live');
    }
  } else {
    stdout.writeln('bytes/sub spread: SKIPPED '
        '(fewer than 2 rungs cleared the 64MB RSS signal floor)');
  }

  // 3. Demotion thrash: the rung just above a boundary must not be dramatically
  //    worse than the rung just below it. A shared promote/demote boundary
  //    shows up here as ~4x steady-state notify cost at threshold+1 only.
  final thrashPairs = {
    [edgeIndexPromoteThreshold, edgeIndexPromoteThreshold + 1].join(','),
    '96,97',
    '128,129',
  }.map((s) => s.split(',').map(int.parse).toList());
  for (final pair in thrashPairs) {
    final below = at(pair[0]);
    final above = at(pair[1]);
    if (below == null || above == null) continue;
    final ratio = above.notifyNsPerSub / below.notifyNsPerSub;
    stdout.writeln('thrash check ${pair[0]} -> ${pair[1]}: '
        '${ratio.toStringAsFixed(2)}x notify');
    if (ratio > 2.0) {
      failures.add('notify cost jumped ${ratio.toStringAsFixed(2)}x from width '
          '${pair[0]} to ${pair[1]} — demotion thrash');
    }
  }

  stdout.writeln('');
  if (failures.isEmpty) {
    stdout.writeln('PASS');
  } else {
    for (final f in failures) {
      stderr.writeln('FAIL: $f');
    }
    exit(1);
  }
}
