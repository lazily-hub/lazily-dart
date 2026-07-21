/// Instrumentation — benchmark harness for reactive operations.
///
/// Lightweight micro-benchmarks for the reactive core, collections, and CRDT
/// types. Run via `dart run tool/benchmark.dart`.
library;

import 'core.dart';
import 'collections.dart';
import 'text_crdt.dart';
import 'seq_crdt.dart';
import 'stable_id.dart';

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
      final c = Source<int>(ctx, 0);
      c.value = 42;
      c.value;
    }, iterations: iterations),
    benchmark('Slot recompute', () {
      final ctx = Context();
      final a = Source<int>(ctx, 1);
      final b = Source<int>(ctx, 2);
      final sum = Slot<int>(ctx, (_) => a.value + b.value);
      a.value = 10;
      sum();
    }, iterations: iterations),
    benchmark('Computed equality guard (cache hit)', () {
      final ctx = Context();
      final src = Source<int>(ctx, 4);
      final parity =
          computed<String>(ctx, (_) => src.value.isEven ? 'even' : 'odd');
      src.value = 6; // still even — the guard suppresses
      parity();
    }, iterations: iterations),
    benchmark('batch coalesce (10 cells)', () {
      final ctx = Context();
      final cells = [for (var i = 0; i < 10; i++) Source<int>(ctx, i)];
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
    benchmark('Position.compareTo ordering (300)', () {
      // #lzdartuint8list — isolates Position.compareTo on the SeqCrdt sort path.
      // The seq is built once (outside the timed body) so the measurement is the
      // fractional-index ordering, not the O(n²) insert scan.
      _seqForOrdering.order();
    }, iterations: iterations ~/ 10),
    benchmark('contentHash realistic text', () {
      // #lzdarthashint — FNV-1a content hash over a ~300-char normalized block.
      contentHash(
          'the quick brown fox jumps over the lazy dog '
          'while a pack of hounds gives chase through the glen; '
          'reactive signals propagate invalidation downstream '
          'and slots recompute only when their dependencies change.');
    }, iterations: iterations ~/ 2),
    benchmark('reconcileDiff 100-entry list', () {
      // #lzdartreconcileidx — keyed reconciliation of a 100-entry list with a
      // scrambled order (exercises the common-key index lookup). prior/target
      // are built once outside the timed body so only the reconciliation runs.
      reconcileDiff(_prior100, _target100);
    }, iterations: iterations ~/ 2),
  ];
}

// Pre-built fixtures for the isolated benches above (constructed once at module
// load so the per-iteration measurement excludes their setup cost).
final _seqForOrdering = () {
  final seq = SeqCrdt<int, int>(1);
  for (var i = 0; i < 300; i++) {
    seq.insertBack(i, i, i);
  }
  return seq;
}();

final _prior100 = [
  for (var i = 0; i < 100; i++) MapEntry('k$i', i),
];
final _target100 = <MapEntry<String, int>>[
  for (var i = 99; i >= 0; i--) MapEntry('k$i', i),
];
