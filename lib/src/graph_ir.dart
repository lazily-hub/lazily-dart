/// Graph IR interpreter.
///
/// A lazily-spec graph document parses into an expression tree, lowers onto
/// sources, computeds, and effects, and emits canonical-source. This is
/// compute, not a Snapshot or Delta.
library;

import 'dart:convert';

const graphIrVersion = '1';
const graphDrainBudget = 100000;
final _idPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
const _unary = {'neg', 'not', 'len'};
const _binary = {
  'add',
  'sub',
  'mul',
  'div',
  'mod',
  'min',
  'max',
  'eq',
  'ne',
  'lt',
  'le',
  'gt',
  'ge',
  'concat',
  'get',
  'and',
  'or',
};

/// A parse, check, edit, or value fault.
class GraphIrError implements Exception {
  /// Human-readable fault. Tests match substrings of [message].
  final String message;
  GraphIrError(this.message);
  @override
  String toString() => message;
}

/// Source merge policies. The wire strings are the constant values.
abstract final class Policy {
  static const keepLatest = 'keep-latest';
  static const sum = 'sum';
  static const max = 'max';
  static const min = 'min';
  static const and = 'and';
  static const or = 'or';
}

/// Read sorts before write.
abstract final class EdgeKind {
  static const read = 'read';
  static const write = 'write';
}

/// A derived read or write edge.
class Edge {
  final String from;
  final String kind;
  final String to;
  const Edge(this.from, this.kind, this.to);
  @override
  bool operator ==(Object other) =>
      other is Edge &&
      other.from == from &&
      other.kind == kind &&
      other.to == to;
  @override
  int get hashCode => Object.hash(from, kind, to);
}

/// One successful effect evaluation. Removal does not erase it.
class GraphEffectRun {
  final String id;
  final Object? result;
  const GraphEffectRun(this.id, this.result);
}

class GraphExpr {
  final String type;
  final Object? lit;
  final String? ref;
  final String? op;
  final List<GraphExpr> args;
  final List<GraphField> fields;
  const GraphExpr._(
    this.type, {
    this.lit,
    this.ref,
    this.op,
    this.args = const [],
    this.fields = const [],
  });
}

class GraphField {
  final String key;
  final GraphExpr value;
  const GraphField(this.key, this.value);
}

class GraphStmt {
  final String type;
  final GraphExpr? expr;
  final String? target;
  final List<GraphStmt> steps;
  final GraphExpr? cond;
  final GraphStmt? then;
  final GraphStmt? otherwise;
  const GraphStmt._(
    this.type, {
    this.expr,
    this.target,
    this.steps = const [],
    this.cond,
    this.then,
    this.otherwise,
  });
}

class GraphIrNode {
  final String kind;
  final String id;
  final Object? init;
  final String policy;
  final bool eager;
  final GraphExpr? expr;
  final GraphStmt? body;
  const GraphIrNode({
    required this.kind,
    required this.id,
    this.init,
    this.policy = Policy.keepLatest,
    this.eager = false,
    this.expr,
    this.body,
  });
}

class _EditOp {
  final String op;
  final GraphIrNode? node;
  final String? id;
  const _EditOp(this.op, {this.node, this.id});
}

/// A parsed graph definition.
class GraphIr {
  final String? id;
  final List<GraphIrNode> _nodes;
  final Map<String, int> _index;
  GraphIr._(this.id, this._nodes, this._index);

  /// Parses a graph document.
  static GraphIr fromJsonStr(String text) => _graphFrom(parseGraphJson(text));

  String? get graphId => id;
  GraphIrNode? node(String id) {
    final slot = _index[id];
    return slot == null ? null : _nodes[slot];
  }

  Map<String, Object?> toJson() {
    final obj = <String, Object?>{'kind': 'graph', 'ir': graphIrVersion};
    if (id != null) obj['id'] = id;
    obj['nodes'] = [for (final node in _nodes) _nodeJson(node)];
    return obj;
  }

  List<Edge> staticEdges() {
    final edges = <Edge>[];
    for (final node in _nodes) {
      final sets = _edgeSets(node);
      for (final to in sets.$1) {
        edges.add(Edge(node.id, EdgeKind.read, to));
      }
      for (final to in sets.$2) {
        edges.add(Edge(node.id, EdgeKind.write, to));
      }
    }
    edges.sort((a, b) {
      final from = a.from.compareTo(b.from);
      if (from != 0) return from;
      final kind = a.kind.compareTo(b.kind);
      if (kind != 0) return kind;
      return a.to.compareTo(b.to);
    });
    return edges;
  }

  String emitSource() {
    final b = StringBuffer();
    if (id == null) {
      b.writeln('graph ir $graphIrVersion');
    } else {
      b.writeln('graph $id ir $graphIrVersion');
    }
    for (final node in _nodes) {
      b.writeln(_emitNode(node));
    }
    return b.toString();
  }

  GraphIr _clone() => GraphIr._(id, [..._nodes], {..._index});

  void _applyOp(_EditOp op) {
    switch (op.op) {
      case 'add':
        if (_index.containsKey(op.node!.id)) {
          throw GraphIrError(
            'add requires a new id, `${op.node!.id}` already exists',
          );
        }
        _nodes.add(op.node!);
      case 'replace':
        final slot = _index[op.node!.id];
        if (slot == null) {
          throw GraphIrError(
            'replace requires an existing node `${op.node!.id}`',
          );
        }
        _nodes[slot] = op.node!;
      case 'remove':
        final slot = _index[op.id];
        if (slot == null)
          throw GraphIrError('remove requires an existing node `${op.id}`');
        _nodes.removeAt(slot);
    }
    _reindex();
    _check();
  }

  void _reindex() {
    _index.clear();
    for (var slot = 0; slot < _nodes.length; slot++) {
      final id = _nodes[slot].id;
      if (_index.containsKey(id)) throw GraphIrError('duplicate node id `$id`');
      _index[id] = slot;
    }
  }

  void _check() {
    _checkRefs();
    _checkInits();
    _checkCycles();
  }

  void _checkRefs() {
    for (final node in _nodes) {
      final sets = _edgeSets(node);
      for (final to in sets.$1) {
        final target = this.node(to);
        if (target == null)
          throw GraphIrError('node `${node.id}` reads unknown node `$to`');
        if (target.kind == 'effect') {
          throw GraphIrError(
            'node `${node.id}` reads effect `$to`, which has no value',
          );
        }
      }
      for (final to in sets.$2) {
        final target = this.node(to);
        if (target == null)
          throw GraphIrError('node `${node.id}` writes unknown node `$to`');
        if (target.kind != 'source') {
          throw GraphIrError('node `${node.id}` writes non-source `$to`');
        }
      }
    }
  }

  void _checkInits() {
    for (final node in _nodes) {
      if (node.kind != 'source') continue;
      try {
        _checkPolicyInit(node.policy, node.init);
      } on GraphIrError catch (err) {
        throw GraphIrError('source `${node.id}`: ${err.message}');
      }
    }
  }

  void _checkCycles() {
    final color = <String, int>{};
    final stack = <String>[];
    void visit(String id) {
      switch (color[id] ?? 0) {
        case 1:
          final start = stack.indexOf(id);
          final cycle = [...stack.sublist(start), id];
          throw GraphIrError('cycle in read edges: ${cycle.join(' -> ')}');
        case 2:
          return;
      }
      color[id] = 1;
      stack.add(id);
      final target = node(id);
      if (target != null) {
        final reads = [..._edgeSets(target).$1]..sort();
        for (final dep in reads) {
          if (node(dep) != null) visit(dep);
        }
      }
      stack.removeLast();
      color[id] = 2;
    }

    for (final node in _nodes) {
      visit(node.id);
    }
  }
}

/// An ordered list of add, replace, and remove ops.
class GraphEdit {
  final List<_EditOp> _ops;
  GraphEdit._(this._ops);
  static GraphEdit fromJsonStr(String text) => _editFrom(parseGraphJson(text));
}

class _SourceState {
  Object? value;
  final String policy;
  _SourceState(this.value, this.policy);
}

class _ComputedState {
  final GraphExpr expr;
  final bool eager;
  Object? cache;
  bool hasValue = false;
  bool dirty = true;
  _ComputedState(this.expr, this.eager);
}

class _EffectState {
  final GraphStmt body;
  _EffectState(this.body);
}

class _Snap {
  final String kind;
  final _SourceState? source;
  final _ComputedState? computed;
  final _EffectState? effect;
  final Set<String> deps;
  _Snap(
    this.kind, {
    this.source,
    this.computed,
    this.effect,
    this.deps = const {},
  });
}

/// A document plus the cells it was lowered onto.
class GraphRuntime {
  GraphIr _doc;
  final Map<String, _SourceState> _sources = {};
  final Map<String, _ComputedState> _computeds = {};
  final Map<String, _EffectState> _effects = {};
  final Map<String, Set<String>> _deps = {};
  final Map<String, Set<String>> _subs = {};
  final Map<String, Set<String>> _observed = {};
  final List<GraphEffectRun> _trace = [];
  final List<Set<String>> _frames = [];
  final List<String?> _stack = [];
  String? _current;
  final Set<String> _computing = {};
  final List<String> _scheduled = [];
  final Set<String> _scheduledSet = {};
  bool _draining = false;
  String? _fault;
  final int drainBudget;
  int? lastDrainExhaustion;

  GraphRuntime._(this._doc, this.drainBudget);

  static GraphRuntime loadJson(String text, {int? drainBudget}) =>
      lower(GraphIr.fromJsonStr(text), drainBudget: drainBudget);

  static GraphRuntime lower(GraphIr doc, {int? drainBudget}) {
    doc._check();
    final rt = GraphRuntime._(doc._clone(), drainBudget ?? graphDrainBudget);
    rt._installDocument();
    return rt;
  }

  GraphIr get document => _doc;
  bool contains(String id) => _doc.node(id) != null;

  bool isEager(String id) {
    final node = _doc.node(id);
    if (node == null) throw GraphIrError('unknown node `$id`');
    if (node.kind != 'computed') throw GraphIrError('`$id` is not a computed');
    return node.eager;
  }

  String sourcePolicy(String id) {
    final node = _doc.node(id);
    if (node == null) throw GraphIrError('unknown node `$id`');
    if (node.kind != 'source') throw GraphIrError('`$id` is not a source');
    return node.policy;
  }

  List<Edge> staticEdges() => _doc.staticEdges();
  String emitSource() => _doc.emitSource();
  Set<String> observedReads(String id) => {...?_observed[id]};
  List<GraphEffectRun> effectTrace() => [..._trace];

  Object? get(String id) {
    if (_effects.containsKey(id) &&
        !_sources.containsKey(id) &&
        !_computeds.containsKey(id)) {
      throw GraphIrError('`$id` is an effect and has no value');
    }
    final src = _sources[id];
    if (src != null) return freezeGraph(src.value);
    final comp = _computeds[id];
    if (comp != null) {
      if (comp.dirty || !comp.hasValue) _recompute(id);
      return freezeGraph(_computeds[id]!.cache);
    }
    throw GraphIrError('unknown node `$id`');
  }

  void writeSource(String id, Object? value) {
    _setSource(id, freezeGraph(value));
    _drain();
    _raiseFault();
  }

  void apply(GraphEdit edit) {
    for (var index = 0; index < edit._ops.length; index++) {
      final op = edit._ops[index];
      final next = _doc._clone();
      try {
        next._applyOp(op);
      } on GraphIrError catch (err) {
        throw GraphIrError('edit op $index: ${err.message}');
      }
      try {
        _installOp(op);
      } on GraphIrError catch (err) {
        throw GraphIrError('edit op $index: ${err.message}');
      }
      _doc = next;
    }
  }

  void _installDocument() {
    for (final node in _doc._nodes) {
      if (node.kind == 'source') _insertSource(node);
    }
    for (final node in _doc._nodes) {
      if (node.kind == 'computed') _insertComputed(node);
    }
    for (final node in _doc._nodes) {
      if (node.kind == 'computed' && node.eager) _recompute(node.id);
    }
    for (final node in _doc._nodes) {
      if (node.kind == 'effect') _insertEffect(node);
    }
    _raiseFault();
  }

  void _installOp(_EditOp op) {
    switch (op.op) {
      case 'add':
        _addNode(op.node!);
      case 'replace':
        _replaceNode(op.node!);
      default:
        _removeNode(op.id!);
    }
    _drain();
    _raiseFault();
  }

  void _addNode(GraphIrNode node) {
    switch (node.kind) {
      case 'source':
        _insertSource(node);
      case 'computed':
        _insertComputed(node);
        if (node.eager) {
          try {
            _recompute(node.id);
          } catch (err) {
            _dropBinding(node.id);
            rethrow;
          }
        }
      default:
        _insertEffect(node);
    }
  }

  void _replaceNode(GraphIrNode node) {
    final snap = _snapshot(node.id);
    _dropBinding(node.id);
    try {
      _addNode(node);
      _notify(node.id);
    } catch (err) {
      _dropBinding(node.id);
      _restore(node.id, snap);
      rethrow;
    }
  }

  void _removeNode(String id) {
    if (!_sources.containsKey(id) &&
        !_computeds.containsKey(id) &&
        !_effects.containsKey(id)) {
      throw GraphIrError('unknown node `$id`');
    }
    _dropBinding(id);
    _subs.remove(id);
  }

  void _insertSource(GraphIrNode node) {
    _checkPolicyInit(node.policy, node.init);
    _sources[node.id] = _SourceState(freezeGraph(node.init), node.policy);
  }

  void _insertComputed(GraphIrNode node) {
    _computeds[node.id] = _ComputedState(node.expr!, node.eager);
    _deps[node.id] = {};
  }

  void _insertEffect(GraphIrNode node) {
    _effects[node.id] = _EffectState(node.body!);
    _deps[node.id] = {};
    try {
      _runEffect(node.id);
    } catch (err) {
      _dropBinding(node.id);
      rethrow;
    }
  }

  _Snap? _snapshot(String id) {
    final src = _sources[id];
    if (src != null)
      return _Snap(
        'source',
        source: _SourceState(freezeGraph(src.value), src.policy),
      );
    final comp = _computeds[id];
    if (comp != null) {
      return _Snap(
        'computed',
        computed: _ComputedState(comp.expr, comp.eager)
          ..cache = comp.hasValue ? freezeGraph(comp.cache) : null
          ..hasValue = comp.hasValue
          ..dirty = comp.dirty,
        deps: {...?_deps[id]},
      );
    }
    final effect = _effects[id];
    if (effect != null)
      return _Snap('effect', effect: effect, deps: {...?_deps[id]});
    return null;
  }

  void _restore(String id, _Snap? snap) {
    if (snap == null) return;
    switch (snap.kind) {
      case 'source':
        _sources[id] = snap.source!;
      case 'computed':
        _computeds[id] = snap.computed!;
        _deps[id] = {};
        for (final dep in snap.deps) {
          _subAdd(dep, id);
          _deps[id]!.add(dep);
        }
      case 'effect':
        _effects[id] = snap.effect!;
        _deps[id] = {};
        for (final dep in snap.deps) {
          _subAdd(dep, id);
          _deps[id]!.add(dep);
        }
    }
  }

  void _dropBinding(String id) {
    _sources.remove(id);
    _computeds.remove(id);
    _effects.remove(id);
    for (final dep in {...?_deps[id]}) {
      _subs[dep]?.remove(id);
    }
    _deps.remove(id);
    _observed.remove(id);
    _scheduledSet.remove(id);
  }

  Object? _setSource(String id, Object? value) {
    final src = _sources[id];
    if (src == null) {
      if (_computeds.containsKey(id) || _effects.containsKey(id)) {
        throw GraphIrError('`$id` is not a source');
      }
      throw GraphIrError('unknown node `$id`');
    }
    final changed = !jsonEq(src.value, value);
    src.value = freezeGraph(value);
    if (changed) _notify(id);
    return freezeGraph(src.value);
  }

  Object? _mergeSource(String id, Object? value) {
    final src = _sources[id];
    if (src == null) {
      if (_computeds.containsKey(id) || _effects.containsKey(id)) {
        throw GraphIrError('`$id` is not a source');
      }
      throw GraphIrError('unknown node `$id`');
    }
    return _setSource(id, _foldPolicy(src.policy, src.value, value));
  }

  void _notify(String id) {
    for (final dep in [...?_subs[id]]..sort()) {
      final comp = _computeds[dep];
      if (comp != null) {
        if (comp.eager || (_subs[dep]?.isNotEmpty ?? false)) {
          if (_computing.contains(dep)) {
            comp.dirty = true;
            continue;
          }
          _recompute(dep);
        } else {
          comp.dirty = true;
        }
      } else if (_effects.containsKey(dep)) {
        _schedule(dep);
      }
    }
  }

  void _schedule(String id) {
    if (_effects.containsKey(id) && _scheduledSet.add(id)) _scheduled.add(id);
  }

  void _drain() {
    if (_draining) return;
    _draining = true;
    try {
      var iterations = 0;
      while (_scheduled.isNotEmpty) {
        final id = _scheduled.removeAt(0);
        _scheduledSet.remove(id);
        iterations++;
        if (iterations >= drainBudget) {
          lastDrainExhaustion = iterations;
          return;
        }
        if (!_effects.containsKey(id)) continue;
        try {
          _runEffect(id);
        } on GraphIrError catch (err) {
          _fault = err.message;
          return;
        }
      }
    } finally {
      _draining = false;
    }
  }

  void _raiseFault() {
    final msg = _fault;
    if (msg == null) return;
    _fault = null;
    throw GraphIrError(msg);
  }

  void _runEffect(String id) {
    final state = _effects[id]!;
    _begin(id);
    Object? result;
    try {
      result = _evalStmt(state.body);
    } finally {
      _end(id);
    }
    _trace.add(GraphEffectRun(id, freezeGraph(result)));
    _drain();
  }

  Object? _recompute(String id) {
    final state = _computeds[id]!;
    if (!_computing.add(id)) throw GraphIrError('cycle in read edges: $id');
    try {
      _begin(id);
      Object? value;
      try {
        value = _evalExpr(state.expr);
      } finally {
        _end(id);
      }
      final changed = !state.hasValue || !jsonEq(state.cache, value);
      state.cache = freezeGraph(value);
      state.hasValue = true;
      state.dirty = false;
      if (changed) _notify(id);
      return state.cache;
    } catch (err) {
      state.dirty = true;
      state.hasValue = false;
      state.cache = null;
      rethrow;
    } finally {
      _computing.remove(id);
    }
  }

  void _begin(String id) {
    for (final dep in {...?_deps[id]}) {
      _subs[dep]?.remove(id);
    }
    _deps[id] = {};
    _frames.add({});
    _stack.add(_current);
    _current = id;
  }

  void _end(String id) {
    _observed[id] = _frames.removeLast();
    _current = _stack.removeLast();
  }

  void _note(String id) {
    if (_frames.isEmpty || _current == null) {
      throw GraphIrError('read outside a node evaluation');
    }
    _frames.last.add(id);
    _subAdd(id, _current!);
    _deps[_current!]!.add(id);
  }

  void _subAdd(String src, String reader) => (_subs[src] ??= {}).add(reader);

  Object? _readRef(String id) {
    _note(id);
    final src = _sources[id];
    if (src != null) return freezeGraph(src.value);
    final comp = _computeds[id];
    if (comp != null) {
      if (comp.dirty || !comp.hasValue) return freezeGraph(_recompute(id));
      return freezeGraph(comp.cache);
    }
    if (_effects.containsKey(id))
      throw GraphIrError('`$id` is an effect and has no value');
    throw GraphIrError('unknown node `$id`');
  }

  Object? _evalExpr(GraphExpr expr) {
    switch (expr.type) {
      case 'lit':
        return freezeGraph(expr.lit);
      case 'ref':
        return _readRef(expr.ref!);
      case 'object':
        final obj = <String, Object?>{};
        for (final field in expr.fields) {
          if (obj.containsKey(field.key))
            throw GraphIrError('duplicate object key `${field.key}`');
          obj[field.key] = _evalExpr(field.value);
        }
        return obj;
      case 'call':
        switch (expr.op) {
          case 'and':
            return _evalAnd(expr.args);
          case 'or':
            return _evalOr(expr.args);
          case 'if':
            return _evalIf(expr.args);
          case 'array':
            return [for (final arg in expr.args) _evalExpr(arg)];
          default:
            return _evalValues(expr.op!, [
              for (final arg in expr.args) _evalExpr(arg),
            ]);
        }
      default:
        throw GraphIrError('unknown expression `${expr.type}`');
    }
  }

  Object? _evalAnd(List<GraphExpr> args) {
    if (args.length != 2)
      throw GraphIrError('op `and` has the wrong number of arguments');
    final left = _expectBool(_evalExpr(args[0]));
    if (!left) return false;
    return _expectBool(_evalExpr(args[1]));
  }

  Object? _evalOr(List<GraphExpr> args) {
    if (args.length != 2)
      throw GraphIrError('op `or` has the wrong number of arguments');
    final left = _expectBool(_evalExpr(args[0]));
    if (left) return true;
    return _expectBool(_evalExpr(args[1]));
  }

  Object? _evalIf(List<GraphExpr> args) {
    if (args.length != 3)
      throw GraphIrError('op `if` has the wrong number of arguments');
    final bit = _expectBool(_evalExpr(args[0]));
    return _evalExpr(bit ? args[1] : args[2]);
  }

  Object? _evalStmt(GraphStmt stmt) {
    switch (stmt.type) {
      case 'eval':
        return _evalExpr(stmt.expr!);
      case 'set':
        return _setSource(stmt.target!, _evalExpr(stmt.expr!));
      case 'merge':
        return _mergeSource(stmt.target!, _evalExpr(stmt.expr!));
      case 'seq':
        return [for (final step in stmt.steps) _evalStmt(step)];
      case 'when':
        final bit = _expectBool(_evalExpr(stmt.cond!));
        if (bit) return _evalStmt(stmt.then!);
        if (stmt.otherwise != null) return _evalStmt(stmt.otherwise!);
        return null;
      default:
        throw GraphIrError('unknown statement `${stmt.type}`');
    }
  }
}

Object? parseGraphJson(String text) {
  Object? value;
  try {
    value = jsonDecode(text);
  } on FormatException catch (err) {
    throw GraphIrError('graph document is not JSON: $err');
  }
  return value;
}

GraphIr _graphFrom(Object? value) {
  final obj = _asMap(value, 'graph document');
  _allow(obj, 'graph document', ['kind', 'ir', 'id', 'nodes']);
  final kind = _requireString(obj, 'kind', 'graph document');
  if (kind != 'graph')
    throw GraphIrError('graph document kind must be "graph", got `$kind`');
  _requireVersion(obj, 'graph document');
  final id = _optionalId(obj, 'id', 'graph id');
  final raw = _require(obj, 'nodes', 'graph document');
  if (raw is! List) throw GraphIrError('graph nodes must be an array');
  final nodes = <GraphIrNode>[];
  final seen = <String>{};
  for (final item in raw) {
    final node = _parseNode(item);
    if (!seen.add(node.id))
      throw GraphIrError('duplicate node id `${node.id}`');
    nodes.add(node);
  }
  final doc = GraphIr._(id, nodes, {});
  doc._reindex();
  doc._check();
  return doc;
}

GraphEdit _editFrom(Object? value) {
  final obj = _asMap(value, 'graph edit');
  _allow(obj, 'graph edit', ['kind', 'ir', 'ops']);
  final kind = _requireString(obj, 'kind', 'graph edit');
  if (kind != 'edit')
    throw GraphIrError('graph edit kind must be "edit", got `$kind`');
  _requireVersion(obj, 'graph edit');
  final raw = _require(obj, 'ops', 'graph edit');
  if (raw is! List) throw GraphIrError('graph edit ops must be an array');
  if (raw.isEmpty) throw GraphIrError('graph edit ops must not be empty');
  return GraphEdit._([for (final item in raw) _parseEdit(item)]);
}

Map<String, Object?> _asMap(Object? value, String what) {
  if (value is Map) {
    return {
      for (final entry in value.entries)
        entry.key.toString(): entry.value as Object?,
    };
  }
  throw GraphIrError('$what must be an object');
}

void _allow(Map<String, Object?> obj, String what, List<String> keys) {
  final allowed = keys.toSet();
  for (final key in obj.keys) {
    if (!allowed.contains(key))
      throw GraphIrError('$what: unknown field `$key`');
  }
}

Object? _require(Map<String, Object?> obj, String field, String what) {
  if (!obj.containsKey(field)) throw GraphIrError('$what requires `$field`');
  return obj[field];
}

String _requireString(Map<String, Object?> obj, String field, String what) {
  final value = _require(obj, field, what);
  if (value is! String)
    throw GraphIrError(
      '$what `$field` must be a string, got ${canonicalJson(value)}',
    );
  return value;
}

String _parseId(String text, String what) {
  if (!_idPattern.hasMatch(text) || text.length > 128) {
    throw GraphIrError('$what `$text` is not a graph IR id');
  }
  return text;
}

void _requireVersion(Map<String, Object?> obj, String what) {
  final version = _requireString(obj, 'ir', what);
  if (version != graphIrVersion)
    throw GraphIrError('unsupported graph IR version `$version`');
}

String? _optionalId(Map<String, Object?> obj, String field, String what) {
  if (!obj.containsKey(field)) return null;
  final value = obj[field];
  if (value is! String)
    throw GraphIrError('$what must be a string, got ${canonicalJson(value)}');
  return _parseId(value, what);
}

GraphIrNode _parseNode(Object? value) {
  final obj = _asMap(value, 'node');
  final kind = _requireString(obj, 'kind', 'node');
  final id = _parseId(_requireString(obj, 'id', 'node'), 'node id');
  switch (kind) {
    case 'source':
      _allow(obj, 'source', ['id', 'kind', 'init', 'policy']);
      if (!obj.containsKey('init'))
        throw GraphIrError('source `$id` requires `init`');
      final policy = _parsePolicy(obj, id);
      _checkPolicyInit(policy, obj['init']);
      return GraphIrNode(
        kind: 'source',
        id: id,
        init: freezeGraph(obj['init']),
        policy: policy,
      );
    case 'computed':
      _allow(obj, 'computed', ['id', 'kind', 'expr', 'eager']);
      return GraphIrNode(
        kind: 'computed',
        id: id,
        eager: _parseEager(obj, id),
        expr: _parseExpr(_require(obj, 'expr', 'computed')),
      );
    case 'effect':
      _allow(obj, 'effect', ['id', 'kind', 'body']);
      return GraphIrNode(
        kind: 'effect',
        id: id,
        body: _parseStmt(_require(obj, 'body', 'effect')),
      );
    default:
      throw GraphIrError('unknown node kind `$kind`');
  }
}

String _parsePolicy(Map<String, Object?> obj, String id) {
  if (!obj.containsKey('policy')) return Policy.keepLatest;
  final value = obj['policy'];
  if (value is! String)
    throw GraphIrError('source `$id` policy must be a string');
  const names = {
    Policy.keepLatest,
    Policy.sum,
    Policy.max,
    Policy.min,
    Policy.and,
    Policy.or,
  };
  if (!names.contains(value))
    throw GraphIrError('unknown source policy `$value`');
  return value;
}

bool _parseEager(Map<String, Object?> obj, String id) {
  if (!obj.containsKey('eager')) return false;
  final value = obj['eager'];
  if (value is! bool)
    throw GraphIrError('computed `$id` eager must be a boolean');
  return value;
}

GraphExpr _parseExpr(Object? value) {
  final obj = _asMap(value, 'expression');
  _allow(obj, 'expression', ['lit', 'ref', 'op', 'args', 'object']);
  final forms = ['lit', 'ref', 'op', 'object'].where(obj.containsKey).length;
  if (forms != 1)
    throw GraphIrError(
      'expression must be exactly one of lit, ref, op, or object',
    );
  if (obj.containsKey('args') && !obj.containsKey('op')) {
    throw GraphIrError('args is only valid on an op expression');
  }
  if (obj.containsKey('lit'))
    return GraphExpr._('lit', lit: freezeGraph(obj['lit']));
  if (obj.containsKey('ref')) {
    return GraphExpr._(
      'ref',
      ref: _parseId(_requireString(obj, 'ref', 'expression'), 'ref'),
    );
  }
  if (obj.containsKey('object')) return _parseObject(obj['object']);
  final op = _requireString(obj, 'op', 'expression');
  if (!_unary.contains(op) &&
      !_binary.contains(op) &&
      op != 'if' &&
      op != 'array') {
    throw GraphIrError('unknown op `$op`');
  }
  final raw = _require(obj, 'args', 'op expression');
  if (raw is! List) throw GraphIrError('op args must be an array');
  final ok = _unary.contains(op)
      ? raw.length == 1
      : op == 'if'
          ? raw.length == 3
          : op == 'array'
              ? true
              : raw.length == 2;
  if (!ok) throw GraphIrError('op `$op` has the wrong number of arguments');
  return GraphExpr._(
    'call',
    op: op,
    args: [for (final item in raw) _parseExpr(item)],
  );
}

GraphExpr _parseObject(Object? value) {
  if (value is! List) throw GraphIrError('object expression must be an array');
  final fields = <GraphField>[];
  final seen = <String>{};
  for (final item in value) {
    final obj = _asMap(item, 'object field');
    _allow(obj, 'object field', ['key', 'value']);
    final key = _requireString(obj, 'key', 'object field');
    if (!seen.add(key)) throw GraphIrError('duplicate object key `$key`');
    fields.add(
      GraphField(key, _parseExpr(_require(obj, 'value', 'object field'))),
    );
  }
  return GraphExpr._('object', fields: fields);
}

GraphStmt _parseStmt(Object? value) {
  final obj = _asMap(value, 'statement');
  final verb = _requireString(obj, 'do', 'statement');
  switch (verb) {
    case 'eval':
      _allow(obj, 'eval', ['do', 'expr']);
      return GraphStmt._(
        'eval',
        expr: _parseExpr(_require(obj, 'expr', 'eval')),
      );
    case 'set':
    case 'merge':
      _allow(obj, verb, ['do', 'target', 'expr']);
      final target = _parseId(
        _requireString(obj, 'target', verb),
        'write target',
      );
      return GraphStmt._(
        verb,
        target: target,
        expr: _parseExpr(_require(obj, 'expr', verb)),
      );
    case 'seq':
      _allow(obj, 'seq', ['do', 'steps']);
      final raw = _require(obj, 'steps', 'seq');
      if (raw is! List) throw GraphIrError('seq steps must be an array');
      if (raw.isEmpty) throw GraphIrError('seq steps must not be empty');
      return GraphStmt._(
        'seq',
        steps: [for (final item in raw) _parseStmt(item)],
      );
    case 'when':
      _allow(obj, 'when', ['do', 'cond', 'then', 'else']);
      return GraphStmt._(
        'when',
        cond: _parseExpr(_require(obj, 'cond', 'when')),
        then: _parseStmt(_require(obj, 'then', 'when')),
        otherwise: obj.containsKey('else') ? _parseStmt(obj['else']) : null,
      );
    default:
      throw GraphIrError('unknown statement `$verb`');
  }
}

_EditOp _parseEdit(Object? value) {
  final obj = _asMap(value, 'edit op');
  final op = _requireString(obj, 'op', 'edit op');
  switch (op) {
    case 'add':
    case 'replace':
      _allow(obj, op, ['op', 'node']);
      return _EditOp(op, node: _parseNode(_require(obj, 'node', op)));
    case 'remove':
      _allow(obj, 'remove', ['op', 'id']);
      return _EditOp(
        op,
        id: _parseId(_requireString(obj, 'id', 'remove'), 'remove id'),
      );
    default:
      throw GraphIrError('unknown edit op `$op`');
  }
}

(List<String>, List<String>) _edgeSets(GraphIrNode node) {
  final reads = <String>{};
  final writes = <String>{};
  if (node.kind == 'computed') _collectExpr(node.expr!, reads);
  if (node.kind == 'effect') _collectStmt(node.body!, reads, writes);
  final readList = reads.toList()..sort();
  final writeList = writes.toList()..sort();
  return (readList, writeList);
}

void _collectExpr(GraphExpr expr, Set<String> reads) {
  switch (expr.type) {
    case 'ref':
      reads.add(expr.ref!);
    case 'call':
      for (final arg in expr.args) {
        _collectExpr(arg, reads);
      }
    case 'object':
      for (final field in expr.fields) {
        _collectExpr(field.value, reads);
      }
  }
}

void _collectStmt(GraphStmt stmt, Set<String> reads, Set<String> writes) {
  switch (stmt.type) {
    case 'eval':
      _collectExpr(stmt.expr!, reads);
    case 'set':
    case 'merge':
      writes.add(stmt.target!);
      _collectExpr(stmt.expr!, reads);
    case 'seq':
      for (final step in stmt.steps) {
        _collectStmt(step, reads, writes);
      }
    case 'when':
      _collectExpr(stmt.cond!, reads);
      _collectStmt(stmt.then!, reads, writes);
      if (stmt.otherwise != null) _collectStmt(stmt.otherwise!, reads, writes);
  }
}

String _emitNode(GraphIrNode node) {
  switch (node.kind) {
    case 'source':
      final line = 'source ${node.id} = ${canonicalJson(node.init)}';
      return node.policy == Policy.keepLatest
          ? line
          : '$line policy ${node.policy}';
    case 'computed':
      final flag = node.eager ? ' eager' : '';
      return 'computed ${node.id}$flag = ${_emitExpr(node.expr!)}';
    default:
      return 'effect ${node.id} = ${_emitStmt(node.body!)}';
  }
}

String _emitExpr(GraphExpr expr) {
  switch (expr.type) {
    case 'lit':
      return 'lit(${canonicalJson(expr.lit)})';
    case 'ref':
      return 'ref(${expr.ref})';
    case 'call':
      return '${expr.op}(${expr.args.map(_emitExpr).join(', ')})';
    default:
      return 'object(${expr.fields.map((field) => '${canonicalJson(field.key)}: ${_emitExpr(field.value)}').join(', ')})';
  }
}

String _emitStmt(GraphStmt stmt) {
  switch (stmt.type) {
    case 'eval':
      return 'eval(${_emitExpr(stmt.expr!)})';
    case 'set':
      return 'set(${stmt.target}, ${_emitExpr(stmt.expr!)})';
    case 'merge':
      return 'merge(${stmt.target}, ${_emitExpr(stmt.expr!)})';
    case 'seq':
      return 'seq(${stmt.steps.map(_emitStmt).join(', ')})';
    default:
      if (stmt.otherwise == null)
        return 'when(${_emitExpr(stmt.cond!)}, ${_emitStmt(stmt.then!)})';
      return 'when(${_emitExpr(stmt.cond!)}, ${_emitStmt(stmt.then!)}, ${_emitStmt(stmt.otherwise!)})';
  }
}

Map<String, Object?> _nodeJson(GraphIrNode node) {
  switch (node.kind) {
    case 'source':
      final obj = <String, Object?>{
        'id': node.id,
        'kind': 'source',
        'init': freezeGraph(node.init),
      };
      if (node.policy != Policy.keepLatest) obj['policy'] = node.policy;
      return obj;
    case 'computed':
      final obj = <String, Object?>{
        'id': node.id,
        'kind': 'computed',
        'expr': _exprJson(node.expr!),
      };
      if (node.eager) obj['eager'] = true;
      return obj;
    default:
      return {'id': node.id, 'kind': 'effect', 'body': _stmtJson(node.body!)};
  }
}

Map<String, Object?> _exprJson(GraphExpr expr) {
  switch (expr.type) {
    case 'lit':
      return {'lit': freezeGraph(expr.lit)};
    case 'ref':
      return {'ref': expr.ref};
    case 'call':
      return {
        'op': expr.op,
        'args': [for (final arg in expr.args) _exprJson(arg)],
      };
    default:
      return {
        'object': [
          for (final field in expr.fields)
            {'key': field.key, 'value': _exprJson(field.value)},
        ],
      };
  }
}

Map<String, Object?> _stmtJson(GraphStmt stmt) {
  switch (stmt.type) {
    case 'eval':
      return {'do': 'eval', 'expr': _exprJson(stmt.expr!)};
    case 'set':
    case 'merge':
      return {
        'do': stmt.type,
        'target': stmt.target,
        'expr': _exprJson(stmt.expr!),
      };
    case 'seq':
      return {
        'do': 'seq',
        'steps': [for (final step in stmt.steps) _stmtJson(step)],
      };
    default:
      final obj = <String, Object?>{
        'do': 'when',
        'cond': _exprJson(stmt.cond!),
        'then': _stmtJson(stmt.then!),
      };
      if (stmt.otherwise != null) obj['else'] = _stmtJson(stmt.otherwise!);
      return obj;
  }
}

/// Compact JSON with object keys sorted. Integers stay integers.
String canonicalJson(Object? value) {
  if (value == null) return 'null';
  if (value is bool) return value ? 'true' : 'false';
  if (value is int) return '$value';
  if (value is double) {
    if (value.isNaN || value.isInfinite)
      throw GraphIrError('non-finite number');
    return jsonEncode(value);
  }
  if (value is String) return jsonEncode(value);
  if (value is List) return '[${value.map(canonicalJson).join(',')}]';
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return '{${keys.map((key) => '${jsonEncode(key)}:${canonicalJson(value[key])}').join(',')}}';
  }
  throw GraphIrError('value is not JSON');
}

Object? freezeGraph(Object? value) {
  if (value == null ||
      value is bool ||
      value is String ||
      value is int ||
      value is double) return value;
  if (value is List) return [for (final item in value) freezeGraph(item)];
  if (value is Map) {
    return {
      for (final entry in value.entries)
        entry.key.toString(): freezeGraph(entry.value),
    };
  }
  throw GraphIrError('value is not JSON');
}

bool jsonEq(Object? left, Object? right) {
  if (left is bool || right is bool)
    return left is bool && right is bool && left == right;
  if (left is int || right is int)
    return left is int && right is int && left == right;
  if (left is double || right is double)
    return left is double && right is double && left == right;
  if (left is String || right is String)
    return left is String && right is String && left == right;
  if (left == null || right == null) return left == null && right == null;
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (!jsonEq(left[i], right[i])) return false;
    }
    return true;
  }
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final key in left.keys) {
      if (!right.containsKey(key) || !jsonEq(left[key], right[key]))
        return false;
    }
    return true;
  }
  return false;
}

bool _expectBool(Object? value) {
  if (value is bool) return value;
  throw GraphIrError('expected a boolean, got ${canonicalJson(value)}');
}

(String, int, double) _asNum(Object? value) {
  if (value is int) return ('int', value, 0);
  if (value is double) {
    if (value.isNaN || value.isInfinite)
      throw GraphIrError('non-finite number');
    return ('float', 0, value);
  }
  throw GraphIrError('expected a number, got ${canonicalJson(value)}');
}

void _checkPolicyInit(String policy, Object? init) {
  switch (policy) {
    case Policy.sum:
    case Policy.max:
    case Policy.min:
      _asNum(init);
    case Policy.and:
    case Policy.or:
      _expectBool(init);
  }
}

Object? _canonicalF64(double number) {
  if (number.isNaN || number.isInfinite)
    throw GraphIrError('non-finite number');
  if (number == number.truncateToDouble() &&
      number >= -9223372036854775808.0 &&
      number < 9223372036854775808.0) {
    final integer = number.toInt();
    if (integer.toDouble() == number) return integer;
  }
  return number;
}

Object? _addInt(int a, int b) {
  final result = a + b;
  if (result > 9223372036854775807 || result < -9223372036854775808) {
    throw GraphIrError('integer overflow');
  }
  return result;
}

Object? _subInt(int a, int b) => _addInt(a, -b);

Object? _mulInt(int a, int b) {
  if (a == 0 || b == 0) return 0;
  final result = a * b;
  if (result ~/ b != a) throw GraphIrError('integer overflow');
  if (result > 9223372036854775807 || result < -9223372036854775808) {
    throw GraphIrError('integer overflow');
  }
  return result;
}

int _ordering(Object? left, Object? right) {
  final a = _asNum(left);
  final b = _asNum(right);
  if (a.$1 == 'int' && b.$1 == 'int') return a.$2.compareTo(b.$2);
  final lf = a.$1 == 'int' ? a.$2.toDouble() : a.$3;
  final rf = b.$1 == 'int' ? b.$2.toDouble() : b.$3;
  return lf.compareTo(rf);
}

Object? _numBin(String op, Object? left, Object? right) {
  final a = _asNum(left);
  final b = _asNum(right);
  if (op != 'div' && a.$1 == 'int' && b.$1 == 'int') {
    switch (op) {
      case 'add':
        return _addInt(a.$2, b.$2);
      case 'sub':
        return _subInt(a.$2, b.$2);
      case 'mul':
        return _mulInt(a.$2, b.$2);
    }
  }
  final lf = a.$1 == 'int' ? a.$2.toDouble() : a.$3;
  final rf = b.$1 == 'int' ? b.$2.toDouble() : b.$3;
  if (op == 'div' && rf == 0) throw GraphIrError('division by zero');
  final double value;
  switch (op) {
    case 'add':
      value = lf + rf;
    case 'sub':
      value = lf - rf;
    case 'mul':
      value = lf * rf;
    case 'div':
      value = lf / rf;
    default:
      throw GraphIrError('op `$op` is not a numeric operator');
  }
  return _canonicalF64(value);
}

Object? _evalValues(String op, List<Object?> values) {
  Object? one() {
    if (values.length != 1)
      throw GraphIrError('op `$op` has the wrong number of arguments');
    return values[0];
  }

  (Object?, Object?) pair() {
    if (values.length != 2)
      throw GraphIrError('op `$op` has the wrong number of arguments');
    return (values[0], values[1]);
  }

  switch (op) {
    case 'neg':
      final value = one();
      final num = _asNum(value);
      if (num.$1 == 'int') {
        if (num.$2 == -9223372036854775808)
          throw GraphIrError('integer overflow');
        return -num.$2;
      }
      return _canonicalF64(-num.$3);
    case 'not':
      return !_expectBool(one());
    case 'len':
      return _len(one());
    case 'add':
    case 'sub':
    case 'mul':
    case 'div':
      final (left, right) = pair();
      return _numBin(op, left, right);
    case 'mod':
      final (left, right) = pair();
      final a = _asNum(left);
      final b = _asNum(right);
      if (a.$1 != 'int' || b.$1 != 'int')
        throw GraphIrError('mod requires integers');
      if (b.$2 == 0) throw GraphIrError('division by zero');
      return a.$2 % b.$2;
    case 'min':
    case 'max':
      final (left, right) = pair();
      final order = _ordering(left, right);
      if (op == 'max') return order >= 0 ? left : right;
      return order <= 0 ? left : right;
    case 'eq':
    case 'ne':
      final (left, right) = pair();
      final equal = jsonEq(left, right);
      return op == 'ne' ? !equal : equal;
    case 'lt':
    case 'le':
    case 'gt':
    case 'ge':
      final (left, right) = pair();
      final order = _ordering(left, right);
      switch (op) {
        case 'lt':
          return order < 0;
        case 'le':
          return order <= 0;
        case 'gt':
          return order > 0;
        default:
          return order >= 0;
      }
    case 'concat':
      final (left, right) = pair();
      if (left is! String || right is! String) {
        throw GraphIrError(
          'concat requires strings, got ${canonicalJson(left)} and ${canonicalJson(right)}',
        );
      }
      return left + right;
    case 'get':
      final (target, key) = pair();
      return _evalGet(target, key);
    default:
      throw GraphIrError('op `$op` is not an eager operator');
  }
}

int _len(Object? value) {
  if (value is String) return value.runes.length;
  if (value is List) return value.length;
  if (value is Map) return value.length;
  throw GraphIrError(
    'len requires a string, array, or object, got ${canonicalJson(value)}',
  );
}

Object? _evalGet(Object? target, Object? key) {
  if (target is List) {
    final index = _asNum(key);
    if (index.$1 != 'int') throw GraphIrError('array index must be an integer');
    if (index.$2 < 0) throw GraphIrError('array index must be >= 0');
    if (index.$2 >= target.length)
      throw GraphIrError('index ${index.$2} out of range');
    return freezeGraph(target[index.$2]);
  }
  if (target is Map) {
    if (key is! String)
      throw GraphIrError(
        'object key must be a string, got ${canonicalJson(key)}',
      );
    if (!target.containsKey(key)) throw GraphIrError('missing key `$key`');
    return freezeGraph(target[key]);
  }
  throw GraphIrError(
    'get requires an array or object, got ${canonicalJson(target)}',
  );
}

Object? _foldPolicy(String policy, Object? old, Object? op) {
  switch (policy) {
    case Policy.keepLatest:
      return freezeGraph(op);
    case Policy.sum:
      return _numBin('add', old, op);
    case Policy.max:
    case Policy.min:
      final order = _ordering(old, op);
      if (policy == Policy.max) return freezeGraph(order >= 0 ? old : op);
      return freezeGraph(order <= 0 ? old : op);
    case Policy.and:
      return _expectBool(old) && _expectBool(op);
    case Policy.or:
      return _expectBool(old) || _expectBool(op);
    default:
      throw GraphIrError('unknown source policy `$policy`');
  }
}
