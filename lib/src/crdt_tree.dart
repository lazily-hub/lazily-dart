/// Lossless mergeable document-tree contract (`#lzcrdttree`).
library;

/// A lossless document CRDT with one identity-preserving delta representation.
///
/// [mergeFrom] and [applyDelta] are commutative, associative, and idempotent.
/// `deltaSince(empty frontier)` is the snapshot, so full and incremental
/// replication preserve the same operation identities.
abstract interface class CrdtTree<V, D, T> {
  V versionVector();
  D deltaSince(V version);
  bool applyDelta(D delta);
  String text();
  T value();
  bool mergeFrom(CrdtTree<V, D, T> other);
}
