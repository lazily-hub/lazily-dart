/// Lazily — lazy reactive primitives for Dart.
///
/// See `package:lazily/src/core.dart` for the reactive family,
/// `package:lazily/src/state_machine.dart` for the Cell-backed state machine,
/// and `package:lazily/src/collections.dart` for the keyed cell collections.
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
export 'src/state_chart.dart';
export 'src/state_machine.dart';
