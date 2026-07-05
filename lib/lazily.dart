/// Lazily — lazy reactive primitives for Dart.
///
/// See `package:lazily/src/core.dart` for the reactive family,
/// `package:lazily/src/state_machine.dart` for the Cell-backed state machine,
/// and `package:lazily/src/collections.dart` for the keyed cell collections.
/// CRDT collection types (`TextCrdt`, `SeqCrdt`) are in
/// `package:lazily/src/text_crdt.dart` and `package:lazily/src/seq_crdt.dart`.
/// `SemTree` is in `package:lazily/src/sem_tree.dart`, and stable-id alignment
/// is in `package:lazily/src/stable_id.dart`.
///
/// Lazily-spec IPC wire types (`Snapshot`, `Delta`, `CrdtSync`, `NodeState`,
/// ...) live in `package:lazily/ipc.dart`. The C-ABI FFI boundary lives in
/// `package:lazily/ffi.dart`, capability negotiation in
/// `package:lazily/capability.dart`, and the async reactive context in
/// `package:lazily/async_context.dart`.
library;

export 'src/async_context.dart';
export 'src/collections.dart';
export 'src/core.dart';
export 'src/registers.dart';
export 'src/sem_tree.dart';
export 'src/seq_crdt.dart';
export 'src/stable_id.dart';
export 'src/state_chart.dart';
export 'src/state_machine.dart';
export 'src/text_crdt.dart';
