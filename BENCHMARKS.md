# lazily-dart Benchmarks

Wall-clock benchmarks for the lazily-dart hot paths. Two runnable programs:

- [`benchmark/micro_benchmark.dart`](benchmark/micro_benchmark.dart) surfaces
  the in-library `runBenchmarkSuite` scenarios
  ([`lib/src/instrumentation.dart`](lib/src/instrumentation.dart), exported via
  `package:lazily/ipc.dart`) — the reactive-core, collection, and CRDT
  micro-paths.
- [`benchmark/scale_benchmark.dart`](benchmark/scale_benchmark.dart) is the
  large-graph `scale` benchmark, replicating the lazily-rs `scale` group
  ([`scale.rs`][rs-scale]) and lazily-go
  ([`scale_bench_test.go`][go-scale]) on a spreadsheet-shaped graph.

Timing uses `Stopwatch` (`elapsedMicroseconds`). Treat the absolute numbers as
indicative — the shapes (relative costs, viewport-vs-full ratio, size scaling)
are what matter across runs; run-to-run variance on wall time is ±10–15%.

## Reproduce

```bash
# Micro-benchmarks (runBenchmarkSuite):
dart run benchmark/micro_benchmark.dart

# Scale — default N = 1,000,000 rows (~2M reactive nodes):
dart run benchmark/scale_benchmark.dart

# Scale at a specific size (N rows ⇒ N inputs + N formulas = 2N cells):
LAZILY_SCALE_N=1000000 dart run benchmark/scale_benchmark.dart
LAZILY_SCALE_N=5000000 dart run benchmark/scale_benchmark.dart  # Google Sheets 10M-cell workbook
LAZILY_SCALE_VIEWPORT=1000 dart run benchmark/scale_benchmark.dart
```

> The `dart` wrapper on this machine prints harmless Flutter-SDK stderr noise;
> pipe stderr to `/dev/null` (`2>/dev/null`) to see only the benchmark output.

## Hardware / environment

| | |
|---|---|
| CPU | AMD Ryzen 9 9950X3D (16 cores / 32 threads) |
| RAM | 186 GiB |
| OS | Linux 7.1.1 (CachyOS), x86-64 |
| Dart | 3.12.2 (stable) on `linux_x64` |

## Micro-benchmarks

Measured with `LAZILY_MICRO_ITERS=100000` (the runner warms the VM with a
tenth-scale pass first, so JIT steady-state is measured, not warmup). Each row
reports average time per iteration (µs) and throughput (ops/s). Every scenario
constructs its own `Context` inside the loop body, so the numbers include
scope + node allocation, not just the isolated operation — this matches the
`runBenchmarkSuite` definitions.

| Benchmark | µs/op | ops/s | What it measures |
|-----------|------:|------:|------------------|
| `Cell read/write` | 0.0512 | 19,527,436 | New `Context` + `Cell`, one guarded write, one read — the core mutation path. |
| `Slot recompute` | 0.2036 | 4,911,591 | Two cells + a dependent `Slot`; edit one cell, re-pull the slot (edge re-tracking + recompute). |
| `Memo equality guard (cache hit)` | 0.1540 | 6,495,615 | `Memo` recompute that yields an equal value, suppressing the downstream cascade. |
| `batch coalesce (10 cells)` | 2.1630 | 462,327 | 10 cell writes inside one `batch`, coalesced into a single invalidation pass, driving one `Effect`. |
| `CellMap insert + read` | 1.2240 | 817,013 | 10 keyed `CellMap` inserts + one read on the keyed collection. |
| `TextCrdt insert 100 chars` | 961.80 | 1,040 | Build a `TextCrdt` of 100 characters (Fugue/RGA ordering rebuilt per insert). |
| `SeqCrdt insert 100 elements` | 138.64 | 7,213 | Build a move-aware `SeqCrdt` of 100 elements (fractional-index positions + LWW registers). |

### Notes

- The reactive-core steady state (`Cell read/write`, `Slot recompute`, `Memo`)
  is sub-microsecond even with a fresh `Context` allocated every iteration —
  reads and equality-guarded writes are cheap.
- The CRDT builders (`TextCrdt`, `SeqCrdt`) measure *whole-document
  construction* (100 ops), not per-op cost — divide by 100 for per-insert.
  They are the heaviest paths because visible order is recomputed as a pure
  function of the element set on each mutation, matching the spec's determinism
  requirement.
- These are single-threaded micro-benchmarks. Dart has no shared-memory
  threads (isolates = separate heaps), so the concurrency surfaces are
  correctness-tested rather than benchmarked here.

## Scale (≥1M cells) — spreadsheet-shaped graph

Replicates the lazily-rs `scale` group ([`scale.rs`][rs-scale]) on a
spreadsheet-shaped graph: `N` input cells + `N` formula slots where
`formula[i] = input[i] + input[i-1]` (local fan-in, like a column of
`=A_i + A_{i-1}`). With the default `N = 1,000,000` that is **~2,000,000
reactive nodes**. Four scenarios cover the spreadsheet lifecycle:

- `build` — construct all 2N nodes (formulas lazy, not yet computed).
- `cold_full_recalc` — first read of every formula (forces every compute + edge-tracking).
- `viewport_recalc` — edit one input, read only a bounded viewport (the lazy-pull win).
- `full_recalc_invalidate_all` — touch every input, then read every formula (worst-case full-sheet edit).

> **A "cell count" here counts two cells per row** — the graph models a column
> of formulas `=A_i + A_{i-1}`, so each row is **one input cell `A_i` plus one
> formula cell**. `N` rows ⇒ `N` inputs + `N` formulas = `2N` cells. Per-cell
> figures divide the whole-pass wall time by `2N` (mirroring the lazily-go
> table).

### 1,000,000 rows (~2M cells)

| Benchmark | Time | Per cell | What it measures |
|-----------|-----:|---------:|------------------|
| `build` | 490 ms | ~245 ns | Construct all 2N nodes (formulas lazy, not yet computed). |
| `cold_full_recalc` | 573 ms | ~286 ns | First read of every formula — forces every compute + edge-tracking. |
| `viewport_recalc` | **32.8 µs** | — | Edit one input, read only a 1,000-cell viewport. ~17,000× cheaper than a full cold recalc. |
| `full_recalc_invalidate_all` | 782 ms | ~391 ns | Touch every input, then read every formula (worst-case full-sheet edit; avg of 3). |

### 5,000,000 rows (10M cells — a full Google Sheets workbook)

Google Sheets caps a workbook at **10,000,000 cells**. Modeled as 5,000,000
input cells + 5,000,000 formula cells (`LAZILY_SCALE_N=5000000`) — the full
10M-cell workbook ran to completion on this machine:

| Benchmark | Time | Per cell | What it measures |
|-----------|-----:|---------:|------------------|
| `build` | 2.50 s | ~250 ns | Build the full 10M-cell workbook. |
| `cold_full_recalc` | 4.02 s | ~402 ns | Compute all 5M formulas cold. |
| `viewport_recalc` | **29.5 µs** | — | Edit one input, read a 1,000-cell viewport. ~136,000× cheaper than a full cold recalc. |
| `full_recalc_invalidate_all` | 5.00 s | ~500 ns | Re-edit every input, recompute the whole workbook (avg of 3). |

So lazily-dart backs a **full-capacity Google Sheets workbook**: build ~2.5 s,
full cold recompute ~4 s, and a one-cell edit + bounded-viewport read stays in
the **~30 µs** range — because the lazy pull-based model leaves off-viewport
formulas dirty and never recomputes them (only ~2 formulas actually recompute
per edit, regardless of sheet size — the property a viewport-rendered
spreadsheet needs).

### Spreadsheet cell-count context

| Spreadsheet | Documented limit | Cells |
|-------------|------------------|------:|
| Google Sheets | 10,000,000 cells per workbook (18,278 columns max) | 10,000,000 |
| Microsoft Excel | 1,048,576 rows × 16,384 columns per worksheet | 17,179,869,184 |

The `LAZILY_SCALE_N=5000000` run above covers a full Google Sheets workbook. A
grid-complete Excel worksheet (17 billion cells) is unrepresentative — real
sheets populate a tiny fraction of the grid, and lazily stores only the cells
you create, so the `scale` group measures the populated-cell path that matters.

### A note on viewport scaling

lazily-dart's viewport recalc is **effectively size-independent**: ~32.8 µs at
2M cells and ~29.5 µs at 10M cells (the small difference is run-to-run noise,
not a size trend). The lazy pull-based model recomputes only the ~2 formulas
that actually depend on the edited input; the other ~998 viewport reads are
identity-cache hits. Dart's `Map.identity` keeps those lookups O(1) without the
cache/TLB degradation lazily-go reported at 10M cells (where its single big Go
map grew per-lookup latency from ~25 µs to ~103 µs). So lazily-dart's flat
viewport curve tracks lazily-rs's slotmap behavior more closely than
lazily-go's. Reported as measured — the point is that a one-cell edit plus a
bounded-viewport read never touches off-viewport formulas, so it stays cheap
(~30 µs, **~136,000× cheaper than a full recalc** at 10M cells) no matter how
large the sheet grows.

[rs-scale]: https://github.com/lazily-hub/lazily-rs/blob/main/benches/scale.rs
[go-scale]: https://github.com/lazily-hub/lazily-go/blob/main/scale_bench_test.go
