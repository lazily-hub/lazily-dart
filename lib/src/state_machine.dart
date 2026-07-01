import 'core.dart';

/// A finite state machine backed by a reactive [Cell].
///
/// The state lives in a [Cell], so any [Slot], [Signal], or subscriber that
/// reads [state] is automatically invalidated when the machine transitions.
///
/// The transition function is pure: `S? Function(S state, E event)`. Returning
/// `null` rejects the event (a guard); returning a value accepts the event and
/// sets the cell to the new state. A self-transition that returns an equal
/// state is accepted but suppressed by the [Cell]'s `!=` guard, so no
/// downstream cascade fires.
///
/// Example::
///
///     final ctx = Context();
///     final m = StateMachine<String, String>(ctx, 'Red', (s, e) =>
///         e == 'advance'
///             ? const {'Red': 'Green', 'Green': 'Yellow', 'Yellow': 'Red'}[s]
///             : null);
///     m.send('advance'); // true
///     m.state;           // 'Green'
class StateMachine<S, E> {
  /// Creates a machine bound to [ctx] with [initial] state and [transition].
  StateMachine(this.ctx, S initial, S? Function(S state, E event) transition)
      : _transition = transition,
        _cell = Cell<S>(ctx, initial);

  final Context ctx;
  final Cell<S> _cell;
  final S? Function(S state, E event) _transition;

  /// The current state. Reading inside a computation subscribes the reader.
  S get state => _cell.value;

  /// The underlying [Cell] holding the state value.
  Cell<S> get cell => _cell;

  /// Send an event to the machine.
  ///
  /// Returns `true` if the transition function accepted the event (returned a
  /// value), `false` if it was rejected (returned `null`). A self-transition
  /// that returns an equal state returns `true` but does not invalidate
  /// dependents (the `!=` guard on the cell).
  bool send(E event) {
    final next = _transition(_cell.peek ?? _cell.value, event);
    if (next != null) {
      _cell.value = next;
      return true;
    }
    return false;
  }

  /// Register a handler fired with `(old, new)` on a transition to a
  /// different state. Not called on registration. Returns a disposer; call it
  /// to stop observing.
  void Function() onTransition(void Function(S oldState, S newState) handler) {
    var prev = _cell.value;
    return _cell.subscribe((value) {
      if (value != prev) {
        handler(prev, value);
      }
      prev = value;
    });
  }

  @override
  String toString() => 'StateMachine($_cell)';
}
