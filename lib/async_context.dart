/// Async reactive context (docs/async.md).
///
/// A separate reactive surface for computations whose values are produced by
/// `async`/future-returning functions. Exposes `AsyncContext`, `AsyncCellHandle`,
/// `AsyncSlotHandle`, `AsyncSlotState`, `AsyncEffectHandle`, `AsyncComputeContext`.
library lazily.async;

export 'src/async_context.dart';
