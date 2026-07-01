# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
(with the pre-1.0 convention that `0.minor` may break between minor bumps).

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
