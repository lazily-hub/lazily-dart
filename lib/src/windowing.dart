/// Stream windowing (`#lzwindow`) — the Dart port.
///
/// See `lazily-spec/docs/windowing.md` and the formal model
/// `lazily-formal/LazilyFormal/Windowing.lean`. Window aggregation *is* a
/// merge: the aggregate of a window equals the associative fold of its
/// elements, so any associative [Merge] fold composes (e.g. `Sum = (a, b) => a
/// + b`). Each primitive is a pure compute **core** (window bookkeeping + the
/// fold) — the C++/bytes-eligible part — split from a thin reactive **cell**
/// projecting the last emitted aggregate onto a [Context] cell. Because the
/// output cell guards writes with `!=` and only writes on an actual emit,
/// dependents invalidate *only when a window fires* with a new aggregate (the
/// backend-portability rule). An emitted value of `null` means "nothing
/// emitted"; `null` is the empty-accumulator sentinel throughout.
library;

import 'core.dart';

/// An associative fold over two window elements (e.g. `Sum = (a, b) => a + b`).
typedef Merge<T> = T Function(T a, T b);

int _atLeast1(int x) => x < 1 ? 1 : x;

/// Fold a window's elements under [merge]; `null` for an empty window.
T? foldWindow<T>(List<T> items, Merge<T> merge) {
  if (items.isEmpty) return null;
  var acc = items.first;
  for (var i = 1; i < items.length; i++) {
    acc = merge(acc, items[i]);
  }
  return acc;
}

// ---------------------------------------------------------------------------
// Cores
// ---------------------------------------------------------------------------

/// Count-based tumbling window core: accumulate `n` elements under the merge;
/// on the `n`-th push emit the window fold and reset.
class TumblingCountCore<T> {
  TumblingCountCore(int n, this.merge) : n = _atLeast1(n);

  final int n;
  final Merge<T> merge;
  T? acc;
  int count = 0;

  /// Push an element; emit the window aggregate on the `n`-th and reset.
  T? push(T v) {
    acc = acc == null ? v : merge(acc as T, v);
    count += 1;
    if (count >= n) {
      count = 0;
      final e = acc;
      acc = null;
      return e;
    }
    return null;
  }
}

/// Time-based tumbling window core: accumulate into the current window; at each
/// period boundary (`tick` with `now >= next`) emit the fold and open the next
/// window. An empty window emits nothing.
class TumblingTimeCore<T> {
  TumblingTimeCore(int period, this.merge)
      : period = _atLeast1(period),
        next = _atLeast1(period);

  final int period;
  int next;
  final Merge<T> merge;
  T? acc;

  /// Accumulate an element into the current window.
  void push(int now, T v) {
    acc = acc == null ? v : merge(acc as T, v);
  }

  /// At a period boundary emit the window aggregate (empty window -> `null`).
  T? tick(int now) {
    if (now < next) return null;
    while (next <= now) {
      next += period;
    }
    final e = acc;
    acc = null;
    return e;
  }
}

/// Count-based sliding window core (fold-recompute, correct for any associative
/// merge): retain the last `size` elements; every `slide` pushes emit the fold
/// over the current window.
class SlidingCore<T> {
  SlidingCore(int size, int slide, this.merge)
      : size = _atLeast1(size),
        slide = _atLeast1(slide);

  final int size;
  final int slide;
  final Merge<T> merge;
  final List<T> buffer = [];
  int since = 0;

  /// Push an element; every `slide` pushes emit the fold over the last `size`.
  T? push(T v) {
    buffer.add(v);
    while (buffer.length > size) {
      buffer.removeAt(0);
    }
    since += 1;
    if (since >= slide) {
      since = 0;
      return foldWindow(buffer, merge);
    }
    return null;
  }
}

/// Gap-based sessionization core: consecutive elements within `gap` accumulate;
/// an element arriving more than `gap` after the previous closes the session
/// (emitting its fold) and opens a new one. `flush` closes an idle-open session.
class SessionCore<T> {
  SessionCore(this.gap, this.merge);

  final int gap;
  final Merge<T> merge;
  T? acc;
  int? last;

  /// Push an element; a gap larger than `gap` closes the session (emitting its
  /// aggregate) and opens a new one.
  T? push(int now, T v) {
    final l = last;
    final idleBreak = l != null && now - l > gap && acc != null;
    if (idleBreak) {
      final emit = acc;
      acc = v;
      last = now;
      return emit;
    }
    acc = acc == null ? v : merge(acc as T, v);
    last = now;
    return null;
  }

  /// Close the open session if it has been idle longer than `gap`.
  T? flush(int now) {
    final l = last;
    if (l != null && now - l > gap && acc != null) {
      final emit = acc;
      acc = null;
      return emit;
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// Reactive cells
// ---------------------------------------------------------------------------

/// Shared output projection: the last emitted aggregate on a [Context] cell.
/// Writes only on a real emit (non-`null`), so the cell's `!=` guard means
/// dependents invalidate only when a window actually fires a new aggregate.
class _WindowOutput<T> {
  _WindowOutput(this.ctx) : outputCell = Source<T?>(ctx, null);

  final Context ctx;
  final Source<T?> outputCell;

  T? emit(T? e) {
    if (e != null) outputCell.value = e;
    return e;
  }

  T? value() => outputCell.value;
}

/// Reactive count-tumbling window; projects the last emitted aggregate.
class TumblingCountWindow<T> {
  TumblingCountWindow(Context ctx, int n, Merge<T> merge)
      : core = TumblingCountCore<T>(n, merge),
        _out = _WindowOutput<T>(ctx);

  final TumblingCountCore<T> core;
  final _WindowOutput<T> _out;

  /// The reactive output cell projecting the last emitted aggregate.
  Source<T?> get outputCell => _out.outputCell;

  T? push(T v) => _out.emit(core.push(v));

  T? output() => _out.value();
}

/// Reactive time-tumbling window (`push(now, v)` then `tick(now)`).
class TumblingTimeWindow<T> {
  TumblingTimeWindow(Context ctx, int period, Merge<T> merge)
      : core = TumblingTimeCore<T>(period, merge),
        _out = _WindowOutput<T>(ctx);

  final TumblingTimeCore<T> core;
  final _WindowOutput<T> _out;

  /// The reactive output cell projecting the last emitted aggregate.
  Source<T?> get outputCell => _out.outputCell;

  void push(int now, T v) => core.push(now, v);

  T? tick(int now) => _out.emit(core.tick(now));

  T? output() => _out.value();
}

/// Reactive count-sliding window; projects the last emitted aggregate.
class SlidingWindow<T> {
  SlidingWindow(Context ctx, int size, int slide, Merge<T> merge)
      : core = SlidingCore<T>(size, slide, merge),
        _out = _WindowOutput<T>(ctx);

  final SlidingCore<T> core;
  final _WindowOutput<T> _out;

  /// The reactive output cell projecting the last emitted aggregate.
  Source<T?> get outputCell => _out.outputCell;

  T? push(T v) => _out.emit(core.push(v));

  T? output() => _out.value();
}

/// Reactive session window (`push(now, v)` + `flush(now)`).
class SessionWindow<T> {
  SessionWindow(Context ctx, int gap, Merge<T> merge)
      : core = SessionCore<T>(gap, merge),
        _out = _WindowOutput<T>(ctx);

  final SessionCore<T> core;
  final _WindowOutput<T> _out;

  /// The reactive output cell projecting the last emitted aggregate.
  Source<T?> get outputCell => _out.outputCell;

  T? push(int now, T v) => _out.emit(core.push(now, v));

  T? flush(int now) => _out.emit(core.flush(now));

  T? output() => _out.value();
}
