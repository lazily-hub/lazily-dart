/// lazily-spec IPC wire types for Dart.
///
/// Exposes the language-agnostic lazily wire protocol (`Snapshot`, `Delta`,
/// `CrdtSync`, `DeltaOp`, `NodeState`, `IpcValue`, `IpcMessage`, `NodeKey`,
/// and the permission boundary), plus the lazily-lean transition helpers
/// (`cellSetOps`, `memoOps`, `signalOps`, `BatchFlush`) that mirror the Lean 4
/// formal model, and the distributed CRDT plane runtime (`Hlc`, `StampFrontier`,
/// `CrdtPlane`) from `src/crdt.dart`.
///
/// See `package:lazily/lazily.dart` for the reactive family
/// (`Slot` / `Cell` / `Signal` / `StateMachine` / `StateChart` /
/// `CellMap` / `CellTree`).
library lazily.ipc;

export 'src/crdt.dart';
export 'src/ipc.dart';
