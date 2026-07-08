/// lazily-spec IPC wire types for Dart.
///
/// Exposes the language-agnostic lazily wire protocol (`Snapshot`, `Delta`,
/// `CrdtSync`, `DeltaOp`, `NodeState`, `IpcValue`, `IpcMessage`, `NodeKey`,
/// and the permission boundary), plus the lazily-lean transition helpers
/// (`cellSetOps`, `memoOps`, `signalOps`, `BatchFlush`) that mirror the Lean 4
/// formal model, the distributed CRDT plane runtime (`Hlc`, `StampFrontier`,
/// `CrdtPlane`, `CrdtPlaneRuntime`), causal receipts, the command / RPC
/// message plane (`command-plane-v1`: `CommandSubmit`, `CommandProjection`,
/// `CommandRpcClient`), and signaling.
///
/// See `package:lazily/lazily.dart` for the reactive family
/// (`Slot` / `Cell` / `Signal` / `StateMachine` / `StateChart` /
/// `CellMap` / `CellTree` / `TextCrdt` / `SeqCrdt` / `SemTree`).
library lazily.ipc;

export 'src/causal_receipts.dart';
export 'src/command.dart';
export 'src/crdt.dart';
export 'src/distributed.dart';
export 'src/instrumentation.dart';
export 'src/ipc.dart';
export 'src/shm_blob_arena.dart';
export 'src/signaling.dart';
export 'src/state_projection.dart';
