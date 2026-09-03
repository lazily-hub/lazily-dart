/// Graph-independent latest-state durable egress (`#lzlatestdurableprojection`).
library;

enum LatestDurableUpsert {
  accepted('accepted'),
  unchanged('unchanged'),
  alreadyDurable('already_durable'),
  staleEpoch('stale_epoch'),
  epochConflict('epoch_conflict');

  const LatestDurableUpsert(this.wireName);
  final String wireName;
}

enum LatestDurableClaimKind {
  claimed('claimed'),
  empty('empty'),
  busy('busy'),
  staleGeneration('stale_generation');

  const LatestDurableClaimKind(this.wireName);
  final String wireName;
}

enum LatestDurableAckKind {
  advanced('advanced'),
  unchanged('unchanged'),
  unknownEpoch('unknown_epoch'),
  staleGeneration('stale_generation');

  const LatestDurableAckKind(this.wireName);
  final String wireName;
}

enum LatestDurableFailureKind {
  pending('pending'),
  superseded('superseded'),
  unknownEpoch('unknown_epoch'),
  staleGeneration('stale_generation');

  const LatestDurableFailureKind(this.wireName);
  final String wireName;
}

enum LatestDurableReconnectKind {
  advanced('advanced'),
  unchanged('unchanged'),
  staleGeneration('stale_generation');

  const LatestDurableReconnectKind(this.wireName);
  final String wireName;
}

final class LatestDurableDesired<T> {
  const LatestDurableDesired(this.epoch, this.value);
  final int epoch;
  final T value;
}

final class LatestDurableEnvelope<K, T> {
  const LatestDurableEnvelope({
    required this.generation,
    required this.key,
    required this.epoch,
    required this.value,
  });

  final int generation;
  final K key;
  final int epoch;
  final T value;
}

final class LatestDurableEntry<K, T> {
  const LatestDurableEntry({
    required this.key,
    required this.desired,
    required this.inflight,
    required this.durableThrough,
  });

  final K key;
  final LatestDurableDesired<T>? desired;
  final LatestDurableEnvelope<K, T>? inflight;
  final int? durableThrough;
}

final class LatestDurableSnapshot<K, T> {
  const LatestDurableSnapshot({
    required this.generation,
    required this.entries,
  });

  final int generation;
  final List<LatestDurableEntry<K, T>> entries;
}

final class LatestDurableClaim<K, T> {
  const LatestDurableClaim(this.kind, {this.envelope, this.current});
  final LatestDurableClaimKind kind;
  final LatestDurableEnvelope<K, T>? envelope;
  final int? current;
}

final class LatestDurableAck {
  const LatestDurableAck(this.kind, {this.durableThrough, this.current});
  final LatestDurableAckKind kind;
  final int? durableThrough;
  final int? current;
}

final class LatestDurableFailure {
  const LatestDurableFailure(this.kind, {this.current});
  final LatestDurableFailureKind kind;
  final int? current;
}

final class LatestDurableReconnect {
  const LatestDurableReconnect(
    this.kind, {
    this.generation,
    this.current,
    this.requeued,
    this.superseded,
  });

  final LatestDurableReconnectKind kind;
  final int? generation;
  final int? current;
  final int? requeued;
  final int? superseded;
}

final class _EntryState<K, T> {
  LatestDurableDesired<T>? desired;
  LatestDurableEnvelope<K, T>? inflight;
  int? durableThrough;
}

/// Pure keyed authority for latest-value durable delivery.
///
/// Values are treated as immutable. A key has at most one claimed envelope;
/// newer desired epochs conflate only pending state and never acknowledge an
/// older effect. Generation changes fence acknowledgements from stale actors.
final class LatestDurableProjectionCore<K, T> {
  LatestDurableProjectionCore([int generation = 0])
      : _generation = _requireEpoch(generation, 'generation');

  int _generation;
  int _version = 0;
  final Map<K, _EntryState<K, T>> _entries = {};

  int get generation => _generation;
  int get version => _version;

  static int _requireEpoch(int value, String name) {
    if (value < 0) throw RangeError('$name must be non-negative');
    return value;
  }

  _EntryState<K, T>? _entry(K key, [bool create = false]) {
    if (create) return _entries.putIfAbsent(key, _EntryState<K, T>.new);
    return _entries[key];
  }

  LatestDurableEntry<K, T> _snapshotEntry(K key, _EntryState<K, T> entry) =>
      LatestDurableEntry<K, T>(
        key: key,
        desired: entry.desired,
        inflight: entry.inflight,
        durableThrough: entry.durableThrough,
      );

  LatestDurableEntry<K, T>? entry(K key) {
    final state = _entry(key);
    return state == null ? null : _snapshotEntry(key, state);
  }

  LatestDurableSnapshot<K, T> snapshot() => LatestDurableSnapshot<K, T>(
        generation: _generation,
        entries: List.unmodifiable(
          _entries.entries.map((item) => _snapshotEntry(item.key, item.value)),
        ),
      );

  LatestDurableUpsert upsertDesired(K key, int epoch, T value) {
    _requireEpoch(epoch, 'epoch');
    final state = _entry(key, true)!;
    final durable = state.durableThrough;
    if (durable != null && epoch <= durable) {
      return LatestDurableUpsert.alreadyDurable;
    }

    var newestEpoch = -1;
    LatestDurableDesired<T>? newest;
    final desired = state.desired;
    if (desired != null && desired.epoch > newestEpoch) {
      newestEpoch = desired.epoch;
      newest = desired;
    }
    final inflight = state.inflight;
    if (inflight != null && inflight.epoch > newestEpoch) {
      newestEpoch = inflight.epoch;
      newest = LatestDurableDesired<T>(inflight.epoch, inflight.value);
    }
    if (epoch < newestEpoch) return LatestDurableUpsert.staleEpoch;
    if (epoch == newestEpoch) {
      return newest!.value == value
          ? LatestDurableUpsert.unchanged
          : LatestDurableUpsert.epochConflict;
    }

    state.desired = LatestDurableDesired<T>(epoch, value);
    _version++;
    return LatestDurableUpsert.accepted;
  }

  LatestDurableClaim<K, T> claim(K key, int generation) {
    _requireEpoch(generation, 'generation');
    if (generation != _generation) {
      return LatestDurableClaim(
        LatestDurableClaimKind.staleGeneration,
        current: _generation,
      );
    }
    final state = _entry(key);
    if (state == null) {
      return const LatestDurableClaim(LatestDurableClaimKind.empty);
    }
    if (state.inflight != null) {
      return const LatestDurableClaim(LatestDurableClaimKind.busy);
    }
    final desired = state.desired;
    if (desired == null) {
      return const LatestDurableClaim(LatestDurableClaimKind.empty);
    }

    final claimed = LatestDurableEnvelope<K, T>(
      generation: _generation,
      key: key,
      epoch: desired.epoch,
      value: desired.value,
    );
    state
      ..desired = null
      ..inflight = claimed;
    _version++;
    return LatestDurableClaim(LatestDurableClaimKind.claimed,
        envelope: claimed);
  }

  LatestDurableAck ackApplied(K key, int generation, int epoch) {
    _requireEpoch(generation, 'generation');
    _requireEpoch(epoch, 'epoch');
    if (generation != _generation) {
      return LatestDurableAck(
        LatestDurableAckKind.staleGeneration,
        current: _generation,
      );
    }
    final state = _entry(key);
    final inflight = state?.inflight;
    if (state == null || inflight == null || inflight.epoch != epoch) {
      final durable = state?.durableThrough;
      if (durable != null && epoch <= durable) {
        return LatestDurableAck(
          LatestDurableAckKind.unchanged,
          durableThrough: durable,
        );
      }
      return const LatestDurableAck(LatestDurableAckKind.unknownEpoch);
    }

    state.inflight = null;
    final durable = state.durableThrough;
    if (durable == null || epoch > durable) {
      state.durableThrough = epoch;
      _version++;
      return LatestDurableAck(
        LatestDurableAckKind.advanced,
        durableThrough: epoch,
      );
    }
    _version++;
    return LatestDurableAck(
      LatestDurableAckKind.unchanged,
      durableThrough: durable,
    );
  }

  LatestDurableFailure failRetryable(K key, int generation, int epoch) {
    _requireEpoch(generation, 'generation');
    _requireEpoch(epoch, 'epoch');
    if (generation != _generation) {
      return LatestDurableFailure(
        LatestDurableFailureKind.staleGeneration,
        current: _generation,
      );
    }
    final state = _entry(key);
    final inflight = state?.inflight;
    if (state == null || inflight == null || inflight.epoch != epoch) {
      return const LatestDurableFailure(
        LatestDurableFailureKind.unknownEpoch,
      );
    }

    state.inflight = null;
    final desired = state.desired;
    if (desired != null && desired.epoch > inflight.epoch) {
      _version++;
      return const LatestDurableFailure(LatestDurableFailureKind.superseded);
    }
    state.desired = LatestDurableDesired<T>(inflight.epoch, inflight.value);
    _version++;
    return const LatestDurableFailure(LatestDurableFailureKind.pending);
  }

  LatestDurableReconnect reconnect(int newGeneration) {
    _requireEpoch(newGeneration, 'generation');
    if (newGeneration < _generation) {
      return LatestDurableReconnect(
        LatestDurableReconnectKind.staleGeneration,
        current: _generation,
      );
    }
    if (newGeneration == _generation) {
      return LatestDurableReconnect(
        LatestDurableReconnectKind.unchanged,
        generation: _generation,
      );
    }

    var requeued = 0;
    var superseded = 0;
    for (final state in _entries.values) {
      final inflight = state.inflight;
      if (inflight == null) continue;
      final desired = state.desired;
      if (desired != null && desired.epoch > inflight.epoch) {
        superseded++;
      } else {
        state.desired = LatestDurableDesired<T>(
          inflight.epoch,
          inflight.value,
        );
        requeued++;
      }
      state.inflight = null;
    }
    _generation = newGeneration;
    _version++;
    return LatestDurableReconnect(
      LatestDurableReconnectKind.advanced,
      generation: newGeneration,
      requeued: requeued,
      superseded: superseded,
    );
  }
}
