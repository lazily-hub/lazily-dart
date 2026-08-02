/// Rate-shaping source operators (`#lzrateshape`) — the Dart port.
///
/// See `lazily-spec/docs/rate-shaping.md` and the formal model
/// `lazily-formal/LazilyFormal/RateShape.lean`. Lifts debounce / throttle /
/// time-sampling out of the relay egress so any reactive source can be
/// rate-shaped. Each operator is a pure compute **core** (the emit/drop
/// decision — the C++/bytes-eligible part) split from a thin reactive **cell**
/// that projects the emitted value onto a [Context] cell, so a dropped input
/// never invalidates dependents (the backend-portability rule). Time is the
/// same monotone logical clock as `#lztime`. An emitted value of `null` from an
/// op means "nothing emitted this op".
library;

import 'core.dart';
import 'u64.dart';

/// Shared shape of a rate-shaping cell: a projected output [Cell] plus its
/// current value. Lets a single replay harness drive every operator.
abstract class RateShapeCell<T extends Object> {
  /// The reactive cell the emitted value is projected onto.
  Source<T?> get outputCell;

  /// The current projected output (`null` before the first emit).
  T? output();
}

// ---------------------------------------------------------------------------
// Debounce
// ---------------------------------------------------------------------------

/// Debounce core: coalesce inputs (KeepLatest) and emit the latest value only
/// after `quiet` ticks with no new input; every input resets the deadline.
class DebounceCore<T extends Object> {
  DebounceCore(this.quiet);

  final int quiet;
  T? pending;
  bool hasPending = false;
  int fireAt = 0;
  bool armed = false;

  void input(int now, T v) {
    pending = v;
    hasPending = true;
    fireAt = now + quiet;
    armed = true;
  }

  /// Advance to [now]; returns the coalesced value on the emit edge, else null.
  T? tick(int now) {
    if (armed && hasPending && fireAt <= now) {
      armed = false;
      hasPending = false;
      final p = pending;
      pending = null;
      return p;
    }
    return null;
  }
}

/// Reactive debounce over any reactive source.
class DebounceCell<T extends Object> implements RateShapeCell<T> {
  DebounceCell(this.ctx, int quiet)
      : core = DebounceCore<T>(quiet),
        outputCell = Source<T?>(ctx, null);

  final Context ctx;
  final DebounceCore<T> core;
  @override
  final Source<T?> outputCell;

  void input(int now, T v) => core.input(now, v);

  T? tick(int now) {
    final emitted = core.tick(now);
    if (emitted != null) outputCell.value = emitted;
    return emitted;
  }

  @override
  T? output() => outputCell.value;
}

// ---------------------------------------------------------------------------
// Throttle
// ---------------------------------------------------------------------------

/// Which edge of the window a [ThrottleCore] emits on.
enum ThrottleEdge { leading, trailing }

/// Throttle core: at most one emit per `window`.
///
/// - Leading: the first input of a window passes immediately and opens a window
///   `[now, now + window)`; later inputs drop until it elapses.
/// - Trailing: the first input opens a window without emitting; inputs coalesce
///   (KeepLatest); at the boundary a `tick` emits the latest and closes.
class ThrottleCore<T extends Object> {
  ThrottleCore(this.edge, this.window);

  final ThrottleEdge edge;
  final int window;
  int? windowEnd;
  int? windowStart;
  T? pending;
  bool hasPending = false;

  T? input(int now, T v) {
    if (edge == ThrottleEdge.leading) {
      final end = windowEnd;
      if (end != null && now < end) return null;
      windowEnd = now + window;
      return v;
    }
    // Trailing
    windowStart ??= now;
    pending = v;
    hasPending = true;
    return null;
  }

  T? tick(int now) {
    if (edge != ThrottleEdge.trailing) return null;
    final start = windowStart;
    if (start == null) return null;
    if (now >= start + window && hasPending) {
      windowStart = null;
      hasPending = false;
      final p = pending;
      pending = null;
      return p;
    }
    return null;
  }
}

/// Reactive throttle over any reactive source.
class ThrottleCell<T extends Object> implements RateShapeCell<T> {
  ThrottleCell(this.ctx, ThrottleEdge edge, int window)
      : core = ThrottleCore<T>(edge, window),
        outputCell = Source<T?>(ctx, null);

  final Context ctx;
  final ThrottleCore<T> core;
  @override
  final Source<T?> outputCell;

  T? input(int now, T v) {
    final emitted = core.input(now, v);
    if (emitted != null) outputCell.value = emitted;
    return emitted;
  }

  T? tick(int now) {
    final emitted = core.tick(now);
    if (emitted != null) outputCell.value = emitted;
    return emitted;
  }

  @override
  T? output() => outputCell.value;
}

// ---------------------------------------------------------------------------
// Sample
// ---------------------------------------------------------------------------

/// Which discipline a [SampleCore] samples on.
enum SampleKind { count, time }

/// Sampling mode: emit every `n`-th input ([SampleMode.count]) or hold the
/// latest and emit at each period boundary ([SampleMode.time]).
class SampleMode {
  const SampleMode._(this.kind, {this.n = 0, this.period = 0});

  /// Emit every [n]-th input.
  factory SampleMode.count(int n) => SampleMode._(SampleKind.count, n: n);

  /// Hold the latest input and emit it at each [period] boundary.
  factory SampleMode.time(int period) =>
      SampleMode._(SampleKind.time, period: period);

  final SampleKind kind;
  final int n;
  final int period;
}

/// Deterministic sampling core.
class SampleCore<T extends Object> {
  SampleCore(this.mode)
      : next = mode.kind == SampleKind.time
            ? (mode.period < 1 ? 1 : mode.period)
            : 0;

  final SampleMode mode;
  int counter = 0;
  int next;
  T? held;

  T? input(T v) {
    if (mode.kind == SampleKind.count) {
      final n = mode.n < 1 ? 1 : mode.n;
      counter += 1;
      return counter % n == 0 ? v : null;
    }
    // Time: hold the latest.
    held = v;
    return null;
  }

  T? tick(int now) {
    if (mode.kind != SampleKind.time) return null;
    final period = mode.period < 1 ? 1 : mode.period;
    if (now < next) return null;
    final fires = ((now - next) ~/ period) + 1;
    next += fires * period;
    return held; // held latest persists across emits
  }
}

/// Reactive sampler over any reactive source.
class SampleCell<T extends Object> implements RateShapeCell<T> {
  SampleCell(this.ctx, SampleMode mode)
      : core = SampleCore<T>(mode),
        outputCell = Source<T?>(ctx, null);

  final Context ctx;
  final SampleCore<T> core;
  @override
  final Source<T?> outputCell;

  T? input(T v) {
    final emitted = core.input(v);
    if (emitted != null) outputCell.value = emitted;
    return emitted;
  }

  T? tick(int now) {
    final emitted = core.tick(now);
    if (emitted != null) outputCell.value = emitted;
    return emitted;
  }

  @override
  T? output() => outputCell.value;
}

// ---------------------------------------------------------------------------
// Probabilistic sample
// ---------------------------------------------------------------------------

/// An injectable random source yielding draws in `[0, 1)`.
abstract class Rng {
  double nextDouble();
}

// SplitMix64's three 64-bit constants, as 32-bit halves. Spelled out rather
// than written as literals because dart2js REFUSES an integer literal above
// 2^53 - 1, and these three were the last thing keeping
// `package:lazily/lazily.dart` from compiling for the web at all
// (`#lzdartwebcompile`).
const int _goldenGammaHigh = 0x9e3779b9;
const int _goldenGammaLow = 0x7f4a7c15;
const int _mix1High = 0xbf58476d;
const int _mix1Low = 0x1ce4e5b9;
const int _mix2High = 0x94d049bb;
const int _mix2Low = 0x133111eb;

/// A small deterministic SplitMix64 RNG — [nextDouble] yields a draw in `[0, 1)`.
///
/// The state and every mixing step are carried as 32-bit halves through [U64],
/// so the sequence is bit-identical on the VM and on a JavaScript target. That
/// matters beyond portability: a sampler whose draws differ by runtime turns a
/// deterministic conformance fixture into a platform-dependent one.
class Lcg implements Rng {
  Lcg(int seed) : _state = U64(highHalfOf(seed), lowHalfOf(seed));

  final U64 _state;

  @override
  double nextDouble() {
    _state.add(_goldenGammaHigh, _goldenGammaLow);
    final z = U64.from(_state);
    z.xorShiftRight(30);
    z.multiply(_mix1High, _mix1Low);
    z.xorShiftRight(27);
    z.multiply(_mix2High, _mix2Low);
    z.xorShiftRight(31);
    // The top 53 bits over 2^53. Shifting first is what keeps the numerator
    // inside the range a double represents exactly on every target.
    return z.shiftedRight(11).toDouble() / 9007199254740992.0;
  }
}

/// Probabilistic (tail) sampling core — a draw in `[0, 1)` passes iff
/// `draw < rate`.
class ProbabilisticSampleCore {
  ProbabilisticSampleCore(double rate)
      : rate = rate < 0
            ? 0
            : rate > 1
                ? 1
                : rate;

  final double rate;

  bool decide(double draw) => draw < rate;
}

/// Reactive probabilistic sampler; owns an injectable [Rng].
class ProbabilisticSampleCell<T extends Object> implements RateShapeCell<T> {
  ProbabilisticSampleCell(this.ctx, double rate, this.rng)
      : core = ProbabilisticSampleCore(rate),
        outputCell = Source<T?>(ctx, null);

  final Context ctx;
  final ProbabilisticSampleCore core;
  final Rng rng;
  @override
  final Source<T?> outputCell;

  T? input(T v) => inputWithDraw(v, rng.nextDouble());

  T? inputWithDraw(T v, double draw) {
    if (core.decide(draw)) {
      outputCell.value = v;
      return v;
    }
    return null;
  }

  @override
  T? output() => outputCell.value;
}
