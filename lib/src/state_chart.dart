import 'core.dart';

/// A node in a [StateChart] state tree.
///
/// A [ChartState] is either **atomic** (a leaf, no children) or **composite**
/// (contains [children] and designates one of them as [initial]). When a
/// composite state is entered, its [initial] child is entered recursively until
/// an atomic state is reached.
class ChartState<S> {
  /// Creates an atomic (leaf) state.
  const ChartState.atomic({this.onEnter, this.onExit})
      : initial = null,
        children = const [];

  /// Creates a composite state whose [initial] child is entered on entry.
  const ChartState.composite({
    required S this.initial,
    required List<S> this.children,
    this.onEnter,
    this.onExit,
  });

  /// For composite states, the child entered by default. `null` for atomic.
  final S? initial;

  /// For composite states, the child state ids. Empty for atomic.
  final List<S> children;

  /// Whether this state is composite.
  bool get isComposite => children.isNotEmpty;

  /// Action fired when this state is entered (after its ancestors' entries).
  final void Function(S state)? onEnter;

  /// Action fired when this state is exited (before its ancestors' exits).
  final void Function(S state)? onExit;
}

/// A declarative transition in a [StateChart].
///
/// A transition fires when [from] (or any of its active descendants, via event
/// bubbling) receives [event], the optional [guard] passes, and no innermost
/// state on the active path handles [event] first.
class ChartTransition<S, E> {
  const ChartTransition({
    required this.from,
    required this.event,
    required this.to,
    this.guard,
    this.action,
  });

  /// Source state id. Active descendants of [from] bubble the event up to it.
  final S from;

  /// The event that triggers this transition.
  final E event;

  /// Target state id. May be composite; it is descended to its initial atomic
  /// leaf on entry.
  final S to;

  /// Optional guard. The transition is enabled only when it returns `true`.
  final bool Function()? guard;

  /// Optional action run after exits and before entries (between states).
  final void Function()? action;
}

/// A Harel-style hierarchical state machine backed by a reactive [Cell].
///
/// States form a tree (composite states contain children). The active state is
/// a path from the root to an atomic leaf, stored in a [Cell] so any [Slot],
/// [Signal], or observer that reads [active] or [isActive] is invalidated on
/// transition.
///
/// On [send], the event **bubbles** from the active leaf up to the root; the
/// innermost matching enabled transition wins. Exiting and entering states are
/// resolved through their lowest common ancestor (LCA): exit actions run
/// leaf-first up to the LCA, the transition action runs, then entry actions
/// run top-down from the LCA to the target's initial atomic leaf.
///
/// Not yet implemented: orthogonal (parallel) regions and history states.
///
/// Example::
///
///     final ctx = Context();
///     final chart = StateChart<String, String>(
///       ctx: ctx,
///       root: 'off',
///       states: {
///         'off': const ChartState.atomic(),
///         'on': const ChartState.composite(initial: 'playing', children: ['playing', 'paused']),
///         'playing': const ChartState.atomic(),
///         'paused': const ChartState.atomic(),
///       },
///       transitions: [
///         ChartTransition(from: 'off', event: 'toggle', to: 'on'),
///         ChartTransition(from: 'on', event: 'toggle', to: 'off'),
///         ChartTransition(from: 'playing', event: 'pause', to: 'paused'),
///         ChartTransition(from: 'paused', event: 'play', to: 'playing'),
///       ],
///     );
///     chart.send('toggle'); // off -> on -> playing (initial)
///     chart.active;         // 'playing'
class StateChart<S, E> {
  StateChart({
    required this.ctx,
    required S root,
    required Map<S, ChartState<S>> states,
    List<ChartTransition<S, E>> transitions = const [],
  }) : _states = Map<S, ChartState<S>>.from(states) {
    _validate(root);
    _index(transitions);
    final initialPath = _descendChain(root);
    _pathCell = Cell<List<S>>(ctx, List<S>.of(initialPath));
    // Run entry actions top-down for the initial active configuration.
    for (final id in initialPath) {
      _states[id]?.onEnter?.call(id);
    }
  }

  /// The reactive context this chart belongs to.
  final Context ctx;
  final Map<S, ChartState<S>> _states;
  final Map<S, List<ChartTransition<S, E>>> _bySource = {};
  final Map<S, S?> _parent = {};
  late final Cell<List<S>> _pathCell;

  /// The active atomic leaf. Reading inside a computation subscribes.
  S get active => _pathCell.value.last;

  /// The active path, root first. Reading inside a computation subscribes.
  List<S> get activePath => List<S>.unmodifiable(_pathCell.value);

  /// Whether [state] is active. A composite state is active when any
  /// descendant is active. Reading inside a computation subscribes.
  bool isActive(S state) {
    final path = _pathCell.value; // establish dependency
    return path.contains(state);
  }

  /// Send an event. Returns `true` if a transition fired.
  bool send(E event) {
    final sourcePath = _pathCell.value;
    // Event bubbling: innermost (leaf) first.
    for (var i = sourcePath.length - 1; i >= 0; i--) {
      final candidate = sourcePath[i];
      final matches = _bySource[candidate];
      if (matches == null) continue;
      for (final t in matches) {
        if (t.event == event && (t.guard == null || t.guard!())) {
          _apply(t, sourcePath);
          return true;
        }
      }
    }
    return false;
  }

  /// Force the chart into [target] without an event (e.g. for tests / resets).
  /// Descends to the target's initial atomic leaf. Returns the new active path.
  List<S> enter(S target) {
    final newPath = _fullTargetPath(target);
    _pathCell.value = List<S>.of(newPath);
    return activePath;
  }

  void _apply(ChartTransition<S, E> t, List<S> sourcePath) {
    final targetPath = _fullTargetPath(t.to);
    final lcaDepth = _commonPrefix(sourcePath, targetPath);

    // Exit chain: leaf-first down to the divergence (inclusive), i.e. every
    // state below the (possibly virtual) lowest common ancestor.
    for (var i = sourcePath.length - 1; i >= lcaDepth; i--) {
      _states[sourcePath[i]]?.onExit?.call(sourcePath[i]);
    }
    // Transition action, between exit and entry.
    t.action?.call();
    // Entry chain: top-down from the divergence (inclusive) to the leaf.
    for (var i = lcaDepth; i < targetPath.length; i++) {
      _states[targetPath[i]]?.onEnter?.call(targetPath[i]);
    }
    _pathCell.value = List<S>.of(targetPath);
  }

  int _commonPrefix(List<S> a, List<S> b) {
    var i = 0;
    while (i < a.length && i < b.length && a[i] == b[i]) {
      i++;
    }
    return i; // index of the first divergence; LCA is at index i - 1
  }

  List<S> _fullTargetPath(S target) {
    final toRoot = <S>[];
    S? cursor = target;
    while (cursor != null) {
      toRoot.add(cursor);
      cursor = _parent[cursor];
    }
    final rootFirst = toRoot.reversed.toList(growable: false);
    // Descend to the target's initial atomic leaf if it is composite.
    if (_states[target]!.isComposite) {
      final descend = _descendChain(target); // [target, initial, ...]
      // rootFirst already ends in target; drop the duplicate from descend.
      return [...rootFirst, ...descend.sublist(1)];
    }
    return rootFirst;
  }

  List<S> _descendChain(S start) {
    final chain = <S>[start];
    var cursor = start;
    while (_states[cursor]!.isComposite) {
      cursor = _states[cursor]!.initial as S;
      chain.add(cursor);
    }
    return chain;
  }

  void _validate(S root) {
    if (!_states.containsKey(root)) {
      throw ArgumentError('root state $root is not in states');
    }
    _states.forEach((id, node) {
      if (node.isComposite) {
        // `initial` is non-null for composite by construction (required param).
        if (!node.children.contains(node.initial)) {
          throw StateError(
              'composite state $id initial ${node.initial} is not in its children');
        }
        for (final child in node.children) {
          if (!_states.containsKey(child)) {
            throw StateError('child $child of $id is not declared in states');
          }
          if (_parent.containsKey(child)) {
            throw StateError('state $child has two parents');
          }
          _parent[child] = id;
        }
      }
    });
    // Cycle guard: no state may be its own ancestor. Also bounds ancestor
    // walks used elsewhere, so a malformed graph can't loop forever.
    for (final id in _states.keys) {
      final seen = <S>{};
      S? cursor = _parent[id];
      while (cursor != null) {
        if (!seen.add(cursor)) {
          throw StateError('cycle detected through state $cursor');
        }
        cursor = _parent[cursor];
      }
    }
  }

  void _index(List<ChartTransition<S, E>> transitions) {
    for (final t in transitions) {
      if (!_states.containsKey(t.from)) {
        throw ArgumentError(
            'transition source ${t.from} is not a declared state');
      }
      if (!_states.containsKey(t.to)) {
        throw ArgumentError(
            'transition target ${t.to} is not a declared state');
      }
      (_bySource[t.from] ??= <ChartTransition<S, E>>[]).add(t);
    }
  }

  @override
  String toString() => 'StateChart(${activePath.join(' > ')})';
}
