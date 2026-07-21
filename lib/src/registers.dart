/// CRDT register primitives: MV register, PN counter, CellCrdt.
///
/// The LWW register lives in `package:lazily/src/seq_crdt.dart` (`LwwRegister`).
/// This module adds the multi-value register, the positive-negative counter,
/// and the reactive-cell-backed CRDT bridge.
///
/// Mirrors `lazily-rs/src/registers.rs`. Conforms to `lazily-spec`
/// `protocol.md § Distributed` + `cell-model.md`.
library;

import 'core.dart';
import 'seq_crdt.dart';

/// A multi-value register. Concurrent writes surface as a set of values;
/// a write that observes a prior value collapses back to a singleton.
class MvRegister<V> {
  MvRegister();

  final Set<HlcStamp> _stamps = {};
  final List<V> _values = [];

  /// The current visible values (concurrent writes = multiple; causal write = one).
  List<V> get values => List.unmodifiable(_values);

  /// Write a new value with [stamp]. If [observedStamps] covers all current
  /// stamps, the register collapses to a singleton.
  void write(V value, HlcStamp stamp, [Set<HlcStamp>? observedStamps]) {
    if (observedStamps != null && observedStamps.containsAll(_stamps)) {
      _stamps.clear();
      _values.clear();
    } else if (_stamps.isNotEmpty) {
      // Keep only values whose stamps are NOT observed (concurrent).
      final concurrent = <int>[];
      for (var i = 0; i < _stamps.length; i++) {
        if (observedStamps == null || !observedStamps.contains(_stamps.elementAt(i))) {
          concurrent.add(i);
        }
      }
      // If this write observes everything, collapse.
      if (concurrent.isEmpty) {
        _stamps.clear();
        _values.clear();
      }
    }
    _stamps.add(stamp);
    _values.add(value);
  }

  /// Merge from another MV register.
  void merge(MvRegister<V> other) {
    for (var i = 0; i < other._stamps.length; i++) {
      final stamp = other._stamps.elementAt(i);
      if (!_stamps.contains(stamp)) {
        _stamps.add(stamp);
        _values.add(other._values[i]);
      }
    }
  }

  /// The stamps observed by this register.
  Set<HlcStamp> get observedStamps => Set.unmodifiable(_stamps);

  MvRegister<V> copy() {
    final c = MvRegister<V>();
    c._stamps.addAll(_stamps);
    c._values.addAll(_values);
    return c;
  }
}

/// A positive-negative counter (state-based CvRDT).
class PnCounter {
  PnCounter(this._peer);
  final int _peer;
  final Map<int, int> _positive = {};
  final Map<int, int> _negative = {};

  int get peer => _peer;

  /// Increment the positive counter for [_peer] by [amount] (default 1).
  void increment([int amount = 1]) {
    _positive[_peer] = (_positive[_peer] ?? 0) + amount;
  }

  /// Increment the negative counter for [_peer] by [amount] (default 1).
  void decrement([int amount = 1]) {
    _negative[_peer] = (_negative[_peer] ?? 0) + amount;
  }

  /// The current value.
  int get value {
    var sum = 0;
    for (final v in _positive.values) {
      sum += v;
    }
    for (final v in _negative.values) {
      sum -= v;
    }
    return sum;
  }

  /// Merge from another PN counter (component-wise max).
  void merge(PnCounter other) {
    for (final entry in other._positive.entries) {
      _positive[entry.key] = (_positive[entry.key] ?? 0) > entry.value
          ? _positive[entry.key]!
          : entry.value;
    }
    for (final entry in other._negative.entries) {
      _negative[entry.key] = (_negative[entry.key] ?? 0) > entry.value
          ? _negative[entry.key]!
          : entry.value;
    }
  }

  Map<String, dynamic> toWire() => {
        'positive': _positive.map((k, v) => MapEntry(k.toString(), v)),
        'negative': _negative.map((k, v) => MapEntry(k.toString(), v)),
      };

  PnCounter copy() {
    final c = PnCounter(_peer);
    c._positive.addAll(_positive);
    c._negative.addAll(_negative);
    return c;
  }
}

/// A reactive cell whose value is resolved by merging concurrent writes from
/// multiple writers. Backed by a [Cell] and a merge function.
///
/// This is the "CellCrdt" — a single-writer/multi-write cell whose value is
/// the result of merging all observed writes. The merge function is pluggable
/// (LWW, MV, or custom).
class CellCrdt<T> {
  CellCrdt(this.ctx, T initial, this._merge)
      : _cell = Source<T>(ctx, initial);

  final Context ctx;
  final Source<T> _cell;
  final T Function(T current, T incoming) _merge;

  /// The current merged value (reactive read).
  T get value => _cell.value;

  /// Merge an incoming write into the current value.
  void write(T incoming) {
    _cell.value = _merge(_cell.peek, incoming);
  }

  /// The underlying cell.
  Source<T> get cell => _cell;
}
