import 'dart:collection';
import 'dart:convert';

import 'core.dart';

/// A Harel/SCXML state chart — compound + parallel (orthogonal) regions, shallow
/// + deep history, entry/exit/transition actions, named guards (fail-closed),
/// and external + internal transitions.
///
/// This is the native Dart counterpart of [`lazily-formal`][formal]'s
/// `LazilyFormal.StateChart` and lazily-rs's / lazily-kt's state charts. It is
/// **compute, not protocol**: it is never serialized as a distinct wire kind.
/// The active configuration lives in a [Cell], so any [Slot]/[Signal]/[Effect]
/// reading [configuration], [activeLeaves], or [matches] is invalidated on a
/// real transition; a no-op (configuration unchanged) is suppressed by the
/// cell's structural-equality guard.
///
/// `send` is deterministic by construction — a total function of
/// `(chart, configuration, history, guards, event)`, mirroring the Lean
/// `StateChart.send`.
///
/// The declarative chart form is parsed from JSON conforming to
/// `lazily-spec/docs/state-charts.md` via [ChartDef.fromJson]. `run` actions
/// and `{"expr": …}` context guards are rejected explicitly; `final` states
/// are accepted as leaves without raising completion (`done`) events, matching
/// lazily-py and lazily-kt.
///
/// [formal]: https://github.com/lazily-hub/lazily-formal

// -- State / transition definitions -------------------------------------------

/// Kind of a state node — mirrors `LazilyFormal.StateChart.Kind`.
sealed class _Kind {
  const _Kind();
}

class _Atomic extends _Kind {
  const _Atomic();
}

class _Compound extends _Kind {
  const _Compound();
}

class _Parallel extends _Kind {
  const _Parallel();
}

class _Final extends _Kind {
  const _Final();
}

/// `deep = true` → deep history; `deep = false` → shallow history.
class _HistoryKind extends _Kind {
  const _HistoryKind(this.deep);
  final bool deep;
}

bool _isLeaf(_Kind k) => k is _Atomic || k is _Final;

class _Transition {
  const _Transition({
    required this.target,
    this.guard,
    this.action = const [],
    this.internal = false,
  });
  final String target;
  final String? guard;
  final List<String> action;
  final bool internal;
}

class _StateDef {
  const _StateDef({
    required this.kind,
    this.parent,
    this.initial,
    this.defaultChild,
    this.transitions = const {},
    this.entry = const [],
    this.exit = const [],
  });
  final _Kind kind;
  final String? parent;
  final String? initial;
  final String? defaultChild;
  final Map<String, _Transition> transitions;
  final List<String> entry;
  final List<String> exit;
}

/// A history recording for a region exited at least once.
sealed class _Recording {}

/// Direct child of the region that was active (shallow history).
class _ShallowRecording extends _Recording {
  _ShallowRecording(this.child);
  final String child;
}

/// Full active sub-configuration below the region (deep history).
class _DeepRecording extends _Recording {
  _DeepRecording(this.set);
  final SplayTreeSet<String> set;
}

// -- Chart definition ---------------------------------------------------------

/// A parsed, immutable chart definition. The node-labeled functions of the
/// declarative JSON form, materialized as maps for deterministic descent.
class ChartDef {
  ChartDef._({
    required this.states,
    required this.children,
    required this.order,
    required this.depths,
    required this.root,
  });

  final Map<String, _StateDef> states;
  final Map<String, List<String>> children;
  final Map<String, int> order;
  final Map<String, int> depths;
  final String root;

  /// Parse a chart definition from the declarative JSON form (a decoded
  /// `Map<String, Object?>` or a JSON string).
  factory ChartDef.fromJson(Object source) {
    final obj = source is String
        ? jsonDecode(source) as Map<String, dynamic>
        : source as Map<String, dynamic>;

    // Validates chart.initial is present; descent uses each compound's own
    // `initial` from the root, so the value itself is not stored.
    if (!_isStr(obj['initial'])) {
      throw const FormatException('chart.initial is required');
    }
    final statesObj = obj['states'];
    if (statesObj is! Map<String, dynamic>) {
      throw const FormatException('chart.states is required');
    }

    final stateDefs = <String, _StateDef>{};
    final docOrder = <String, int>{};
    var idx = 0;
    for (final entry in statesObj.entries) {
      docOrder[entry.key] = idx++;
      stateDefs[entry.key] =
          _parseState(entry.key, entry.value as Map<String, dynamic>);
    }
    final topInitial = obj['initial']! as String;
    if (!stateDefs.containsKey(topInitial)) {
      throw FormatException(
          'chart.initial names undeclared state "$topInitial"');
    }

    final kids = <String, List<String>>{};
    String? rootId;
    for (final entry in stateDefs.entries) {
      final p = entry.value.parent;
      if (p != null) {
        (kids[p] ??= <String>[]).add(entry.key);
      } else {
        if (rootId != null) {
          throw StateError('chart has more than one root (parent-less state)');
        }
        rootId = entry.key;
      }
    }
    // Sort children by document order for deterministic parallel descent.
    for (final list in kids.values) {
      list.sort(
          (a, b) => (docOrder[a] ?? 1 << 30).compareTo(docOrder[b] ?? 1 << 30));
    }
    if (rootId == null) {
      throw StateError('chart has no root (parent-less state)');
    }

    // Every state id a chart NAMES must be a state the chart DECLARES
    // (#failclosedsweep). Without this, an id that resolves to nothing —
    // a typo'd transition target, an `initial` naming a deleted child, a
    // history `default` pointing outside its region — reached the runtime as
    // a plain map miss, and `ChartDef.kind`, `_computeExitEnter`, and
    // `_enterSubtree` each answered it with a silent default (`_Atomic`, the
    // root, an empty child list). The chart then ENTERED a state that does not
    // exist: the active configuration contained a phantom id, the fixture's
    // expected configuration did not, and the mismatch surfaced as a diff
    // somewhere else entirely. The chart JSON is externally supplied, so this
    // is validated once at parse and never re-guessed at step time.
    void requireDeclared(String owner, String what, String? id) {
      if (id == null) return;
      if (!stateDefs.containsKey(id)) {
        throw FormatException(
            'state $owner: $what names undeclared state "$id"');
      }
    }

    for (final entry in stateDefs.entries) {
      final id = entry.key;
      final def = entry.value;
      requireDeclared(id, 'parent', def.parent);
      requireDeclared(id, 'initial', def.initial);
      requireDeclared(id, 'default', def.defaultChild);
      for (final t in def.transitions.entries) {
        requireDeclared(id, 'transition "${t.key}" target', t.value.target);
      }
    }

    final depthMap = <String, int>{};
    _computeDepth(stateDefs, rootId, 0, depthMap);

    return ChartDef._(
      states: stateDefs,
      children: kids,
      order: docOrder,
      depths: depthMap,
      root: rootId,
    );
  }

  /// The structural kind of state [id].
  ///
  /// Throws when [id] is not a declared state. This used to answer an unknown
  /// id with `_Atomic()`, which made every caller below treat a nonexistent
  /// state as an ordinary leaf and enter it (#failclosedsweep). Chart-supplied
  /// ids are now proven declared by [ChartDef.fromJson], so reaching this
  /// throw means a CALLER invented the id.
  _Kind kind(String id) {
    final def = states[id];
    if (def == null) {
      throw ArgumentError.value(id, 'id', 'unknown state in this chart');
    }
    return def.kind;
  }

  /// Ancestors of [id] inclusive, `[id, …, root]`.
  List<String> ancestorsInclusive(String id) {
    final out = <String>[];
    var cur = id;
    while (true) {
      out.add(cur);
      final p = states[cur]?.parent;
      if (p == null) break;
      cur = p;
    }
    return out;
  }

  /// Lowest common ancestor (inclusive) of [a] and [b]; falls back to [root].
  String lca(String a, String b) {
    final ancA = ancestorsInclusive(a).toSet();
    for (final cid in ancestorsInclusive(b)) {
      if (ancA.contains(cid)) return cid;
    }
    return root;
  }

  /// `true` iff [desc] is a proper descendant of [anc].
  bool isProperDescendant(String desc, String anc) =>
      desc != anc && ancestorsInclusive(desc).contains(anc);

  int depth(String id) => depths[id] ?? 0;
}

bool _isStr(Object? v) => v is String;

String _requireStr(Object? v, String what) {
  if (v is! String) throw FormatException('$what must be a string');
  return v;
}

_StateDef _parseState(String id, Map<String, dynamic> obj) {
  String? optionalString(String field) {
    final value = obj[field];
    if (value != null && value is! String) {
      throw FormatException('state $id: $field must be a string');
    }
    return value as String?;
  }

  final parent = optionalString('parent');
  final initial = optionalString('initial');
  final defaultChild = optionalString('default');

  if (obj['run'] != null) {
    throw FormatException(
        'state $id uses `run` actions, which are not supported');
  }

  final histKind = obj['history'];
  final declaredKind = obj['kind'];
  final parallel = obj['parallel'];
  if (histKind != null && histKind is! String) {
    throw FormatException('state $id: history must be a string');
  }
  if (parallel != null && parallel is! bool) {
    throw FormatException('state $id: parallel must be a boolean');
  }

  final _Kind inferredKind;
  final String inferredName;
  if (histKind is String) {
    switch (histKind) {
      case 'shallow':
        inferredKind = const _HistoryKind(false);
      case 'deep':
        inferredKind = const _HistoryKind(true);
      default:
        throw FormatException('state $id: unknown history kind $histKind');
    }
    inferredName = 'history';
  } else if (parallel == true) {
    inferredKind = const _Parallel();
    inferredName = 'parallel';
  } else if (initial != null) {
    inferredKind = const _Compound();
    inferredName = 'compound';
  } else {
    inferredKind = const _Atomic();
    inferredName = 'atomic';
  }

  if (declaredKind != null && declaredKind is! String) {
    throw FormatException('state $id: kind must be a string');
  }
  final _Kind kind;
  if (declaredKind == 'final') {
    if (inferredName != 'atomic') {
      throw FormatException(
          'state $id: declared kind "final" contradicts "$inferredName"');
    }
    kind = const _Final();
  } else if (declaredKind != null) {
    if (!const {
      'atomic',
      'compound',
      'parallel',
      'history',
    }.contains(declaredKind)) {
      throw FormatException('state $id: unknown kind "$declaredKind"');
    }
    if (declaredKind != inferredName) {
      throw FormatException(
          'state $id: declared kind "$declaredKind" contradicts "$inferredName"');
    }
    kind = inferredKind;
  } else {
    kind = inferredKind;
  }

  final entry = _actionList(obj['entry']);
  final exit = _actionList(obj['exit']);

  final transitions = <String, _Transition>{};
  final on = obj['on'];
  if (on is Map<String, dynamic>) {
    for (final entry_ in on.entries) {
      transitions[entry_.key] = _parseTransition(entry_.value);
    }
  }

  return _StateDef(
    kind: kind,
    parent: parent,
    initial: initial,
    defaultChild: defaultChild,
    transitions: transitions,
    entry: entry,
    exit: exit,
  );
}

List<String> _actionList(Object? raw) {
  if (raw == null) return const [];
  if (raw is! List) {
    throw const FormatException(
        'action must be a string (object-form actions are rejected explicitly per spec)');
  }
  return raw.map((e) {
    if (e is! String) {
      throw const FormatException(
          'action must be a string (object-form actions are rejected explicitly per spec)');
    }
    return e;
  }).toList(growable: false);
}

_Transition _parseTransition(Object? raw) {
  if (raw is String) return _Transition(target: raw);
  if (raw is Map<String, dynamic>) {
    final target = _requireStr(raw['target'], 'transition target');
    final guardRaw = raw['guard'];
    final String? guard;
    if (guardRaw == null) {
      guard = null;
    } else if (guardRaw is String) {
      guard = guardRaw;
    } else if (guardRaw is Map) {
      throw const FormatException(
          'context-expression `{expr: …}` guards are not supported (rejected explicitly per spec)');
    } else {
      throw const FormatException('guard must be a string');
    }
    final internal = raw['internal'];
    if (internal != null && internal is! bool) {
      throw const FormatException('transition internal must be a boolean');
    }
    return _Transition(
      target: target,
      guard: guard,
      action: _actionList(raw['action']),
      internal: internal == true,
    );
  }
  throw const FormatException('transition must be a string or object');
}

void _computeDepth(Map<String, _StateDef> states, String id, int current,
    Map<String, int> out) {
  out[id] = current;
  for (final entry in states.entries) {
    if (entry.value.parent == id)
      _computeDepth(states, entry.key, current + 1, out);
  }
}

// -- Active configuration (value-equal wrapper for the Cell's no-op guard) ----

/// The active configuration: the set of active states (atomic leaves plus all
/// active ancestors). Structural [==]/[hashCode] let the backing [Cell]
/// suppress a no-op write (configuration unchanged) — the Dart counterpart of
/// Kotlin's content-equal `TreeSet.equals`.
class Configuration {
  Configuration(Set<String> states) : _states = SplayTreeSet<String>.of(states);

  final SplayTreeSet<String> _states;

  /// A sorted snapshot of the active states.
  Set<String> toSet() => SplayTreeSet<String>.of(_states);

  bool contains(String id) => _states.contains(id);

  bool get isEmpty => _states.isEmpty;

  Iterable<String> where(bool Function(String) test) => _states.where(test);

  @override
  bool operator ==(Object other) =>
      other is Configuration &&
      _states.length == other._states.length &&
      _states.containsAll(other._states);

  @override
  int get hashCode => Object.hashAll(_states);
}

// -- Reactive chart -----------------------------------------------------------

/// A reactive full-Harel state chart backed by a configuration [Cell].
///
/// Construct via [StateChart.new] (descending the root's initial configuration,
/// recording initial entry actions). Then drive with [send]; query with
/// [configuration], [activeLeaves], [matches]; inspect the last step's action
/// trace with [lastActions].
class StateChart {
  /// Creates a chart bound to [ctx] that enters the initial configuration by
  /// descending from [def]'s root.
  StateChart(this.ctx, this.def)
      : _history = {},
        _lastActions = const [] {
    final enter = <String>{};
    final actions = <String>[];
    _enterSubtree(def.root, enter, actions);
    _config = Source<Configuration>(ctx, Configuration(enter));
    _lastActions = actions;
  }

  /// The reactive context this chart belongs to.
  final Context ctx;

  /// The parsed chart definition.
  final ChartDef def;

  final Map<String, _Recording> _history;

  /// Actions fired by the initial entry or the most recent [send]
  /// (exit innermost-first → transition → entry outermost-first).
  List<String> _lastActions;
  late final Source<Configuration> _config;

  /// Ordered action names fired by the initial entry or the most recent [send].
  List<String> lastActions() => List<String>.unmodifiable(_lastActions);

  /// The full active configuration (active leaves plus all active ancestors).
  /// Pass the ambient [Compute] to subscribe the reader (value-threaded
  /// tracking); a bare call outside a compute is an untracked read.
  Configuration configuration([Compute? cx]) {
    final stored = cx == null ? _config.value : cx.get(_config);
    return Configuration(stored.toSet());
  }

  /// Active atomic leaves, sorted (one per parallel region; one for single-region).
  List<String> activeLeaves([Compute? cx]) =>
      configuration(cx).where((s) => _isLeaf(def.kind(s))).toList()..sort();

  /// Hierarchical "state-in" predicate: `true` iff [id] is in the active
  /// configuration. Pass the ambient [Compute] to subscribe the reader.
  bool matches(String id, [Compute? cx]) => configuration(cx).contains(id);

  /// Send an event (run-to-completion). Returns `true` if any transition was
  /// taken, `false` if rejected (configuration unchanged, no actions fired).
  ///
  /// [guards] resolves named guards for this send (absent/unknown name →
  /// fail-closed `false`).
  bool send(String event, [Map<String, bool> guards = const {}]) {
    final config = configuration().toSet();

    // 1. Enabled transitions: per active leaf, innermost passing match.
    final candidates = <_Candidate>[];
    for (final leaf in config.where((s) => _isLeaf(def.kind(s)))) {
      for (final anc in def.ancestorsInclusive(leaf)) {
        final t = def.states[anc]?.transitions[event];
        if (t != null && _guardPasses(t, guards)) {
          candidates.add(_Candidate(anc, t, leaf));
          break; // innermost wins for this leaf's chain
        }
      }
    }

    if (candidates.isEmpty) {
      _lastActions = const [];
      return false;
    }

    // 2. Conflict resolution: order by source depth desc, then document order;
    //    take greedily, skipping any whose exit set intersects the taken union.
    candidates.sort((a, b) {
      final byDepth = def.depth(b.source).compareTo(def.depth(a.source));
      if (byDepth != 0) return byDepth;
      return (def.order[a.source] ?? 1 << 30)
          .compareTo(def.order[b.source] ?? 1 << 30);
    });

    final exitUnion = <String>{};
    final enterUnion = <String>{};
    final takenTransitions = <_Transition>[];
    for (final cand in candidates) {
      final pair =
          _computeExitEnter(cand.source, cand.transition, cand.leaf, config);
      if (pair.exit.any(exitUnion.contains))
        continue; // conflicts with a taken transition
      exitUnion.addAll(pair.exit);
      enterUnion.addAll(pair.enter);
      takenTransitions.add(cand.transition);
    }

    if (takenTransitions.isEmpty) {
      _lastActions = const [];
      return false;
    }

    // 3. Record history for regions being exited that own a history child.
    for (final s in exitUnion) {
      final hChild = _historyChildOf(s);
      if (hChild != null) _recordRegion(s, hChild, config);
    }

    // 4. Action trace: exit (innermost-first) → transition → entry (outermost-first).
    final actions = <String>[];
    final exitSorted = exitUnion.toList()
      ..sort((a, b) => def.depth(b).compareTo(def.depth(a)));
    for (final s in exitSorted) {
      actions.addAll(def.states[s]!.exit);
    }
    for (final t in takenTransitions) {
      actions.addAll(t.action);
    }
    final enterSorted = enterUnion.toList()
      ..sort((a, b) => def.depth(a).compareTo(def.depth(b)));
    for (final s in enterSorted) {
      actions.addAll(def.states[s]!.entry);
    }

    // 5. Apply new configuration (structural-equality guard suppresses no-ops).
    final newConfig = SplayTreeSet<String>.of(config);
    for (final s in exitUnion) {
      newConfig.remove(s);
    }
    for (final s in enterUnion) {
      newConfig.add(s);
    }

    _lastActions = actions;
    final next = Configuration(newConfig);
    if (next != Configuration(config)) {
      _config.value = next;
    }
    return true;
  }

  ({Set<String> exit, Set<String> enter}) _computeExitEnter(
    String source,
    _Transition transition,
    String leaf,
    Set<String> config,
  ) {
    final target = transition.target;
    final internal = transition.internal &&
        (target == source || def.isProperDescendant(target, source));
    final lca = internal ? source : def.lca(leaf, target);

    // Exit set: active proper-descendants of the lca.
    final exitSet = <String>{};
    for (final s in config) {
      if (def.isProperDescendant(s, lca)) exitSet.add(s);
    }

    final enter = <String>{};
    final kind = def.kind(target);
    if (kind is _HistoryKind) {
      final region = def.states[target]?.parent ?? def.root;
      enter.addAll(_pathBelow(lca, region));
      _restoreViaHistory(target, region, enter);
    } else {
      enter.addAll(_pathBelow(lca, target));
      final tmp = <String>[];
      _enterSubtree(target, enter, tmp);
    }
    return (exit: exitSet, enter: enter);
  }

  void _restoreViaHistory(String hist, String region, Set<String> enter) {
    switch (_history[hist]) {
      case _ShallowRecording(:final child):
        enter.add(child);
        final tmp = <String>[];
        _enterSubtree(child, enter, tmp);
      case _DeepRecording(:final set):
        enter.addAll(set);
      case null:
        // First entry: descend via `default`, else the region's `initial`.
        final start =
            def.states[hist]?.defaultChild ?? def.states[region]?.initial;
        if (start != null) {
          enter.addAll(_pathBelow(region, start));
          final tmp = <String>[];
          _enterSubtree(start, enter, tmp);
        }
    }
  }

  /// Enter [state] and its default descendants, recording entry actions top-down.
  void _enterSubtree(String state, Set<String> enter, List<String> actions) {
    enter.add(state);
    final sd = def.states[state];
    if (sd != null) actions.addAll(sd.entry);
    switch (def.kind(state)) {
      case _Atomic():
      case _Final():
      case _HistoryKind():
        break;
      case _Compound():
        final init = def.states[state]?.initial;
        if (init != null) _enterSubtree(init, enter, actions);
      case _Parallel():
        for (final region in def.children[state] ?? const <String>[]) {
          _enterSubtree(region, enter, actions);
        }
    }
  }

  /// Path from just-below [lca] down to [target] (exclusive lca, inclusive target).
  List<String> _pathBelow(String lca, String target) {
    final chain = def.ancestorsInclusive(target); // [target, ..., root]
    var idx = chain.indexOf(lca);
    if (idx < 0) idx = chain.length;
    return chain
        .sublist(0, idx)
        .reversed
        .toList(growable: false); // [child-of-lca, ..., target]
  }

  String? _historyChildOf(String region) {
    for (final child in def.children[region] ?? const <String>[]) {
      if (def.kind(child) is _HistoryKind) return child;
    }
    return null;
  }

  void _recordRegion(String region, String histChild, Set<String> config) {
    final kind = def.kind(histChild);
    if (kind is! _HistoryKind) return;
    if (!kind.deep) {
      // Shallow: record the direct child of `region` that was active.
      for (final child in def.children[region] ?? const <String>[]) {
        if (config.contains(child) && def.kind(child) is! _HistoryKind) {
          _history[histChild] = _ShallowRecording(child);
          return;
        }
      }
    } else {
      // Deep: record every active state strictly below `region`.
      final set = SplayTreeSet<String>();
      for (final s in config) {
        if (def.isProperDescendant(s, region)) set.add(s);
      }
      _history[histChild] = _DeepRecording(set);
    }
  }

  @override
  String toString() => 'StateChart(${activeLeaves().join(', ')})';
}

class _Candidate {
  _Candidate(this.source, this.transition, this.leaf);
  final String source;
  final _Transition transition;
  final String leaf;
}

bool _guardPasses(_Transition t, Map<String, bool> guards) {
  final g = t.guard;
  if (g == null) return true;
  return guards[g] ?? false; // fail-closed
}
