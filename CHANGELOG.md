# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/2.0.0.html)
(with the pre-1.0 convention that `0.minor` may break between minor bumps).

## 0.6.0

Full feature-parity release: every feature row in the lazily-spec
cross-language coverage matrix that can run on the Dart platform is now
shipped (`✅`). Dart moves from `~`/`—` to `✅` on **13 rows** — the
reactive core, all CRDT collection types, the distributed plane, signaling,
state projection, causal receipts, and instrumentation.

The only `—` remaining is **Thread-safe context** — a legitimate Dart
carve-out per the spec (Dart isolates are a process/actor-isolation model
with no shared address space, so `thread_safe: none` is declared). The
`~` remaining is **Shared-memory blob path** — the arena + header validation
ship, but cross-process shared memory is carried `Inline` per the platform
carve-out.

### Added — Reactive core completion (`package:lazily/lazily.dart`)

- **`Effect`** — side-effect observer with cleanup-before-rerun semantics.
  Tracks dependencies dynamically; reruns after the current cascade (or at
  batch exit).
- **`Memo<T>`** — a [Slot] subclass with an equality guard. A dirty memo
  that recomputes equal suppresses the downstream cascade (no `SlotValue`,
  no `Invalidate`), implementing the memo-equality invariant.
- **`Context.batch`** — depth-counted, coalesced batch. Cell writes inside
  a batch defer their cascades until the outermost exit; effects flush once.

### Added — CRDT collection types

- **`TextCrdt`** (`package:lazily/src/text_crdt.dart`) — Fugue/RGA-style
  character CRDT. Sticky tombstones, deterministic order (pre-order DFS,
  siblings descending by OpId), state-based merge (C/A/I), GC. Delta sync:
  `versionVector()`, `deltaSince(theirVv)`, `applyDelta(ops)`.
- **`SeqCrdt<Id, V>`** (`package:lazily/src/seq_crdt.dart`) — Move-aware
  sequence CRDT. Three independent LWW registers per element (value,
  fractional-index position, deleted); a move is a single LWW reassignment.
  HLC-stamped; concurrent moves converge to the later stamp.
- **`Hlc`** / **`HlcStamp`** / **`LwwRegister<V>`** / **`Position`** — the
  HLC clock and LWW register primitives backing SeqCrdt.
- **`MvRegister<V>`** / **`PnCounter`** / **`CellCrdt<T>`**
  (`package:lazily/src/registers.dart`) — multi-value register, PN counter,
  and reactive-cell-backed CRDT bridge.
- **`SemTree<V, D>`** (`package:lazily/src/sem_tree.dart`) — memoized
  semantic tree. One memo slot per node; editing a node recomputes only its
  ancestor chain; a non-changing fold result suppresses downstream.
- **Stable-id alignment** (`package:lazily/src/stable_id.dart`) —
  `Block` / `BlockKey` / `align` / `assignStableKeys`. Three layers: anchors,
  FNV-1a content hashes, word-LCS similarity (≥ 0.5 → Edited).

### Added — Distributed plane + receipts + signaling

- **`CrdtPlaneRuntime`** (`package:lazily/src/distributed.dart`) —
  state-based anti-entropy runtime with op-log dedup, per-node LWW cells,
  `converged()` output, idempotent re-ingest.
- **Causal receipts** (`package:lazily/src/causal_receipts.dart`) —
  `CausalReceipt` / `CausalReceipts` wire types, `ReceiptProjection`
  (monotonic ledger: stale-gen ignored, duplicate no-op, terminal conflict).
- **Signaling** (`package:lazily/src/signaling.dart`) — `SignalingRoom`
  with anti-spoof `from` stamping, `ClientMessage` / `ServerMessage`
  sealed unions, permission modes (open / allowlist).
- **State projection** (`package:lazily/src/state_projection.dart`) —
  `StateProjectionMirror` (coalesced flush delta), `documentHash`,
  `buildStateEvent`.

### Added — Infrastructure

- **`ShmBlobArena`** (`package:lazily/src/shm_blob_arena.dart`) — in-process
  blob arena with generation/epoch header validation.
- **Instrumentation** (`package:lazily/src/instrumentation.dart`) —
  `benchmark()` harness + `runBenchmarkSuite()` for the reactive core,
  collections, and CRDT types.

### Conformance

All 30+ lazily-spec conformance fixtures now replay:
- `collections/textcrdt_convergence.json` (6 scenarios)
- `collections/textcrdt_delta_sync.json` (4 scenarios)
- `collections/seqcrdt_convergence.json` (6 scenarios)
- `collections/semtree_incremental.json` (3 scenarios)
- `collections/stableid_alignment.json` (6 scenarios)
- `distributed/anti_entropy_converge.json` (3 scenarios)
- `receipts/causal_receipts.json`
- `signaling/anti_spoof_session.json` (7-step transcript)

212 tests pass, incl. the `lazily-formal` Lean proof build.

## 0.5.1

Docs-only sync against the latest [`lazily-spec`](https://github.com/lazily-hub/lazily-spec)
`coverage.json`. No code or API changes; re-verified against the current
`lazily-formal` Lean proofs.

### Changed

- **README** coverage table resynced from `lazily-spec/coverage.json` via
  `node scripts/sync-coverage.mjs` — adds the Causal receipts
  (`CausalReceipts` outcome projection) row now tracked by the spec.
  lazily-dart remains `—` on that layer (not yet ported); the table is the
  single source of truth for cross-language coverage.

## 0.5.0

This release makes [`lazily-formal`](https://github.com/lazily-hub/lazily-formal)
part of the test suite — `dart test` now builds the Lean 4 model and verifies
the proofs the Dart implementation mirrors, closing the formal-compliance
side of the [`lazily-spec`](https://github.com/lazily-hub/lazily-spec)
Binding Conformance Matrix alongside the wire layers shipped in 0.1–0.4.

### Added — Formal model in the test suite

- **`tool/formal_check.dart`** — a proof-verification hook (mirroring
  `lazily-js/scripts/formal-check.mjs`) that runs `lake build` over the
  sibling `lazily-formal` checkout, located via the `LAZILY_FORMAL_PATH` env
  var and then the `src/lazily-dart` ↔ `src/lazily-formal` submodule layout.
  SKIPs with a clear notice (exit 0) when the submodule or the `lake`
  toolchain is absent, so pub.dev consumers and shallow clones are not broken.
  CI verifies the proofs for real under a full checkout + elan.
- **`test/formal_check_test.dart`** — wires the Lean build into `dart test`
  so a broken proof fails the suite.
- **`test/statechart_properties_test.dart`** — property tests mirroring the
  `LazilyFormal.StateChart` / `StateMachine` theorems (determinism by
  construction, `enabled_empty_rejects`, `send_preserves_chart`,
  `single_region_refines_flat_machine`, `single_region_enabled_at_most_one`,
  `parallel_region_confluence`, `recordHistory_idempotent`,
  `send_actions_empty_when_rejected`).
- **`test/reactive_properties_test.dart`** — property tests mirroring the
  `LazilyFormal.Reactive` theorems (`setCell_equal_preserves_graph`,
  `setCell_different_invalidates_dependents`,
  `recomputeSlot_equal_preserves_dependents`,
  `recomputeSlot_different_invalidates_dependents`,
  `signal_materialized_after_recompute`).

### Changed

- **CI** now checks out `lazily-formal` as a sibling and installs
  [elan](https://github.com/leanprover/lean-action) so `dart test` runs the
  formal proof verification instead of SKIP-ing. A dedicated `lean` job
  (mirroring lazily-kt) builds the canonical `lazily-formal` +
  `lazily-spec` Lean models independently.

## 0.4.0

This release closes the lazily-spec **Binding Conformance Matrix** — every
MUST layer is now implemented. lazily-dart conforms to the keyed cell
collections, distributed CRDT, C-ABI FFI boundary, capability negotiation, and
async reactive context layers alongside the reactive core, state charts, IPC,
and permission boundary shipped in 0.1–0.3.

### Added — Keyed cell collections (`package:lazily/lazily.dart`)

- **`CellMap<K, V>`** — a reactive composition of per-entry cells plus a
  dedicated membership cell and a dedicated order cell, so the three reactivity
  planes are independent: writing one entry's value invalidates only that
  entry's value readers; adding/removing a key invalidates membership and order
  readers; a pure atomic move (`moveTo` / `moveBefore` / `moveAfter`) bumps
  only the order signal once and keeps the moved entry's same `Cell` handle,
  dependents, and lineage (it is not a remove + re-mint). `#lzcellfamily`,
  `#lzcellmove`.
- **`CellTree<K, V>`** — the ordered keyed tree. A node is
  `(stable id, value cell, ordered keyed child collection)`, so per-level
  membership/order reactivity and the atomic-move guarantee are inherited
  node-by-node.
- **`CellFamily<K, V>`** — a parameterized factory of reactive cells keyed by
  `K` (à la Recoil/Jotai `atomFamily`).
- **`reconcileDiff` + `DiffOp`** — the move-minimized keyed reconciliation
  (`#lzkeyrecon`). Diffs two keyed sequences by stable key (not position),
  emitting the minimal `{insert, remove, move, update}` op set; the
  longest-increasing-subsequence over prior indices is held fixed so keys
  already in relative order do not move. `CellMap.reconcile` applies it
  per-cell. O(n log n) patience-sort LIS.
- **Collections conformance** — mirrors the shared
  `lazily-spec/conformance/collections/` fixtures
  (`cellmap_independence`, `cellmap_atomic_move`, `keyed_reconciliation_lis`)
  and replays them in `test/collections_conformance_test.dart`, asserting
  value/membership/order reactivity-independence, stable-handle invariance, and
  the LIS op set identically to every sibling binding (lazily-rs / lazily-kt /
  lazily-js).

### Added — Distributed CRDT plane (`package:lazily/ipc.dart`)

- **`WireStamp` / `CrdtOp` / `CrdtSync`** wire types (protocol.md §
  Distributed). `CrdtSync` rides the same lazily-ipc transport as
  `Snapshot`/`Delta` as a third `IpcMessage` variant. `CrdtOp.key` is always
  present on the wire (`null` when unset, mirroring lazily-rs derived serde);
  the frontier is a list of `[peer, WireStamp]` 2-tuple arrays (per
  `schemas/distributed.json`). Canonical bytes verified byte-identical to the
  lazily-rs serde reference.
- **`Hlc` / `HlcStamp`** — the hybrid logical clock (Karger-Shrinkman-Levine)
  that produces the runtime stamps. Caller-supplied wall time keeps the clock
  deterministic. `tick` (local) and `observe` (remote) preserve the monotonic
  invariant.
- **`StampFrontier`** — the per-peer stamp frontier with its
  commutative/associative/idempotent `merge` (formally
  `stampJoin_{comm,assoc,idem}`) and the causal-stability watermark (the `min`
  over membership — `null` until every member has been observed).
- **`CrdtPlane`** — wires the `Hlc` + `StampFrontier` + live membership. Local
  edits (`tick`) and remote observations (`observeRemote`) fold into the
  frontier; `stabilityWatermark` is what the tombstone-GC contract consumes,
  and `isCollectable` is `delete stamp ≤ watermark`.
- **`CrdtSync.filterReadable`** — permission-filtered frame that omits ops for
  non-readable nodes entirely (omission, not redaction) while retaining the
  frontier advertisement in full.

### Added — C-ABI FFI boundary (`package:lazily/ffi.dart`)

- **`LazilyFfiBytes`**, **`LazilyFfiStatus`** (`Ok/Empty/NullPointer/
  InvalidMessage/EncodeFailed/Panic`), and **`LazilyFfiMessageKind`**
  (`Unknown=0/Snapshot=1/Delta=2/CrdtSync=3`). The `CrdtSync = 3` discriminant
  is normative (the FFI message kind MUST include it). Mirrors
  `lazily-rs/src/ffi.rs`.
- **Channel contract**: `lazilyFfiValidateJson`, `lazilyFfiKindJson` (classify
  by decoding), `lazilyFfiCloneJson` (decode + re-encode canonical JSON), and
  the `LazilyFfiChannel` relay. The frame is just serialized `IpcMessage`
  bytes — no custom header; the kind is derived by full decode.
- lazily-dart declares the **`ffi = host`** capability (Dart has `dart:ffi`;
  it never takes the `none` carve-out reserved for browser/Worker JS).

### Added — Capability negotiation (`package:lazily/capability.dart`)

- **`CapabilityHandshake`** + **`CapabilityCheck`** — the compatibility
  handshake exchanged before any graph state flows. Peers fail closed on
  `protocol_id`, `protocol_major_version`, `codec`, `ordered_reliable`, or a
  required feature the peer does not offer. Standalone frame, not an
  `IpcMessage` variant.
- **`BindingCapabilities`** + **`FfiCapability`** — the binding-level
  conformance declaration: every MUST layer advertised as implemented, `ffi =
  host`.

### Added — Async reactive context (`package:lazily/async_context.dart`)

- **`AsyncContext`** — a separate reactive surface for `async`/future-returning
  computations (compute, not protocol). Distinct handles
  (`AsyncCellHandle` / `AsyncSlotHandle` / `AsyncEffectHandle`) — not an
  overload of the synchronous `Context`.
- **The full `Empty → Computing → Resolved | Error` state machine** with
  **revision tracking** (a stale completion is discarded, never published),
  **in-flight deduplication** (concurrent `getAsync` callers await the same
  future), the **re-resolve contract** (benign-race windows don't panic),
  **`memoAsync`** (equality memo guard), **async effects** (serialized reruns,
  cleanup-before-body ordering), **batch** (synchronous boundary; async reruns
  fire after the outermost batch exits), and **disposal** (cancels in-flight
  computations). Honors all five properties of the cancellation contract
  (docs/async.md § Cancellation contract).

### Changed

- `IpcMessage` is now a three-variant sum: `Snapshot | Delta | CrdtSync`. The
  `isCrdtSync` / `crdtSync` accessors and `IpcMessage.ofCrdtSync` constructor
  are added; existing `Snapshot`/`Delta` code is unchanged.

## 0.3.0

### Changed

- **`StateChart` is now a full Harel/SCXML chart**, the native counterpart of
  [`lazily-formal`](https://github.com/lazily-hub/lazily-formal)'s
  `LazilyFormal.StateChart` and lazily-rs's / lazily-kt's charts. It is rebuilt
  around a JSON `ChartDef` (`lazily-spec/docs/state-charts.md`) and a
  configuration-set `Cell` (active leaves plus all active ancestors). `send` is
  deterministic by construction — a total function of
  `(chart, configuration, history, guards, event)`, mirroring the Lean
  `StateChart.send`. **Breaking**: replaces the previous code-first generic
  `StateChart<S,E>` / `ChartState` / `ChartTransition` API.

### Added

- **Orthogonal (parallel) regions** with document-order descent and
  conflict-free concurrent advancement — witnesses the formal
  `parallel_region_confluence` (under pairwise-disjoint exit sets every enabled
  transition is taken; the result depends only on the enabled *set*, not its
  order).
- **Shallow + deep history** (record-on-exit / restore-on-enter, with `default`
  fallback on first entry) — witnesses `recordHistory_idempotent` and the
  history restore lemmas.
- **External + internal transitions** (LCA chosen per the formal `lcaOf`:
  `source` for internal-to-source, `lca(activeLeaf, target)` otherwise).
- **Sourced action trace** — `lastActions()` returns the ordered names fired by
  the initial entry or the most recent `send` (exit innermost-first →
  transition → entry outermost-first), witnessing `send_actions_empty_when_rejected`
  and `stepActions_sourcing` observably.
- **Named guards, resolved at `send` time** (fail-closed on an absent/unknown
  name) — witnesses `enabled_empty_rejects`.
- **`run` actions and `{"expr": …}` context guards rejected explicitly** per
  the spec's implementation-status note. `final` states are accepted as leaves
  without raising completion (`done`) events, matching lazily-py and lazily-kt.
- **State-chart conformance** — mirrors the shared
  `lazily-spec/conformance/statechart/` fixtures (compound, parallel, shallow +
  deep history, guarded, entry/exit/transition actions) and replays them in
  `test/statechart_conformance_test.dart`, asserting `accepted`, `active`,
  `matches`, and `actions` identically to every sibling binding.

## 0.2.0

### Added

- **`package:lazily/ipc.dart`** — the lazily-spec wire protocol: `Snapshot`,
  `Delta`, `DeltaOp` (all 7 variants), `NodeState`, `IpcValue`, `IpcMessage`,
  `ShmBlobRef`, and the optional wire-stable `NodeKey` keyed address. Pure Dart
  (`dart:convert` + `dart:typed_data` only): Flutter, web, and native. Round-trips
  the canonical conformance fixtures from [`lazily-spec`](https://github.com/lazily-hub/lazily-spec/tree/main/conformance).
- **lazily-lean transition helpers** — runtime mirrors of the Lean 4 formal
  model invariants (`lazily-spec/formal/lean/LazilyFormal/IPC.lean`): `Delta.next`
  / `isNextAfter` / `applyStatus` (epoch sequencing + fail-closed gap resync),
  `cellSetOps` (PartialEq cell guard), `memoOps` (memo equality suppression),
  `signalOps` (eager Signal materialization, never a bare `Invalidate`), and
  `BatchFlush` (coalesced no-duplicate frontier, single epoch advance).
- **Permission boundary** — `OpKind`, `RemoteOp`, `PeerPermissions`
  (default-deny per-peer allowlist; read / write / trigger_effect gated
  independently), plus permission-filtered `Snapshot` / `Delta` (omission, not
  redaction).

## 0.1.0

### Added

- Reactive core: `Slot` (lazy memoized derived), `Cell` (mutable source),
  `Signal` (eager derived), and the shared `Context` with automatic dependency
  tracking and cache invalidation.
- `StateMachine<S, E>` — a finite state machine backed by a reactive `Cell`.
- `StateChart` — a Harel-style hierarchical state machine (composite states,
  event bubbling, LCA entry/exit resolution, guards, transition/entry/exit
  actions) backed by a reactive `Cell`.
