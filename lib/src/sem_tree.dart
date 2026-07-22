/// Memoized semantic tree — a reactive, incrementally-memoized fold tree.
///
/// One guarded [Computed] per node folds `(node value, [child derived values])`.
/// Editing one node recomputes only its **ancestor chain**; a sibling subtree's
/// derived slot stays cached. A node edit that does not change the folded value
/// does not re-run a downstream consumer (the [Computed] equality guard).
///
/// Composes over a reactive [Context]. Mirrors `lazily-js/src/sem-tree.js`.
/// Conforms to `lazily-spec` `conformance/collections/semtree_incremental.json`.
library;

import 'core.dart';

/// A node spec for building a [SemTree].
class TreeNodeSpec {
  TreeNodeSpec({
    required this.id,
    required this.value,
    this.children,
  });

  final String id;
  final Object? value;
  final TreeNodeChildren? children;
}

class TreeNodeChildren {
  TreeNodeChildren({this.order, this.values});

  final List<String>? order;
  final Map<String, TreeNodeSpec>? values;
}

/// A fold function: combine a node's value with its children's derived values.
typedef FoldFn<V, D> = D Function(V value, List<D> childDerived);

class _SemNode {
  _SemNode(this.id);
  final String id;

  late Source<Object?> valueCell;
  late Source<List<String>> childKeysCell;
  final Map<String, Computed<Object?>> childSlots = {};
  Computed<Object?>? slot;
}

/// A memoized semantic tree.
///
/// Build via [SemTree.build]. The child-slot map is fixed at build time;
/// inserting a brand-new child requires a fresh [build] (mirrors lazily-rs/
/// lazily-kt). Removals mutate the parent's child-keys cell.
class SemTree<V, D> {
  SemTree._(this._ctx, this._fold);

  final Context _ctx;
  final FoldFn<V, D> _fold;
  final Map<String, _SemNode> _nodes = {};
  late final String _rootId;

  /// Build a [SemTree] from [rootSpec] using [fold].
  static SemTree<V, D> build<V, D>(
    Context ctx,
    TreeNodeSpec rootSpec,
    FoldFn<V, D> fold,
  ) {
    final tree = SemTree<V, D>._(ctx, fold);
    tree._rootId = rootSpec.id;
    tree._build(rootSpec);
    return tree;
  }

  _SemNode _build(TreeNodeSpec spec) {
    final node = _SemNode(spec.id);
    node.valueCell = Source<Object?>(_ctx, spec.value);
    _nodes[spec.id] = node;

    final childOrder = <String>[];
    final kids = spec.children;
    if (kids != null) {
      final order = kids.order ?? (kids.values?.keys.toList() ?? <String>[]);
      for (final childKey in order) {
        final childSpec = kids.values?[childKey];
        if (childSpec == null) continue;
        final childNode = _build(childSpec);
        childOrder.add(childSpec.id);
        node.childSlots[childSpec.id] = childNode.slot!;
      }
    }

    node.childKeysCell = Source<List<String>>(_ctx, childOrder);

    // Register the computed AFTER childKeysCell is set, so it observes it.
    node.slot = Computed<Object?>(_ctx, (cx) {
      final v = cx.get(node.valueCell) as V;
      final keys = cx.get(node.childKeysCell);
      final ds = <D>[];
      for (final kid in keys) {
        final childSlot = node.childSlots[kid];
        if (childSlot != null) {
          ds.add(cx.get(childSlot) as D);
        }
      }
      return _fold(v, ds) as Object?;
    });

    return node;
  }

  /// Set the value of node [id]. Throws [StateError] if absent.
  void setValue(String id, V value) {
    final node = _nodes[id];
    if (node == null) {
      throw StateError('SemTree: unknown node $id');
    }
    node.valueCell.value = value;
  }

  /// Remove child [childId] from parent [parentId]. Throws [StateError] if
  /// the parent is absent.
  void removeChild(String parentId, String childId) {
    final node = _nodes[parentId];
    if (node == null) {
      throw StateError('SemTree: unknown parent node $parentId');
    }
    final keys = node.childKeysCell.value.where((k) => k != childId).toList();
    node.childKeysCell.value = keys;
  }

  /// The root's derived value (reactive read).
  D value() => (_nodes[_rootId]!.slot!()) as D;

  /// The derived value of node [id], or null if absent.
  D? nodeValue(String id) {
    final node = _nodes[id];
    if (node?.slot == null) return null;
    return node!.slot!() as D;
  }

  /// Whether node [id]'s derived value is currently cached.
  bool isCached(String id) {
    final node = _nodes[id];
    if (node?.slot == null) return false;
    return _ctx.contains(node!.slot!);
  }

  /// The root slot handle.
  Computed<Object?> rootHandle() => _nodes[_rootId]!.slot!;

  /// The slot handle for node [id], or null if absent.
  Computed<Object?>? nodeHandle(String id) => _nodes[id]?.slot;
}
