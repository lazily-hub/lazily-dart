// RelayCell backpressure plan (#relaycell), Phases 2–6 — the Dart port.
//
// See `lazily-spec/docs/relaycell.md` and `relaycell-backpressure-analysis.md`.
// A [RelayCell] is an *algebra-typed conflating relay*: it accumulates a fast
// ingress into a hot head (a [MergePolicy] fold), bounds it with a reactive
// [BackpressurePolicy], and lets a slow egress drain the coalesced window. The
// converged egress state is independent of the drain schedule whenever the merge
// ⊕ is associative (the `relay_converges` invariant, pinned in LazilyFormal.Relay).
//
// Phase 2 [RelayCell] + [BackpressurePolicy] · Phase 3 [SpillStore] · Phase 4
// [RelayTransport] · Phase 5 [Outbox]/[Inbox] roles · Phase 6
// [RatePolicy]/[WindowPolicy]/[ExpiryPolicy]/[PriorityStorage]/[KeyedRelay].
// Time is a logical clock (a monotone tick) so behaviour is deterministic.

import 'core.dart';
import 'merge.dart';

// -- Phase 2: RelayCell + BackpressurePolicy ---------------------------------

/// What a bound measures (analysis §4.4). The core meters [count].
enum BoundDim { count, bytes, keys, age }

/// The action taken when the hot head crosses `highWater` (analysis §4.4).
enum Overflow {
  /// Refuse ingress; the producer backpressures (observes `isFull`). Lossless.
  block,

  /// Discard the incoming op. Lossy.
  dropNewest,

  /// Reset the window to the incoming op, discarding what accumulated. Lossy.
  dropOldest,

  /// Keep merging — the coalescence *is* the bound. Requires `policy.conflates`.
  conflate,

  /// Page the accumulated window to a durable tail (Phase 3 [SpillStore]).
  spill,
}

/// Why a construction/merge-swap was rejected (analysis §4.3 flag validation).
enum RelayConfigError {
  /// `Conflate` chosen for a non-conflating policy (`RawFifo`).
  conflateNotBounding,
}

/// Thrown when a relay is constructed with an illegal overflow for its policy.
///
/// Extends [ArgumentError] so callers may catch it either as the specific
/// [RelayConfigException] (inspecting [error]) or as a generic argument error.
class RelayConfigException extends ArgumentError {
  RelayConfigException(this.error) : super(error.name);

  final RelayConfigError error;
}

/// The outcome of a single [RelayCell.ingress] op.
enum IngressOutcome {
  /// Merged into an empty window (window depth was 0).
  accepted,

  /// Merged into a non-empty window (coalesced with prior ops).
  conflated,

  /// Dropped by `DropNewest`/`DropOldest` overflow.
  dropped,

  /// Refused by `Block` overflow; the producer must retry after a drain.
  blocked,
}

/// Reactive backpressure limits (analysis §4.4). Every field is a cell, so an
/// operator or an adaptive controller retunes it live and dependent relays react.
/// Hysteresis (`highWater` ≠ `lowWater`) prevents flapping.
class BackpressurePolicy {
  BackpressurePolicy(
    Context ctx,
    BoundDim dimension,
    int highWater,
    int lowWater,
    Overflow overflow,
  )   : dimension = Source<BoundDim>(ctx, dimension),
        highWater = Source<int>(ctx, highWater),
        lowWater = Source<int>(ctx, lowWater),
        overflow = Source<Overflow>(ctx, overflow);

  final Source<BoundDim> dimension;
  final Source<int> highWater;
  final Source<int> lowWater;
  final Source<Overflow> overflow;
}

/// The algebra-typed conflating relay (Phase 2, in-proc core). The hot head is a
/// cell; [depth]/[isFull]/[isEmpty] are demand-driven slots, so an unobserved
/// relay costs `N·⊕` and no more (the merge cost law).
///
/// The empty window is modeled with a nullable `T?` head cell (`null` = empty).
class RelayCell<T> {
  RelayCell(this.ctx, this.policy, this.mergePolicy)
      : _head = Source<T?>(ctx, null),
        _pending = Source<int>(ctx, 0) {
    if (policy.overflow.peek == Overflow.conflate && !mergePolicy.conflates) {
      throw RelayConfigException(RelayConfigError.conflateNotBounding);
    }
    depth = Slot<int>(ctx, (_) => _pending.value);
    isFull = Slot<bool>(ctx, (_) => _pending.value >= policy.highWater.value);
    isEmpty = Slot<bool>(ctx, (_) => _head.value == null);
  }

  final Context ctx;
  final BackpressurePolicy policy;
  final MergePolicy<T> mergePolicy;

  final Source<T?> _head;
  final Source<int> _pending;

  /// Demand-driven reader: current window depth (`Count`). Callable: `depth()`.
  late final Slot<int> depth;

  /// Demand-driven reader: depth ≥ `highWater`. Callable: `isFull()`.
  late final Slot<bool> isFull;

  /// Demand-driven reader: the window is empty. Callable: `isEmpty()`.
  late final Slot<bool> isEmpty;

  /// Whether the current overflow choice is legal for [mergePolicy].
  bool overflowIsLegal() =>
      policy.overflow.peek != Overflow.conflate || mergePolicy.conflates;

  bool _readFull() => _pending.peek >= policy.highWater.peek;

  void _mergeIntoHead(T op) {
    final cur = _head.peek;
    _head.set(cur == null ? op : mergePolicy.merge(cur, op));
  }

  /// Ingest one op. Applies the reactive overflow policy when the window is at
  /// `highWater`; otherwise merges the op into the hot head under [mergePolicy].
  IngressOutcome ingress(T op) {
    final wasEmpty = _pending.peek == 0;
    if (_readFull()) {
      switch (policy.overflow.peek) {
        case Overflow.block:
          return IngressOutcome.blocked;
        case Overflow.dropNewest:
          return IngressOutcome.dropped;
        case Overflow.dropOldest:
          // Discard the accumulated window, restart from this op.
          _head.set(op);
          _pending.set(1);
          return IngressOutcome.dropped;
        case Overflow.conflate:
        case Overflow.spill:
          // Conflate keeps merging; Spill degrades to Conflate until wired.
          break;
      }
    }
    _mergeIntoHead(op);
    _pending.set(_pending.peek + 1);
    return wasEmpty ? IngressOutcome.accepted : IngressOutcome.conflated;
  }

  /// Drain the coalesced window: take the hot head's value and reset the window.
  /// Returns `null` for an empty window. `relay_converges` guarantees the egress
  /// fold equals the flat fold of every ingested op, for any drain schedule.
  T? drain() {
    final cur = _head.peek;
    if (cur != null) {
      _head.set(null);
      _pending.set(0);
    }
    return cur;
  }

  /// Peek the current coalesced window without draining.
  T? peek() => _head.peek;
}

// -- Phase 3: SpillStore -----------------------------------------------------

/// How spilled windows are laid out on the durable tail (analysis §6).
enum SpillMode {
  /// Merge each spilled window into the open page until it fills — minimizes
  /// disk (keep-latest / semilattice). One page holds a coalesced run.
  compactOnWrite,

  /// Append each spilled window as its own page — preserves increments for an
  /// accumulating (non-idempotent) policy that must not double-count.
  appendCompact,
}

/// One immutable cold page: a coalesced window summary plus its manifest entry.
class SpillPage<T> {
  SpillPage(this.id, this.summary, this.bytes);

  final int id;
  T summary;
  int bytes;
}

/// A paged durable tail for a [RelayCell] (Phase 3, in-memory reference backend).
/// Holds a hot page in RAM plus immutable cold pages, a bounded manifest, an
/// egress cursor, and ack-before-reclaim. Memory is `O(hot) + O(manifest)`.
class SpillStore<T> {
  SpillStore(this._mode, int pageSize, this._mergePolicy)
      : _pageSize = pageSize < 1 ? 1 : pageSize;

  final SpillMode _mode;
  final int _pageSize;
  final MergePolicy<T> _mergePolicy;
  final List<SpillPage<T>> _pages = [];
  int _openFill = 0;
  int _nextId = 0;

  /// Pages acked from the front (reclaimable) — the egress cursor.
  int _acked = 0;

  /// Spill one coalesced window summary to the durable tail. `AppendCompact`
  /// always opens a new page; `CompactOnWrite` merges into the open page until
  /// it reaches `pageSize`, then seals it.
  void spill(T window, int bytes) {
    switch (_mode) {
      case SpillMode.appendCompact:
        _pushPage(window, bytes);
      case SpillMode.compactOnWrite:
        if (_openFill >= _pageSize || _pages.isEmpty) {
          _pushPage(window, bytes);
          _openFill = 1;
        } else {
          final last = _pages.last;
          last.summary = _mergePolicy.merge(last.summary, window);
          last.bytes += bytes;
          _openFill += 1;
        }
    }
  }

  void _pushPage(T summary, int bytes) {
    _pages.add(SpillPage(_nextId, summary, bytes));
    _nextId += 1;
  }

  /// The manifest: `(id, bytes)` for every live page (bounded metadata).
  List<(int, int)> manifest() => [for (final p in _pages) (p.id, p.bytes)];

  /// Pages the egress has not yet acked (at/after the ack cursor).
  List<SpillPage<T>> pendingPages() => _pages.sublist(_acked);

  int pageCount() => _pages.length;

  /// Ack every page through `id` (inclusive), advancing the reclaim cursor.
  void ackThrough(int id) {
    while (_acked < _pages.length && _pages[_acked].id <= id) {
      _acked += 1;
    }
  }

  /// Drop acked pages (durable reclaim). Manifest/cursor stay consistent.
  void reclaim() {
    if (_acked > 0) {
      _pages.removeRange(0, _acked);
      _acked = 0;
    }
  }

  /// Fold every live cold page (oldest first) into `s0`.
  T foldPages(T s0) {
    var acc = s0;
    for (final p in _pages) {
      acc = _mergePolicy.merge(acc, p.summary);
    }
    return acc;
  }

  /// Reconstruction (`spill_lossless`). Fold the cold tail then the hot head —
  /// reproduces the flat fold of every op the relay ever ingested.
  T reconstruct(T s0, T? hot) {
    final cold = foldPages(s0);
    return hot == null ? cold : _mergePolicy.merge(cold, hot);
  }

  /// Crash replay. Re-deliver every unacked page from the ack cursor into
  /// `downstream`. For an idempotent policy re-applying an already-delivered page
  /// is a no-op (`spill_replay_idempotent`), so at-least-once replay converges.
  T replayUnacked(T downstream) {
    var acc = downstream;
    for (final p in pendingPages()) {
      acc = _mergePolicy.merge(acc, p.summary);
    }
    return acc;
  }
}

// -- Phase 4: Transport ------------------------------------------------------

/// A pluggable delivery mechanism for relay ops. The merge algebra — not the
/// transport — guarantees converged state (`transport_independent`), so
/// transports may differ across bindings and still converge.
abstract class RelayTransport<T> {
  /// Enqueue an op for delivery.
  void deliver(T op);

  /// Pull the next ready frame (empty when nothing is ready).
  List<T> poll();

  /// Whether any op is still buffered for delivery.
  bool hasPending();
}

/// `InProc` — direct delivery: every buffered op is handed over in one frame.
class InProcTransport<T> implements RelayTransport<T> {
  final List<T> _buf = [];

  @override
  void deliver(T op) => _buf.add(op);

  @override
  List<T> poll() {
    final out = List<T>.of(_buf);
    _buf.clear();
    return out;
  }

  @override
  bool hasPending() => _buf.isNotEmpty;
}

/// A *framed* transport — models `CrossThread`/`Ipc`/`Ws`: ops are delivered in
/// bounded frames of at most `frameSize` (an MTU / batch boundary).
class FramedTransport<T> implements RelayTransport<T> {
  FramedTransport(int frameSize) : _frameSize = frameSize < 1 ? 1 : frameSize;

  final int _frameSize;
  final List<T> _buf = [];

  @override
  void deliver(T op) => _buf.add(op);

  @override
  List<T> poll() {
    final n = _frameSize < _buf.length ? _frameSize : _buf.length;
    final out = _buf.sublist(0, n);
    _buf.removeRange(0, n);
    return out;
  }

  @override
  bool hasPending() => _buf.isNotEmpty;
}

// -- Phase 5: Outbox / Inbox roles -------------------------------------------

/// The app → transport send side (analysis §4.7). Backpressures the local
/// producer directly via `isFull`. Default overflow `Conflate` (state broadcast).
class Outbox<T> {
  Outbox(
    Context ctx,
    int highWater,
    MergePolicy<T> mergePolicy, {
    BoundDim dimension = BoundDim.count,
    Overflow overflow = Overflow.conflate,
  }) : relay = RelayCell<T>(
          ctx,
          BackpressurePolicy(ctx, dimension, highWater, highWater ~/ 2, overflow),
          mergePolicy,
        );

  final RelayCell<T> relay;

  /// The local producer sends an op. A `Blocked` outcome is the producer's
  /// backpressure signal — it should await a drain before retrying.
  IngressOutcome send(T op) => relay.ingress(op);

  /// The transport drains the coalesced window for egress.
  T? drain() => relay.drain();

  /// The producer-facing backpressure signal (window at/over the watermark).
  Slot<bool> isFull() => relay.isFull;
}

/// The transport → app receive side (analysis §4.7). Cannot block the remote
/// directly; backpressure is a **credit meter** the app replenishes.
class Inbox<T> {
  Inbox(
    Context ctx,
    int highWater,
    this._maxCredits,
    MergePolicy<T> mergePolicy, {
    Overflow overflow = Overflow.conflate,
  })  : relay = RelayCell<T>(
          ctx,
          BackpressurePolicy(
              ctx, BoundDim.count, highWater, highWater ~/ 2, overflow),
          mergePolicy,
        ),
        _creditsRemaining = _maxCredits;

  final RelayCell<T> relay;
  final int _maxCredits;
  int _creditsRemaining;

  /// Whether the transport may deliver another message (a credit is available).
  /// When `false`, the transport must stop reading → the remote throttles.
  bool ready() => _creditsRemaining > 0;

  /// Credits currently available to the remote.
  int credits() => _creditsRemaining;

  /// The transport delivers a received op. Consumes a credit; the caller MUST
  /// have checked [ready] (a delivery without credit still applies but drives
  /// credits to zero, signalling the remote to stop).
  IngressOutcome receive(T op) {
    _creditsRemaining = _creditsRemaining > 0 ? _creditsRemaining - 1 : 0;
    return relay.ingress(op);
  }

  /// The app consumes the coalesced window and replenishes `n` credits (up to
  /// the budget), re-opening the remote's flow.
  T? consume(int replenish) {
    final out = relay.drain();
    final next = _creditsRemaining + replenish;
    _creditsRemaining = next < _maxCredits ? next : _maxCredits;
    return out;
  }
}

// -- Phase 6: extra reactive policies ----------------------------------------

/// Case 9 — rate-limited egress (token bucket). A drain is permitted only when a
/// token is available. Refilled `refillPerTick` tokens per logical tick, capped
/// at `capacity`.
class RatePolicy {
  RatePolicy(this._capacity, this._refillPerTick) : _tokens = _capacity;

  final int _capacity;
  final int _refillPerTick;
  int _tokens;

  int tokens() => _tokens;

  /// Try to consume one token for an egress; returns `true` if paced through.
  bool tryEgress() {
    if (_tokens > 0) {
      _tokens -= 1;
      return true;
    }
    return false;
  }

  /// Advance the logical clock, refilling the bucket (saturating at capacity).
  void tick() {
    final next = _tokens + _refillPerTick;
    _tokens = next < _capacity ? next : _capacity;
  }
}

/// Case 8 — time-windowed coalescence (debounce/throttle). Flushes when it
/// reaches `windowOps` ops or on an explicit `tick`. Because a window is just a
/// flush group, associativity keeps the converged state unchanged.
class WindowPolicy {
  WindowPolicy(int windowOps) : _windowOps = windowOps < 1 ? 1 : windowOps;

  final int _windowOps;
  int _pending = 0;

  /// Record one ingress; returns `true` when the window is full and should flush.
  bool onIngress() {
    _pending += 1;
    if (_pending >= _windowOps) {
      _pending = 0;
      return true;
    }
    return false;
  }

  /// The debounce/throttle interval elapsed: flush whatever is pending.
  bool tick() {
    if (_pending > 0) {
      _pending = 0;
      return true;
    }
    return false;
  }
}

/// Case 10 — TTL / deadline expiry. Drops elements whose age exceeds `ttl`
/// against a logical clock. Lossy-by-age (explicit); used to shed cold data.
class ExpiryPolicy {
  ExpiryPolicy(this._ttl);

  final int _ttl;
  int _nowTick = 0;

  void advance(int by) => _nowTick += by;

  int now() => _nowTick;

  /// Whether an element stamped at `stampedAt` is still live (not expired).
  bool isLive(int stampedAt) {
    final age = _nowTick - stampedAt;
    return (age < 0 ? 0 : age) <= _ttl;
  }

  /// Retain only the live elements of a timestamped batch (drop the aged tail).
  List<T> retainLive<T>(List<(int, T)> batch) =>
      [for (final entry in batch) if (isLive(entry.$1)) entry.$2];
}

/// Case 11 — priority egress. Ingress carries a priority; egress pops the highest
/// priority first (**not** FIFO), FIFO within equal priority. Reordering, so
/// sound for a commutative merge downstream (`reorder_adjacent`).
class PriorityStorage<T> {
  final List<_PriorityEntry<T>> _items = [];
  int _seq = 0;

  void push(int priority, T value) {
    _items.add(_PriorityEntry(priority, _seq, value));
    _seq += 1;
  }

  /// Pop the highest-priority element (FIFO within equal priority).
  T? pop() {
    if (_items.isEmpty) return null;
    var best = 0;
    for (var i = 1; i < _items.length; i++) {
      final a = _items[i];
      final b = _items[best];
      if (a.priority > b.priority ||
          (a.priority == b.priority && a.seq < b.seq)) {
        best = i;
      }
    }
    return _items.removeAt(best).value;
  }

  int size() => _items.length;

  bool isEmpty() => _items.isEmpty;
}

class _PriorityEntry<T> {
  _PriorityEntry(this.priority, this.seq, this.value);

  final int priority;
  final int seq;
  final T value;
}

/// Case 18 — keyed sharding. N independent relays keyed by `K`; an op routes to
/// its key's shard. Merging *across* shards requires a **commutative** merge. The
/// converged per-key state equals a single relay per key.
class KeyedRelay<K, T> {
  KeyedRelay(this._ctx, this._highWater, this._overflow, this._mergePolicy);

  final Context _ctx;
  final int _highWater;
  final Overflow _overflow;
  final MergePolicy<T> _mergePolicy;
  final Map<K, RelayCell<T>> _shards = {};

  /// Route `op` to `key`'s shard, creating the shard on first use.
  IngressOutcome ingress(K key, T op) {
    final relay = _shards.putIfAbsent(
      key,
      () => RelayCell<T>(
        _ctx,
        BackpressurePolicy(
            _ctx, BoundDim.count, _highWater, _highWater ~/ 2, _overflow),
        _mergePolicy,
      ),
    );
    return relay.ingress(op);
  }

  /// Drain a key's coalesced window.
  T? drain(K key) => _shards[key]?.drain();

  Set<K> keys() => _shards.keys.toSet();
}
