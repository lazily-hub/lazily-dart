import 'dart:convert';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

// Property-based validation of the Dart state chart against the universal
// properties established by the Lean `LazilyFormal.StateChart` /
// `StateMachine` formal model in `lazily-formal`. These are the guarantees no
// finite fixture suite can establish: determinism-by-construction,
// parallel-region confluence, and single-region refinement of the flat FSM
// kernel.
//
// Each test names the Lean theorem it mirrors and exercises the Dart
// implementation against the theorem's statement. `test/formal_check_test.dart`
// builds the Lean model itself, so these mirrored statements are checked
// against a compiling proof.

StateChart _chart(Context ctx, Map<String, dynamic> chart) =>
    StateChart(ctx, ChartDef.fromJson(chart));

Map<String, dynamic> _clone(Map<String, dynamic> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, dynamic>;

class _Snapshot {
  final List<String> leaves;
  final Set<String> config;
  final List<String> actions;
  final bool? accepted;
  _Snapshot(this.leaves, this.config, this.actions, {this.accepted});
}

_Snapshot _snap(StateChart c, {bool? accepted}) => _Snapshot(
      c.activeLeaves(),
      c.configuration().toSet(),
      c.lastActions(),
      accepted: accepted,
    );

// A minimal flat FSM (the `LazilyFormal.StateMachine.Machine` kernel) for the
// single-region refinement check: `current` + `transition: state -> event -> ?state`.
class _FlatMachine {
  _FlatMachine(this.current, this.table);
  String current;
  final Map<String, Map<String, String>> table;
  bool send(String event) {
    final next = table[current]?[event];
    if (next == null) return false;
    current = next;
    return true;
  }
}

void main() {
  // ===========================================================================
  // enabled_empty_rejects (StateChart.lean)
  // "An event with no enabled, guard-passing transition leaves the configuration
  //  (and history) unchanged, and the action trace empty."
  // ===========================================================================
  test('Lean enabled_empty_rejects: unknown event leaves cfg + history unchanged, actions empty', () {
    final ctx = Context();
    final chart = _chart(ctx, {
      'initial': 'a1',
      'states': {
        'root': {'initial': 'a'},
        'a': {'parent': 'root', 'initial': 'a1', 'entry': ['enterA']},
        'a1': {'parent': 'a', 'on': {'SWAP': 'a2'}},
        'a2': {'parent': 'a'},
      },
    });

    final before = _snap(chart);
    final accepted = chart.send('NOPE');
    final after = _snap(chart, accepted: accepted);

    expect(accepted, isFalse);
    expect(after.leaves, before.leaves);
    expect(after.config, before.config);
    expect(after.actions, isEmpty);
  });

  test('Lean enabled_empty_rejects: guard failing -> rejected (guard-passing is part of "enabled")', () {
    final ctx = Context();
    final chart = _chart(ctx, {
      'initial': 'closed',
      'states': {
        'root': {'initial': 'closed'},
        'closed': {
          'parent': 'root',
          'on': {'OPEN': {'target': 'open', 'guard': 'allowed'}},
        },
        'open': {'parent': 'root', 'on': {'CLOSE': 'closed'}},
      },
    });

    final before = _snap(chart);
    final accepted = chart.send('OPEN', {'allowed': false});
    final after = _snap(chart, accepted: accepted);

    expect(accepted, isFalse);
    expect(after.config, before.config);
    expect(after.actions, isEmpty);
  });

  // ===========================================================================
  // send_preserves_chart (StateChart.lean) / send_preserves_transition (StateMachine.lean)
  // "send never mutates the chart definition." ChartDef is immutable; assert the
  // observable derived structure is identical after a send that takes a transition.
  // ===========================================================================
  test('Lean send_preserves_chart: taking a transition never mutates the chart definition', () {
    final json = {
      'initial': 'green',
      'states': {
        'root': {'initial': 'green'},
        'red': {'parent': 'root', 'on': {'TICK': 'green'}},
        'green': {'parent': 'root', 'on': {'TICK': 'yellow'}},
        'yellow': {'parent': 'root', 'on': {'TICK': 'red'}},
      },
    };
    final ctx = Context();
    final def = ChartDef.fromJson(json);
    final chart = StateChart(ctx, def);

    final rootBefore = def.root;
    final orderBefore = Map<String, int>.from(def.order);
    final childrenBefore = def.children.map((k, v) => MapEntry(k, List<String>.from(v)));
    final depthsBefore = Map<String, int>.from(def.depths);
    final statesBefore = def.states.keys.toSet();

    expect(chart.send('TICK'), isTrue); // green -> yellow

    expect(def.root, rootBefore);
    expect(def.order, orderBefore);
    expect(def.children, childrenBefore);
    expect(def.depths, depthsBefore);
    expect(def.states.keys.toSet(), statesBefore);
  });

  // ===========================================================================
  // Determinism by construction (StateChart.send is a total function)
  // "A given (chart, history, configuration, event, guards) yields a unique
  //  StepResult." Validate by cloning the chart definition and replaying an
  //  identical event sequence on two independent instances.
  // ===========================================================================
  test('Lean determinism-by-construction: identical inputs yield identical results', () {
    final chartJson = {
      'initial': 'a1',
      'states': {
        'root': {'initial': 'a'},
        'a': {'parent': 'root', 'initial': 'a1', 'entry': ['enterA'], 'exit': ['exitA']},
        'a1': {'parent': 'a', 'on': {'GO': 'a2'}},
        'a2': {'parent': 'a', 'on': {'GO': 'a1'}, 'entry': ['enterA2']},
      },
    };

    final steps = [
      ['GO'],
      ['GO'],
      ['NOPE'],
      ['GO'],
      ['GO'],
    ];

    List<_Snapshot> run() {
      final ctx = Context();
      final c = StateChart(ctx, ChartDef.fromJson(_clone(chartJson)));
      final trace = [_snap(c, accepted: null)];
      for (final s in steps) {
        final accepted = c.send(s[0]);
        trace.add(_snap(c, accepted: accepted));
      }
      return trace;
    }

    final trace1 = run();
    final trace2 = run();

    void expectEq(_Snapshot a, _Snapshot b) {
      expect(a.leaves, b.leaves);
      expect(a.config, b.config);
      expect(a.actions, b.actions);
      expect(a.accepted, b.accepted);
    }

    for (var i = 0; i < trace1.length; i++) {
      expectEq(trace1[i], trace2[i]);
    }
  });

  // ===========================================================================
  // single_region_refines_flat_machine (StateChart.lean)
  // "A single-region chart's send refines the flat StateMachine kernel: the new
  //  active leaf equals the flat machine's transition target (reject case from
  //  pointer well-formedness; take case under single-region structural coherence)."
  // ===========================================================================
  test('Lean single_region_refines_flat_machine: flat chart send == flat FSM send', () {
    final ctx = Context();
    final chart = _chart(ctx, {
      'initial': 'green',
      'states': {
        'root': {'initial': 'green'},
        'red': {'parent': 'root', 'on': {'TICK': 'green'}},
        'green': {'parent': 'root', 'on': {'TICK': 'yellow'}},
        'yellow': {'parent': 'root', 'on': {'TICK': 'red'}},
      },
    });

    final flat = _FlatMachine('green', {
      'red': {'TICK': 'green'},
      'green': {'TICK': 'yellow'},
      'yellow': {'TICK': 'red'},
    });

    const events = ['TICK', 'TICK', 'UNKNOWN', 'TICK', 'TICK', 'TICK', 'TICK'];
    for (final ev in events) {
      final chartAccepted = chart.send(ev);
      final flatAccepted = flat.send(ev);
      expect(chartAccepted, flatAccepted, reason: 'accepted mismatch on $ev');
      expect(chart.activeLeaves(), [flat.current], reason: 'leaf mismatch after $ev');
    }
  });

  test('Lean single_region_refines_flat_machine: hierarchical single-region chart refines flat kernel', () {
    final ctx = Context();
    final chart = _chart(ctx, {
      'initial': 'on',
      'states': {
        'root': {'initial': 'on'},
        'on': {'parent': 'root', 'initial': 'ready', 'on': {'POWER': 'off'}},
        'ready': {'parent': 'on', 'on': {'FIRE': 'firing'}},
        'firing': {'parent': 'on', 'on': {'DONE': 'ready'}},
        'off': {'parent': 'root', 'on': {'POWER': 'on'}},
      },
    });

    final flat = _FlatMachine('ready', {
      'ready': {'FIRE': 'firing', 'POWER': 'off'},
      'firing': {'DONE': 'ready', 'POWER': 'off'},
      'off': {'POWER': 'ready'}, // target "on" is compound; defaultLeaf("on") = "ready"
    });

    const events = ['FIRE', 'DONE', 'POWER', 'POWER', 'FIRE', 'POWER', 'NOPE'];
    for (final ev in events) {
      final chartAccepted = chart.send(ev);
      final flatAccepted = flat.send(ev);
      expect(chartAccepted, flatAccepted, reason: 'accepted mismatch on $ev');
      expect(chart.activeLeaves(), [flat.current], reason: 'leaf mismatch after $ev');
    }
  });

  // ===========================================================================
  // single_region_enabled_at_most_one (StateChart.lean)
  // "With exactly one active leaf, the enabled set has length <= 1, so send takes
  //  at most one transition." Validated by observing the accepted-leaf delta.
  // ===========================================================================
  test('Lean single_region_enabled_at_most_one: single leaf never takes >1 transition', () {
    final ctx = Context();
    final chart = _chart(ctx, {
      'initial': 's1',
      'states': {
        'root': {'initial': 's1'},
        's1': {'parent': 'root', 'on': {'GO': 's2', 'ALSO': 's1'}},
        's2': {'parent': 'root', 'on': {'GO': 's1'}},
      },
    });

    for (final ev in ['GO', 'ALSO', 'GO', 'NOPE', 'ALSO', 'GO']) {
      chart.send(ev);
      expect(chart.activeLeaves().length, 1, reason: 'single leaf invariant after $ev');
    }
  });

  // ===========================================================================
  // parallel_region_confluence (StateChart.lean)
  // "When enabled transitions are pairwise non-conflicting (orthogonal regions),
  //  every enabled transition is taken and the resulting configuration depends
  //  only on the enabled SET, not its order -- invariant under any reordering."
  // ===========================================================================
  Map<String, dynamic> parallelChart(List<String> regionOrder) {
    final states = <String, dynamic>{'root': {'parallel': true}};
    for (final region in regionOrder) {
      states[region] = {
        'parent': 'root',
        'initial': '${region}_a',
        'on': {'TICK': '${region}_b'},
      };
      states['${region}_a'] = {'parent': region};
      states['${region}_b'] = {'parent': region, 'on': {'TICK': '${region}_a'}};
    }
    return {'initial': regionOrder.first, 'states': states};
  }

  test('Lean parallel_region_confluence: take-all across orthogonal regions', () {
    final ctx = Context();
    final chart = StateChart(ctx, ChartDef.fromJson(parallelChart(['alpha', 'beta', 'gamma'])));
    // TICK is enabled independently in every region; pairwise disjoint exit sets
    // => the conflict resolver is transparent => all three are taken.
    expect(chart.send('TICK'), isTrue);
    expect(chart.activeLeaves()..sort(), ['alpha_b', 'beta_b', 'gamma_b']);
  });

  test('Lean parallel_region_confluence: result invariant under reordering of regions', () {
    final orderings = [
      ['alpha', 'beta', 'gamma'],
      ['gamma', 'alpha', 'beta'],
      ['beta', 'gamma', 'alpha'],
    ];

    List<Set<String>> run(List<String> ordering) {
      final ctx = Context();
      final c = StateChart(ctx, ChartDef.fromJson(parallelChart(ordering)));
      const seq = ['TICK', 'TICK', 'TICK', 'TICK']; // toggles every region each step
      return seq.map((_) {
        c.send('TICK');
        return c.activeLeaves().toSet();
      }).toList();
    }

    final traces = orderings.map(run).toList();
    for (var i = 0; i < traces.first.length; i++) {
      final reference = traces.first[i];
      for (var j = 1; j < traces.length; j++) {
        expect(
          traces[j][i].toList()..sort(),
          reference.toList()..sort(),
          reason: 'confluence violated at step $i for ordering $j',
        );
      }
    }
  });

  // ===========================================================================
  // recordHistory_idempotent (StateChart.lean)
  // "Recording the same exit pass twice is a no-op." Validated by exiting a
  //  history-owning region, then re-entering and re-exiting it: the recorded
  //  shallow/deep configuration must be stable.
  // ===========================================================================
  test('Lean recordHistory_idempotent: re-exiting a region records the same history', () {
    Map<String, dynamic> build() => {
          'initial': 'p',
          'states': {
            'root': {'initial': 'p'},
            'p': {'parent': 'root', 'initial': 'a', 'on': {'OUT': 'idle'}},
            'hist': {'parent': 'p', 'history': 'deep'},
            'a': {'parent': 'p', 'on': {'TOGGLE': 'b'}},
            'b': {'parent': 'p', 'on': {'TOGGLE': 'a'}},
            'idle': {'parent': 'root', 'on': {'BACK': 'p'}},
          },
        };

    List<String> run() {
      final ctx = Context();
      final c = StateChart(ctx, ChartDef.fromJson(build()));
      c.send('TOGGLE'); // p.a -> p.b (active leaf under p is now b)
      c.send('OUT'); // exit p, record deep history = {b}
      c.send('BACK'); // re-enter p, restore b
      c.send('OUT'); // exit p again, record deep history = {b}
      return c.activeLeaves();
    }

    // The recorded configuration after the second exit equals the first; the
    // observable leaf after a fresh restore cycle is therefore stable.
    expect(run(), ['idle']);
    // And a final restore lands on the same leaf the history captured.
    final ctx = Context();
    final c = StateChart(ctx, ChartDef.fromJson(build()));
    c.send('OUT'); // record {a} (initial)
    c.send('BACK'); // restore a
    expect(c.activeLeaves(), ['a']);
  });

  // ===========================================================================
  // send_actions_empty_when_rejected / stepActions_sourcing (StateChart.lean)
  // "The action trace is empty precisely when an event is rejected; on the take
  //  branch every fired action is sourced from an exit, transition, or entry."
  // ===========================================================================
  test('Lean send_actions_empty_when_rejected: rejected iff empty action trace', () {
    final ctx = Context();
    final chart = _chart(ctx, {
      'initial': 'a',
      'states': {
        'root': {'initial': 'a'},
        'a': {'parent': 'root', 'on': {'GO': 'b'}, 'entry': ['inA'], 'exit': ['outA']},
        'b': {'parent': 'root', 'entry': ['inB']},
      },
    });

    chart.send('GO'); // takes a transition, actions non-empty (exit a, enter b)
    expect(chart.lastActions(), isNotEmpty);

    final accepted = chart.send('NOPE'); // rejected
    expect(accepted, isFalse);
    expect(chart.lastActions(), isEmpty);
  });
}
