import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

void main() {
  group('StateChart basics', () {
    test('enters the initial atomic leaf on construction', () {
      final ctx = Context();
      final chart = playerChart(ctx);
      expect(chart.active, 'playing');
      expect(chart.activePath, ['on', 'playing']);
    });

    test('a composite state is active when a descendant is active', () {
      final ctx = Context();
      final chart = playerChart(ctx);
      expect(chart.isActive('on'), isTrue);
      expect(chart.isActive('playing'), isTrue);
      expect(chart.isActive('paused'), isFalse);
    });
  });

  group('transitions', () {
    test('flat transition within a composite (pause/play)', () {
      final ctx = Context();
      final chart = playerChart(ctx);
      chart.send('pause');
      expect(chart.active, 'paused');
      chart.send('play');
      expect(chart.active, 'playing');
    });

    test('event bubbles up to a composite-level transition (toggle)', () {
      final ctx = Context();
      final chart = playerChart(ctx); // on > playing
      chart.send('toggle'); // handled by 'on' -> 'off'
      expect(chart.active, 'off');
      expect(chart.isActive('on'), isFalse);
    });

    test('entering a composite descends to its initial atomic leaf', () {
      final ctx = Context();
      final chart = playerChart(ctx);
      chart.send('toggle'); // -> off
      chart.send('toggle'); // off -> on -> playing (initial)
      expect(chart.activePath, ['on', 'playing']);
    });

    test('unhandled event returns false and leaves state unchanged', () {
      final ctx = Context();
      final chart = playerChart(ctx);
      expect(chart.send('bogus'), isFalse);
      expect(chart.active, 'playing');
    });

    test('innermost transition wins over an ancestor handler', () {
      // 'playing' defines its own 'toggle'; it must win over 'on' toggle.
      final ctx = Context();
      final chart = StateChart<String, String>(
        ctx: ctx,
        root: 'on',
        states: {
          'on': const ChartState.composite(
              initial: 'playing', children: ['playing']),
          'playing': const ChartState.atomic(),
          'off': const ChartState.atomic(),
        },
        transitions: [
          const ChartTransition(from: 'on', event: 'toggle', to: 'off'),
          const ChartTransition(from: 'playing', event: 'toggle', to: 'off'),
        ],
      );
      // Both would land on 'off'; the point is no exception and a single fire.
      expect(chart.send('toggle'), isTrue);
      expect(chart.active, 'off');
    });
  });

  group('guards and actions', () {
    test('a failing guard disables the transition', () {
      final ctx = Context();
      final chart = playerChart(ctx);
      expect(chart.send('conditional'), isFalse); // guard false
      expect(chart.active, 'playing');
    });

    test('a passing guard fires and runs the transition action', () {
      final ctx = Context();
      var actionRan = false;
      final chart = StateChart<String, String>(
        ctx: ctx,
        root: 'a',
        states: {
          'a': const ChartState.atomic(),
          'b': const ChartState.atomic(),
        },
        transitions: [
          ChartTransition(
            from: 'a',
            event: 'go',
            to: 'b',
            guard: () => true,
            action: () => actionRan = true,
          ),
        ],
      );
      expect(chart.send('go'), isTrue);
      expect(chart.active, 'b');
      expect(actionRan, isTrue);
    });
  });

  group('entry / exit ordering', () {
    test('exits run leaf-first, entries run top-down, across the LCA', () {
      final ctx = Context();
      final log = <String>[];
      final chart = StateChart<String, String>(
        ctx: ctx,
        root: 'root',
        states: {
          'root':
              const ChartState.composite(initial: 'a', children: ['a', 'b']),
          'a': ChartState.atomic(
            onEnter: (_) => log.add('enter a'),
            onExit: (_) => log.add('exit a'),
          ),
          'b': ChartState.atomic(
            onEnter: (_) => log.add('enter b'),
            onExit: (_) => log.add('exit b'),
          ),
        },
        transitions: const [
          ChartTransition(from: 'a', event: 'swap', to: 'b'),
        ],
      );
      // initial entry logged enter a (root has no callbacks)
      expect(log, ['enter a']);
      log.clear();

      chart.send('swap');
      // LCA is 'root'; exit 'a', then enter 'b'.
      expect(log, ['exit a', 'enter b']);
    });

    test(
        're-entering a composite from outside runs entry of the composite and '
        'its initial leaf', () {
      final ctx = Context();
      final log = <String>[];
      final chart = StateChart<String, String>(
        ctx: ctx,
        root: 'on',
        states: {
          'on': ChartState.composite(
            initial: 'playing',
            children: const ['playing', 'paused'],
            onEnter: (_) => log.add('enter on'),
            onExit: (_) => log.add('exit on'),
          ),
          'playing':
              ChartState.atomic(onEnter: (_) => log.add('enter playing')),
          'paused': const ChartState.atomic(),
          'off': const ChartState.atomic(),
        },
        transitions: const [
          ChartTransition(from: 'on', event: 'toggle', to: 'off'),
          ChartTransition(from: 'off', event: 'toggle', to: 'on'),
        ],
      );
      expect(log, ['enter on', 'enter playing']); // construction
      log.clear();

      chart.send('toggle'); // -> off (exit playing, exit on)
      expect(log, ['exit on']);
      log.clear();

      chart.send('toggle'); // off -> on -> playing (initial)
      expect(log, ['enter on', 'enter playing']);
    });
  });

  group('reactivity', () {
    test('a slot reading active invalidates on transition', () {
      final ctx = Context();
      final chart = playerChart(ctx);
      var calls = 0;
      final label = Slot<String>(ctx, (_) {
        calls++;
        return 'state=${chart.active}';
      });
      expect(label(), 'state=playing');
      chart.send('pause');
      expect(label(), 'state=paused');
      expect(calls, 2);
    });

    test('a transition invalidates even when isActive is unchanged', () {
      final ctx = Context();
      final chart = playerChart(ctx); // on > playing
      var calls = 0;
      final isOn = Slot<bool>(ctx, (_) {
        calls++;
        return chart.isActive('on');
      });
      expect(isOn(), true);
      // pause keeps us inside 'on', but the active-path cell changed object,
      // so the dependent slot still recomputes.
      chart.send('pause');
      expect(isOn(), true);
      expect(calls, 2);
    });
  });

  group('validation', () {
    test('rejects a composite whose initial is not a child', () {
      final ctx = Context();
      expect(
        () => StateChart<String, String>(
          ctx: ctx,
          root: 'a',
          states: {
            'a': const ChartState.composite(initial: 'x', children: ['b']),
            'b': const ChartState.atomic(),
          },
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('rejects a cycle', () {
      // 'a' lists 'b' as child; 'b' lists 'a' as child -> cycle.
      final ctx = Context();
      expect(
        () => StateChart<String, String>(
          ctx: ctx,
          root: 'a',
          states: {
            'a': const ChartState.composite(initial: 'b', children: ['b']),
            'b': const ChartState.composite(initial: 'a', children: ['a']),
          },
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}

/// A small media-player chart: on { playing, paused } <-> off.
StateChart<String, String> playerChart(Context ctx) => StateChart(
      ctx: ctx,
      root: 'on',
      states: {
        'on': const ChartState.composite(
            initial: 'playing', children: ['playing', 'paused']),
        'playing': const ChartState.atomic(),
        'paused': const ChartState.atomic(),
        'off': const ChartState.atomic(),
      },
      transitions: [
        const ChartTransition(from: 'playing', event: 'pause', to: 'paused'),
        const ChartTransition(from: 'paused', event: 'play', to: 'playing'),
        const ChartTransition(from: 'on', event: 'toggle', to: 'off'),
        const ChartTransition(from: 'off', event: 'toggle', to: 'on'),
        ChartTransition(
            from: 'playing',
            event: 'conditional',
            to: 'paused',
            guard: () => false),
      ],
    );
