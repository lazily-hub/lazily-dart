/// Thread-safe reactive context ([ThreadSafeContext]) — the lock-serialized
/// batch boundary, plus the pure batch-flush kernel (`#lzfamilysync`,
/// thread-safe).
///
/// Spec:   `lazily-spec/protocol.md` § "Concurrency layers are required".
/// Formal: `lazily-formal/LazilyFormal/ThreadSafe.lean`
///   (`flushBatch_singleton_eq_setCell` — thread-safe batch refines `setCell`;
///    `flushBatch_dependent_dirty` / `flushBatch_preserves_nondependent_dirty`
///    — the coalesced-frontier / glitch-freedom laws).
/// Rust reference:   `lazily-rs/src/thread_safe.rs`.
/// Go reference:     `lazily-go/thread_safe.go` (ApplyBatch/FlushBatch/UnionDependents).
/// JS reference:     `lazily-js/src/thread-safe.js` (single-realm degraded guard).
///
/// DART RUNTIME PREMISE. Dart isolates have **no shared mutable heap**. Within a
/// single isolate, synchronous code runs to completion and never yields, so it
/// already serializes access to the reactive graph — exactly like the JS
/// single-realm degraded path (`lazily-js/src/thread-safe.js` degrades its
/// `Atomics` mutex to a no-op guard when `SharedArrayBuffer` is absent). Go and
/// Rust need a real OS lock because they have shared-memory threads; Dart does
/// not.
///
/// The "lock" here is therefore a **reentrant run-to-completion guard** — a
/// plain depth counter, NOT an OS mutex — and the "thread-safe" contract is
/// delivered by (a) that run-to-completion serialization within an isolate and
/// (b) the deterministic batch-coalescing kernel below, proven equivalent to the
/// Lean model. A one-write section is observationally identical to a plain
/// [Cell.set] (`flushBatch_singleton_eq_setCell`), so concurrency changes
/// neither the written value nor the invalidation.
library;

import 'core.dart';

/// The single-isolate, run-to-completion flavor of [Context]: every public
/// operation runs under a reentrant guard. Handles returned here are ordinary
/// [core.dart] handles (the wrapped inner [Context] owns the graph).
///
/// Build reactives and read/write cells inside [withLock]/[read]/[batch] (or via
/// the passthrough helpers). Because a synchronous isolate never yields
/// mid-section, all callers are already linearized; the guard exists to (a) make
/// reentrancy explicit and structurally match the Go/Rust/JS flavors, and (b)
/// wrap batch flushes as one critical section so coalescing is glitch-free.
class ThreadSafeContext {
  /// Wrap [context] (a fresh [Context] if omitted) behind a reentrant guard.
  ThreadSafeContext({Context? context}) : _ctx = context ?? Context();

  final Context _ctx;

  /// Reentrancy depth of the run-to-completion guard. `0` outside any critical
  /// section; incremented on entry, decremented on exit. Because a synchronous
  /// isolate never yields inside a section, this counter is isolate-private and
  /// race-free — the exact role JS's realm-private depth counter plays.
  int _depth = 0;

  /// The underlying single-isolate [Context]. Only touch it inside a guarded
  /// section (via [withLock]/[read]/[batch]); direct use bypasses the batch
  /// framing.
  Context get context => _ctx;

  /// Current reentrancy depth (`> 0` while inside a guarded section). Exposed for
  /// tests and instrumentation.
  int get depth => _depth;

  /// Run [fn] under the guard, giving it exclusive, run-to-completion access to
  /// the reactive graph (build nodes, read slots, write cells). **Reentrant**:
  /// [fn] may itself call [withLock]/[batch]/[setCell] without deadlock — the
  /// depth counter simply nests.
  void withLock(void Function(Context ctx) fn) {
    _depth++;
    try {
      fn(_ctx);
    } finally {
      _depth--;
    }
  }

  /// Run [fn] under the guard and return its result — the read-oriented
  /// convenience over [withLock]. Reentrant.
  T read<T>(T Function(Context ctx) fn) {
    _depth++;
    try {
      return fn(_ctx);
    } finally {
      _depth--;
    }
  }

  /// Run [run] under the guard inside an underlying [Context.batch], so all cell
  /// writes queued in [run] flush in a single coalesced invalidation pass at the
  /// outermost boundary. The whole batch — including the invalidation flush — is
  /// one critical section. Nested [batch] calls only flush at the outermost
  /// [Context] boundary. Reentrant.
  void batch(void Function() run) {
    _depth++;
    try {
      _ctx.batch(run);
    } finally {
      _depth--;
    }
  }

  // -- Reactive creation (guarded passthroughs) --------------------------------

  /// Create a [Source] (source cell) under the guard.
  Source<T> source<T>(T value) => read((ctx) => Source<T>(ctx, value));

  /// Deprecated alias for [source] (`#lzcellkernel`).
  @Deprecated('Use source — the canonical source-cell constructor (#lzcellkernel)')
  Source<T> cell<T>(T value) => source<T>(value);

  /// Create a guarded [Computed] under the guard.
  Computed<T> computed<T>(T Function(Context ctx) compute) =>
      read((ctx) => Computed<T>(ctx, compute));

  /// Create a lazy, unguarded [Slot] under the guard. Retained as the
  /// lower-level unguarded primitive (dart keeps [Slot] distinct from the
  /// guarded [Computed]); prefer [computed] for a guarded derived value.
  Slot<T> slot<T>(T Function(Context ctx) compute) =>
      read((ctx) => Slot<T>(ctx, compute));

  // -- Reads (guarded passthroughs) --------------------------------------------

  /// Read a [Source] value under the guard — the unified cell read
  /// (`#lzcellkernel`).
  T get<T>(Source<T> handle) => read((_) => handle.get());

  /// Deprecated alias for [get] (`#lzcellkernel`).
  @Deprecated('Use get — the unified cell read (#lzcellkernel)')
  T getCell<T>(Source<T> cell) => get<T>(cell);

  /// Read a guarded [Computed] value under the guard.
  T getComputed<T>(Computed<T> handle) => read((_) => handle.get());

  /// Read a [Slot] value under the guard.
  T getSlot<T>(Slot<T> slot) => read((_) => slot.call());

  // -- Writes (guarded passthroughs) -------------------------------------------

  /// Write a [Source] value under the guard — the unified cell write
  /// (`#lzcellkernel`; only source cells are writable). Outside a [batch] it
  /// applies immediately (a singleton batch ≡ [Source.set], per
  /// `flushBatch_singleton_eq_setCell`); inside a [batch] it defers to the
  /// coalesced flush. Reentrant.
  void set<T>(Source<T> handle, T value) => withLock((_) => handle.set(value));

  /// Deprecated alias for [set] (`#lzcellkernel`).
  @Deprecated('Use set — the unified cell write (#lzcellkernel)')
  void setCell<T>(Source<T> cell, T value) => set<T>(cell, value);
}

// --- pure batch-flush kernel (faithful port of the Lean ThreadSafe model) --- //
//
// These operate on a plain node table so they can be property-tested against
// `LazilyFormal.ThreadSafe` independently of the live reactive graph. Faithful
// port of Go's ApplyBatch/FlushBatch/UnionDependents (`lazily-go/thread_safe.go`).

/// A node's `(value, state)` pair in the pure kernel. [state] is one of
/// `'clean'` / `'dirty'` — the Lean `Node.dirty` flag, projected to a string tag.
class NodeEntry {
  /// Create a node entry with [value] and dirty/clean [state].
  const NodeEntry(this.value, this.state);

  /// A clean node holding [value].
  const NodeEntry.clean(Object? value) : this(value, 'clean');

  /// A dirty node holding [value].
  const NodeEntry.dirty(Object? value) : this(value, 'dirty');

  /// The node's cached value.
  final Object? value;

  /// `'clean'` or `'dirty'` — the projected Lean dirty flag.
  final String state;

  @override
  bool operator ==(Object other) =>
      other is NodeEntry && other.value == value && other.state == state;

  @override
  int get hashCode => Object.hash(value, state);

  @override
  String toString() => 'NodeEntry($value, $state)';
}

/// A `(nodeId, value)` write accumulated under the guard — the pure model of the
/// lock-serialized write queue (Lean `Write`; Go `BatchWrite`).
class BatchWrite {
  /// Create a write of [value] to [nodeId].
  const BatchWrite(this.nodeId, this.value);

  /// The target node's id.
  final Object nodeId;

  /// The value to write.
  final Object? value;

  @override
  String toString() => 'BatchWrite($nodeId, $value)';
}

/// The result of [applyBatch]: the new node table plus the source ids that
/// actually changed (survived the `PartialEq` guard).
class ApplyBatchResult {
  /// Create a result carrying [nodes] and the [changed] source ids.
  const ApplyBatchResult(this.nodes, this.changed);

  /// The updated node table (a copy — the input is never mutated).
  final Map<Object, NodeEntry> nodes;

  /// The source ids whose value actually changed, deduplicated in first-changed
  /// order.
  final List<Object> changed;
}

/// Apply [batch]'s value updates (with the `PartialEq` guard) to a copy of
/// [nodes] and return the new table plus the list of source ids that actually
/// changed. A faithful port of the Lean `applyBatch` (and Go `ApplyBatch`): a
/// write to an unknown node, or one whose value is unchanged, produces no churn.
ApplyBatchResult applyBatch(
  Map<Object, NodeEntry> nodes,
  List<BatchWrite> batch,
) {
  final next = Map<Object, NodeEntry>.of(nodes);
  final changed = <Object>[];
  final seen = <Object>{};
  for (final w in batch) {
    final cur = next[w.nodeId];
    if (cur == null) continue; // unknown node — no churn.
    if (cur.value == w.value) continue; // PartialEq guard — no churn.
    next[w.nodeId] = NodeEntry(w.value, 'dirty');
    if (seen.add(w.nodeId)) changed.add(w.nodeId);
  }
  return ApplyBatchResult(next, changed);
}

/// The flat union of [dependents] over [sources] — a faithful port of the Lean
/// `unionDependents` (and Go `UnionDependents`). Plain flatMap: the dirty-flag
/// model makes marking an already-dirty node dirty a no-op, so deduplication is
/// a wire/delta concern handled in [flushBatch]'s frontier.
List<Object> unionDependents(
  Map<Object, List<Object>> dependents,
  List<Object> sources,
) {
  final out = <Object>[];
  for (final n in sources) {
    final deps = dependents[n];
    if (deps != null) out.addAll(deps);
  }
  return out;
}

/// Apply [batch]'s values, then mark the **coalesced union** of changed sources'
/// dependents dirty in one pass — a faithful port of the Lean `flushBatch` (and
/// Go `FlushBatch`). The coalesced frontier: a dependent reached through many
/// changed cells in one batch appears at most once (dedup), so the flush is a
/// deterministic function of the writes, independent of interleaving.
///
/// Certified by `flushBatch_singleton_eq_setCell` (a one-write batch ≡
/// [Cell.set]) and the coalesced-frontier / glitch-freedom laws
/// (`flushBatch_dependent_dirty`, `flushBatch_preserves_nondependent_dirty`).
Map<Object, NodeEntry> flushBatch(
  Map<Object, NodeEntry> nodes,
  Map<Object, List<Object>> dependents,
  List<BatchWrite> batch,
) {
  final applied = applyBatch(nodes, batch);
  final next = applied.nodes;
  final frontier = <Object>[];
  final inFrontier = <Object>{};
  for (final src in applied.changed) {
    final deps = dependents[src];
    if (deps == null) continue;
    for (final d in deps) {
      if (inFrontier.add(d)) frontier.add(d);
    }
  }
  for (final d in frontier) {
    final entry = next[d];
    if (entry != null) next[d] = NodeEntry(entry.value, 'dirty');
  }
  return next;
}
