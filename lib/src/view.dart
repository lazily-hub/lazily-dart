import 'state_chart.dart';
import 'core.dart';

/// Host-neutral view compute document installed on one [Context].
///
/// A signal is a [Source], each text/hidden/disabled expression is a guarded
/// [Computed], and the optional chart is one [StateChart]. Not a widget tree.
class View {
  View._(
    this._ctx,
    this._root,
    this._nodes,
    this._signals,
    this._exprs,
    this._effects,
    this._chart,
    this.subscription,
  );

  final Context _ctx;
  final String _root;
  final Map<String, _Node> _nodes;
  final Map<String, Source<ViewValue>> _signals;
  final Map<String, Computed<ViewValue>> _exprs;
  final Map<String, Map<String, Object?>> _effects;
  final StateChart? _chart;
  final Effect subscription;
  ViewValue? _payload;

  static const _roles = {'text', 'button', 'field', 'list', 'region'};
  static const _flows = {'row', 'column', 'stack'};
  static const _aligns = {'start', 'center', 'end', 'stretch'};
  static const _events = {'activate', 'change', 'submit'};
  static const _exprOps = {'lit', 'ref', 'call', 'if', 'eq', 'concat', 'trim'};
  static const _effectOps = {'set', 'batch', 'send'};
  static const _calls = {'event', 'not', 'add', 'len'};

  static View install(Map<String, Object?> doc) {
    _allow(doc, 'view', ['id', 'root', 'signals', 'nodes', 'chart']);
    final id = _str(doc['id'], 'view id');
    if (id.isEmpty) throw StateError('view id must be a non-empty string');
    final root = _str(doc['root'], 'view root');
    if (root.isEmpty) throw StateError('view root must be a non-empty string');
    final signalsDoc = _map(doc['signals'], 'view signals');
    final initials = <String, ViewValue>{};
    for (final entry in signalsDoc.entries) {
      if (entry.key.isEmpty)
        throw StateError('signal id must be a non-empty string');
      final sig = _map(entry.value, 'signal ${entry.key}');
      _allow(sig, 'signal ${entry.key}', ['initial']);
      initials[entry.key] = _literal(sig['initial']);
    }
    final hasChart = doc.containsKey('chart');
    if (hasChart && doc['chart'] is! Map) {
      throw StateError('chart must be a statechart document');
    }
    ChartDef? chartDef;
    if (hasChart) chartDef = ChartDef.fromJson(doc['chart'] as Map);
    final nodesDoc = _map(doc['nodes'], 'view nodes');
    if (nodesDoc.isEmpty)
      throw StateError('view nodes must contain at least one node');
    final nodes = <String, _Node>{};
    final effects = <String, Map<String, Object?>>{};
    final exprDocs = <MapEntry<String, Object?>>[];
    for (final entry in nodesDoc.entries) {
      final nid = entry.key;
      if (nid.isEmpty) throw StateError('node id must be a non-empty string');
      final node = _map(entry.value, 'node $nid');
      _allow(node, 'node $nid', [
        'role',
        'children',
        'layout',
        'text',
        'bind',
        'hidden',
        'disabled',
        'effects'
      ]);
      final role = _str(node['role'], 'node $nid role');
      if (!_roles.contains(role)) throw StateError('unknown role `$role`');
      final children = node.containsKey('children')
          ? _children(nid, node['children'])
          : <String>[];
      final flow =
          node.containsKey('layout') ? _layout(nid, node['layout']) : null;
      if (node.containsKey('bind')) {
        final bind = _str(node['bind'], 'bind');
        if (bind.isEmpty || !initials.containsKey(bind)) {
          throw StateError('bind names unknown signal `$bind`');
        }
      }
      if (node.containsKey('text')) {
        exprDocs.add(MapEntry(
            '$nid.text', _standingText(node['text'], initials.keys.toSet())));
      }
      if (node.containsKey('hidden')) {
        exprDocs.add(MapEntry('$nid.hidden',
            _standingFlag('hidden', node['hidden'], initials.keys.toSet())));
      }
      if (node.containsKey('disabled')) {
        exprDocs.add(MapEntry(
            '$nid.disabled',
            _standingFlag(
                'disabled', node['disabled'], initials.keys.toSet())));
      }
      if (node.containsKey('effects')) {
        final effectMap = _map(node['effects'], 'node $nid effects');
        _allow(
            effectMap, 'node $nid effects', ['activate', 'change', 'submit']);
        final stored = <String, Object?>{};
        for (final event in effectMap.entries) {
          _validateEffect(event.value, initials.keys.toSet(), hasChart);
          stored[event.key] = event.value;
        }
        if (stored.isNotEmpty) effects[nid] = stored;
      }
      nodes[nid] = _Node(role, children, flow);
    }
    if (!nodes.containsKey(root))
      throw StateError('root `$root` is not a node');
    _checkTree(root, nodes);
    final ctx = Context();
    final signals = <String, Source<ViewValue>>{
      for (final entry in initials.entries) entry.key: ctx.source(entry.value),
    };
    ViewValue readBare(String sid) =>
        ctx.get(signals[sid] ?? (throw StateError('unknown signal `$sid`')));
    for (final docExpr in exprDocs) {
      try {
        _evalExpr(docExpr.value, readBare, null);
      } catch (err) {
        throw StateError('${docExpr.key}: $err');
      }
    }
    final exprs = <String, Computed<ViewValue>>{};
    for (final docExpr in exprDocs) {
      final expr = docExpr.value;
      exprs[docExpr.key] = ctx.computed(
          (cx) => _evalExpr(expr, (sid) => cx.get(signals[sid]!), null));
    }
    final chart = chartDef == null ? null : StateChart(ctx, chartDef);
    final subscription = ctx.effect((cx) {
      if (exprs.isNotEmpty) {
        for (final expr in exprs.values) cx.get(expr);
      } else {
        for (final src in signals.values) cx.get(src);
      }
      return null;
    });
    return View._(
        ctx, root, nodes, signals, exprs, effects, chart, subscription);
  }

  Map<String, Object?> signalsJson() =>
      {for (final e in _signals.entries) e.key: _ctx.get(e.value).toJson()};

  Map<String, Object?> expressionsJson() =>
      {for (final e in _exprs.entries) e.key: _ctx.get(e.value).toJson()};

  List<Map<String, Object?>> layoutJson() {
    final out = <Map<String, Object?>>[];
    void walk(String id) {
      final node = _nodes[id]!;
      out.add({
        'id': id,
        'role': node.role,
        'children': node.children,
        'flow': node.flow
      });
      for (final child in node.children) walk(child);
    }

    walk(_root);
    return out;
  }

  List<String>? chartJson() => _chart?.activeLeaves();

  List<Map<String, Object?>> dispatchJson(
      String node, String event, Object? value) {
    if (!_events.contains(event)) throw StateError('unknown event `$event`');
    if (!_nodes.containsKey(node)) throw StateError('unknown node `$node`');
    final effect = _effects[node]?[event];
    if (effect == null) return [];
    _payload = _literal(value);
    try {
      final trace = <Map<String, Object?>>[];
      _exec(effect, trace);
      return trace;
    } finally {
      _payload = null;
    }
  }

  void _exec(Object? effect, List<Map<String, Object?>> trace) {
    final obj = _map(effect, 'effect');
    final op = _str(obj['op'], 'effect op');
    final args = _list(obj['args'], 'effect args');
    switch (op) {
      case 'set':
        final sid = _str(args[0], 'set signal');
        final src =
            _signals[sid] ?? (throw StateError('unknown signal `$sid`'));
        final next =
            _evalArg(args[1], (id) => _ctx.get(_signals[id]!), _payload);
        src.set(next);
        trace.add({'op': 'set', 'signal': sid, 'value': next.toJson()});
      case 'send':
        final chart = _chart ?? (throw StateError('send requires a chart'));
        final name = _str(args[0], 'send event');
        final record = <String, Object?>{'op': 'send', 'event': name};
        if (args.length == 2) {
          record['payload'] =
              _evalArg(args[1], (id) => _ctx.get(_signals[id]!), _payload)
                  .toJson();
        }
        chart.send(name, const {});
        trace.add(record);
      case 'batch':
        for (final nested in args) _exec(nested, trace);
      default:
        throw StateError('unknown effect op `$op`');
    }
  }
}

class _Node {
  _Node(this.role, this.children, this.flow);
  final String role;
  final List<String> children;
  final String? flow;
}

class ViewValue {
  ViewValue._(this.kind, this.b, this.n, this.s);
  final String kind;
  final bool b;
  final int n;
  final String s;

  static final nul = ViewValue._('null', false, 0, '');
  factory ViewValue.boolean(bool v) => ViewValue._('bool', v, 0, '');
  factory ViewValue.integer(int v) => ViewValue._('int', false, v, '');
  factory ViewValue.text(String v) => ViewValue._('str', false, 0, v);

  Object? toJson() => switch (kind) {
        'bool' => b,
        'int' => n,
        'str' => s,
        _ => null,
      };

  @override
  bool operator ==(Object other) =>
      other is ViewValue &&
      kind == other.kind &&
      b == other.b &&
      n == other.n &&
      s == other.s;

  @override
  int get hashCode => Object.hash(kind, b, n, s);
}

Map<String, Object?> _map(Object? value, String what) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.map((k, v) => MapEntry(k.toString(), v));
  throw StateError('$what must be an object');
}

List<Object?> _list(Object? value, String what) {
  if (value is List) return value;
  throw StateError('$what must be an array');
}

void _allow(Map<String, Object?> obj, String what, List<String> keys) {
  final allowed = keys.toSet();
  for (final key in obj.keys) {
    if (!allowed.contains(key))
      throw StateError('$what has unknown field `$key`');
  }
}

String _str(Object? value, String what) {
  if (value is String) return value;
  throw StateError('$what must be a string');
}

ViewValue _literal(Object? value) {
  if (value == null) return ViewValue.nul;
  if (value is bool) return ViewValue.boolean(value);
  if (value is int) return ViewValue.integer(value);
  if (value is double) {
    if (value == value.roundToDouble()) return ViewValue.integer(value.toInt());
    throw StateError('non-integer number $value');
  }
  if (value is String) return ViewValue.text(value);
  throw StateError('value must be null, boolean, integer, or string');
}

List<String> _children(String nid, Object? value) {
  final arr = _list(value, 'node $nid children');
  final seen = <String>{};
  return [
    for (final child in arr)
      () {
        if (child is! String || child.isEmpty) {
          throw StateError('node `$nid` children must be non-empty strings');
        }
        if (!seen.add(child))
          throw StateError('node `$nid` repeats child `$child`');
        return child;
      }(),
  ];
}

String? _layout(String nid, Object? value) {
  final obj = _map(value, 'node $nid layout');
  _allow(obj, 'node $nid layout', ['flow', 'align', 'grow']);
  String? flow;
  if (obj.containsKey('flow')) {
    flow = _str(obj['flow'], 'flow');
    if (!View._flows.contains(flow)) throw StateError('unknown flow `$flow`');
  }
  if (obj.containsKey('align')) {
    final align = _str(obj['align'], 'align');
    if (!View._aligns.contains(align))
      throw StateError('unknown align `$align`');
  }
  if (obj.containsKey('grow')) {
    final grow = _literal(obj['grow']);
    if (grow.kind != 'int' || grow.n < 0) {
      throw StateError('node `$nid` layout.grow must be an integer >= 0');
    }
  }
  return flow;
}

Object? _standingText(Object? value, Set<String> signals) {
  if (value is String)
    return {
      'op': 'lit',
      'args': [value]
    };
  if (value is Map) {
    _validateExpr(value, signals, false);
    return value;
  }
  throw StateError('text must be a string or an expression');
}

Object? _standingFlag(String field, Object? value, Set<String> signals) {
  if (value is bool)
    return {
      'op': 'lit',
      'args': [value]
    };
  if (value is Map) {
    _validateExpr(value, signals, false);
    return value;
  }
  throw StateError('$field must be a boolean or an expression');
}

void _validateEffect(Object? effect, Set<String> signals, bool hasChart) {
  final obj = _map(effect, 'effect');
  _allow(obj, 'effect', ['op', 'args']);
  final op = _str(obj['op'], 'effect op');
  if (!View._effectOps.contains(op))
    throw StateError('unknown effect op `$op`');
  final args = _list(obj['args'], 'effect args');
  switch (op) {
    case 'set':
      if (args.length != 2)
        throw StateError('set takes a signal id and a value');
      final sid = _str(args[0], 'set signal');
      if (!signals.contains(sid)) throw StateError('unknown signal `$sid`');
      _validateArg(args[1], signals, true);
    case 'send':
      if (!hasChart) throw StateError('send requires a chart');
      if (args.length != 1 && args.length != 2) {
        throw StateError('send takes an event name and an optional payload');
      }
      _str(args[0], 'send event');
      if (args.length == 2) _validateArg(args[1], signals, true);
    case 'batch':
      if (args.isEmpty) throw StateError('batch takes one or more effects');
      for (final nested in args) _validateEffect(nested, signals, hasChart);
  }
}

void _validateArg(Object? value, Set<String> signals, bool inEffect) {
  if (value is Map) {
    _validateExpr(value, signals, inEffect);
  } else {
    _literal(value);
  }
}

void _validateExpr(Object? expr, Set<String> signals, bool inEffect) {
  final obj = _map(expr, 'expression');
  _allow(obj, 'expression', ['op', 'args']);
  final op = _str(obj['op'], 'expression op');
  if (!View._exprOps.contains(op))
    throw StateError('unknown expression op `$op`');
  final args = _list(obj['args'], 'expression args');
  switch (op) {
    case 'lit':
      if (args.length != 1) throw StateError('lit takes one literal');
      _literal(args[0]);
    case 'ref':
      if (args.length != 1) throw StateError('ref takes one signal id');
      final sid = _str(args[0], 'ref');
      if (!signals.contains(sid)) throw StateError('unknown signal `$sid`');
    case 'call':
      _validateCall(args, signals, inEffect);
    case 'if':
      if (args.length != 3) throw StateError('if takes three arguments');
      for (final arg in args) _validateArg(arg, signals, inEffect);
    case 'eq':
      if (args.length != 2) throw StateError('eq takes two arguments');
      for (final arg in args) _validateArg(arg, signals, inEffect);
    case 'concat':
      for (final arg in args) _validateArg(arg, signals, inEffect);
    case 'trim':
      if (args.length != 1) throw StateError('trim takes one value');
      _validateArg(args[0], signals, inEffect);
  }
}

void _validateCall(List<Object?> args, Set<String> signals, bool inEffect) {
  if (args.isEmpty) throw StateError('call takes a name');
  final name = _str(args[0], 'call');
  if (!View._calls.contains(name)) throw StateError('unknown call `$name`');
  final rest = args.skip(1).toList();
  switch (name) {
    case 'event':
      if (rest.isNotEmpty) throw StateError('event takes no arguments');
      if (!inEffect) throw StateError('event is illegal outside an effect');
    case 'not':
      if (rest.length != 1) throw StateError('not takes one boolean');
    case 'add':
      if (rest.length < 2) throw StateError('add takes two or more integers');
    case 'len':
      if (rest.length != 1) throw StateError('len takes one string');
  }
  if (name != 'event') {
    for (final arg in rest) _validateArg(arg, signals, inEffect);
  }
}

void _checkTree(String root, Map<String, _Node> nodes) {
  final stack = <String>{};
  final done = <String>{};
  void walk(String id) {
    if (stack.contains(id)) throw StateError('children cycle at `$id`');
    if (done.contains(id))
      throw StateError('node `$id` has more than one parent');
    stack.add(id);
    for (final child in nodes[id]!.children) {
      if (!nodes.containsKey(child))
        throw StateError('children name unknown node `$child`');
      walk(child);
    }
    stack.remove(id);
    done.add(id);
  }

  walk(root);
  if (done.length != nodes.length)
    throw StateError('a node is not reachable from root');
}

ViewValue _evalExpr(
    Object? expr, ViewValue Function(String) read, ViewValue? payload) {
  final obj = _map(expr, 'expression');
  final op = _str(obj['op'], 'expression op');
  final args = _list(obj['args'], 'expression args');
  switch (op) {
    case 'lit':
      return _literal(args[0]);
    case 'ref':
      return read(_str(args[0], 'ref'));
    case 'call':
      return _evalCall(args, read, payload);
    case 'if':
      final cond = _evalArg(args[0], read, payload);
      if (cond.kind != 'bool')
        throw StateError('if condition must be a boolean');
      return _evalArg(cond.b ? args[1] : args[2], read, payload);
    case 'eq':
      final left = _evalArg(args[0], read, payload);
      final right = _evalArg(args[1], read, payload);
      return ViewValue.boolean(left == right);
    case 'concat':
      final buf = StringBuffer();
      for (final arg in args)
        buf.write(_stringify(_evalArg(arg, read, payload)));
      return ViewValue.text(buf.toString());
    case 'trim':
      return ViewValue.text(
          _stringify(_evalArg(args[0], read, payload)).trim());
    default:
      throw StateError('unknown expression op `$op`');
  }
}

ViewValue _evalCall(
    List<Object?> args, ViewValue Function(String) read, ViewValue? payload) {
  final name = _str(args[0], 'call');
  final rest = args.skip(1).toList();
  switch (name) {
    case 'event':
      return payload ??
          (throw StateError('event is illegal outside an effect'));
    case 'not':
      final value = _evalArg(rest[0], read, payload);
      if (value.kind != 'bool') throw StateError('not expects a boolean');
      return ViewValue.boolean(!value.b);
    case 'add':
      var sum = 0;
      for (final arg in rest) {
        final value = _evalArg(arg, read, payload);
        if (value.kind != 'int') throw StateError('add expects integers');
        final next = sum + value.n;
        if ((value.n > 0 && next < sum) || (value.n < 0 && next > sum)) {
          throw StateError('add overflow');
        }
        sum = next;
      }
      return ViewValue.integer(sum);
    case 'len':
      final value = _evalArg(rest[0], read, payload);
      if (value.kind != 'str') throw StateError('len expects a string');
      return ViewValue.integer(value.s.runes.length);
    default:
      throw StateError('unknown call `$name`');
  }
}

ViewValue _evalArg(
    Object? value, ViewValue Function(String) read, ViewValue? payload) {
  if (value is Map) return _evalExpr(value, read, payload);
  return _literal(value);
}

String _stringify(ViewValue value) => switch (value.kind) {
      'bool' => value.b ? 'true' : 'false',
      'int' => value.n.toString(),
      'str' => value.s,
      _ => '',
    };
