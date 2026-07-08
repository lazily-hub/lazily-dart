/// Lossless full-document tree CRDT — M1 syntax-agnostic core (`#lzlosstree`).
///
/// A lossless concrete-syntax tree CRDT whose leaves own every rendered byte.
/// Where [TextCrdt] is a *flat* lossless floor and [SeqCrdt] orders opaque keyed
/// siblings, this is a **single rooted concrete-syntax tree** whose *leaves own
/// every rendered byte*. The guiding invariant is losslessness —
/// `render(tree) == source_text` for valid, invalid, and unknown source alike —
/// so the tree itself can be the wire authority instead of a semantic AST
/// layered over a separate text floor. Internal Element nodes own *structure
/// only*; all text lives in Leaf nodes tagged Token / Trivia / Raw / Error, so
/// unknown or invalid spans round-trip exactly as Raw/Error leaves rather than
/// being discarded.
///
/// M1 scope: create / tombstone / intra-parent reorder / leaf-edit / split-leaf /
/// merge-adjacent-leaves, plus op-based delta sync over a dotted, non-contiguous
/// version frontier ([TreeVersionFrontier]). Positions and seed text travel
/// inside ops so both replicas store byte-identical keys and converge.
///
/// Mirrors `lazily-kt/.../LosslessTreeCrdt.kt` and `lazily-js/.../lossless-tree-crdt.js`.
/// Leaf text embeds [TextCrdt] wholesale; child order is a minimal move-aware
/// fractional index ([keyBetween], mirroring [SeqCrdt]'s proven generator); the
/// clock is a Lamport [TreeOpId]. Leaf-local text offsets on the wire are UTF-8
/// bytes, converted via [byteToCodePoint] / [codePointToUtf16].
library;

import 'text_crdt.dart' show OpId, TextCrdt, TextOp;
import 'utf8_offsets.dart';
import 'seq_crdt.dart' show keyBetween;

/// A dotted, totally-ordered operation id (Lamport counter tiebroken by peer),
/// ordered `(counter, peer)`. Distinct from [OpId] (the text-CRDT char id).
class TreeOpId implements Comparable<TreeOpId> {
  const TreeOpId(this.counter, this.peer);

  final int counter;
  final int peer;

  @override
  int compareTo(TreeOpId other) {
    final c = counter.compareTo(other.counter);
    if (c != 0) return c;
    return peer.compareTo(other.peer);
  }

  @override
  bool operator ==(Object other) =>
      other is TreeOpId && counter == other.counter && peer == other.peer;

  @override
  int get hashCode => Object.hash(counter, peer);

  @override
  String toString() => 'TreeOpId($counter,$peer)';

  /// Wire form: `{"counter": int, "peer": int}`.
  Map<String, dynamic> toWire() => {'counter': counter, 'peer': peer};

  static TreeOpId fromWire(Object? v) {
    final m = v as Map<String, dynamic>;
    return TreeOpId(m['counter'] as int, m['peer'] as int);
  }
}

/// Stable identity of one tree node: the id of the op that created it.
class TreeNodeId implements Comparable<TreeNodeId> {
  const TreeNodeId(this.op);

  final TreeOpId op;

  /// The sentinel id of the document root.
  static const TreeNodeId root = TreeNodeId(TreeOpId(0, 0));

  @override
  int compareTo(TreeNodeId other) => op.compareTo(other.op);

  @override
  bool operator ==(Object other) =>
      other is TreeNodeId && op == other.op;

  @override
  int get hashCode => op.hashCode;

  @override
  String toString() => 'TreeNodeId($op)';

  /// Node ids serialize as bare op ids (newtype transparent).
  Map<String, dynamic> toWire() => op.toWire();

  static TreeNodeId fromWire(Object? v) =>
      TreeNodeId(TreeOpId.fromWire(v));
}

/// Classification of a leaf's exact source span.
enum LeafKind {
  token('Token'),
  trivia('Trivia'),
  raw('Raw'),
  error('Error');

  const LeafKind(this.wire);

  final String wire;

  static LeafKind fromWire(String v) =>
      values.firstWhere((k) => k.wire == v,
          orElse: () => throw FormatException('unknown leaf kind: $v'));
}

/// What a `CreateNode` materializes: an element shell or a seeded text leaf.
sealed class NodeSeed {
  const NodeSeed();

  /// Externally-tagged wire form.
  Map<String, dynamic> toWire();
  static NodeSeed fromWire(Object? v) {
    final m = v as Map<String, dynamic>;
    if (m.length != 1) {
      throw FormatException('NodeSeed must be externally tagged: $v');
    }
    final tag = m.keys.single;
    final body = m[tag] as Map<String, dynamic>;
    switch (tag) {
      case 'Element':
        return NodeSeedElement(body['kind'] as String);
      case 'Leaf':
        return NodeSeedLeaf(
          LeafKind.fromWire(body['kind'] as String),
          body['text'] as String,
        );
      default:
        throw FormatException('unknown NodeSeed variant: $tag');
    }
  }
}

/// An element shell (structure only).
final class NodeSeedElement extends NodeSeed {
  const NodeSeedElement(this.kind);
  final String kind;

  @override
  Map<String, dynamic> toWire() => {'Element': {'kind': kind}};

  @override
  bool operator ==(Object other) =>
      other is NodeSeedElement && kind == other.kind;
  @override
  int get hashCode => Object.hash('Element', kind);
  @override
  String toString() => 'NodeSeed.Element($kind)';
}

/// A seeded text leaf.
final class NodeSeedLeaf extends NodeSeed {
  const NodeSeedLeaf(this.kind, this.text);
  final LeafKind kind;
  final String text;

  @override
  Map<String, dynamic> toWire() => {'Leaf': {'kind': kind.wire, 'text': text}};

  @override
  bool operator ==(Object other) =>
      other is NodeSeedLeaf && kind == other.kind && text == other.text;
  @override
  int get hashCode => Object.hash('Leaf', kind, text);
  @override
  String toString() => 'NodeSeed.Leaf($kind,$text)';
}

/// A fractional-index child position: orderable bytes tiebroken by minting peer.
class SortKey implements Comparable<SortKey> {
  const SortKey(this.frac, this.peer);

  /// Bytes in `0..255`.
  final List<int> frac;
  final int peer;

  @override
  int compareTo(SortKey other) {
    final n = frac.length < other.frac.length ? frac.length : other.frac.length;
    for (var i = 0; i < n; i++) {
      final c = frac[i].compareTo(other.frac[i]);
      if (c != 0) return c;
    }
    final lenCmp = frac.length.compareTo(other.frac.length);
    if (lenCmp != 0) return lenCmp;
    return peer.compareTo(other.peer);
  }

  @override
  bool operator ==(Object other) =>
      other is SortKey &&
      _listEquals(frac, other.frac) &&
      peer == other.peer;

  @override
  int get hashCode => Object.hash(Object.hashAll(frac), peer);

  @override
  String toString() => 'SortKey(${frac.join(',')},$peer)';

  /// Wire form: `{"frac": [u8...], "peer": int}`.
  Map<String, dynamic> toWire() => {'frac': List<int>.from(frac), 'peer': peer};

  static SortKey fromWire(Object? v) {
    final m = v as Map<String, dynamic>;
    return SortKey(
      List<int>.from(m['frac'] as List),
      m['peer'] as int,
    );
  }
}

/// The M1 op vocabulary. Positions/seed text travel inside the op.
sealed class TreeOpKind {
  const TreeOpKind();

  /// Externally-tagged wire form.
  Map<String, dynamic> toWire();

  static TreeOpKind fromWire(Object? v) {
    final m = v as Map<String, dynamic>;
    if (m.length != 1) {
      throw FormatException('TreeOpKind must be externally tagged: $v');
    }
    final tag = m.keys.single;
    final body = m[tag] as Map<String, dynamic>;
    switch (tag) {
      case 'CreateNode':
        return TreeOpKindCreateNode(
          TreeNodeId.fromWire(body['id']),
          TreeNodeId.fromWire(body['parent']),
          SortKey.fromWire(body['sort']),
          NodeSeed.fromWire(body['seed']),
        );
      case 'Tombstone':
        return TreeOpKindTombstone(TreeNodeId.fromWire(body['node']));
      case 'Reorder':
        return TreeOpKindReorder(
          TreeNodeId.fromWire(body['node']),
          SortKey.fromWire(body['sort']),
        );
      case 'LeafEdit':
        return TreeOpKindLeafEdit(
          TreeNodeId.fromWire(body['node']),
          TreeOpId.fromWire(body['prev']),
          (body['ops'] as List).map(TextOp.fromWire).toList(),
        );
      case 'SplitLeaf':
        return TreeOpKindSplitLeaf(
          TreeNodeId.fromWire(body['node']),
          TreeNodeId.fromWire(body['new']),
          SortKey.fromWire(body['sort']),
          body['at_char'] as int,
          TreeOpId.fromWire(body['prev']),
        );
      case 'MergeLeaves':
        return TreeOpKindMergeLeaves(
          TreeNodeId.fromWire(body['left']),
          TreeNodeId.fromWire(body['right']),
          TreeOpId.fromWire(body['prev_left']),
          TreeOpId.fromWire(body['prev_right']),
        );
      default:
        throw FormatException('unknown TreeOpKind variant: $tag');
    }
  }
}

/// Materialize a node under a parent at a sort position from a seed.
final class TreeOpKindCreateNode extends TreeOpKind {
  const TreeOpKindCreateNode(this.id, this.parent, this.sort, this.seed);
  final TreeNodeId id;
  final TreeNodeId parent;
  final SortKey sort;
  final NodeSeed seed;

  @override
  Map<String, dynamic> toWire() => {
        'CreateNode': {
          'id': id.toWire(),
          'parent': parent.toWire(),
          'sort': sort.toWire(),
          'seed': seed.toWire(),
        },
      };

  @override
  bool operator ==(Object other) =>
      other is TreeOpKindCreateNode &&
      id == other.id &&
      parent == other.parent &&
      sort == other.sort &&
      seed == other.seed;
  @override
  int get hashCode => Object.hash('CreateNode', id, parent, sort, seed);
}

/// Tombstone a node (its subtree renders away).
final class TreeOpKindTombstone extends TreeOpKind {
  const TreeOpKindTombstone(this.node);
  final TreeNodeId node;

  @override
  Map<String, dynamic> toWire() => {'Tombstone': {'node': node.toWire()}};

  @override
  bool operator ==(Object other) =>
      other is TreeOpKindTombstone && node == other.node;
  @override
  int get hashCode => Object.hash('Tombstone', node);
}

/// Reorder a node within its parent to a new sort position.
final class TreeOpKindReorder extends TreeOpKind {
  const TreeOpKindReorder(this.node, this.sort);
  final TreeNodeId node;
  final SortKey sort;

  @override
  Map<String, dynamic> toWire() => {
        'Reorder': {'node': node.toWire(), 'sort': sort.toWire()},
      };

  @override
  bool operator ==(Object other) =>
      other is TreeOpKindReorder && node == other.node && sort == other.sort;
  @override
  int get hashCode => Object.hash('Reorder', node, sort);
}

/// Edit a leaf's text by applying a text-CRDT delta.
final class TreeOpKindLeafEdit extends TreeOpKind {
  const TreeOpKindLeafEdit(this.node, this.prev, this.ops);
  final TreeNodeId node;
  final TreeOpId prev;
  final List<TextOp> ops;

  @override
  Map<String, dynamic> toWire() => {
        'LeafEdit': {
          'node': node.toWire(),
          'prev': prev.toWire(),
          'ops': ops.map((o) => o.toWire()).toList(),
        },
      };

  @override
  bool operator ==(Object other) =>
      other is TreeOpKindLeafEdit &&
      node == other.node &&
      prev == other.prev &&
      _listEquals(ops, other.ops);
  @override
  int get hashCode => Object.hash('LeafEdit', node, prev);
}

/// Split a leaf into two adjacent leaves of the same kind.
final class TreeOpKindSplitLeaf extends TreeOpKind {
  const TreeOpKindSplitLeaf(this.node, this.newNode, this.sort, this.atChar, this.prev);
  final TreeNodeId node;
  final TreeNodeId newNode;
  final SortKey sort;
  final int atChar;
  final TreeOpId prev;

  @override
  Map<String, dynamic> toWire() => {
        'SplitLeaf': {
          'node': node.toWire(),
          'new': newNode.toWire(),
          'sort': sort.toWire(),
          'at_char': atChar,
          'prev': prev.toWire(),
        },
      };

  @override
  bool operator ==(Object other) =>
      other is TreeOpKindSplitLeaf &&
      node == other.node &&
      newNode == other.newNode &&
      sort == other.sort &&
      atChar == other.atChar &&
      prev == other.prev;
  @override
  int get hashCode => Object.hash('SplitLeaf', node, newNode, sort, atChar, prev);
}

/// Merge two adjacent live leaf siblings into one.
final class TreeOpKindMergeLeaves extends TreeOpKind {
  const TreeOpKindMergeLeaves(this.left, this.right, this.prevLeft, this.prevRight);
  final TreeNodeId left;
  final TreeNodeId right;
  final TreeOpId prevLeft;
  final TreeOpId prevRight;

  @override
  Map<String, dynamic> toWire() => {
        'MergeLeaves': {
          'left': left.toWire(),
          'right': right.toWire(),
          'prev_left': prevLeft.toWire(),
          'prev_right': prevRight.toWire(),
        },
      };

  @override
  bool operator ==(Object other) =>
      other is TreeOpKindMergeLeaves &&
      left == other.left &&
      right == other.right &&
      prevLeft == other.prevLeft &&
      prevRight == other.prevRight;
  @override
  int get hashCode =>
      Object.hash('MergeLeaves', left, right, prevLeft, prevRight);
}

/// A transport-ready tree operation: its dotted id plus the change it encodes.
class TreeOp {
  const TreeOp(this.id, this.kind);
  final TreeOpId id;
  final TreeOpKind kind;

  @override
  bool operator ==(Object other) =>
      other is TreeOp && id == other.id && kind == other.kind;
  @override
  int get hashCode => Object.hash(id, kind);

  Map<String, dynamic> toWire() => {'id': id.toWire(), 'kind': kind.toWire()};

  static TreeOp fromWire(Object? v) {
    final m = v as Map<String, dynamic>;
    return TreeOp(
      TreeOpId.fromWire(m['id']),
      TreeOpKind.fromWire(m['kind']),
    );
  }
}

/// A batch of ops — the output of [LosslessTreeCrdt.diff], input to
/// [LosslessTreeCrdt.applyUpdate].
class TreeUpdate {
  const TreeUpdate(this.ops);
  final List<TreeOp> ops;

  @override
  bool operator ==(Object other) =>
      other is TreeUpdate && _listEquals(ops, other.ops);
  @override
  int get hashCode => Object.hashAll(ops);

  /// Externally-tagged wire JSON validating against
  /// `lazily-spec/schemas/lossless-tree-delta.json`.
  Map<String, dynamic> toWire() => {
        'ops': ops.map((o) => o.toWire()).toList(),
      };

  static TreeUpdate fromWire(Object? v) {
    final m = v as Map<String, dynamic>;
    return TreeUpdate(
      (m['ops'] as List).map(TreeOp.fromWire).toList(),
    );
  }
}

/// Errors from tree mutations. Text preservation wins, so these reject rather
/// than drop bytes.
class TreeException implements Exception {
  TreeException(this.message);
  final String message;
  @override
  String toString() => 'TreeException: $message';
}

/// The observed dots for one peer: a contiguous prefix plus out-of-order holes.
class _DotRange {
  int contiguous = 0;
  final Set<int> sparse = {};

  bool contains(int counter) => counter <= contiguous || sparse.contains(counter);

  void observe(int counter) {
    if (counter <= contiguous) return;
    sparse.add(counter);
    while (sparse.remove(contiguous + 1)) {
      contiguous += 1;
    }
  }

  _DotRange copy() {
    final r = _DotRange()
      ..contiguous = contiguous
      ..sparse.addAll(sparse);
    return r;
  }
}

/// A dotted version frontier: per peer, exactly which op dots are held. Unlike a
/// version vector (per-peer max), this represents non-contiguous delivery so
/// [LosslessTreeCrdt.diff] never omits a missing interior op.
class TreeVersionFrontier {
  final Map<int, _DotRange> _dots;

  TreeVersionFrontier() : _dots = {};
  TreeVersionFrontier._(this._dots);

  /// Whether the op with dotted [id] is held.
  bool contains(TreeOpId id) => _dots[id.peer]?.contains(id.counter) ?? false;

  void _observe(TreeOpId id) {
    (_dots[id.peer] ??= _DotRange()).observe(id.counter);
  }

  TreeVersionFrontier _deepCopy() {
    final out = <int, _DotRange>{};
    for (final entry in _dots.entries) {
      out[entry.key] = entry.value.copy();
    }
    return TreeVersionFrontier._(out);
  }
}

sealed class _NodeBody {}

final class _ElementBody extends _NodeBody {
  _ElementBody(this.kind);
  String kind;
}

final class _LeafBody extends _NodeBody {
  _LeafBody(this.kind, this.text);
  LeafKind kind;
  TextCrdt? text;
}

class _NodeRecord {
  _NodeRecord({
    this.parent,
    required this.sort,
    required this.sortStamp,
    required this.body,
    this.tomb,
    required this.textHead,
  });

  TreeNodeId? parent;
  SortKey sort;
  TreeOpId sortStamp;
  _NodeBody body;
  TreeOpId? tomb;
  TreeOpId textHead;
}

/// A lossless concrete-syntax tree CRDT (M1 core).
class LosslessTreeCrdt {
  LosslessTreeCrdt(this._peer)
      : _counter = 0,
        _nodes = {},
        _frontier = TreeVersionFrontier(),
        _log = [],
        _buffered = [] {
    _nodes[TreeNodeId.root] = _NodeRecord(
      parent: null,
      sort: const SortKey([], 0),
      sortStamp: const TreeOpId(0, 0),
      body: _ElementBody('root'),
      tomb: null,
      textHead: const TreeOpId(0, 0),
    );
  }

  LosslessTreeCrdt._(
    this._peer,
    this._counter,
    this._nodes,
    this._frontier,
    this._log,
    this._buffered,
  );

  int _peer;
  int _counter;
  final Map<TreeNodeId, _NodeRecord> _nodes;
  final TreeVersionFrontier _frontier;
  final List<TreeOp> _log;
  final List<TreeOp> _buffered;

  /// Fork this replica's full state under a new owning [peer] (deep copy, new
  /// identity).
  LosslessTreeCrdt fork(int peer) =>
      LosslessTreeCrdt._(peer, _counter, _copyNodes(), _frontier._deepCopy(),
          List<TreeOp>.from(_log), List<TreeOp>.from(_buffered));

  Map<TreeNodeId, _NodeRecord> _copyNodes() {
    final out = <TreeNodeId, _NodeRecord>{};
    for (final entry in _nodes.entries) {
      final r = entry.value;
      final body = switch (r.body) {
        _ElementBody() => _ElementBody((r.body as _ElementBody).kind),
        _LeafBody() => () {
            final b = r.body as _LeafBody;
            return _LeafBody(b.kind, b.text?.clone());
          }(),
      };
      out[entry.key] = _NodeRecord(
        parent: r.parent,
        sort: r.sort,
        sortStamp: r.sortStamp,
        body: body,
        tomb: r.tomb,
        textHead: r.textHead,
      );
    }
    return out;
  }

  TreeOpId _nextOpId() {
    _counter += 1;
    return TreeOpId(_counter, _peer);
  }

  /// The live children of [parent], in rendered (SortKey) order.
  List<TreeNodeId> _liveChildren(TreeNodeId parent) {
    final kids = <MapEntry<TreeNodeId, _NodeRecord>>[];
    for (final entry in _nodes.entries) {
      if (entry.value.parent == parent && entry.value.tomb == null) {
        kids.add(entry);
      }
    }
    kids.sort((a, b) => a.value.sort.compareTo(b.value.sort));
    return kids.map((e) => e.key).toList();
  }

  /// Render the whole document by concatenating live-leaf text in tree order.
  String render() {
    final sb = StringBuffer();
    _renderInto(TreeNodeId.root, sb);
    return sb.toString();
  }

  void _renderInto(TreeNodeId id, StringBuffer sb) {
    final rec = _nodes[id];
    if (rec == null) return;
    switch (rec.body) {
      case _LeafBody():
        sb.write((rec.body as _LeafBody).text?.text() ?? '');
      case _ElementBody():
        for (final child in _liveChildren(id)) {
          _renderInto(child, sb);
        }
    }
  }

  /// Live nodes excluding the root — grows by one on split, restored on merge.
  int liveNodeCount() => _nodes.entries
      .where((e) => e.key != TreeNodeId.root && e.value.tomb == null)
      .length;

  /// This replica's dotted version frontier (what to advertise to a partner).
  TreeVersionFrontier frontier() => _frontier._deepCopy();

  /// The kind of an element node, or `null` if [node] is absent or a leaf.
  String? elementKind(TreeNodeId node) {
    final rec = _nodes[node];
    if (rec == null) return null;
    final body = rec.body;
    return body is _ElementBody ? body.kind : null;
  }

  /// The kind of a leaf node, or `null` if [node] is absent or an element.
  LeafKind? leafKind(TreeNodeId node) {
    final rec = _nodes[node];
    if (rec == null) return null;
    final body = rec.body;
    return body is _LeafBody ? body.kind : null;
  }

  /// The live children of [parent] in rendered order.
  List<TreeNodeId> children(TreeNodeId parent) => _liveChildren(parent);

  /// A leaf's current text; throws if [node] is absent or an element.
  String leafText(TreeNodeId node) {
    final rec = _nodes[node];
    if (rec == null) throw TreeException('node not found');
    final body = rec.body;
    if (body is _LeafBody) return body.text?.text() ?? '';
    throw TreeException('node is not a leaf');
  }

  _LeafBody _leafBody(TreeNodeId node) {
    final rec = _nodes[node];
    if (rec == null) throw TreeException('node not found');
    final body = rec.body;
    if (body is _LeafBody) return body;
    throw TreeException('node is not a leaf');
  }

  /// The fractional key placing a new/moved child of [parent] immediately after
  /// [after] (front when `null`).
  SortKey _keyAfter(TreeNodeId parent, TreeNodeId? after) {
    final order = _liveChildren(parent);
    List<int>? loFrac;
    List<int>? hiFrac;
    if (after == null) {
      loFrac = null;
      hiFrac = order.isEmpty ? null : _nodes[order.first]!.sort.frac;
    } else {
      final idx = order.indexOf(after);
      if (idx >= 0) {
        loFrac = _nodes[after]!.sort.frac;
        hiFrac = (idx + 1 < order.length)
            ? _nodes[order[idx + 1]]!.sort.frac
            : null;
      } else {
        // Anchor not a live child: append at the end.
        loFrac = order.isEmpty ? null : _nodes[order.last]!.sort.frac;
        hiFrac = null;
      }
    }
    return SortKey(keyBetween(loFrac, hiFrac), _peer);
  }

  /// Create a node under [parent], positioned after [after] (front when `null`).
  TreeNodeId createNode(TreeNodeId parent, TreeNodeId? after, NodeSeed seed) {
    if (!_nodes.containsKey(parent)) throw TreeException('node not found');
    final sort = _keyAfter(parent, after);
    final opId = _nextOpId();
    final node = TreeNodeId(opId);
    _commitLocal(TreeOp(
        opId, TreeOpKindCreateNode(node, parent, sort, seed)));
    return node;
  }

  /// Tombstone [node] (its subtree renders away once the ancestor is gone).
  void tombstoneNode(TreeNodeId node) {
    if (!_nodes.containsKey(node) || node == TreeNodeId.root) {
      throw TreeException('node not found');
    }
    final opId = _nextOpId();
    _commitLocal(TreeOp(opId, TreeOpKindTombstone(node)));
  }

  /// Reorder [node] within its parent to just after [after] (front when `null`).
  void reorderChild(TreeNodeId node, TreeNodeId? after) {
    final rec = _nodes[node];
    if (rec == null || rec.parent == null) {
      throw TreeException('node not found');
    }
    final sort = _keyAfter(rec.parent!, after);
    final opId = _nextOpId();
    _commitLocal(TreeOp(opId, TreeOpKindReorder(node, sort)));
  }

  /// Edit a leaf's text: delete [deleteBytes] and insert [insert] at UTF-8 byte
  /// offset [atByte] (leaf-local). Offsets must land on char boundaries.
  void editLeaf(TreeNodeId node, int atByte, int deleteBytes, String insert) {
    final s = leafText(node);
    final start = byteToCodePoint(s, atByte);
    if (start == null) throw TreeException('offset not on a char boundary');
    final end = byteToCodePoint(s, atByte + deleteBytes);
    if (end == null) throw TreeException('offset not on a char boundary');
    final deleteCount = end - start;

    // Re-own the leaf's text under this replica so concurrent edits from
    // different peers mint distinct char ids (no collision on merge).
    final leaf = _leafBody(node);
    leaf.text = leaf.text!.fork(_peer);
    final vv = leaf.text!.versionVector();
    for (var i = 0; i < deleteCount; i++) {
      leaf.text!.delete(start);
    }
    leaf.text!.insertStr(start, insert);
    final ops = leaf.text!.deltaSince(vv);

    final prev = _nodes[node]!.textHead;
    final opId = _nextOpId();
    _commitLocal(TreeOp(opId, TreeOpKindLeafEdit(node, prev, ops)));
  }

  /// Split a leaf at UTF-8 byte offset [atByte] into two adjacent leaves of the
  /// same kind (head keeps [node], tail is a fresh node returned here).
  TreeNodeId splitLeaf(TreeNodeId node, int atByte) {
    final s = leafText(node);
    final atChar = byteToCodePoint(s, atByte);
    if (atChar == null) throw TreeException('offset not on a char boundary');
    final rec = _nodes[node]!;
    if (rec.parent == null) throw TreeException('node not found');
    final sort = _keyAfter(rec.parent!, node);
    final prev = rec.textHead;
    final opId = _nextOpId();
    final newNode = TreeNodeId(opId);
    _commitLocal(TreeOp(
        opId, TreeOpKindSplitLeaf(node, newNode, sort, atChar, prev)));
    return newNode;
  }

  /// Merge [right] into [left] when they are adjacent live leaf siblings.
  void mergeAdjacentLeaves(TreeNodeId left, TreeNodeId right) {
    leafText(left); // validate leaf-ness
    leafText(right);
    final rec = _nodes[left]!;
    if (rec.parent == null) throw TreeException('node not found');
    final order = _liveChildren(rec.parent!);
    final li = order.indexOf(left);
    final adjacent = li >= 0 && li + 1 < order.length && order[li + 1] == right;
    if (!adjacent) throw TreeException('leaves are not adjacent live siblings');
    final prevLeft = _nodes[left]!.textHead;
    final prevRight = _nodes[right]!.textHead;
    final opId = _nextOpId();
    _commitLocal(TreeOp(
        opId, TreeOpKindMergeLeaves(left, right, prevLeft, prevRight)));
  }

  /// Ops this replica holds that [their] frontier lacks, ordered by dotted id.
  TreeUpdate diff(TreeVersionFrontier their) {
    final ops = _log
        .where((op) => !their.contains(op.id))
        .toList()
      ..sort((a, b) {
        final c = a.id.counter.compareTo(b.id.counter);
        if (c != 0) return c;
        return a.id.peer.compareTo(b.id.peer);
      });
    return TreeUpdate(ops);
  }

  /// Apply a batch of remote ops. Idempotent (already-held ops skipped) and
  /// order-tolerant (an op whose target/parent has not arrived is buffered and
  /// retried). Advances the Lamport counter past every observed op.
  void applyUpdate(TreeUpdate update) {
    for (final op in update.ops) {
      if (_counter < op.id.counter) _counter = op.id.counter;
      if (_frontier.contains(op.id)) continue;
      _buffered.add(op);
    }
    _drainBuffered();
  }

  void _drainBuffered() {
    while (true) {
      var progressed = false;
      final pending = List<TreeOp>.from(_buffered);
      _buffered.clear();
      for (final op in pending) {
        if (_frontier.contains(op.id)) continue;
        if (_dependenciesReady(op)) {
          _applyOp(op);
          _record(op);
          progressed = true;
        } else {
          _buffered.add(op);
        }
      }
      if (!progressed) break;
    }
  }

  bool _dependenciesReady(TreeOp op) {
    final k = op.kind;
    return switch (k) {
      TreeOpKindCreateNode() => _nodes.containsKey(k.parent),
      TreeOpKindTombstone() => _nodes.containsKey(k.node),
      TreeOpKindReorder() => _nodes.containsKey(k.node),
      TreeOpKindLeafEdit() =>
        _nodes.containsKey(k.node) && _frontier.contains(k.prev),
      TreeOpKindSplitLeaf() =>
        _nodes.containsKey(k.node) && _frontier.contains(k.prev),
      TreeOpKindMergeLeaves() =>
        _nodes.containsKey(k.left) &&
            _nodes.containsKey(k.right) &&
            _frontier.contains(k.prevLeft) &&
            _frontier.contains(k.prevRight),
    };
  }

  void _commitLocal(TreeOp op) {
    _applyOp(op);
    _record(op);
  }

  void _record(TreeOp op) {
    _frontier._observe(op.id);
    _log.add(op);
  }

  void _applyOp(TreeOp op) {
    final k = op.kind;
    switch (k) {
      case TreeOpKindCreateNode():
        if (_nodes.containsKey(k.id)) return;
        final body = switch (k.seed) {
          NodeSeedElement(:final kind) => _ElementBody(kind),
          NodeSeedLeaf(:final kind, :final text) =>
            _LeafBody(kind, TextCrdt.fromStr(k.id.op.peer, text)),
        };
        _nodes[k.id] = _NodeRecord(
          parent: k.parent,
          sort: k.sort,
          sortStamp: op.id,
          body: body,
          tomb: null,
          textHead: op.id,
        );
      case TreeOpKindTombstone():
        final rec = _nodes[k.node];
        if (rec == null) return;
        rec.tomb = (rec.tomb == null)
            ? op.id
            : (rec.tomb!.compareTo(op.id) <= 0 ? rec.tomb! : op.id);
      case TreeOpKindReorder():
        final rec = _nodes[k.node];
        if (rec == null) return;
        if (op.id.compareTo(rec.sortStamp) > 0) {
          rec.sort = k.sort;
          rec.sortStamp = op.id;
        }
      case TreeOpKindLeafEdit():
        final rec = _nodes[k.node];
        if (rec == null) return;
        final body = rec.body;
        if (body is _LeafBody) {
          body.text?.applyDelta(k.ops);
          rec.textHead = op.id;
        }
      case TreeOpKindSplitLeaf():
        _applySplit(k.node, k.newNode, k.sort, k.atChar, op.id);
      case TreeOpKindMergeLeaves():
        _applyMerge(k.left, k.right, op.id);
    }
  }

  void _applySplit(
      TreeNodeId node, TreeNodeId newNode, SortKey sort, int atChar, TreeOpId opId) {
    final rec = _nodes[node];
    if (rec == null) return;
    final leaf = rec.body;
    if (leaf is! _LeafBody) return;
    final kind = leaf.kind;
    final parent = rec.parent;
    final s = leaf.text?.text() ?? '';
    final cut = codePointToUtf16(s, atChar);
    final head = s.substring(0, cut);
    final tail = s.substring(cut);
    // Reseed head under the original node's create peer so both replicas
    // rebuild byte-identical leaf state.
    rec.body = _LeafBody(kind, TextCrdt.fromStr(node.op.peer, head));
    rec.textHead = opId;
    _nodes.putIfAbsent(
      newNode,
      () => _NodeRecord(
        parent: parent,
        sort: sort,
        sortStamp: opId,
        body: _LeafBody(kind, TextCrdt.fromStr(newNode.op.peer, tail)),
        tomb: null,
        textHead: opId,
      ),
    );
  }

  void _applyMerge(TreeNodeId left, TreeNodeId right, TreeOpId opId) {
    final l = _nodes[left];
    final r = _nodes[right];
    if (l == null || r == null) return;
    final lb = l.body;
    final rb = r.body;
    if (lb is! _LeafBody || rb is! _LeafBody) return;
    final combined = (lb.text?.text() ?? '') + (rb.text?.text() ?? '');
    l.body = _LeafBody(lb.kind, TextCrdt.fromStr(left.op.peer, combined));
    l.textHead = opId;
    r.tomb = (r.tomb == null)
        ? opId
        : (r.tomb!.compareTo(opId) <= 0 ? r.tomb! : opId);
  }
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
