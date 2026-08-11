import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

/// The canonical `(counter, peer)` ordering of [LosslessTreeCrdt.diff]
/// (#lzdifforderallbindings).
///
/// The order is a CROSS-BINDING CONTRACT, not an implementation detail: the
/// shared corpus addresses diff output POSITIONALLY. `lossless-tree/
/// non_contiguous_anti_entropy.json` says `deliver.only: [0, 2]`, which indexes
/// into whatever `diff` returns, so that fixture only means the same thing in
/// every binding while every binding returns the same order.
///
/// The corpus cannot police it. Measured in lazily-zig (commit e8a2a28): both
/// REVERSING the diff sort and DELETING it outright left the entire suite green,
/// anti-entropy fixture included — the two indices select the same SET either
/// way, and `applyUpdate` is order-tolerant by design. Only a direct test
/// catches a reorder, which is why this one exists.
void main() {
  test('diff returns ops in canonical (counter, peer) order', () {
    final a = LosslessTreeCrdt(1);
    final para =
        a.createNode(TreeNodeId.root, null, const NodeSeedElement('para'));
    final base =
        a.createNode(para, null, const NodeSeedLeaf(LeafKind.trivia, '0'));

    final b = a.fork(2);

    // `a` runs ahead to counter 4 while `b`'s single op stays at counter 3, so
    // the remote op ARRIVES last and SORTS earlier. Without that split, arrival
    // order and canonical order coincide and the assertions below would hold
    // for an unsorted — or reversed — diff too, pinning nothing.
    final one =
        a.createNode(para, base, const NodeSeedLeaf(LeafKind.trivia, '1'));
    final two =
        a.createNode(para, one, const NodeSeedLeaf(LeafKind.trivia, '2'));
    final nine =
        b.createNode(para, base, const NodeSeedLeaf(LeafKind.trivia, '9'));

    a.applyUpdate(b.diff(a.frontier()));

    // The log is private, so arrival order is reconstructed from the ids the
    // create calls returned: four local commits in the order they were made,
    // then the remote op `applyUpdate` appended last.
    final arrival = <TreeOpId>[para.op, base.op, one.op, two.op, nine.op];
    final canonical = List<TreeOpId>.from(arrival)..sort();

    // Non-vacuity, asserted EXPLICITLY before the ordering check: the two
    // orders genuinely differ.
    expect(nine.op.counter, lessThan(two.op.counter),
        reason: 'the remote op must carry a LOWER counter than the local op it '
            'arrived after, or arrival order and canonical order coincide');
    expect(canonical, isNot(equals(arrival)),
        reason: 'arrival order and canonical order must DIFFER, or a diff that '
            'returns log order (or reverses it) would satisfy this test');

    final ids = a.diff(TreeVersionFrontier()).ops.map((op) => op.id).toList();

    expect(ids.length, arrival.length,
        reason: 'diff over an empty frontier must return every held op');
    expect(ids, equals(canonical),
        reason: 'diff must return canonical (counter, peer) order, not the '
            'order the ops arrived in');
    for (var i = 1; i < ids.length; i++) {
      expect(ids[i - 1].compareTo(ids[i]), lessThan(0),
          reason: 'diff must be strictly increasing by (counter, peer): '
              '${ids[i - 1]} then ${ids[i]}');
    }
  });
}
