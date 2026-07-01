# lazily (Dart)

Lazy reactive primitives for Dart — **Slots, Cells, and Signals** with automatic
dependency tracking and cache invalidation. Pure Dart: Flutter, web, and native.

A port of the lazily reactive family ([`lazily-rs`][rs], [`lazily-py`][py],
[`lazily-js`][js], [`lazily-zig`][zig]).

## The reactive family

- **Slot** — a lazily-computed cached value that automatically tracks its
  dependencies and recomputes only when read after an upstream change.
- **Cell** — a mutable source value that invalidates dependent Slots/Signals
  when it changes.
- **Signal** — an *eager* derived value that recomputes the instant a dependency
  changes, with no intermediate unset value.

Values are **lazy by default**. When you need eager push-style semantics, reach
for `Signal`.

## Usage

```dart
import 'package:lazily/lazily.dart';

final ctx = Context();
final a = Cell<int>(ctx, 2);
final b = Cell<int>(ctx, 3);

// Lazy: computes on first read, caches, recomputes only when a or b changes.
final sum = Slot<int>(ctx, (_) => a.value + b.value);
print(sum()); // 5

a.value = 10;
print(sum()); // 13

// Eager: recomputes immediately when a dependency changes.
final parity = Signal<String>(ctx, (_) => a.value.isEven ? 'even' : 'odd');
print(parity.value); // even
a.value = 11;
print(parity.value); // odd (already updated before the read)
```

A [Cell] also supports persistent observers (the hook for Flutter
`ValueNotifier` bridges and `setState` wrappers):

```dart
final count = Cell<int>(ctx, 0);
final dispose = count.subscribe((v) => print('now $v'));
count.value = 1; // prints "now 1"
dispose();
```

## Context

All reactives that react to each other must share a `Context`. The context
holds an identity-keyed cache and the computation stack used for automatic
dependency tracking. One context per reactive graph is the contract.

## State machine

`StateMachine` is a finite state machine backed by a `Cell`, so any slot or
signal that reads `state` is invalidated on transition:

```dart
final m = StateMachine<String, String>(
  ctx, 'Red',
  (s, e) => e == 'advance'
      ? const {'Red': 'Green', 'Green': 'Yellow', 'Yellow': 'Red'}[s]
      : null,
);
m.send('advance'); // true -> 'Green'
```

## State chart

`StateChart` is a Harel-style **hierarchical** state machine: composite
states contain children, events bubble up from the active leaf to the root
(innermost handler wins), and entering/exiting is resolved through the lowest
common ancestor. It is backed by a `Cell`, so any slot or signal reading
`active` or `isActive` invalidates on transition.

```dart
final chart = StateChart<String, String>(
  ctx: ctx,
  root: 'on',
  states: {
    'on': const ChartState.composite(initial: 'playing', children: ['playing', 'paused']),
    'playing': const ChartState.atomic(),
    'paused': const ChartState.atomic(),
    'off': const ChartState.atomic(),
  },
  transitions: [
    ChartTransition(from: 'playing', event: 'pause', to: 'paused'),
    ChartTransition(from: 'on', event: 'toggle', to: 'off'),   // bubbles from a child
    ChartTransition(from: 'off', event: 'toggle', to: 'on'),   // re-enters -> 'playing'
  ],
);
chart.send('toggle'); // off -> on -> playing (initial)
chart.isActive('on'); // true
```

Entry/exit actions, guards, and transition actions are supported. Orthogonal
(parallel) regions and history states are not yet implemented.

## lazily-spec IPC

The `package:lazily/ipc.dart` library implements the language-agnostic
lazily-spec wire protocol (`Snapshot`, `Delta`, `NodeState`, ...) so a Dart
graph's state can be mirrored to remote observers across processes and
languages. It round-trips the canonical fixtures from
[`lazily-spec`][spec]/`conformance/`.

## Status

Early. The reactive core and the lazily-spec IPC wire types are in place.
Distributed sync, CRDTs, shared-memory blobs, and WebRTC transports are not
ported yet (see `lazily-rs` for the full feature set).

## Development

```bash
dart pub get
dart analyze --fatal-infos
dart test
```

## See also

- [`lazily-spec`][spec] — language-agnostic wire protocol + conformance fixtures shared by every binding
- [`lazily-lean`][formal] — Lean 4 formal model (IPC Snapshot/Delta, CRDT, state-machine invariants)

[rs]: https://github.com/lazily-hub/lazily-rs
[py]: https://github.com/lazily-hub/lazily-py
[js]: https://github.com/lazily-hub/lazily-js
[zig]: https://github.com/lazily-hub/lazily-zig
[spec]: https://github.com/lazily-hub/lazily-spec
[formal]: https://github.com/lazily-hub/lazily-spec/tree/main/formal/lean
