# lazily (Dart)

Lazy reactive primitives for Dart — the **Cell kernel** (`Source`, `Computed`,
`Effect`) with automatic dependency tracking and cache invalidation. Pure Dart:
Flutter, web, and native.

A port of the lazily reactive family ([`lazily-rs`][rs], [`lazily-py`][py],
[`lazily-js`][js], [`lazily-zig`][zig]).

## The Cell kernel (v2)

**Cell** is the value-bearing *node concept* — a reactive that holds a readable
value. It is not a type: there is no `Cell<T, K>` genus. The two concrete *cell*
handles are what a caller holds (`#lzcellkernel`):

- **`Source<T>`** — a value written from *outside* (`get` / `set` / `merge`); the
  writable kind. Construct with `source(ctx, v)` or `Source<T>(ctx, v)`. A
  `MergeCell` is a `Source` whose write folds under a policy
  (`Source ≡ MergeCell(KeepLatest)`). `Cell` is retained as a compatibility
  spelling of `Source`.
- **`Computed<T>`** — a value computed from *upstream* (`get`, `.eager()`,
  `.lazy()`, `isEager`). Construct with `computed(ctx, f)`; **guarded, always** —
  an equal recompute (`==`) suppresses the downstream cascade (TC39
  `Signal.Computed`). Lazy by default; make it *eager* with
  `computed(ctx, f).eager()`, which re-materializes immediately on every upstream
  change.
- **`Effect`** — a value-less sink, outside the cell hierarchy; nothing can
  depend on it.

`Slot` is retained as the lower-level storage/computation position and the
**unguarded** callable lazy computed — reach for it when a value is not
`==`-comparable or the guard is unwanted. There is **no separate `memo` kind**:
the equality guard folded into `Computed`. Dart has **no compile-time read/write
split**: the kind is convention — a `Source` has `set` / `merge`, a `Computed`
does not.

Values are **lazy by default**. When you need eager push-style semantics, call
`computed(ctx, f).eager()`. There is no `Signal` compatibility constructor.

## Usage

```dart
import 'package:lazily/lazily.dart';

final ctx = Context();
final a = Cell<int>(ctx, 2);
final b = Cell<int>(ctx, 3);

// Lazy: computes on first read, caches, recomputes only when a or b changes.
final sum = Slot<int>(ctx, (_) => a.value + b.value);
print(sum()); // 5

a.value = 10;
print(sum()); // 13

// A guarded, lazy derived value.
final label = computed(ctx, (_) => 'sum=${sum()}');
print(label.value); // sum=13

// Eager: `.eager()` re-materializes immediately when a dependency changes.
final parity = computed(ctx, (_) => a.value.isEven ? 'even' : 'odd').eager();
print(parity.value); // even
a.value = 11;
print(parity.value); // odd (already updated before the read)
```

Side effects — the hook for Flutter `ValueNotifier` bridges and `setState`
wrappers — are declared as an `Effect`. A `Cell` has no listener registry: an
effect observes through a real dependency edge, so it batches and stays
glitch-free with the rest of the graph.

```dart
final count = Cell<int>(ctx, 0);
final effect = Effect(ctx, (_) {
  print('now ${count.value}');
  return null;
}); // prints "now 0"
count.value = 1; // prints "now 1"
effect.dispose();
```

When a consumer genuinely needs a stream of *every* transition rather than the
settled value, publish to a `Topic` — that is the stream primitive, and it
survives batching by design.

## Competing-consumer work queue

`WorkQueueCell<T>` provides exclusive FIFO claims, visibility deadlines,
worker-scoped acknowledgements, tail retries, and bounded dead-letter handling.
Item ids remain stable across retries; each claim gets a fresh delivery id.

```dart
final work = WorkQueueCell<String>(
  ctx,
  visibilityTimeout: 10,
  maxDeliveries: 3,
);
work.push('job');
final delivery = work.claim('worker-a', 100)!;
assert(work.ack('worker-a', delivery.deliveryId));
```

## Context

All reactives that react to each other must share a `Context`. The context
holds an identity-keyed cache and the computation stack used for automatic
dependency tracking. One context per reactive graph is the contract.

## State machine

`StateMachine` is a finite state machine backed by a `Cell`, so any slot or
signal that reads `state` is invalidated on transition:

```dart
final m = StateMachine<String, String>(
  ctx, 'Red',
  (s, e) => e == 'advance'
      ? const {'Red': 'Green', 'Green': 'Yellow', 'Yellow': 'Red'}[s]
      : null,
);
m.send('advance'); // true -> 'Green'
```

## State chart

`StateChart` is a full Harel/SCXML **hierarchical** state machine — the native
counterpart of [`lazily-formal`][formal]'s `LazilyFormal.StateChart` and
lazily-rs's / lazily-kt's state charts. It is **compute, not protocol**: it is
never serialized as a distinct wire kind. The active configuration lives in a
`Cell`, so any slot or signal reading `configuration`, `activeLeaves`, or
`matches` is invalidated on a real transition; a no-op (configuration
unchanged) is suppressed by the cell's structural-equality guard.

`send` is deterministic by construction — a total function of
`(chart, configuration, history, guards, event)`, mirroring the Lean
`StateChart.send`. A chart is built from the declarative JSON form
(`lazily-spec/docs/state-charts.md`) via `ChartDef.fromJson`.

Implemented subset (per the spec's implementation-status note): compound
(hierarchical) states with default initial descent, orthogonal (parallel)
regions, shallow **and** deep history (record-on-exit / restore-on-enter),
entry/exit/transition actions (exit innermost-first → transition → entry
outermost-first), named guards resolved at `send` time (fail-closed), and
external + internal transitions. `run` actions and `{"expr": …}` context
guards are rejected explicitly. `final` states are accepted as leaves without
raising completion (`done`) events, matching lazily-py and lazily-kt.

```dart
import 'package:lazily/lazily.dart';

final def = ChartDef.fromJson({
  'initial': 'on',
  'states': {
    'root': {'initial': 'on'},
    'on': {
      'parent': 'root', 'initial': 'playing',
      'on': {'toggle': 'off'},           // handled by 'on', bubbles from a child
    },
    'playing': {'parent': 'on', 'on': {'pause': 'paused'}},
    'paused':  {'parent': 'on', 'on': {'play': 'playing'}},
    'off':     {'parent': 'root', 'on': {'toggle': 'on'}},  // re-enters -> 'playing'
  },
});
final chart = StateChart(ctx, def);

chart.activeLeaves();            // ['playing']
chart.send('toggle');            // true; off -> on -> playing (initial)
chart.matches('on');             // true
chart.lastActions();             // exit → transition → entry actions
```

## Conformance

lazily-dart replays the shared [`lazily-spec`][spec] conformance fixtures:

- State-chart fixtures mirrored into `test/conformance/statechart/` are
  replayed by `test/statechart_conformance_test.dart`, asserting `accepted`,
  `active`, `matches`, and `actions` identically to every other binding
  (lazily-rs / lazily-kt / lazily-py / lazily-zig / lazily-js). When the
  sibling `lazily-spec` checkout is present on disk, the canonical fixtures are
  preferred, so this harness also guards against cross-family drift.
- The reactive-source families — temporal (`#lztime`), rate-shaping
  (`#lzrateshape`), membership + phi-accrual (`#lzmemb`), coordination
  (`#lzcoord`), presence (`#lzpresence`), windowing (`#lzwindow`), resilience
  (`#lzresilience`), and the embedded-service plane (`#lzservice`) — mirror
  `test/conformance/{temporal,rateshape,membership,coordination,presence,windowing,resilience,service}/`
  and are replayed by the matching `test/*_conformance_test.dart`, asserting op
  returns, the projected reader value, and per-step reader invalidation
  (`invalidates`) — a reader recomputes only when its projected value actually
  changes.

### Formal model (`lazily-formal`)

`dart test` also builds the [`lazily-formal`][formal] Lean 4 model — the
executable reference behind the state-chart fixtures and the deterministic
`send` lazily-dart inherits. `tool/formal_check.dart` runs `lake build` over
the sibling `lazily-formal` checkout (located via the `LAZILY_FORMAL_PATH` env
var, then the `src/lazily-dart` ↔ `src/lazily-formal` submodule layout); it
SKIPs gracefully when the submodule or the `lake` toolchain is absent — so
pub.dev consumers and shallow clones are not broken. CI uses a full checkout +
[elan](https://github.com/leanprover/lean-action), so the proofs are verified
for real there.

Each lazily-formal module that has a Dart counterpart has a matching
property test that names the universal theorem it mirrors — the guarantees no
finite fixture suite can establish:

| lazily-formal module | Dart test file | Mirrored theorems |
|----------------------|----------------|-------------------|
| `StateMachine` / `StateChart` | `test/statechart_properties_test.dart` | `enabled_empty_rejects`, `send_preserves_chart`, determinism-by-construction, `single_region_refines_flat_machine`, `single_region_enabled_at_most_one`, `parallel_region_confluence`, `recordHistory_idempotent`, `send_actions_empty_when_rejected` |
| `Reactive` | `test/reactive_properties_test.dart` | `setCell_equal_preserves_graph`, `setCell_different_invalidates_dependents`, `recomputeSlot_equal_preserves_dependents`, `recomputeSlot_different_invalidates_dependents`, `signal_materialized_after_recompute` |
| `ThreadSafe` | `test/thread_safe_test.dart` | `flushBatch_singleton_eq_setCell`, `flushBatch_dependent_dirty`, `flushBatch_preserves_nondependent_dirty`, coalesced-frontier dedup |
| `Materialization` | `test/thread_safe_reactive_family_test.dart` | `materialize_present_comm`, `materialize_observe_comm` (confluence), `materialize_preserves_observe` |
| `AsyncMaterialization` | `test/async_reactive_family_test.dart` | `eventual_transparency`, `async_resolved_matches_sync`, `observe_pending_is_none`, `cell_resolved_at_build`, `resolve_monotone` |
| `FamilySync` | `test/familysync_conformance_test.dart` | `applyOp_absent_adopts`, `present_merge`, `applyOp_idem`, `aggregate_converges` |

## lazily-spec IPC

The `package:lazily/ipc.dart` library implements the language-agnostic
lazily-spec wire protocol (`Snapshot`, `Delta`, `NodeState`, ...) so a Dart
graph's state can be mirrored to remote observers across processes and
languages. It round-trips the canonical fixtures from
[`lazily-spec`][spec]/`conformance/`.

### The wire on a JavaScript target

**The IPC surface is a supported web target**, and `make check` proves it:
`tool/ipc_browser_check.dart` compiles `package:lazily/ipc.dart` with
`dart compile js` and runs the result under Node on every build and in CI. That
gate is newer than the surface it guards — until it landed, the wire did not
compile to JavaScript at all, because dart2js rejects an integer literal above
2^53 - 1 and the FNV-1a and SplitMix64 constants were spelled as literals. The
older `tool/stdlib_browser_check.dart` passed the whole time; it imports
`package:lazily/stdlib.dart` and covers none of the protocol.

Support comes with one rule, and it is the same on both codecs: **a value this
runtime cannot represent is refused, never rounded.** Dart's `int` is 64 bits on
the VM and an IEEE-754 double everywhere else, and `jsonDecode` rounds
`9007199254740993` to `...992` without an error — a corrupted node id that
decodes cleanly is undetectable downstream. So:

- On the VM, `NodeId`/`PeerId` values above 2^53 round-trip exactly, as
  protocol.md § NodeId / PeerId allows. Nothing is refused.
- On a JavaScript target, a frame carrying such a value is rejected with a
  `FormatException`. Everything at or below 2^53 - 1 decodes normally, including
  a small value a peer chose to carry in a wide `uint64` tag.
- `contentHash` returns the packed 64-bit digest and therefore throws
  `UnsupportedError` on a JavaScript target. Use `contentHashHex`, which is the
  `c:` wire form and is exact everywhere; `BlockKey.content` takes that hex.

Every 64-bit constant and operation in this package lives in
`lib/src/u64.dart` as 32-bit halves, so hashes and the SplitMix64 sampler
produce identical results on the VM and in a browser rather than one answer per
runtime.

## Feature coverage

The full `lazily` capability set across every binding. Legend: ✅ shipped ·
`~` partial · `—` absent or not applicable. The canonical matrix with per-cell
notes and platform carve-outs lives in
[`lazily-spec` § Cross-Language Coverage](https://github.com/lazily-hub/lazily-spec/blob/main/docs/coverage.md).

<!-- coverage-table:start -->
| Feature | Rust | Python | Kotlin | JS | Dart | Zig | Go | C++ | C# |
| --------- | :----: | :------: | :------: | :--: | :----: | :---: | :--: | :---: | :--: |
| Reactive graph [^reactive-graph] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Keyed-map materialization [^keyed-map-materialization] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Thread-safe keyed map [^thread-safe-keyed-map] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Async keyed map [^async-keyed-map] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Keyed-map sync [^keyed-map-sync] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Thread-safe context [^thread-safe-context] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Async reactive context [^async-reactive-context] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Flat state machine [^flat-state-machine] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Harel state charts [^harel-state-charts] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Keyed reactive maps [^keyed-reactive-maps] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| ReactiveMap core — single-threaded [^reactivemap-core-single-threaded] | ✅ | ✅ | ✅ | ✅ | ✅ | ~ | ✅ | ✅ | ✅ |
| ReactiveMap core — thread-safe [^reactivemap-core-thread-safe] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| ReactiveMap core — async [^reactivemap-core-async] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Exact-key dependency availability [^exact-key-dependency-availability] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Atomic ordered move [^atomic-ordered-move] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Memoized semantic tree [^memoized-semantic-tree] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Stable-id alignment [^stable-id-alignment] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Reactive queue core — single-threaded [^reactive-queue-core-single-threaded] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Reactive queue core — thread-safe [^reactive-queue-core-thread-safe] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Reactive queue core — async [^reactive-queue-core-async] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Broadcast topic core — single-threaded [^broadcast-topic-core-single-threaded] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Broadcast topic core — thread-safe [^broadcast-topic-core-thread-safe] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Broadcast topic core — async [^broadcast-topic-core-async] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Work queue core — single-threaded [^work-queue-core-single-threaded] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Work queue core — thread-safe [^work-queue-core-thread-safe] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Work queue core — async [^work-queue-core-async] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Merge algebra [^merge-algebra] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| RelayCell [^relaycell] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Free-text character CRDT [^free-text-character-crdt] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| TextCrdt delta sync [^textcrdt-delta-sync] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| CrdtTree lossless document [^crdttree-lossless-document] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Move-aware sequence CRDT [^move-aware-sequence-crdt] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Lossless tree CRDT core [^lossless-tree-crdt-core] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Lossless tree — anti-entropy [^lossless-tree-anti-entropy] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Lossless tree — merge convergence [^lossless-tree-merge-convergence] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Registers (LWW/MV) + PnCounter [^registers] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| IPC wire — Snapshot/Delta/CrdtSync [^ipc-wire] | ✅ | ✅ | ✅ | ✅ | ~ | ✅ | ✅ | ✅ | ✅ |
| Frame codec — json [^frame-codec-json] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Frame codec — msgpack [^frame-codec-msgpack] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Frame codec — postcard [^frame-codec-postcard] | ✅ | — | — | — | — | — | — | — | — |
| NodeId/PeerId exact-representation [^nodeid-peerid-exact-representation] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| NodeKey null-leniency [^nodekey-null-leniency] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Shared-memory blob path [^shared-memory-blob-path] | ✅ | ✅ | ✅ | ~ | ~ | ✅ | ✅ | ~ | ✅ |
| Cross-process zero-copy transport [^cross-process-zero-copy-transport] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Distributed CRDT plane [^distributed-crdt-plane] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Reliable sync [^reliable-sync] | ~ | ~ | ~ | ~ | ~ | ~ | ~ | ~ | ~ |
| Storage-independent durable outbox [^storage-independent-durable-outbox] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Reliable-sync transport seam [^reliable-sync-transport-seam] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Distributed plane — WebRTC [^distributed-plane-webrtc] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| State projection / mirror [^state-projection-mirror] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Causal receipts [^causal-receipts] | ~ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Message-passing + RPC command plane [^message-passing-rpc-command-plane] | ✅ | ✅ | ✅ | ✅ | ✅ | ~ | ✅ | ✅ | ✅ |
| C-ABI FFI boundary [^c-abi-ffi-boundary] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Permission boundary [^permission-boundary] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Capability negotiation [^capability-negotiation] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Instrumentation / benchmarks [^instrumentation-benchmarks] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Temporal sources [^temporal-sources] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Rate-shaping operators [^rate-shaping-operators] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Membership + failure detection [^membership-failure-detection] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Distributed coordination [^distributed-coordination] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Presence + ephemeral plane [^presence-ephemeral-plane] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Stream windowing [^stream-windowing] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Fault tolerance [^fault-tolerance] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Portable stdlib Timer [^portable-stdlib-timer] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Portable stdlib Timeout [^portable-stdlib-timeout] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Portable stdlib RevisionBarrier [^portable-stdlib-revision-barrier] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Embedded-service plane [^embedded-service-plane] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Reactive ingress [^reactive-ingress] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Ingress — thread-safe [^ingress-thread-safe] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Ingress — async [^ingress-async] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |

[^reactive-graph]: Reactive graph — two cell kinds (nodes `SourceCell` / `ComputedCell`; handles `Source<T, M>` / `Computed<T>`) + `Effect` sink + eager `Computed` (`computed().eager()`) / all cells guarded / batch
[^keyed-map-materialization]: Keyed-map materialization (`ComputedMap`) — mint-on-access derived slots: transparency + deferral (`#lzmatmode`)
[^thread-safe-keyed-map]: Thread-safe keyed map (`ThreadSafeComputedMap`) — `Send + Sync` + materialization confluence (`#lzmatmode`)
[^async-keyed-map]: Async keyed map (`AsyncComputedMap`) — eventual transparency (`#lzmatmode`)
[^keyed-map-sync]: Keyed-map sync — membership propagation + materialize-on-ingest + derived-aggregate transparency (`#lzfamilysync`)
[^thread-safe-context]: Thread-safe context (lock-backed)
[^async-reactive-context]: Async reactive context
[^flat-state-machine]: Flat state machine
[^harel-state-charts]: Harel state charts
[^keyed-reactive-maps]: Keyed reactive maps (`ReactiveMap`: `SourceMap` / `ComputedMap`) + `SourceTree` + reconcile
[^reactivemap-core-single-threaded]: `ReactiveMap` **Core surface** — single-threaded flavor (cell-model.md § Core surface vs. binding extensions)
[^reactivemap-core-thread-safe]: `ReactiveMap` **Core surface** — thread-safe flavor (ordering + membership reactivity)
[^reactivemap-core-async]: `ReactiveMap` **Core surface** — async flavor (ordering + membership reactivity)
[^exact-key-dependency-availability]: Exact-key dependency availability (`DependencyMap`: observe before publish, unrelated-key isolation, stable identity; `#lzdependencyavailability`)
[^atomic-ordered-move]: Atomic ordered move replayed against **all three flavors** (`cellmap_atomic_move` + `cellmap_independence`)
[^memoized-semantic-tree]: Memoized semantic tree (`SemTree`)
[^stable-id-alignment]: Stable-id alignment (manufactured identity)
[^reactive-queue-core-single-threaded]: Reactive queue (`QueueCell` SPSC/MPSC + `QueueStorage` adapter) **Core surface** — single-threaded flavor
[^reactive-queue-core-thread-safe]: Reactive queue (`QueueCell` SPSC/MPSC + `QueueStorage` adapter) **Core surface** — thread-safe flavor (reader kinds + closure lifecycle)
[^reactive-queue-core-async]: Reactive queue (`QueueCell` SPSC/MPSC + `QueueStorage` adapter) **Core surface** — async flavor (reader kinds + eventual transparency)
[^broadcast-topic-core-single-threaded]: Broadcast topic (`TopicCell`) **Core surface** — single-threaded flavor — independent cursors + durable replay + safe GC (`#lztopiccell`)
[^broadcast-topic-core-thread-safe]: Broadcast topic (`TopicCell`) **Core surface** — thread-safe flavor (reader kinds + closure lifecycle)
[^broadcast-topic-core-async]: Broadcast topic (`TopicCell`) **Core surface** — async flavor (reader kinds + eventual transparency)
[^work-queue-core-single-threaded]: Competing-consumer work queue (`WorkQueueCell`) **Core surface** — single-threaded flavor — exclusive leases + ack/nack + redelivery + DLQ (`#lzworkqueue`)
[^work-queue-core-thread-safe]: Competing-consumer work queue (`WorkQueueCell`) **Core surface** — thread-safe flavor (reader kinds + closure lifecycle)
[^work-queue-core-async]: Competing-consumer work queue (`WorkQueueCell`) **Core surface** — async flavor (reader kinds + eventual transparency)
[^merge-algebra]: Merge algebra + `Source<T, M>` — associative `MergePolicy` (`KeepLatest`/`Sum`/`Max`/`SetUnion`/`RawFifo`), `Cell ≡ Source<KeepLatest>`, read-any-cell/write-`Source` split (`#relaycell`)
[^relaycell]: RelayCell — conflating relay + `BackpressurePolicy` + `SpillStore` + `Transport` + Inbox/Outbox + Rate/Window/Expiry/Priority/keyed policies (`#relaycell`)
[^free-text-character-crdt]: Free-text character CRDT (`TextCrdt`)
[^textcrdt-delta-sync]: `TextCrdt` delta sync (`version_vector` / `delta_since` / `apply_delta`)
[^crdttree-lossless-document]: `CrdtTree` lossless document contract (`#lzcrdttree`)
[^move-aware-sequence-crdt]: Move-aware sequence CRDT (`SeqCrdt`)
[^lossless-tree-crdt-core]: Lossless tree CRDT core (`LosslessTreeCrdt`, M1)
[^lossless-tree-anti-entropy]: Lossless tree — dotted-frontier anti-entropy
[^lossless-tree-merge-convergence]: Lossless tree — concurrent merge convergence
[^registers]: Registers (LWW / MV) + `PnCounter` + `CellCrdt`
[^ipc-wire]: IPC wire — `Snapshot` + `Delta` + `CrdtSync`
[^frame-codec-json]: Frame codec — `json` **reference codec**: dependency-free interop floor, FFI baseline form, byte-canonical (**MUST**) — executable round-trip obligation (`conformance/codec/frame_roundtrip_json.json`, `#lzmsgpackparity`)
[^frame-codec-msgpack]: Frame codec — `msgpack` **cross-language binary default**: externally-tagged frame over named-field maps, semantic (not byte-identical) round-trip (**MUST**) — executable round-trip obligation (`conformance/codec/frame_roundtrip_msgpack.json`, `#lzmsgpackparity`). Shipping *a* MessagePack codec does not earn this mark: lazily-cpp read `~` here while its private internally-tagged framing wore the token, and only flipped once it shipped the spec wire (`#lzcppmsgpackwire`)
[^frame-codec-postcard]: Frame codec — `postcard` positional same-schema fast path: smallest + byte-canonical, not cross-language (**MAY**)
[^nodeid-peerid-exact-representation]: `NodeId` / `PeerId` exact-representation bound (**MUST**) — a decoder that cannot represent a received identifier exactly rejects the frame rather than rounding it (`conformance/codec/nodeid_exact_range.json`, `#lzspecdecoderbound`). A binding's exact range MAY be narrower than the `u64` wire type; ✅ means it refuses outside that range instead of substituting a neighbouring id, not that it carries the full `u64`. Exact ranges: full `u64` in Rust / Zig / C#, unbounded in Python, `[0, 2^63)` in Kotlin / Go / C++, `[0, 2^53)` in JS, and platform-split in Dart (63-bit on the VM, 53-bit on web). protocol.md stated only the PRODUCER half until this audit, and two C++ decoders were substituting rather than refusing.
[^nodekey-null-leniency]: `NodeKey` null-leniency on decode (**MUST**) — omit-when-absent binds the ENCODER; a decoder reads both an omitted `key` and an explicit `key: null` as absent, refusing neither and constructing a key from neither (`conformance/codec/nodekey_null_leniency.json`, `#lzkeynullstrict`). Replayed on BOTH optional-key sites (`NodeSnapshot`, the `NodeAdd` delta op) in both codecs, and the fixture pins the RE-ENCODED field set as well: reading null as absent and writing it back out is a correct decode with a non-conforming encoder. Before the audit lazily-py and lazily-zig refused the null form, and lazily-kt decoded it into a real key named `null` — all three had the same field right on `CrdtOp`, in the same file.
[^shared-memory-blob-path]: Shared-memory blob path (`ShmBlobArena`)
[^cross-process-zero-copy-transport]: Cross-process zero-copy transport (`BlobBackend` / shm / arrow)
[^distributed-crdt-plane]: Distributed CRDT plane (`CrdtPlaneRuntime` / anti-entropy)
[^reliable-sync]: Reliable sync — resync coordinator + at-least-once durable outbox + OR-set/LWW liveness (`#lzsync`)
[^storage-independent-durable-outbox]: Storage-independent durable outbox (`OutboxStore` + shared outbox protocol; SQLite/Room/IndexedDB/file adapters)
[^reliable-sync-transport-seam]: Reliable-sync transport seam + full-duplex `SyncDriver` loop (`IpcSink`/`IpcSource`, `#sync-driver`)
[^distributed-plane-webrtc]: Distributed plane — WebRTC transport + signaling
[^state-projection-mirror]: State projection / mirror
[^causal-receipts]: Causal receipts (`CausalReceipts` outcome projection)
[^message-passing-rpc-command-plane]: Message-passing + RPC command plane (`command-plane-v1`)
[^c-abi-ffi-boundary]: C-ABI FFI boundary
[^permission-boundary]: Permission boundary (`PeerPermissions` / `RemoteOp`)
[^capability-negotiation]: Capability negotiation (`SessionHandshake`)
[^instrumentation-benchmarks]: Instrumentation / benchmarks
[^temporal-sources]: Temporal sources — `TimerCell` / `IntervalCell` / `CronCell` / `DeadlineCell` over a logical clock (`#lztime`)
[^rate-shaping-operators]: Rate-shaping operators — `DebounceCell` / `ThrottleCell` / `SampleCell` / `ProbabilisticSampleCell` (`#lzrateshape`)
[^membership-failure-detection]: Membership + failure detection — `MembershipCell` (SWIM + Phi-accrual) / `PeerSet` / `PeerChangeEvent` (`#lzmemb`)
[^distributed-coordination]: Distributed coordination — `LeaseCell` / `LeaderCell` / `LockCell` / `SemaphoreCell` / `BarrierCell`+`QuorumCell` (`#lzcoord`)
[^presence-ephemeral-plane]: Presence + ephemeral plane — `PresenceCell` / `AwarenessCell` / `EphemeralCell` + `Ephemeral`/`Durable` markers (`#lzpresence`)
[^stream-windowing]: Stream windowing — `TumblingWindow` / `SlidingWindow` / `SessionWindow` over the merge algebra (`#lzwindow`)
[^fault-tolerance]: Fault tolerance — `CircuitBreakerCell` / `RetryPolicyCell` / `BulkheadCell` / `TimeoutCell` (`#lzresilience`)
[^portable-stdlib-timer]: Portable stdlib `Timer` (`stdlib_timer_v1`) — canonical fixture + mutation-gate verified
[^portable-stdlib-timeout]: Portable stdlib caller-driven `Timeout<T>` (`stdlib_timeout_v1`) — distinct from reactive `TimeoutCell`
[^portable-stdlib-revision-barrier]: Portable stdlib `RevisionBarrier` (`stdlib_revision_barrier_v1`) — register/recheck lost-wakeup guard
[^embedded-service-plane]: Embedded-service plane — `HealthCell` / `ReadinessCell` / `DiscoveryCell` / `ServiceRegistry` (`#lzservice`)
[^reactive-ingress]: Transport-agnostic reactive ingress (`IngressCell`) — keyed lifecycle scopes, generation/sequence/freshness envelopes, reorder buffer, accepted/dropped/error receipt readers (`#designimplementtransport`)
[^ingress-thread-safe]: Ingress family — `Send + Sync` flavor (`ThreadSafeIngressCell`): one frontier walk per admission (`#designimplementtransport`)
[^ingress-async]: Ingress family — async flavor (`AsyncIngressCell`): admission is not async-coloured (`#designimplementtransport`)
<!-- coverage-table:end -->

## Benchmarks

Wall-clock benchmarks live in [`BENCHMARKS.md`](BENCHMARKS.md), with two
runnable programs:

- **Micro-benchmarks** — the in-library `runBenchmarkSuite` reactive-core,
  collection, and CRDT paths (`Source`/`Slot`/`Computed`/`batch`/`SourceMap`/
  `TextCrdt`/`SeqCrdt`). The reactive-core steady state is sub-microsecond per op.
- **Scale** — a spreadsheet-shaped graph (`N` input cells + `N` formula slots,
  `formula[i] = input[i] + input[i-1]`) replicating the lazily-rs `scale` group
  and lazily-go. It runs a **full 10M-cell Google Sheets workbook**
  (`N = 5,000,000`): build ~2.5 s, full cold recompute ~4 s, and a one-cell edit
  + bounded-viewport read stays **size-independent at ~30 µs** (~136,000×
  cheaper than a full recalc) — only the ~2 dependent formulas recompute.

```bash
dart run benchmark/micro_benchmark.dart
dart run benchmark/scale_benchmark.dart                          # N = 1,000,000 (~2M nodes)
LAZILY_SCALE_N=5000000 dart run benchmark/scale_benchmark.dart   # 10M cells (Google Sheets workbook)
```

See [`BENCHMARKS.md`](BENCHMARKS.md) for the measured results, hardware, and
methodology.

## Status

**Full feature parity on the Dart platform** — every row of the lazily-spec
cross-language matrix is shipped (`✅`), including the concurrency layers.

Dart isolates have no shared mutable heap, so the "thread-safe" layers are
realized the same way JavaScript ships them on its single-realm event loop:
within an isolate, synchronous code runs to completion and already serializes
access, so `ThreadSafeContext` / `ThreadSafeReactiveMap` use a **reentrant
run-to-completion guard** and the deterministic batch-coalescing kernel proven
equivalent to `LazilyFormal.ThreadSafe`. Genuine cross-isolate parallelism is
served by (a) `TransferableTypedData` for the **zero-copy shared-memory blob
path** (`ShmBlobArena.transfer`, a zero-copy move — Dart's isolate-model
counterpart of `mmap`/`SharedArrayBuffer`) and (b) the CRDT wire protocol for
replicated state — reconciled with materialization confluence under real
multi-isolate workloads (`test/shm_isolate_test.dart`).

| Layer | Where |
|-------|-------|
| Reactive core — Cell kernel v2 (`Source`/`Cell` / `Computed`+`computed`/`.eager()`/`.lazy()` / `Effect` / `Slot` (unguarded) / `batch`; no `Signal` compatibility constructor) | `package:lazily/lazily.dart` |
| Keyed cell collections (`ReactiveMap` / `SourceMap` / `ComputedMap` / `SourceTree` / reconciliation) | `package:lazily/lazily.dart` |
| Flat state machine + Harel state charts | `package:lazily/lazily.dart` |
| TextCrdt (char CRDT) + delta sync | `package:lazily/lazily.dart` |
| SeqCrdt (move-aware sequence CRDT) + Hlc + LwwRegister | `package:lazily/lazily.dart` |
| Lossless tree CRDT (`LosslessTreeCrdt` M1 + dotted-frontier delta sync) | `package:lazily/lazily.dart` |
| Registers (MV / PnCounter / CellCrdt) | `package:lazily/lazily.dart` |
| SemTree (memoized semantic tree) | `package:lazily/lazily.dart` |
| Stable-id alignment | `package:lazily/lazily.dart` |
| Async reactive context | `package:lazily/async_context.dart` |
| Queue family across sync / thread-safe / async (`QueueCell` / `TopicCell` / `WorkQueueCell`) | `package:lazily/lazily.dart` |
| Transport-agnostic reactive ingress across sync / thread-safe / async (`IngressCore` + `IngressCell` / `ThreadSafeIngressCell` / `AsyncIngressCell`, `#designimplementtransport`) | `package:lazily/lazily.dart` |
| Keyed reactive map materialization (`ComputedMap` lazy `getOrInsertWith` / eager `materializeAll`, `#reactivemap`) | `package:lazily/lazily.dart` |
| Thread-safe context + reactive map (`ThreadSafeContext` / `ThreadSafeReactiveMap` / `ThreadSafeSourceMap` / `ThreadSafeComputedMap`) | `package:lazily/lazily.dart` |
| Async reactive map (`AsyncReactiveMap` / `AsyncSourceMap` / `AsyncComputedMap`) | `package:lazily/lazily.dart` |
| Reactive family sync (`#lzfamilysync`, materialize-on-ingest) | `package:lazily/ipc.dart` |
| IPC (`Snapshot` + `Delta` + `CrdtSync`) | `package:lazily/ipc.dart` |
| Distributed CRDT plane (`CrdtPlaneRuntime` / anti-entropy) | `package:lazily/ipc.dart` |
| Causal receipts (`CausalReceipt` / `ReceiptProjection`) | `package:lazily/ipc.dart` |
| Command/RPC message plane (`CommandSubmit`/`Cancel`/`Events`/`Projection` + `CommandRpcClient`) | `package:lazily/ipc.dart` |
| Signaling (`SignalingRoom` / `ClientMessage` / `ServerMessage`) | `package:lazily/ipc.dart` |
| State projection / mirror (`StateProjectionMirror`) | `package:lazily/ipc.dart` |
| ShmBlobArena (blob arena + header validation + zero-copy cross-isolate transfer) | `package:lazily/ipc.dart` |
| C-ABI FFI boundary (`LazilyFfi*`, `CrdtSync = 3`) | `package:lazily/ffi.dart` |
| Permission boundary (`RemoteOp` / `PeerPermissions`) | `package:lazily/ipc.dart` |
| Capability negotiation | `package:lazily/capability.dart` |
| Instrumentation (`benchmark` / `runBenchmarkSuite`) | `package:lazily/ipc.dart` |
| Formal model verification (`lazily-formal` Lean proofs in `dart test`) | `tool/formal_check.dart` + `test/formal_check_test.dart` |

## Keyed cell collections

There is **one** keyed primitive, `ReactiveMap<K, V, H>`, generic over the
entry's handle kind `H`, with two specializations (`#reactivemap`):

- `SourceMap<K, V>` = `ReactiveMap<K, V, Cell<V>>` — **input-cell** entries; adds
  cell-only `set` plus eager value-minting (`entry` / `entryWith`).
- `ComputedMap<K, V>` = `ReactiveMap<K, V, Computed<V>>` — guarded derived entries;
`getOrInsertWith` mints a computed on first access (**lazy materialization**),
`materializeAll` pre-mints the keyset (**eager**). Its value is derived,
  so `ComputedMap` has **no `set`**, and there is **no eager/lazy mode flag**.

The shared surface (`getOrInsertWith` / `remove` / `move*` / membership / order /
`keys` / `len` / `containsKey`) lives on `ReactiveMap`.

`SourceMap<K, V>` is a **composition of cells**, not a new cell kind. Each entry
is an ordinary `Cell`; a dedicated membership cell tracks the key set, and a
dedicated order cell tracks the ordered key list, so the three reactivity
planes are independent:

- writing one entry's value invalidates **only** that entry's value readers;
- adding/removing a key invalidates membership readers (`len` / `containsKey`)
  and order readers (`keys`), but **not** unrelated entry value readers;
- a pure reorder (atomic move) invalidates order readers only.

```dart
final ctx = Context();
final scores = SourceMap<String, int>(ctx)
  ..set('alice', 10)
  ..set('bob', 20);

final leaderboard = Slot<List<String>>(ctx, (_) => scores.keys());
leaderboard(); // ['alice', 'bob']

scores.moveTo('bob', 0);
leaderboard(); // ['bob', 'alice']  — recomputed (order changed)
```

`reconcileDiff` is the move-minimized keyed reconciliation (`#lzkeyrecon`):
diffs two keyed sequences by stable key and emits the minimal
`{insert, remove, move, update}` op set, holding the longest-increasing
subsequence fixed so keys already in relative order do not move.

`SourceTree<K, V>` is the ordered keyed tree — each node is
`(stable id, value cell, ordered keyed child collection)`, inheriting per-level
reactivity and the atomic-move guarantee.

## Distributed CRDT plane

The CRDT plane rides the same lazily-ipc transport as `Snapshot`/`Delta`:
`CrdtSync` is a third `IpcMessage` variant. State-based and idempotent —
out-of-order, duplicated, or batched delivery all converge.

```dart
import 'package:lazily/ipc.dart';

final a = CrdtPlane(1);
final stamp = a.tick(12345);                              // local event
final op = CrdtOp.newOp(nodeId, stamp, [1, 2, 3]);        // state to merge
final frame = CrdtSync(
  frontier: a.frontier.toWire(),                          // per-peer stamp frontier
  ops: [op],
);
// → IpcMessage.ofCrdtSync(frame).encodeJson()  is the wire form.
```

`StampFrontier.merge` is commutative, associative, idempotent; the
causal-stability watermark (`stabilityWatermark`) is the `min` over
membership — only once every replica has observed a tombstone may it be
collected (`isCollectable`).

## FFI boundary

`package:lazily/ffi.dart` exposes `LazilyFfiBytes`, `LazilyFfiStatus`, and
`LazilyFfiMessageKind` (with `CrdtSync = 3`). A frame is just serialized
`IpcMessage` bytes; the channel decodes each accepted frame as `IpcMessage`
and re-encodes canonical JSON.

```dart
import 'package:lazily/ffi.dart';
import 'package:lazily/ipc.dart';

final frame = LazilyFfiBytes(IpcMessage.ofCrdtSync(sync).encodeJson());
final c = lazilyFfiKindJson(frame);
expect(c.kind, LazilyFfiMessageKind.crdtSync);
```

lazily-dart declares the **`ffi = host`** capability (Dart has `dart:ffi`).

## Capability negotiation

`package:lazily/capability.dart` ships the compatibility handshake. Peers fail
closed on `protocol_id`, `protocol_major_version`, `codec`,
`ordered_reliable`, or a required feature the other does not offer.

## Async reactive context

`package:lazily/async_context.dart` is a separate reactive surface for
`async`/future-returning computations, with the full
`Empty → Computing → Resolved | Error` state machine, revision tracking (stale
completions discarded), in-flight deduplication, the re-resolve contract, an
equality `memoAsync` guard, serialized async effects (cleanup-before-body),
batching, and disposal.

## Development

```bash
dart pub get
dart analyze --fatal-infos
dart test
```

`dart test` builds [`lazily-formal`][formal] (Lean proofs) when the sibling
submodule + `lake` toolchain are present, and SKIPs otherwise. To verify the
proofs in a standalone clone:

```bash
git clone https://github.com/lazily-hub/lazily-formal.git ../lazily-formal
# (or) set LAZILY_FORMAL_PATH=/path/to/lazily-formal
dart run tool/formal_check.dart
```

## The lazily family

`lazily` is one reactive model — the Cell kernel, keyed collections, state
machines and charts, CRDTs, and the distributed plane — implemented natively per
language and held to the same behaviour by a shared conformance corpus.

- [`lazily-spec`][spec] — language-agnostic wire protocol + the conformance
  fixtures (IPC and state-chart) every binding replays. It also carries the
  generated cross-language feature matrix; read that table rather than any
  per-binding copy.
- [`lazily-formal`][formal] — Lean 4 formal model (shared primitives, the flat
  `StateMachine` kernel, and the full Harel `StateChart`). Not a binding: it is
  the neutral formal home every binding depends on *equally*, and the executable
  reference behind the state-chart fixtures and the deterministic `send`
  lazily-dart inherits.

| Repo | Language |
|---|---|
| [`lazily-rs`][rs] | Rust — the reference implementation |
| [`lazily-py`][py] | Python |
| [`lazily-go`][go] | Go |
| [`lazily-kt`][kt] | Kotlin / JVM |
| [`lazily-js`][js] | JavaScript / TypeScript |
| [`lazily-cs`][cs] | C# / .NET |
| [`lazily-cpp`][cpp] | C++ |
| [`lazily-zig`][zig] | Zig |
| **`lazily-dart`** | Dart / Flutter — you are here |
| [`lazily-react`][react] | React / Preact bindings layered over [`lazily-js`][js] — not a separate language binding |

[rs]: https://github.com/lazily-hub/lazily-rs
[py]: https://github.com/lazily-hub/lazily-py
[go]: https://github.com/lazily-hub/lazily-go
[kt]: https://github.com/lazily-hub/lazily-kt
[js]: https://github.com/lazily-hub/lazily-js
[cs]: https://github.com/lazily-hub/lazily-cs
[cpp]: https://github.com/lazily-hub/lazily-cpp
[zig]: https://github.com/lazily-hub/lazily-zig
[react]: https://github.com/lazily-hub/lazily-react
[spec]: https://github.com/lazily-hub/lazily-spec
[formal]: https://github.com/lazily-hub/lazily-formal
