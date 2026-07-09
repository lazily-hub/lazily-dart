import 'dart:convert';
import 'dart:io';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

/// Reactive queue conformance (lazily-spec/conformance/collections/).
///
/// Replays the canonical `queuecell_*.json` fixtures every binding replays,
/// asserting observable state and the per-reader-kind invalidation matrix
/// using the live reactive graph: readers are primed as [Slot]s, and
/// invalidation is observed via `ctx.contains(reader)` (warm = not
/// invalidated, evicted = invalidated). Mirrors `lazily-kt`'s
/// `QueueCellConformanceTest` and `lazily-js`'s `queue.test.js`.

final _localDir = Directory('test/conformance/collections');
final _specDir = Directory('../lazily-spec/conformance/collections');

String _fixturePath(String name) {
  final local = _localDir.resolveSymbolicLinksSync() + '/$name';
  if (File(local).existsSync()) return local;
  final sibling = _specDir.resolveSymbolicLinksSync() + '/$name';
  if (File(sibling).existsSync()) return sibling;
  throw StateError('queue fixture not found: $name');
}

Map<String, dynamic> _loadFixture(String name) =>
    jsonDecode(File(_fixturePath(name)).readAsStringSync()) as Map<String, dynamic>;

/// Build a QueueCell from the fixture's `initial` block.
QueueCell<String> _buildInitial(
  Context ctx,
  Map<String, dynamic> initial,
) {
  final elements = (initial['elements'] as List?)?.cast<String>() ?? const [];
  final capacity = initial['capacity'] as int?;
  final closed = (initial['closed'] as bool?) ?? false;
  return QueueCell<String>(
    ctx,
    VecDequeStorage<String>.from(
      elements: elements,
      capacity: capacity,
      closed: closed,
    ),
  );
}

/// Whether a [Slot]'s cache is still warm (not invalidated).
bool _isWarm(Slot<dynamic> reader, Context ctx) => ctx.contains(reader);

/// Reader-kind probes — one [Slot] per reader kind, primed before each op.
class _Readers<T> {
  _Readers(Context ctx, QueueCell<T> q)
      : head = Slot<Object?>(ctx, (_) => q.head())..call(),
        len = Slot<int>(ctx, (_) => q.len())..call(),
        isEmpty = Slot<bool>(ctx, (_) => q.isEmpty())..call(),
        isFull = Slot<bool>(ctx, (_) => q.isFull())..call(),
        isClosed = Slot<bool>(ctx, (_) => q.isClosed())..call();

  final Slot<Object?> head;
  final Slot<int> len;
  final Slot<bool> isEmpty;
  final Slot<bool> isFull;
  final Slot<bool> isClosed;
}

/// Assert per-reader-kind invalidation. A reader kind explicitly present in the
/// fixture's `invalidates` map is asserted; absent kinds are not asserted
/// (fixtures that focus on one reader kind only declare that one).
void _assertInvalidation(
  String name,
  int stepIndex,
  String opType,
  _Readers readers,
  Context ctx,
  Map<String, dynamic> invalidates,
) {
  void check(String kind, Slot<dynamic> reader) {
    if (!invalidates.containsKey(kind)) return;
    final expected = invalidates[kind] as bool;
    final warm = _isWarm(reader, ctx);
    expect(warm, !expected,
        reason: '$name step $stepIndex `$opType` reader `$kind`: '
            'expected invalidated=$expected (warm=$warm)');
  }

  check('head', readers.head);
  check('len', readers.len);
  check('is_empty', readers.isEmpty);
  check('is_full', readers.isFull);
  check('closed', readers.isClosed);
}

/// Assert observable queue state (only fields present in `expected`).
void _assertState(
  QueueCell<String> q,
  Map<String, dynamic> expected,
) {
  if (expected.containsKey('elements')) {
    expect(q.elements(), equals((expected['elements'] as List).cast<String>()),
        reason: 'elements mismatch');
  }
  if (expected.containsKey('head')) {
    expect(q.head(), equals(expected['head']),
        reason: 'head mismatch');
  }
  if (expected.containsKey('len')) {
    expect(q.len(), expected['len'], reason: 'len mismatch');
  }
  if (expected.containsKey('is_empty')) {
    expect(q.isEmpty(), expected['is_empty'], reason: 'is_empty mismatch');
  }
  if (expected.containsKey('is_full')) {
    expect(q.isFull(), expected['is_full'], reason: 'is_full mismatch');
  }
  if (expected.containsKey('closed')) {
    expect(q.isClosed(), expected['closed'], reason: 'closed mismatch');
  }
}

/// Extract the `returns` label or value from a pop/push result for fixture
/// comparison.
String _returnsLabel(QueuePopResult<String> result) {
  switch (result) {
    case QueuePopValue<String>(:final value):
      return value;
    case QueuePopFailed<String>(:final error):
      return error.label;
  }
}

/// Replay a single fixture end-to-end.
void _runFixture(String name) {
  final fixture = _loadFixture(name);
  final ctx = Context();
  final q = _buildInitial(ctx, fixture['initial'] as Map<String, dynamic>);

  final steps = (fixture['steps'] as List).cast<Map<String, dynamic>>();
  for (var i = 0; i < steps.length; i++) {
    final step = steps[i];
    final op = step['op'] as Map<String, dynamic>;
    final expected = step['expected'] as Map<String, dynamic>;
    final invalidates = (expected['invalidates'] ?? {}) as Map<String, dynamic>;

    // Prime readers from the CURRENT state so each step's invalidation is
    // measured in isolation.
    final readers = _Readers(ctx, q);

    // Apply the op.
    switch (op['type'] as String) {
      case 'push':
        final err = q.tryPush(op['value'] as String);
        expect(err, isNull, reason: '$name step $i: push should succeed');
      case 'try_push':
        q.tryPush(op['value'] as String);
      case 'pop':
      case 'try_pop':
        final result = q.tryPop();
        if (step.containsKey('returns')) {
          expect(_returnsLabel(result), equals(step['returns']),
              reason: '$name step $i: returns mismatch');
        }
      case 'close':
        q.close();
      case 'batch':
        // MPSC: multiple producers push inside one logical batch. The reactive
        // graph groups them inside Context.batch via _syncContent; the fixture's
        // expected invalidates reflects the net change across the whole batch.
        ctx.batch(() {
          for (final inner in op['ops'] as List) {
            final innerOp = inner as Map<String, dynamic>;
            expect(innerOp['type'], 'push',
                reason: '$name step $i: batch currently only wraps pushes');
            q.tryPush(innerOp['value'] as String);
          }
        });
      default:
        throw StateError('unknown queue op type: ${op['type']}');
    }

    // Assert observable state.
    _assertState(q, expected);

    // Assert per-reader-kind invalidation.
    _assertInvalidation(name, i, op['type'] as String, readers, ctx, invalidates);
  }
}

// ---------------------------------------------------------------------------
// Fixture-driven conformance — one test per queuecell_*.json
// ---------------------------------------------------------------------------

void main() {
  test('queue conformance: queuecell_spsc_push_pop.json', () {
    _runFixture('queuecell_spsc_push_pop.json');
  });

  test('queue conformance: queuecell_popped_head_observation.json', () {
    _runFixture('queuecell_popped_head_observation.json');
  });

  test('queue conformance: queuecell_mpsc_multi_writer.json', () {
    _runFixture('queuecell_mpsc_multi_writer.json');
  });

  test('queue conformance: queuecell_bounded_backpressure.json', () {
    _runFixture('queuecell_bounded_backpressure.json');
  });

  test('queue conformance: queuecell_closure_lifecycle.json', () {
    _runFixture('queuecell_closure_lifecycle.json');
  });

  // -------------------------------------------------------------------------
  // Unit tests — direct coverage of the storage adapter seam + edge cases.
  // -------------------------------------------------------------------------

  group('VecDequeStorage', () {
    test('SPSC total FIFO', () {
      final s = VecDequeStorage<String>();
      expect(s.tryPush('a'), isNull);
      expect(s.tryPush('b'), isNull);
      expect(s.peek(), 'a');
      expect(s.len(), 2);
      expect((s.tryPop() as QueuePopValue).value, 'a');
      expect((s.tryPop() as QueuePopValue).value, 'b');
      expect((s.tryPop() as QueuePopFailed).error, QueuePopError.empty);
      expect(s.peek(), isNull);
    });

    test('bounded reject-at-capacity', () {
      final s = VecDequeStorage<int>.bounded(2);
      expect(s.capacity(), 2);
      expect(s.tryPush(1), isNull);
      expect(s.tryPush(2), isNull);
      expect(s.tryPush(3), QueuePushError.full);
      expect((s.tryPop() as QueuePopValue).value, 1);
      expect(s.tryPush(3), isNull);
      expect((s.tryPop() as QueuePopValue).value, 2);
      expect((s.tryPop() as QueuePopValue).value, 3);
    });

    test('zero capacity is rejected', () {
      expect(() => VecDequeStorage<int>.bounded(0), throwsArgumentError);
    });
  });

  group('QueueCell', () {
    test('closure drains then Closed-distinct-from-Empty', () {
      final ctx = Context();
      final q = QueueCell<String>.unbounded(ctx);

      q.tryPush('a');
      q.tryPush('b');

      // close → only `closed` reader invalidated.
      final closedReaders = _Readers(ctx, q);
      q.close();
      expect(_isWarm(closedReaders.head, ctx), isTrue);
      expect(_isWarm(closedReaders.len, ctx), isTrue);
      expect(_isWarm(closedReaders.isEmpty, ctx), isTrue);
      expect(_isWarm(closedReaders.isFull, ctx), isTrue);
      expect(_isWarm(closedReaders.isClosed, ctx), isFalse);

      // push on closed is an error, no invalidation.
      final afterCloseReaders = _Readers(ctx, q);
      final rejected = q.tryPush('c');
      expect(rejected, QueuePushError.closed);
      expect(_isWarm(afterCloseReaders.head, ctx), isTrue);
      expect(_isWarm(afterCloseReaders.len, ctx), isTrue);
      expect(_isWarm(afterCloseReaders.isClosed, ctx), isTrue);

      // pop on closed+non-empty drains.
      expect((q.tryPop() as QueuePopValue).value, 'a');
      expect((q.tryPop() as QueuePopValue).value, 'b');
      // pop on closed+empty returns Closed (distinct from Empty).
      expect((q.tryPop() as QueuePopFailed).error, QueuePopError.closed);

      // idempotent close — no-op, no invalidation.
      final idemReaders = _Readers(ctx, q);
      q.close();
      expect(_isWarm(idemReaders.isClosed, ctx), isTrue);
    });

    test('bounded backpressure flips is_full both ways', () {
      final ctx = Context();
      final q = QueueCell<int>.bounded(ctx, 1);
      expect(q.isFull(), isFalse);

      // Push to capacity flips is_full true.
      final pushReaders = _Readers(ctx, q);
      q.tryPush(1);
      expect(_isWarm(pushReaders.isFull, ctx), isFalse); // invalidated
      expect(q.isFull(), isTrue);

      // Push at capacity → Full, no invalidation.
      final fullReaders = _Readers(ctx, q);
      final full = q.tryPush(2);
      expect(full, QueuePushError.full);
      expect(_isWarm(fullReaders.isFull, ctx), isTrue); // not invalidated

      // Pop off capacity → is_full flips false (backpressure recovery).
      final popReaders = _Readers(ctx, q);
      expect((q.tryPop() as QueuePopValue).value, 1);
      expect(_isWarm(popReaders.isFull, ctx), isFalse); // invalidated
      expect(q.isFull(), isFalse);
    });

    test('reader-kind independence — push to non-empty spares head', () {
      final ctx = Context();
      final q = QueueCell<String>.unbounded(ctx);

      q.tryPush('a');

      // Push to non-empty: head NOT invalidated.
      final readers2 = _Readers(ctx, q);
      q.tryPush('b');
      expect(_isWarm(readers2.head, ctx), isTrue); // not invalidated
      expect(_isWarm(readers2.len, ctx), isFalse); // invalidated

      // Another push: head still not invalidated.
      final readers3 = _Readers(ctx, q);
      q.tryPush('c');
      expect(_isWarm(readers3.head, ctx), isTrue);

      // Pop changes head → invalidated.
      final popReaders = _Readers(ctx, q);
      expect((q.tryPop() as QueuePopValue).value, 'a');
      expect(_isWarm(popReaders.head, ctx), isFalse); // invalidated
    });

    test('pluggable storage via custom backend', () {
      final ctx = Context();
      final q = QueueCell<int>(
        ctx,
        _BoundedRing<int>(2),
      );
      expect(q.capacity(), 2);
      expect(q.tryPush(1), isNull);
      expect(q.tryPush(2), isNull);
      expect(q.isFull(), isTrue);
      expect(q.tryPush(3), QueuePushError.full);
      expect((q.tryPop() as QueuePopValue).value, 1);
      expect(q.isFull(), isFalse);
      expect(q.len(), 1);
      expect(q.head(), 2);
    });

    test('snapshot round-trip via VecDequeStorage.from', () {
      final ctx = Context();
      final q1 = QueueCell<String>(
        ctx,
        VecDequeStorage<String>.from(elements: ['a', 'b', 'c']),
      );
      expect(q1.elements(), equals(['a', 'b', 'c']));

      final ctx2 = Context();
      final q2 = QueueCell<String>(
        ctx2,
        VecDequeStorage<String>.from(elements: q1.elements()),
      );
      expect(q2.elements(), equals(['a', 'b', 'c']));
      expect((q2.tryPop() as QueuePopValue).value, 'a');
    });
  });
}

/// A minimal custom bounded backend proving the [QueueStorage] adapter seam.
class _BoundedRing<T> implements QueueStorage<T> {
  _BoundedRing(this.cap);

  final List<T> _buf = [];
  final int cap;
  bool _closed = false;

  @override
  QueuePushError? tryPush(T value) {
    if (_closed) return QueuePushError.closed;
    if (_buf.length >= cap) return QueuePushError.full;
    _buf.add(value);
    return null;
  }

  @override
  QueuePopResult<T> tryPop() {
    if (_buf.isNotEmpty) return QueuePopValue<T>(_buf.removeAt(0));
    return QueuePopFailed<T>(
      _closed ? QueuePopError.closed : QueuePopError.empty,
    );
  }

  @override
  T? peek() => _buf.isNotEmpty ? _buf.first : null;

  @override
  int len() => _buf.length;

  @override
  int? capacity() => cap;

  @override
  bool isClosed() => _closed;

  @override
  void close() => _closed = true;
}
