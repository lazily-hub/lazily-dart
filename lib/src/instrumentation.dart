/// Instrumentation — benchmark harness for reactive operations.
///
/// Lightweight micro-benchmarks for the reactive core, collections, and CRDT
/// types. Run via `dart run tool/benchmark.dart`.
library;

import 'core.dart';
import 'collections.dart';
import 'text_crdt.dart';
import 'seq_crdt.dart';

/// A single benchmark result.
class BenchmarkResult {
  BenchmarkResult(this.name, this.iterations, this.totalMicros);

  final String name;
  final int iterations;
  final int totalMicros;

  /// Average time per iteration in microseconds.
  double get avgMicros => totalMicros / iterations;

  /// Operations per second.
  double get opsPerSecond => iterations / (totalMicros / 1000000);

  @override
  String toString() =>
      '$name: ${avgMicros.toStringAsFixed(2)}µs/op, ${opsPerSecond.toStringAsFixed(0)} ops/s ($iterations iters)';
}

/// Run a benchmark: execute [body] [iterations] times and measure the total.
BenchmarkResult benchmark(
  String name,
  void Function() body, {
  int iterations = 10000,
}) {
  final sw = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    body();
  }
  sw.stop();
  return BenchmarkResult(name, iterations, sw.elapsedMicroseconds);
}

/// Run the full benchmark suite. Returns all results.
List<BenchmarkResult> runBenchmarkSuite({int iterations = 10000}) {
  return [
    benchmark('Cell read/write', () {
      final ctx = Context();
      final c = Cell<int>(ctx, 0);
      c.value = 42;
      c.value;
    }, iterations: iterations),
    benchmark('Slot recompute', () {
      final ctx = Context();
      final a = Cell<int>(ctx, 1);
      final b = Cell<int>(ctx, 2);
      final sum = Slot<int>(ctx, (_) => a.value + b.value);
      a.value = 10;
      sum();
    }, iterations: iterations),
    benchmark('Memo equality guard (cache hit)', () {
      final ctx = Context();
      final src = Cell<int>(ctx, 4);
      final parity = Memo<String>(ctx, (_) => src.value.isEven ? 'even' : 'odd');
      src.value = 6; // still even — memo suppresses
      parity();
    }, iterations: iterations),
    benchmark('batch coalesce (10 cells)', () {
      final ctx = Context();
      final cells = [for (var i = 0; i < 10; i++) Cell<int>(ctx, i)];
      Effect(ctx, (_) {
        for (final c in cells) {
          c.value;
        }
        return null;
      });
      ctx.batch(() {
        for (var i = 0; i < 10; i++) {
          cells[i].value = i + 1;
        }
      });
    }, iterations: iterations),
    benchmark('CellMap insert + read', () {
      final ctx = Context();
      final map = CellMap<String, int>(ctx);
      for (var i = 0; i < 10; i++) {
        map.set('k$i', i);
      }
      map.read('k5');
    }, iterations: iterations),
    benchmark('TextCrdt insert 100 chars', () {
      final crdt = TextCrdt(1);
      for (var i = 0; i < 100; i++) {
        crdt.insert(i, 'a');
      }
    }, iterations: iterations ~/ 10),
    benchmark('SeqCrdt insert 100 elements', () {
      final seq = SeqCrdt<int, int>(1);
      for (var i = 0; i < 100; i++) {
        seq.insertBack(i, i, i);
      }
    }, iterations: iterations ~/ 10),
  ];
}
