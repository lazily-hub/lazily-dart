// Phase 1 of the RelayCell backpressure plan (#relaycell) — the merge algebra
// and the Reactive/Source read/write split.
//
// See lazily-spec/docs/reactive-graph.md § "MergeCell and the merge algebra" and
// relaycell-backpressure-analysis.md §4.0/§4.3. A merge policy is an associative
// fold ⊕: T×T→T; the properties it satisfies (associativity always; commutativity
// = reordering tax; idempotency = durability tax) select which overflow behaviour
// is sound. MergeCell generalizes a plain Cell — Cell ≡ MergeCell(KeepLatest) —
// a source whose write is a merge. Backed by an ordinary cell, so it inherits the
// Phase-0 != store-guard + store-without-cascade.

import 'core.dart';

/// An associative merge `⊕` with its transport-selected property flags.
///
/// Associativity (`(a⊕b)⊕c == a⊕(b⊕c)`) is a law, verified by the law-tests, not
/// a flag. [commutative] is the reordering tax; [idempotent] the durability tax;
/// [conflates] gates the `Conflate` overflow (Phase 2 — only `RawFifo` cannot bound).
class MergePolicy<T> {
  const MergePolicy(
    this.name,
    this.merge, {
    required this.commutative,
    required this.idempotent,
    this.conflates = true,
  });

  final String name;
  final T Function(T old, T op) merge;
  final bool commutative;
  final bool idempotent;
  final bool conflates;
}

/// Keep-latest band (`old ⊕ op = op`) — the policy behind a plain [Cell].
MergePolicy<T> keepLatest<T>() =>
    MergePolicy('KeepLatest', (old, op) => op, commutative: false, idempotent: true);

/// Additive commutative monoid (`old + op`). Not idempotent.
MergePolicy<int> sum() =>
    MergePolicy('Sum', (a, b) => a + b, commutative: true, idempotent: false);

/// Max semilattice (`max(old, op)`). Associative, commutative, idempotent.
MergePolicy<int> max() => MergePolicy(
      'Max',
      (a, b) => b > a ? b : a,
      commutative: true,
      idempotent: true,
    );

/// Grow-only set-union semilattice over [Set].
MergePolicy<Set<E>> setUnion<E>() => MergePolicy(
      'SetUnion',
      (old, op) => {...old, ...op},
      commutative: true,
      idempotent: true,
    );

/// Raw FIFO append over [List] (`old ++ op`). Order + multiplicity are meaning —
/// associative only; cannot conflate.
MergePolicy<List<E>> rawFifo<E>() => MergePolicy(
      'RawFifo',
      (old, op) => [...old, ...op],
      commutative: false,
      idempotent: false,
      conflates: false,
    );

/// The read supertype: `get` (analysis §4.0). Every reader satisfies it.
abstract interface class Reactive<T> {
  T get();
}

/// A writable [Reactive] — adds `set` (replace) and `merge` (fold under policy).
abstract interface class Source<T> implements Reactive<T> {
  void set(T value);
  void merge(T op);
}

/// A cell whose write is a *merge* under [policy] rather than a replace.
///
/// `Cell ≡ MergeCell(KeepLatest)`. `merge` routes through the cell's `!=`-guarded
/// setter, so an idempotent policy's no-op merge fires no cascade (free dedup)
/// and store-without-cascade still applies.
class MergeCell<T> implements Source<T> {
  MergeCell(Context ctx, T initial, this.policy) : cell = Cell<T>(ctx, initial);

  /// The underlying reactive cell (for wiring derived readers).
  final Cell<T> cell;
  final MergePolicy<T> policy;

  /// Read the current converged value (tracks a dependency in a computation).
  @override
  T get() => cell.get();

  /// Replace the value outright (the keep-latest write), bypassing the policy.
  @override
  void set(T value) => cell.set(value);

  /// Fold `op` into the current value under the policy. Reads untracked via peek.
  @override
  void merge(T op) => cell.set(policy.merge(cell.peek, op));
}

/// Create a [MergeCell] over [ctx].
MergeCell<T> mergeCell<T>(Context ctx, T initial, MergePolicy<T> policy) =>
    MergeCell(ctx, initial, policy);
