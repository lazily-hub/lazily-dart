/// The C-ABI FFI boundary (protocol.md § FFI Boundary).
///
/// Exposes `LazilyFfiBytes`, `LazilyFfiStatus`, `LazilyFfiMessageKind` (with
/// `CrdtSync = 3`), and the channel contract (validate / classify / clone).
library lazily.ffi;

export 'src/ffi.dart';
