import 'dart:convert';
import 'dart:io';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

/// Reactive queue conformance (lazily-spec/conformance/collections/).
///
/// Replays the canonical `queuecell_*.json` fixtures every binding replays,
/// asserting observable state and the per-reader-kind invalidation matrix
/// using the live reactive graph: readers are primed as [Slot]s, and
/// invalidation is observed via `ctx.contains(reader)` (warm = not
/// invalidated, evicted = invalidated). Mirrors `lazily-kt`'s
/// `QueueCellConformanceTest` and `lazily-js`'s `queue.test.js`.

/// This runner's slice of the shared corpus. Root resolution — the
/// `LAZILY_SPEC_CONFORMANCE_DIR` override, the sibling-first-then-mirror
/// ordering, and the fail-closed behaviour when an explicit override cannot be
/// read — lives in `conformance_manifest.dart`, so every runner and the
/// coverage guard auditing them resolve ONE corpus (#lzoverrideallrunners).
const _family = 'collections';

String _fixturePath(String name) => specFixturePath('$_family/$name');

Map<String, dynamic> _loadFixture(String name) => attributeFixture(
        jsonDecode(File(_fixturePath(name)).specReadAsStringSync()))
    as Map<String, dynamic>;

/// Build a QueueCell from the fixture's `initial` block.
QueueCell<String> _buildInitial(
  Context ctx,
  String name,
  Map<String, dynamic> initial,
) {
  final elements = (initial['elements'] as List?)?.cast<String>() ?? const [];
  final capacity = initial['capacity'] as int?;
  // `flagAt`, not `(initial['closed'] as bool?) ?? false`
  // (`#lzsiblingrunnermasking`). The cast form was SAFE as spelled — `as bool?`
  // throws on a String, so only ABSENCE defaulted — but it is the same shape
  // the coercion audit had to reason about one site at a time, and leaving one
  // legitimate instance standing is what lets the next copy reach for it.
  // `flagAt` is that exact contract by name: absent or null means false, a
  // present non-boolean is a named refusal. The spelling is now unused across
  // the whole suite, which is what `scripts/check-conformance-coverage.sh`'s
  // flag-hygiene rung needs in order to ban it with no allowlist.
  final closed = flagAt(initial, 'closed', '$name initial');
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
      : head = Slot<Object?>(ctx, (cx) => q.head(cx))..call(),
        len = Slot<int>(ctx, (cx) => q.len(cx))..call(),
        isEmpty = Slot<bool>(ctx, (cx) => q.isEmpty(cx))..call(),
        isFull = Slot<bool>(ctx, (cx) => q.isFull(cx))..call(),
        isClosed = Slot<bool>(ctx, (cx) => q.isClosed(cx))..call();

  final Slot<Object?> head;
  final Slot<int> len;
  final Slot<bool> isEmpty;
  final Slot<bool> isFull;
  final Slot<bool> isClosed;
}

/// Assert per-reader-kind invalidation. A reader kind explicitly present in the
/// fixture's `invalidates` map is asserted; absent kinds are not asserted
/// (fixtures that focus on one reader kind only declare that one).
/// The matrix is consumed through the child tracker (`#lzsubblockkeyset`):
/// checking five named reader kinds and returning left a sixth key added to
/// `invalidates` upstream compared by nothing, while every scalar sibling of
/// `invalidates` reddened. [assertKeysOf] bounds the key set by the readers
/// this runner really primes and asserts every key the fixture does name.
void _assertInvalidation(
  String name,
  int stepIndex,
  String opType,
  _Readers readers,
  Context ctx,
  Map<String, dynamic> expected,
) {
  final byKind = <String, Slot<dynamic>>{
    'head': readers.head,
    'len': readers.len,
    'is_empty': readers.isEmpty,
    'is_full': readers.isFull,
    'closed': readers.isClosed,
  };
  // REQUIRED, not `assertKeysOfIfPresent` (`#lzsiblingrunnermasking`).
  // `queue_family_conformance_test` replays all five of these fixtures and
  // refuses a step whose `expected` carries no matrix at all; this runner made
  // the whole matrix optional, so a step that lost `invalidates` upstream — or
  // moved it back to step level, the misplacement the family runner names —
  // asserted NO invalidation here and reported green. The coverage was an
  // accident of the family runner existing, and every step of all five
  // fixtures carries the key.
  assertKeysOf(expected, 'invalidates', byKind.keys, (kind, want) {
    final warm = _isWarm(byKind[kind]!, ctx);
    // Inverted, so type-strict `assertKey` equality is unavailable and the flag
    // is required by type instead (`#lzflagcoercion`): `want != true` read
    // every non-boolean as "not invalidated", so a fixture spelling
    // `"head": "true"` against a step that really left the head reader warm
    // passed while asserting the opposite.
    expect(warm,
        !flagOf(want, '$name step $stepIndex `$opType` invalidates.$kind'),
        reason: '$name step $stepIndex `$opType` reader `$kind`: '
            'expected invalidated=$want (warm=$warm)');
  },
      reason: '$name step $stepIndex `$opType`: `invalidates` names a reader '
          'kind this runner never primes');
}

/// Assert observable queue state (only fields present in `expected`).
void _assertState(
  QueueCell<String> q,
  Map<String, dynamic> expected,
) {
  assertKeyIfPresent(expected, 'elements', (v) {
    expect(q.elements(), equals((v as List).cast<String>()),
        reason: 'elements mismatch');
  });
  assertKeyIfPresent(expected, 'head',
      (v) => expect(q.head(), equals(v), reason: 'head mismatch'));
  assertKeyIfPresent(
      expected, 'len', (v) => expect(q.len(), v, reason: 'len mismatch'));
  assertKeyIfPresent(expected, 'is_empty',
      (v) => expect(q.isEmpty(), v, reason: 'is_empty mismatch'));
  assertKeyIfPresent(expected, 'is_full',
      (v) => expect(q.isFull(), v, reason: 'is_full mismatch'));
  assertKeyIfPresent(expected, 'closed',
      (v) => expect(q.isClosed(), v, reason: 'closed mismatch'));
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
  final q =
      _buildInitial(ctx, name, fixture['initial'] as Map<String, dynamic>);

  final steps = (fixture['steps'] as List).cast<Map<String, dynamic>>();
  // VACUITY FLOOR + the misplacement guard, carried locally rather than
  // borrowed from the sibling runner (`#lzsiblingrunnermasking`).
  // `queue_family_conformance_test` replays all five of these fixtures and
  // already refuses a zero-step fixture and a step that puts `invalidates` at
  // step level instead of under `expected`. This runner refused neither, so
  // both defects were caught only because that runner exists — and its
  // `invalidates` checks are the ones this runner duplicates, so a split or a
  // rename takes the floor away with it.
  expect(steps, isNotEmpty,
      reason: '$name has no steps - loading a fixture is not replaying it, '
          'and a zero-step replay reports green having compared nothing');
  for (var i = 0; i < steps.length; i++) {
    final step = steps[i];
    expect(step.containsKey('invalidates'), isFalse,
        reason: '$name step $i puts `invalidates` at step level; the canonical '
            'location is `expected.invalidates`, and a matrix this runner '
            'never descends into is a matrix nothing compares');
    final op = step['op'] as Map<String, dynamic>;
    final expected = assertionsOf(step['expected']);

    // Prime readers from the CURRENT state so each step's invalidation is
    // measured in isolation.
    final readers = _Readers(ctx, q);

    // Apply the op, and produce the step's RETURN LABEL whatever the op was.
    //
    // `returns` used to be compared inside the pop/try_pop arm only
    // (`#lzsiblingrunnermasking`), so the two `try_push` steps that carry it —
    // `queuecell_bounded_backpressure` step 2 (`Full`) and
    // `queuecell_closure_lifecycle` step 6 (`Closed`) — were read by NOTHING
    // in this runner. They are asserted in `queue_family_conformance_test`,
    // which computes the label for every op type, so the corpus' backpressure
    // and post-close refusal labels were covered here purely by that runner's
    // existence. Same label expression as the family runner, hoisted out of
    // the switch so an op type that grows a `returns` cannot go unread.
    final Object? returns;
    switch (op['type'] as String) {
      case 'push':
        final err = q.tryPush(op['value'] as String);
        expect(err, isNull, reason: '$name step $i: push should succeed');
        returns = err?.label ?? 'Ok';
      case 'try_push':
        returns = q.tryPush(op['value'] as String)?.label ?? 'Ok';
      case 'pop':
      case 'try_pop':
        returns = _returnsLabel(q.tryPop());
      case 'close':
        q.close();
        returns = null;
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
        returns = null;
      default:
        throw StateError('unknown queue op type: ${op['type']}');
    }

    if (step.containsKey('returns')) {
      expect(returns, equals(step['returns']),
          reason: '$name step $i `${op['type']}`: returns mismatch');
    }

    // Assert observable state.
    _assertState(q, expected);

    // Assert per-reader-kind invalidation.
    _assertInvalidation(name, i, op['type'] as String, readers, ctx, expected);
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

  // Minimal contract (Phase 0, #relaycell): a raw-channel-style backend with
  // only tryPush/tryPop/len/isClosed/close — the default (absent) peek/capacity
  // — is fully conforming, with no head reader and never full.
  group('minimal contract (raw channel)', () {
    test('conforms with no peek / no capacity', () {
      final ctx = Context();
      final q = QueueCell<int>(ctx, _MinimalFifo<int>());

      expect(q.isEmpty(), isTrue);
      expect(q.tryPush(1), isNull);
      expect(q.tryPush(2), isNull);
      expect(q.len(), 2);

      // No peek → head is null; no capacity → never full.
      expect(q.head(), isNull);
      expect(q.isFull(), isFalse);
      expect(q.capacity(), isNull);

      expect((q.tryPop() as QueuePopValue).value, 1);
      expect((q.tryPop() as QueuePopValue).value, 2);
      expect(q.isEmpty(), isTrue);

      q.close();
      expect(q.isClosed(), isTrue);
      expect(q.tryPush(3), QueuePushError.closed);
      expect(q.tryPop(), isA<QueuePopFailed>());
    });

    test('reader-kinds stay reactive without peek', () {
      final ctx = Context();
      final q = QueueCell<int>(ctx, _MinimalFifo<int>());
      final log = <int>[];
      Effect(ctx, (cx) {
        log.add(q.len(cx));
        return null;
      });

      expect(log, equals([0]));
      q.tryPush(10);
      expect(log, equals([0, 1]));
      q.tryPop();
      expect(log, equals([0, 1, 0]));
    });
  });
}

/// A raw-channel-style backend implementing ONLY the required contract. Uses
/// `extends` (not `implements`) to inherit the default (absent) peek/capacity.
class _MinimalFifo<T> extends QueueStorage<T> {
  final List<T> _buf = [];
  bool _closed = false;

  @override
  QueuePushError? tryPush(T value) {
    if (_closed) return QueuePushError.closed;
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
  int len() => _buf.length;

  @override
  bool isClosed() => _closed;

  @override
  void close() => _closed = true;
  // NB: no peek(), no capacity() — the QueueStorage defaults apply.
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
