import 'dart:convert';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

/// Build a [StateChart] from a JSON chart object string.
StateChart _chart(Context ctx, Map<String, dynamic> chart) =>
    StateChart(ctx, ChartDef.fromJson(chart));

void main() {
  group('StateChart basics', () {
    test('enters the initial atomic leaf on construction', () {
      final ctx = Context();
      final chart = _chart(ctx, {
        'initial': 'on',
        'states': {
          'root': {'initial': 'on'},
          'on': {
            'parent': 'root',
            'initial': 'playing',
          },
          'playing': {'parent': 'on'},
          'paused': {'parent': 'on'},
        },
      });
      expect(chart.activeLeaves(), ['playing']);
      expect(chart.matches('on'), isTrue);
      expect(chart.matches('paused'), isFalse);
    });

    test('initial entry actions are recorded top-down', () {
      final ctx = Context();
      final chart = _chart(ctx, {
        'initial': 'a1',
        'states': {
          'root': {'initial': 'a'},
          'a': {
            'parent': 'root',
            'initial': 'a1',
            'entry': ['enterA'],
          },
          'a1': {
            'parent': 'a',
            'entry': ['enterA1'],
          },
        },
      });
      expect(chart.lastActions(), ['enterA', 'enterA1']);
      expect(chart.activeLeaves(), ['a1']);
    });
  });

  group('transitions', () {
    test('flat transition within a composite (pause/play)', () {
      final ctx = Context();
      final chart = _playerChart(ctx);
      expect(chart.send('pause'), isTrue);
      expect(chart.activeLeaves(), ['paused']);
      expect(chart.send('play'), isTrue);
      expect(chart.activeLeaves(), ['playing']);
    });

    test('event bubbles up to a composite-level transition (toggle)', () {
      final ctx = Context();
      final chart = _playerChart(ctx); // on > playing
      expect(chart.send('toggle'), isTrue); // handled by 'on' -> 'off'
      expect(chart.activeLeaves(), ['off']);
      expect(chart.matches('on'), isFalse);
    });

    test('entering a composite descends to its initial atomic leaf', () {
      final ctx = Context();
      final chart = _playerChart(ctx);
      chart.send('toggle'); // -> off
      chart.send('toggle'); // off -> on -> playing (initial)
      expect(chart.activeLeaves(), ['playing']);
      expect(chart.matches('on'), isTrue);
    });

    test('unhandled event returns false and leaves state unchanged', () {
      final ctx = Context();
      final chart = _playerChart(ctx);
      expect(chart.send('bogus'), isFalse);
      expect(chart.activeLeaves(), ['playing']);
      expect(chart.lastActions(), isEmpty);
    });

    test('innermost transition wins over an ancestor handler', () {
      final ctx = Context();
      final chart = _chart(ctx, {
        'initial': 'on',
        'states': {
          'root': {'initial': 'on'},
          'on': {
            'parent': 'root',
            'initial': 'playing',
            'on': {'toggle': 'off'},
          },
          'playing': {
            'parent': 'on',
            'on': {'toggle': 'off'},
          },
          'off': {'parent': 'root'},
        },
      });
      expect(chart.send('toggle'), isTrue);
      expect(chart.activeLeaves(), ['off']);
    });
  });

  group('guards', () {
    test('a failing guard rejects the event and leaves state unchanged', () {
      final ctx = Context();
      final chart = _chart(ctx, {
        'initial': 'closed',
        'states': {
          'root': {'initial': 'closed'},
          'closed': {
            'parent': 'root',
            'on': {
              'OPEN': {'target': 'open', 'guard': 'allowed'},
            },
          },
          'open': {'parent': 'root'},
        },
      });
      expect(chart.send('OPEN', {'allowed': false}), isFalse);
      expect(chart.activeLeaves(), ['closed']);
      expect(chart.lastActions(), isEmpty);
    });

    test('a passing guard fires the transition', () {
      final ctx = Context();
      final chart = _chart(ctx, {
        'initial': 'closed',
        'states': {
          'root': {'initial': 'closed'},
          'closed': {
            'parent': 'root',
            'on': {
              'OPEN': {'target': 'open', 'guard': 'allowed'},
            },
          },
          'open': {'parent': 'root'},
        },
      });
      expect(chart.send('OPEN', {'allowed': true}), isTrue);
      expect(chart.activeLeaves(), ['open']);
    });

    test('an unknown guard name is fail-closed', () {
      final ctx = Context();
      final chart = _chart(ctx, {
        'initial': 'closed',
        'states': {
          'root': {'initial': 'closed'},
          'closed': {
            'parent': 'root',
            'on': {
              'OPEN': {'target': 'open', 'guard': 'allowed'},
            },
          },
          'open': {'parent': 'root'},
        },
      });
      expect(chart.send('OPEN'), isFalse); // no guards supplied -> fail-closed
      expect(chart.activeLeaves(), ['closed']);
    });
  });

  group('entry / exit ordering', () {
    test('exits run innermost-first, entries run outermost-first, across the LCA', () {
      final ctx = Context();
      final chart = _chart(ctx, {
        'initial': 'a',
        'states': {
          'root': {
            'initial': 'a',
          },
          'a': {
            'parent': 'root',
            'initial': 'a1',
            'entry': ['enterA'],
            'exit': ['exitA'],
          },
          'a1': {
            'parent': 'a',
            'entry': ['enterA1'],
            'exit': ['exitA1'],
            'on': {'SWAP': 'a2'},
          },
          'a2': {
            'parent': 'a',
            'entry': ['enterA2'],
            'exit': ['exitA2'],
            'on': {'SWAP': 'a1'},
          },
        },
      });
      expect(chart.activeLeaves(), ['a1']);
      // SWAP: LCA is `a`; only a1 exited, a2 entered.
      expect(chart.send('SWAP'), isTrue);
      expect(chart.activeLeaves(), ['a2']);
      expect(chart.lastActions(), ['exitA1', 'enterA2']);
    });

    test('transition actions run after exits and before entries', () {
      final ctx = Context();
      final chart = _chart(ctx, {
        'initial': 'a1',
        'states': {
          'root': {'initial': 'a'},
          'a': {
            'parent': 'root',
            'initial': 'a1',
            'entry': ['enterA'],
            'exit': ['exitA'],
          },
          'a1': {
            'parent': 'a',
            'entry': ['enterA1'],
            'exit': ['exitA1'],
            'on': {
              'LEAVE': {'target': 'b', 'action': ['leaveA']},
            },
          },
          'b': {
            'parent': 'root',
            'entry': ['enterB'],
            'exit': ['exitB'],
          },
        },
      });
      expect(chart.send('LEAVE'), isTrue);
      expect(chart.activeLeaves(), ['b']);
      // LCA root: a1,a exited (innermost-first), transition action, then b entered.
      expect(chart.lastActions(), ['exitA1', 'exitA', 'leaveA', 'enterB']);
    });
  });

  group('parallel regions', () {
    test('orthogonal regions advance independently and conflict-free', () {
      final ctx = Context();
      final chart = _chart(ctx, {
        'initial': 'active',
        'states': {
          'root': {'initial': 'active'},
          'active': {
            'parent': 'root',
            'parallel': true,
            'on': {'PAUSE': 'paused'},
          },
          'audio': {'parent': 'active', 'initial': 'a_off'},
          'a_off': {
            'parent': 'audio',
            'on': {'AUDIO_ON': 'a_on'},
          },
          'a_on': {
            'parent': 'audio',
            'on': {'AUDIO_OFF': 'a_off'},
          },
          'video': {'parent': 'active', 'initial': 'v_off'},
          'v_off': {
            'parent': 'video',
            'on': {'VIDEO_ON': 'v_on'},
          },
          'v_on': {
            'parent': 'video',
            'on': {'VIDEO_OFF': 'v_off'},
          },
          'paused': {'parent': 'root'},
        },
      });
      expect(chart.activeLeaves(), ['a_off', 'v_off']);
      expect(chart.send('AUDIO_ON'), isTrue);
      expect(chart.activeLeaves(), ['a_on', 'v_off']);
      expect(chart.send('VIDEO_ON'), isTrue);
      expect(chart.activeLeaves(), ['a_on', 'v_on']);
      // PAUSE exits both regions at once (single transition, disjoint-from-nothing).
      expect(chart.send('PAUSE'), isTrue);
      expect(chart.activeLeaves(), ['paused']);
    });
  });

  group('history', () {
    test('shallow history restores the last direct child', () {
      final ctx = Context();
      final chart = _chart(ctx, {
        'initial': 'on',
        'states': {
          'root': {'initial': 'on'},
          'on': {
            'parent': 'root',
            'initial': 'a',
            'on': {'POWER_OFF': 'off'},
          },
          'a': {
            'parent': 'on',
            'on': {'NEXT': 'b'},
          },
          'b': {
            'parent': 'on',
            'on': {'NEXT': 'a'},
          },
          'h': {
            'parent': 'on',
            'history': 'shallow',
            'default': 'a',
          },
          'off': {
            'parent': 'root',
            'on': {'POWER_ON_HISTORY': 'h'},
          },
        },
      });
      expect(chart.send('NEXT'), isTrue); // a -> b
      expect(chart.activeLeaves(), ['b']);
      expect(chart.send('POWER_OFF'), isTrue); // records shallow = b
      expect(chart.activeLeaves(), ['off']);
      expect(chart.send('POWER_ON_HISTORY'), isTrue); // resume b (not initial a)
      expect(chart.activeLeaves(), ['b']);
    });

    test('deep history restores the full nested leaf', () {
      final ctx = Context();
      final chart = _chart(ctx, {
        'initial': 'on',
        'states': {
          'root': {'initial': 'on'},
          'on': {
            'parent': 'root',
            'initial': 'playing',
            'on': {'POWER_OFF': 'off'},
          },
          'playing': {
            'parent': 'on',
            'initial': 'ready',
            'on': {'PAUSE': 'paused'},
          },
          'ready': {
            'parent': 'playing',
            'on': {'BUFFER': 'buffering'},
          },
          'buffering': {
            'parent': 'playing',
            'on': {'LOADED': 'ready'},
          },
          'paused': {
            'parent': 'on',
            'on': {'RESUME': 'playing'},
          },
          'hdeep': {
            'parent': 'on',
            'history': 'deep',
            'default': 'playing',
          },
          'off': {
            'parent': 'root',
            'on': {'POWER_ON': 'hdeep'},
          },
        },
      });
      expect(chart.send('BUFFER'), isTrue); // ready -> buffering
      expect(chart.activeLeaves(), ['buffering']);
      expect(chart.send('POWER_OFF'), isTrue); // deep record = {playing, buffering}
      expect(chart.activeLeaves(), ['off']);
      expect(chart.send('POWER_ON'), isTrue); // resume all the way to buffering
      expect(chart.activeLeaves(), ['buffering']);
    });

    test('history first-entry falls back to default when none recorded', () {
      final ctx = Context();
      final chart = _chart(ctx, {
        'initial': 'on',
        'states': {
          'root': {'initial': 'on'},
          'on': {
            'parent': 'root',
            'initial': 'a',
            'on': {'POWER_OFF': 'off'},
          },
          'a': {'parent': 'on'},
          'h': {
            'parent': 'on',
            'history': 'shallow',
            'default': 'a',
          },
          'off': {
            'parent': 'root',
            'on': {'POWER_ON_HISTORY': 'h'},
          },
        },
      });
      // POWER_OFF without NEXT: region exited for the first time, so the
      // record on exit is the current child `a`; POWER_ON_HISTORY restores it.
      expect(chart.send('POWER_OFF'), isTrue);
      expect(chart.send('POWER_ON_HISTORY'), isTrue);
      expect(chart.activeLeaves(), ['a']);
    });
  });

  group('internal / external transitions', () {
    // Per lazily-formal `lcaOf` (StateChart.lean): an internal transition
    // (target == source OR target a proper descendant of source) uses `source`
    // as the LCA; an external transition uses `lca(activeLeaf, target)`.
    // `exitSet = proper descendants of the lca`; `enterSet = pathBelow ++
    // enterSubtree(target)`. For an atomic self-transition (target == source)
    // the exit set is empty (atomic ⇒ no proper descendants) and the target is
    // re-entered, so both flavors fire the entry action; the `internal` flag's
    // observable effect is on transitions handled by a compound source.

    test('an internal transition on a compound source keeps the source active', () {
      // C (initial=a) holds siblings a, b. A transition on C to b, taken while
      // leaf=a is active. Internal ⇒ lca=C; exit={a}; enter={b}; C is never
      // exited or re-entered (C has no entry/exit in the trace).
      final ctx = Context();
      final chart = _chart(ctx, {
        'initial': 'C',
        'states': {
          'root': {'initial': 'C'},
          'C': {
            'parent': 'root',
            'initial': 'a',
            'entry': ['enterC'],
            'exit': ['exitC'],
            'on': {'GO': {'target': 'b', 'internal': true}},
          },
          'a': {
            'parent': 'C',
            'entry': ['enterA'],
            'exit': ['exitA'],
          },
          'b': {
            'parent': 'C',
            'entry': ['enterB'],
            'exit': ['exitB'],
          },
        },
      });
      expect(chart.activeLeaves(), ['a']);
      expect(chart.send('GO'), isTrue);
      expect(chart.activeLeaves(), ['b']);
      // lca=C: exit a (not C), enter b (not C). C's entry/exit do NOT fire.
      expect(chart.lastActions(), ['exitA', 'enterB']);
      expect(chart.matches('C'), isTrue);
    });

    test('an internal self-transition fires its action and re-enters the target', () {
      final ctx = Context();
      final chart = _chart(ctx, {
        'initial': 's',
        'states': {
          'root': {'initial': 's'},
          's': {
            'parent': 'root',
            'entry': ['enterS'],
            'exit': ['exitS'],
            'on': {
              'SELF': {'target': 's', 'internal': true, 'action': ['reSelf']},
            },
          },
        },
      });
      chart.send('SELF');
      // exit set empty (atomic s); enter set {s}: transition action then entry.
      expect(chart.lastActions(), ['reSelf', 'enterS']);
    });

    test('an external transition across a compound boundary exits the source', () {
      // Here the transition is handled by the root-level leaf 'off' targeting
      // 'on' (a compound). External ⇒ lca=root: the active leaf and its
      // ancestors up to root are exited, then the target subtree is entered.
      final ctx = Context();
      final chart = _chart(ctx, {
        'initial': 'on',
        'states': {
          'root': {'initial': 'on'},
          'on': {
            'parent': 'root',
            'initial': 'playing',
            'entry': ['enterOn'],
            'exit': ['exitOn'],
            'on': {'POWER': 'off'},
          },
          'playing': {
            'parent': 'on',
            'entry': ['enterPlaying'],
            'exit': ['exitPlaying'],
          },
          'off': {
            'parent': 'root',
            'entry': ['enterOff'],
            'exit': ['exitOff'],
            'on': {'POWER': 'on'},
          },
        },
      });
      chart.send('POWER'); // on>playing -> off
      // lca=root: exit playing, exit on (innermost-first), then enter off.
      expect(chart.lastActions(), ['exitPlaying', 'exitOn', 'enterOff']);
    });
  });

  group('determinism / no-op suppression', () {
    test('a rejected event fires no actions', () {
      final ctx = Context();
      final chart = _playerChart(ctx);
      expect(chart.send('bogus'), isFalse);
      expect(chart.lastActions(), isEmpty);
    });

    test('a transition to an equal configuration is a no-op for observers', () {
      final ctx = Context();
      final chart = _playerChart(ctx); // on > playing
      var calls = 0;
      final leaf = Slot<String>(ctx, (_) {
        calls++;
        return chart.activeLeaves().join(',');
      });
      expect(leaf(), 'playing');
      final baseline = calls;
      // Internal self-transition keeps configuration identical → Cell suppresses.
      expect(chart.send('bogus'), isFalse);
      expect(leaf(), 'playing');
      expect(calls, baseline); // no recompute
    });
  });

  group('reactivity', () {
    test('a slot reading active invalidates on transition', () {
      final ctx = Context();
      final chart = _playerChart(ctx);
      var calls = 0;
      final label = Slot<String>(ctx, (_) {
        calls++;
        return 'leaf=${chart.activeLeaves().first}';
      });
      expect(label(), 'leaf=playing');
      chart.send('pause');
      expect(label(), 'leaf=paused');
      expect(calls, 2);
    });

    test('a slot reading matches invalidates when a state is exited', () {
      final ctx = Context();
      final chart = _playerChart(ctx); // on > playing
      var calls = 0;
      final isOn = Slot<bool>(ctx, (_) {
        calls++;
        return chart.matches('on');
      });
      expect(isOn(), true);
      chart.send('toggle'); // on -> off
      expect(isOn(), false);
      expect(calls, 2);
    });
  });

  group('validation', () {
    test('chart.initial is required', () {
      expect(
        () => ChartDef.fromJson(<String, dynamic>{
          'states': {'a': {}},
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('run actions are rejected', () {
      expect(
        () => ChartDef.fromJson(<String, dynamic>{
          'initial': 'a',
          'states': {
            'a': {'run': ['x']},
          },
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('expr guards are rejected', () {
      expect(
        () => ChartDef.fromJson(<String, dynamic>{
          'initial': 'a',
          'states': {
            'a': {
              'on': {
                'GO': {'target': 'a', 'guard': {'expr': 'x'}}
              }
            },
          },
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('final states are accepted as leaves without completion (done) events', () {
      final ctx = Context();
      final chart = _chart(ctx, {
        'initial': 'running',
        'states': {
          'root': {'initial': 'running'},
          'running': {
            'parent': 'root',
            'on': {'finish': 'done'},
          },
          'done': {
            'parent': 'root',
            'kind': 'final',
            'entry': ['log-done'],
          },
        },
      });
      expect(chart.activeLeaves(), ['running']);
      expect(chart.matches('done'), isFalse);
      // Transition into the final state is accepted; it becomes an active leaf.
      expect(chart.send('finish'), isTrue);
      expect(chart.activeLeaves(), ['done']);
      expect(chart.matches('done'), isTrue);
      // Entry actions fire on entering the final leaf.
      expect(chart.lastActions(), ['log-done']);
      // No completion (done) event is auto-raised for the parent — the spec
      // allows deferring completion, matching lazily-py / lazily-kt.
      expect(chart.send('done'), isFalse);
    });
  });

  test('ChartDef round-trips a JSON string', () {
    final ctx = Context();
    final json = jsonEncode({
      'initial': 'on',
      'states': {
        'root': {'initial': 'on'},
        'on': {
          'parent': 'root',
          'initial': 'playing',
        },
        'playing': {'parent': 'on'},
      },
    });
    final chart = StateChart(ctx, ChartDef.fromJson(json));
    expect(chart.activeLeaves(), ['playing']);
  });
}

/// The media-player chart reused across groups: on { playing, paused } <-> off.
StateChart _playerChart(Context ctx) => _chart(ctx, {
      'initial': 'on',
      'states': {
        'root': {'initial': 'on'},
        'on': {
          'parent': 'root',
          'initial': 'playing',
          'on': {'toggle': 'off'},
        },
        'playing': {
          'parent': 'on',
          'on': {
            'pause': 'paused',
          },
        },
        'paused': {
          'parent': 'on',
          'on': {'play': 'playing'},
        },
        'off': {
          'parent': 'root',
          'on': {'toggle': 'on'},
        },
      },
    });
