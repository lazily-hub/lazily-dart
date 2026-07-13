# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/2.0.0.html)
(with the pre-1.0 convention that `0.minor` may break between minor bumps).

## 0.16.0

### Added

- **`TopicCell` broadcast topics (`#lztopiccell`).** Independent absolute
  subscriber cursors, durable offline replay, ephemeral disconnect lifecycle,
  per-subscriber reactive invalidation, snapshot restore, and safe prefix GC at
  the slowest durable cursor.

## 0.15.0

### Added

- **RelayCell — Phases 2–6 (`#relaycell`).** The algebra-typed conflating relay,
  ported from lazily-rs: `RelayCell<T>` (hot head under a `MergePolicy`, reactive
  `BackpressurePolicy`, `Overflow` block/dropNewest/dropOldest/conflate/spill,
  demand-driven `depth`/`isFull`/`isEmpty` slots; rejects `conflate` for a
  non-conflating policy); `SpillStore<T>` paged durable tail (`reconstruct`
  spill_lossless, `replayUnacked` idempotent replay, ack-before-reclaim);
  `RelayTransport<T>` seam (`InProcTransport`/`FramedTransport`); `Outbox<T>` /
  `Inbox<T>` role facades (producer backpressure via `isFull`; remote credit
  meter); and the Phase-6 policies `RatePolicy`/`WindowPolicy`/`ExpiryPolicy`/
  `PriorityStorage<T>`/`KeyedRelay<K,T>`. Logical-clock time for determinism.

## 0.14.0

### Added

- **Merge algebra + `MergeCell` (Phase 1, `#relaycell`).** `MergePolicy<T>` (an
  associative fold with commutative/idempotent/conflates flags) with factories
  keepLatest/sum/max/setUnion/rawFifo; `MergeCell<T>` generalizes `Cell`
  (`Cell ≡ MergeCell(KeepLatest)`), a source whose write is a merge. Law-tests +
  cross-language `mergecell_algebra.json` fixture replay.

## 0.13.0

### Changed

- **Demand-driven queue reader-kinds + optional `peek`/`capacity` (Phase 0,
  `#relaycell`).** `QueueCell` reader-kinds (`head`/`len`/`isEmpty`/`isFull`) are
  now demand-driven memoized `Slot`s (were eagerly-set `Cell`s): a successful
  push/pop derives no reader value and invalidates only the readers whose value
  provably changed. `peek`/`capacity` become optional `QueueStorage` capabilities
  (default method bodies returning `null`) — the minimal contract is
  `tryPush`/`tryPop`/`len`/`isClosed`/`close`, so a raw-channel-style backend
  conforms directly (no `head`/`isFull` reader). Observable semantics are
  unchanged; all conformance fixtures stay green.

## 0.12.0

### Added

- **Reliable Sync (`#lzsync` + `#sync-driver`).** The delivery-reliability layer
  over the `Snapshot`/`Delta`/`CrdtSync` planes (lazily-spec § Reliable Sync), at
  parity with the `lazily-rs`/`lazily-kt`/`lazily-js` references:
  - `ResyncCoordinator` — receiver-side `Apply`/`RequestSnapshot`/`Ignore`
    decision function, multi-epoch-span aware, single-request-per-gap suppression.
  - `DurableOutbox` interface + `InMemoryOutbox` — append-before-send,
    `ackThrough` retention, `replayFrom` cursor (at-least-once → exactly-once).
  - `OrSet` (add-wins) + `WireLwwRegister<V>` liveness cells on the CrdtSync plane.
  - `SyncDriver` + `IpcSink`/`IpcSource`/`Clock`/`SnapshotProvider` seams — the
    full-duplex drain → retain-on-fail → receive/route → advertise-ack loop.
  - `ResyncRequest` / `OutboxAck` `IpcMessage` control frames (FFI kinds 4/5).
  Replays the 5 `conformance/reliable-sync/` fixtures + SyncDriver loop-shape
  tests (17 new; 329 total). Dart is now ✅ on both reliable-sync coverage rows.

## 0.11.0

**Keyed collections unified on `ReactiveMap<K, V, H>` (`#reactivemap`).** Mirrors
lazily-spec v0.27.0 and the lazily-rs reference: one generic keyed primitive
`ReactiveMap<K, V, H>` (reactive membership + order, `getOrInsertWith`
mint-on-access, `remove`, `move*`) over a handle-kind abstraction, with two
specializations:

- `CellMap<K, V>` = `ReactiveMap<K, V, Cell<V>>` — input-cell entries; adds
  cell-only `set` + eager value-minting (`entry` / `entryWith`).
- `SlotMap<K, V>` = `ReactiveMap<K, V, Slot<V>>` — derived-slot entries;
  `getOrInsertWith` mints a slot on first access (lazy materialization),
  `materializeAll` pre-mints the keyset (eager); **no `set`**.

The same pattern applies to the concurrency flavors: `ThreadSafeReactiveMap` /
`ThreadSafeCellMap` / `ThreadSafeSlotMap` and `AsyncReactiveMap` /
`AsyncCellMap` / `AsyncSlotMap`.

**BREAKING.** Removes `ReactiveFamily`, `CellFamily`, the `MaterializationMode`
enum + `kDefaultMaterializationMode`, `cellFamily`, and the
`ThreadSafeReactiveFamily` / `AsyncReactiveFamily` types (and their
`eager*/lazy*` factories). Behavior is unchanged — there is **no eager/lazy mode
flag**: eager = pre-mint loop (`materializeAll`), lazy = mint-on-access
(`getOrInsertWith`). The 3 materialization conformance suites pass against the
shared lazily-spec fixtures (now `"model": "SlotMap"`).

## 0.10.0

**Full feature parity.** The remaining concurrency rows land in the Dart
column of the lazily-spec cross-language matrix (`—`/`~` → `✅`) — Dart now
ships every row.

**Thread-safe context (lock-backed) — `lib/src/thread_safe.dart`.**
`ThreadSafeContext` wraps a `Context` behind a **reentrant run-to-completion
guard**. Dart isolates have no shared mutable heap, so — exactly as JavaScript
ships this layer on its single-realm event loop — synchronous code runs to
completion and already serializes access; the guard is a reentrant depth
counter, not an OS lock. Ships the pure batch-flush kernel (`applyBatch` /
`flushBatch` / `unionDependents`) as a faithful port of the
`LazilyFormal.ThreadSafe` model, property-tested independently of the live
graph (`flushBatch_singleton_eq_setCell` and the coalesced-frontier laws).

**Thread-safe reactive family — `lib/src/thread_safe_reactive_family.dart`.**
`ThreadSafeReactiveFamily<K, V>`: the guarded, value-caching flavor of
`ReactiveFamily` with the same eager/lazy contract, observational transparency,
present-set monotonicity, and **materialization confluence**
(`materialize_present_comm` / `materialize_observe_comm`). Factories
`eagerSlotFamily` / `lazySlotFamily` / `eagerCellFamily` / `lazyCellFamily`.

**Async reactive family — `lib/src/async_reactive_family.dart`.**
`AsyncReactiveFamily<K, V>` adds a resolution axis (pending → resolved via
`drive`) orthogonal to the present-set. Non-blocking `observe` returns
`(null, false)` while pending and `(value, true)` once resolved — the
**eventual-transparency** law (`AsyncMaterialization.lean`).

**Reactive family sync (`#lzfamilysync`) — `lib/src/distributed.dart`.**
`CrdtPlaneRuntime` gains `registerFamilyLww` / `familySetLww` / `familyKeys` /
`familyValueLww` / `familyCountTrue` / `membershipEpoch`. A keyed op for an
unregistered family entry **materializes on ingest** (membership propagates,
values are adopted, LWW updates converge, re-ingest is idempotent, and a
derived aggregate converges) — replays
`conformance/familysync/materialize_on_ingest.json`
(`FamilySync.lean`: `applyOp_absent_adopts`, `present_merge`, `applyOp_idem`,
`aggregate_converges`).

**Shared-memory blob path (`~` → `✅`) — `lib/src/shm_blob_arena.dart`.**
`ShmBlobArena.transfer` packages a validated blob as a `ShmBlobTransfer`
(descriptor + `TransferableTypedData`) for a **zero-copy cross-isolate move** —
Dart's isolate-model counterpart of the `mmap`/`SharedArrayBuffer` shared-memory
path. The receiver adopts the moved buffer and re-validates the header.
`test/shm_isolate_test.dart` demonstrates real multi-isolate parallelism:
zero-copy blob hand-off and family CRDT convergence across isolates,
order-independent.

## 0.9.0

Two cross-language coverage rows land in the Dart column (`—` → `✅`):

**Reactive family (`ReactiveFamily`) + materialization mode (`#lzmatmode`).**
A unified keyed reactive family (`lib/src/reactive_family.dart`, exported from
`package:lazily/lazily.dart`) that maps keys to per-entry reactive nodes and
abstracts over the entry's handle kind:

- `EntryKind.cell` entries are **input** cells — always materialized, any mode.
- `EntryKind.slot` entries are **derived** slots — governed by materialization
  mode.
- `MaterializationMode.eager` (the required default) allocates every declared
  node up front; `MaterializationMode.lazy` defers each derived node to its
  first read ("materialize on pull"), keyed rather than handle-addressed.

Materialization mode is orthogonal to entry kind and never observable on the
value axis (`observe` returns identical values under either mode). `cellFamily`
is the input-cell specialization. Mirrors
`lazily-rs/src/reactive_family.rs` and the `lazily-spec/cell-model.md`
`ReactiveFamily` vehicle; pinned by the shared
`conformance/materialization/*.json` fixtures and the `lazily-formal`
`Materialization` proofs (`observe_canonical`,
`cell_entries_materialized_in_every_mode`, `slot_entries_deferred_under_lazy`,
`materialize_present_monotone`, `lazy_present_subset_eager`).

**Cross-process zero-copy transport (`BlobBackend` / shm / arrow, `#lzzcpy`).**
Large IPC payloads spill to a pluggable blob backend and cross the wire as a
small descriptor rather than a copy (`lib/src/transport.dart`, exported from
`package:lazily/ipc.dart`):

- `BlobBackend` adapter seam: `write(bytes) → ShmBlobRef`, `readView(desc)`
  zero-copy resolve, `advanceEpoch()`.
- `InProcessBackend` and `ArrowBackend` in-process adapters (the isolate model
  has no cross-process shared memory — the `shared_memory: partial` carve-out;
  a real POSIX `shm` region would need `dart:ffi`).
- `BlobRouter` receiver-side multi-backend resolver routing by the descriptor's
  `backend` discriminator, plus `spillMessage` / `spillValue` / `resolveValue`
  policy.

`ShmBlobRef` gains an optional `backend` discriminator (`BlobBackendKind` —
`shm` (default) / `arrow` / `in_process`); it is omitted from the wire when
`shm`, so every legacy descriptor round-trips byte-identically. Mirrors
`lazily-rs/src/transport.rs` and `lazily-spec/docs/zero-copy-transport.md`;
pinned by `conformance/delta_zero_copy_arrow.json` and the `lazily-formal`
`ZeroCopyTransport` proofs (`resolve_write`, `resolve_wrong_backend`,
`resolve_stale_generation`, `resolve_corrupt_checksum`, `transport_roundtrip`).

## 0.8.0

Reactive queue — `QueueCell` SPSC/MPSC primitive + `QueueStorage` adapter
seam. Dart now ships the reactive queue row from the lazily-spec cross-language
matrix (Dart column → `✅`). Mirrors `lazily-spec/cell-model.md` § "Reactive
queues" and `lazily-formal/LazilyFormal/QueueCell.lean`.

### Added — Reactive queue (`package:lazily/src/queue.dart`)

- **`QueueCell<T>`** — a reactive FIFO queue: SPSC primitive with an MPSC
  usage rule (multiple producers push inside a `Context.batch`; there is no
  separate MPSC type). The reactive shell owns five reader-kind version cells
  (`head` / `len` / `is_empty` / `is_full` / `closed`) and invalidates by
  reader kind — a push to a non-empty queue does NOT invalidate the `head`
  reader, a pop does. This reader-kind independence falls out of the `!=` guard
  on `Cell.value`'s setter: after each op the shell re-derives each reader-kind
  cell from the storage and writes it back in one atomic `batch`, and a cell
  whose value did not change is not invalidated.
- **`QueueStorage<T>`** — the pluggable storage adapter interface. The shell /
  storage split keeps the reactive shell storage-agnostic; a `RaftQueueStorage`
  (embedded consensus, per the distributed-queue PRD) or an external-broker
  adapter (`KafkaStorage`, etc.) plugs into the same reactive shell.
- **`VecDequeStorage<T>`** — the reference `ListQueue`-backed FIFO, optionally
  bounded. Unbounded is the default; bounded exposes reactive backpressure via
  `isFull` (a pop that transitions full → not-full invalidates `is_full`
  readers — the backpressure recovery signal). Overflow policy is **reject**
  (`tryPush` at capacity returns `Full`; elements are never silently dropped).
- **Closure lifecycle** — close is idempotent and terminal; pop on closed +
  non-empty drains (returns the next element); pop on closed + empty returns
  `Closed` (distinct from `Empty`); push on closed returns `Closed`.
- **`QueuePushError` / `QueuePopError` / `QueuePopResult`** — sealed union
  types for the observable rejection labels.
- **Conformance** — replays all 5 `lazily-spec/conformance/collections/
  queuecell_*.json` fixtures (`spsc_push_pop`, `popped_head_observation`,
  `mpsc_multi_writer`, `bounded_backpressure`, `closure_lifecycle`) using the
  live reactive graph as invalidation probes, plus unit tests for
  `VecDequeStorage` FIFO/bounded/zero-capacity, closure drain, bounded
  backpressure, reader-kind independence, pluggable custom storage, and
  snapshot round-trip. 250 tests pass.

## 0.7.0

Lossless tree CRDT + command/RPC message plane. Dart now ships the two
remaining feature rows from the lazily-spec cross-language matrix (Dart
column → `✅` on lossless-tree ×3 + message-passing). The only Dart `—` is
**Thread-safe context** (isolate carve-out) and the `~` is **Shared-memory
blob path** (I/O-channel fallback) — both documented platform carve-outs.

### Added — Lossless tree CRDT (`package:lazily/src/lossless_tree_crdt.dart`)

- **`LosslessTreeCrdt`** — lossless concrete-syntax tree CRDT (M1). Leaves
  own every rendered byte; internal Element nodes own structure only, so
  invalid/unknown spans round-trip exactly as Raw/Error leaves. Ops:
  CreateNode / Tombstone / Reorder / LeafEdit / SplitLeaf / MergeLeaves,
  plus op-based delta sync over a dotted non-contiguous version frontier
  (`TreeVersionFrontier`). Leaves embed `TextCrdt`; child order reuses
  `SeqCrdt`'s fractional index (`keyBetween`); the clock is a Lamport
  `TreeOpId`. Leaf-local text offsets on the wire are UTF-8 bytes (via
  `utf8_offsets`). Wire parity with lazily-rs/kt/js. Replays all 9
  lazily-spec/conformance/lossless-tree/ fixtures.

### Added — Command/RPC message plane (`command-plane-v1`, `package:lazily/src/command.dart`)

- **`CommandSubmit` / `CommandCancel` / `CommandEvents` / `CommandProjection`**
  — the evented command message family, an additive sibling to
  Snapshot/Delta/CrdtSync. Terminal authority is the causal receipt, not
  the event or transport. RPC is a facade (`CommandRpcClient.call` /
  `submit` / `cancel`) over the `CommandProjection` reducer; a unary `call`
  resolves only on a terminal projection. Wire parity with lazily-rs/kt/js.
  Replays all 8 lazily-spec/conformance/message-passing/ fixtures.

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
