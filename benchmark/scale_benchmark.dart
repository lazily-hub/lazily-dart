/// #lzscalebench — large-graph scale benchmark for lazily-dart, replicating the
/// lazily-rs `scale` group (`benches/scale.rs`) and lazily-go
/// (`scale_bench_test.go`).
///
/// Models a spreadsheet-shaped graph: `N` input cells plus `N` formula slots,
/// where `formula[i] = input[i] + input[i-1]` (local fan-in, like a column of
/// `=A_i + A_{i-1}`). With the default `N = 1_000_000` that is ~2M reactive
/// nodes. Four scenarios cover the spreadsheet lifecycle:
///
///   - build                     — construct all 2N nodes (formulas lazy).
///   - cold_full_recalc          — first read of every formula (forces compute).
///   - viewport_recalc           — edit one input, read only a bounded viewport
///                                 (the lazy-pull win: off-viewport formulas
///                                 stay dirty and never recompute).
///   - full_recalc_invalidate_all — touch every input, then read every formula.
///
/// Wall-clock timing via [Stopwatch] (`elapsedMicroseconds`). Run on demand or
/// at a different size:
///
///   dart run benchmark/scale_benchmark.dart
///   LAZILY_SCALE_N=1000000 dart run benchmark/scale_benchmark.dart
///   LAZILY_SCALE_N=5000000 dart run benchmark/scale_benchmark.dart  # Google Sheets 10M-cell workbook
///   LAZILY_SCALE_VIEWPORT=1000 dart run benchmark/scale_benchmark.dart
library;

import 'dart:io';

import 'package:lazily/lazily.dart';

int _scaleN() {
  final v = int.tryParse(Platform.environment['LAZILY_SCALE_N'] ?? '');
  return (v != null && v > 0) ? v : 1000000;
}

int _scaleViewport(int n) {
  var v = 1000;
  final x = int.tryParse(Platform.environment['LAZILY_SCALE_VIEWPORT'] ?? '');
  if (x != null && x > 0) v = x;
  if (v > n) v = n;
  return v;
}

/// The spreadsheet-shaped graph: N inputs + N formula slots.
class ScaleGraph {
  ScaleGraph(this.ctx, this.inputs, this.formulas);
  final Context ctx;
  final List<Cell<int>> inputs;
  final List<Slot<int>> formulas;
}

/// Construct the graph (formulas not yet computed — lazy until first read).
ScaleGraph buildScaleGraph(int n) {
  final ctx = Context();
  final inputs = List<Cell<int>>.generate(n, (i) => Cell<int>(ctx, i),
      growable: false);
  final formulas = List<Slot<int>>.generate(n, (i) {
    final a = inputs[i];
    final b = inputs[i - 1 < 0 ? 0 : i - 1];
    return Slot<int>(ctx, (_) => a.value + b.value);
  }, growable: false);
  return ScaleGraph(ctx, inputs, formulas);
}

/// Read every formula; return an accumulator to defeat dead-code elimination.
int readAllFormulas(ScaleGraph g) {
  var acc = 0;
  for (final f in g.formulas) {
    acc += f();
  }
  return acc;
}

int _sink = 0;

String _ms(int micros) => (micros / 1000).toStringAsFixed(1);

String _perCellNs(int micros, int cells) =>
    ((micros * 1000) / cells).toStringAsFixed(0);

void main() {
  final n = _scaleN();
  final vp = _scaleViewport(n);
  final cells = 2 * n;

  stdout.writeln('lazily-dart scale benchmark');
  stdout.writeln('  N (rows)      = $n');
  stdout.writeln('  nodes (2N)    = $cells');
  stdout.writeln('  viewport      = $vp formulas');
  stdout.writeln('  Dart          = ${Platform.version}');
  stdout.writeln('');

  // --- build ---
  final swBuild = Stopwatch()..start();
  var g = buildScaleGraph(n);
  swBuild.stop();
  final buildUs = swBuild.elapsedMicroseconds;
  stdout.writeln(
      'build                        : ${_ms(buildUs)} ms  (${_perCellNs(buildUs, cells)} ns/cell)');

  // --- cold_full_recalc --- first read of every formula on a fresh graph.
  g = buildScaleGraph(n);
  final swCold = Stopwatch()..start();
  _sink = readAllFormulas(g);
  swCold.stop();
  final coldUs = swCold.elapsedMicroseconds;
  stdout.writeln(
      'cold_full_recalc             : ${_ms(coldUs)} ms  (${_perCellNs(coldUs, cells)} ns/cell)');

  // --- viewport_recalc --- edit one input, read only a bounded viewport.
  // Warm the whole sheet once, then measure repeated single-cell edits.
  _sink = readAllFormulas(g); // g is already warm from cold pass; harmless.
  final mid = n ~/ 2;
  var lo = mid - vp ~/ 2;
  if (lo < 0) lo = 0;
  var hi = lo + vp;
  if (hi > n) hi = n;
  const vpIters = 2000;
  var tick = 0;
  final swVp = Stopwatch()..start();
  for (var it = 0; it < vpIters; it++) {
    tick++;
    g.inputs[mid].value = tick; // edit one input (toggling value passes guard)
    var acc = 0;
    for (var j = lo; j < hi; j++) {
      acc += g.formulas[j]();
    }
    _sink = acc;
  }
  swVp.stop();
  final vpAvgUs = swVp.elapsedMicroseconds / vpIters;
  stdout.writeln(
      'viewport_recalc              : ${vpAvgUs.toStringAsFixed(2)} µs/edit  (edit 1 input, read $vp-cell viewport; $vpIters iters)');

  // --- full_recalc_invalidate_all --- touch every input, recompute all.
  const fullIters = 3;
  var fullTotalUs = 0;
  tick = 0;
  for (var it = 0; it < fullIters; it++) {
    tick++;
    final base = tick;
    final sw = Stopwatch()..start();
    for (var j = 0; j < n; j++) {
      g.inputs[j].value = base + j;
    }
    _sink = readAllFormulas(g);
    sw.stop();
    fullTotalUs += sw.elapsedMicroseconds;
  }
  final fullAvgUs = (fullTotalUs / fullIters).round();
  stdout.writeln(
      'full_recalc_invalidate_all   : ${_ms(fullAvgUs)} ms  (${_perCellNs(fullAvgUs, cells)} ns/cell; avg of $fullIters iters)');

  // Report the ratio the lazy-pull model buys.
  final ratio = (coldUs / vpAvgUs).round();
  stdout.writeln('');
  stdout.writeln(
      'viewport edit is ~${_thousands(ratio)}× cheaper than a full cold recalc.');

  // Keep the sink observable so the optimizer cannot elide the work.
  if (_sink == 0x7fffffffffffffff) stdout.writeln('sink=$_sink');
}

String _thousands(int v) {
  final s = v.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}
