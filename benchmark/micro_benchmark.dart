/// Micro-benchmark runner — surfaces the in-library `runBenchmarkSuite`
/// scenarios (`lib/src/instrumentation.dart`, exported via
/// `package:lazily/ipc.dart`) with wall-clock timing.
///
///   dart run benchmark/micro_benchmark.dart
///   LAZILY_MICRO_ITERS=100000 dart run benchmark/micro_benchmark.dart
library;

import 'dart:io';

import 'package:lazily/ipc.dart';

void main() {
  final iters =
      int.tryParse(Platform.environment['LAZILY_MICRO_ITERS'] ?? '') ?? 100000;
  stdout.writeln('lazily-dart micro benchmarks (runBenchmarkSuite)');
  stdout.writeln('  iterations = $iters');
  stdout.writeln('  Dart       = ${Platform.version}');
  stdout.writeln('');
  // Warm the VM once so JIT-compiled steady state is measured, not warmup.
  runBenchmarkSuite(iterations: iters ~/ 10);
  for (final r in runBenchmarkSuite(iterations: iters)) {
    stdout.writeln(
        '${r.name.padRight(34)} ${r.avgMicros.toStringAsFixed(4)} µs/op  '
        '${r.opsPerSecond.toStringAsFixed(0).padLeft(12)} ops/s');
  }
}
