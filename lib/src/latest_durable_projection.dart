/// Reactive shells for [LatestDurableProjectionCore].
library;

import 'async_context.dart';
import 'core.dart';
import 'latest_durable_projection_core.dart';
import 'thread_safe.dart';

/// Single-isolate reactive latest-durable projection.
final class LatestDurableProjection<K, T> {
  LatestDurableProjection(this.ctx, [int generation = 0])
      : _core = LatestDurableProjectionCore<K, T>(generation) {
    _generation = Slot<int>(ctx, (_) => _core.generation);
    _snapshot = Slot<LatestDurableSnapshot<K, T>>(
      ctx,
      (_) => _core.snapshot(),
    );
  }

  final Context ctx;
  final LatestDurableProjectionCore<K, T> _core;
  final Map<K, Slot<LatestDurableEntry<K, T>?>> _entries = {};
  late final Slot<int> _generation;
  late final Slot<LatestDurableSnapshot<K, T>> _snapshot;

  Slot<LatestDurableEntry<K, T>?> entryHandle(K key) => _entries.putIfAbsent(
        key,
        () => Slot<LatestDurableEntry<K, T>?>(ctx, (_) => _core.entry(key)),
      );

  Slot<int> get generationHandle => _generation;
  Slot<LatestDurableSnapshot<K, T>> get snapshotHandle => _snapshot;

  LatestDurableEntry<K, T>? entry(K key, [Compute? cx]) {
    final handle = entryHandle(key);
    return cx == null ? handle() : cx.get(handle);
  }

  int generation([Compute? cx]) =>
      cx == null ? _generation() : cx.get(_generation);

  LatestDurableSnapshot<K, T> snapshot([Compute? cx]) =>
      cx == null ? _snapshot() : cx.get(_snapshot);

  R _transitionKey<R>(K key, R Function() operation) {
    final before = _core.version;
    final result = operation();
    if (_core.version == before) return result;
    final roots = <Slot>[_snapshot];
    final entry = _entries[key];
    if (entry != null) roots.add(entry);
    ctx.invalidateSlots(roots);
    return result;
  }

  R _transitionAll<R>(R Function() operation) {
    final before = _core.version;
    final result = operation();
    if (_core.version == before) return result;
    ctx.invalidateSlots(<Slot>[_snapshot, _generation, ..._entries.values]);
    return result;
  }

  LatestDurableUpsert upsertDesired(K key, int epoch, T value) =>
      _transitionKey(key, () => _core.upsertDesired(key, epoch, value));

  LatestDurableClaim<K, T> claim(K key, int generation) =>
      _transitionKey(key, () => _core.claim(key, generation));

  LatestDurableAck ackApplied(K key, int generation, int epoch) =>
      _transitionKey(
        key,
        () => _core.ackApplied(key, generation, epoch),
      );

  LatestDurableFailure failRetryable(
    K key,
    int generation,
    int epoch,
  ) =>
      _transitionKey(
        key,
        () => _core.failRetryable(key, generation, epoch),
      );

  LatestDurableReconnect reconnect(int newGeneration) => _transitionAll(
        () => _core.reconnect(newGeneration),
      );
}

/// Run-to-completion flavor for Dart's isolate concurrency model.
final class ThreadSafeLatestDurableProjection<K, T> {
  ThreadSafeLatestDurableProjection(this.ctx, [int generation = 0])
      : _inner = ctx.read(
          (raw) => LatestDurableProjection<K, T>(raw, generation),
        );

  final ThreadSafeContext ctx;
  final LatestDurableProjection<K, T> _inner;

  Slot<LatestDurableEntry<K, T>?> entryHandle(K key) =>
      ctx.read((_) => _inner.entryHandle(key));
  Slot<int> get generationHandle => _inner.generationHandle;
  Slot<LatestDurableSnapshot<K, T>> get snapshotHandle => _inner.snapshotHandle;

  LatestDurableEntry<K, T>? entry(K key, [Compute? cx]) =>
      ctx.read((_) => _inner.entry(key, cx));
  int generation([Compute? cx]) => ctx.read((_) => _inner.generation(cx));
  LatestDurableSnapshot<K, T> snapshot([Compute? cx]) =>
      ctx.read((_) => _inner.snapshot(cx));

  LatestDurableUpsert upsertDesired(K key, int epoch, T value) =>
      ctx.read((_) => _inner.upsertDesired(key, epoch, value));
  LatestDurableClaim<K, T> claim(K key, int generation) =>
      ctx.read((_) => _inner.claim(key, generation));
  LatestDurableAck ackApplied(K key, int generation, int epoch) =>
      ctx.read((_) => _inner.ackApplied(key, generation, epoch));
  LatestDurableFailure failRetryable(K key, int generation, int epoch) =>
      ctx.read((_) => _inner.failRetryable(key, generation, epoch));
  LatestDurableReconnect reconnect(int newGeneration) =>
      ctx.read((_) => _inner.reconnect(newGeneration));
}

/// Async-graph flavor; transitions remain synchronous and local.
final class AsyncLatestDurableProjection<K, T> {
  AsyncLatestDurableProjection(this.ctx, [int generation = 0])
      : _core = LatestDurableProjectionCore<K, T>(generation) {
    _generation = ctx.computed<int>((_) => _core.generation);
    _snapshot = ctx.computed<LatestDurableSnapshot<K, T>>(
      (_) => _core.snapshot(),
    );
  }

  final AsyncContext ctx;
  final LatestDurableProjectionCore<K, T> _core;
  final Map<K, AsyncSlotHandle<LatestDurableEntry<K, T>?>> _entries = {};
  late final AsyncSlotHandle<int> _generation;
  late final AsyncSlotHandle<LatestDurableSnapshot<K, T>> _snapshot;

  AsyncSlotHandle<LatestDurableEntry<K, T>?> entryHandle(K key) =>
      _entries.putIfAbsent(
        key,
        () => ctx.computed<LatestDurableEntry<K, T>?>(
          (_) => _core.entry(key),
        ),
      );

  AsyncSlotHandle<int> get generationHandle => _generation;
  AsyncSlotHandle<LatestDurableSnapshot<K, T>> get snapshotHandle => _snapshot;

  LatestDurableEntry<K, T>? entry(K key, [AsyncComputeContext? cx]) {
    final handle = entryHandle(key);
    return cx == null ? ctx.get(handle) : cx.get(handle);
  }

  int generation([AsyncComputeContext? cx]) =>
      cx == null ? ctx.get(_generation) : cx.get(_generation);

  LatestDurableSnapshot<K, T> snapshot([AsyncComputeContext? cx]) =>
      cx == null ? ctx.get(_snapshot) : cx.get(_snapshot);

  R _transitionKey<R>(K key, R Function() operation) {
    final before = _core.version;
    final result = operation();
    if (_core.version == before) return result;
    final roots = <AsyncSlotHandle<dynamic>>[_snapshot];
    final entry = _entries[key];
    if (entry != null) roots.add(entry);
    ctx.clearSlots(roots);
    return result;
  }

  R _transitionAll<R>(R Function() operation) {
    final before = _core.version;
    final result = operation();
    if (_core.version == before) return result;
    ctx.clearSlots(<AsyncSlotHandle<dynamic>>[
      _snapshot,
      _generation,
      ..._entries.values,
    ]);
    return result;
  }

  LatestDurableUpsert upsertDesired(K key, int epoch, T value) =>
      _transitionKey(key, () => _core.upsertDesired(key, epoch, value));
  LatestDurableClaim<K, T> claim(K key, int generation) =>
      _transitionKey(key, () => _core.claim(key, generation));
  LatestDurableAck ackApplied(K key, int generation, int epoch) =>
      _transitionKey(
        key,
        () => _core.ackApplied(key, generation, epoch),
      );
  LatestDurableFailure failRetryable(
    K key,
    int generation,
    int epoch,
  ) =>
      _transitionKey(
        key,
        () => _core.failRetryable(key, generation, epoch),
      );
  LatestDurableReconnect reconnect(int newGeneration) => _transitionAll(
        () => _core.reconnect(newGeneration),
      );
}
