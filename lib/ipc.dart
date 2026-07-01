/// lazily-spec IPC wire types for Dart.
///
/// Exposes the language-agnostic lazily wire protocol (`Snapshot`, `Delta`,
/// `DeltaOp`, `NodeState`, `IpcValue`, `IpcMessage`, `NodeKey`, and the
/// permission boundary), plus the lazily-lean transition helpers (`cellSetOps`,
/// `memoOps`, `signalOps`, `BatchFlush`) that mirror the Lean 4 formal model.
///
/// See `package:lazily/lazily.dart` for the reactive family
/// (`Slot` / `Cell` / `Signal` / `StateMachine` / `StateChart`).
library lazily.ipc;

export 'src/ipc.dart';
