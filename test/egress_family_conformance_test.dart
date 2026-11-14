/// The transport-agnostic egress contract (`#lzegress`), replayed against
/// **every flavor this binding ships** — `EgressCell` / `ThreadSafeEgressCell` /
/// `AsyncEgressCell`, matching the three coverage rows `reactive-egress`,
/// `egress-thread-safe`, and `egress-async`.
///
/// Mirrors `ingress_family_conformance_test.dart`, and keeps the same three
/// guards against reporting green while testing nothing:
///
///  * The ledger test greps `lib/` for each flavor's class declaration, in both
///    directions, so a row claimed shipped whose class is gone fails.
///  * Every replay counts the steps it EXECUTED inside the loop and compares
///    that against the steps it LOADED; an unknown op type throws instead of
///    skipping, and a missing fixture fails rather than skips
///    (`specFamilyDir` throws on an absent corpus, `_fixture` asserts the file).
///  * `invalidates` is asserted in BOTH directions through a cache-validity
///    probe per reader kind (`Context.contains` / `AsyncContext.isSet`). Every
///    reader is warmed and the warmth is ASSERTED before each step, so a
///    `false` expectation cannot pass vacuously on a reader that was already
///    cold.
///
/// Each step's `expected` block is consumed WHOLE with [assertBlock]: the run
/// builds the full projected state plus the observed invalidation set, and the
/// two are deep-equalled, so a key the fixture adds and a key the run invents
/// each fail.
library;

import 'dart:convert';
import 'dart:io';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

/// Every fixture the egress corpus ships for `EgressCore`. Named explicitly: a
/// fixture added to the corpus and not here is a missing replay, which the
/// conformance-coverage guard reports.
const _fixtures = [
  'egress_ordered_ack.json',
  'egress_inflight_window.json',
  'egress_retry_budget.json',
  'egress_generation_fence.json',
];

enum _Flavor { singleThreaded, threadSafe, async }

extension on _Flavor {
  String get label => switch (this) {
        _Flavor.singleThreaded => 'single-threaded',
        _Flavor.threadSafe => 'thread-safe',
        _Flavor.async => 'async',
      };

  /// The class declaration whose presence in `lib/` proves the claim.
  String get marker => switch (this) {
        _Flavor.singleThreaded => 'class EgressCell',
        _Flavor.threadSafe => 'class ThreadSafeEgressCell',
        _Flavor.async => 'class AsyncEgressCell',
      };
}

const _ledger = <({String primitive, _Flavor flavor, bool shipped})>[
  (primitive: 'EgressCell', flavor: _Flavor.singleThreaded, shipped: true),
  (primitive: 'EgressCell', flavor: _Flavor.threadSafe, shipped: true),
  (primitive: 'EgressCell', flavor: _Flavor.async, shipped: true),
];

// ---------------------------------------------------------------------------
// Corpus loading
// ---------------------------------------------------------------------------

Directory _fixtureDir() => specFamilyDir('egress');

Map<String, dynamic> _fixture(String name) {
  final file = File('${_fixtureDir().path}/$name');
  expect(file.existsSync(), isTrue, reason: '$name is declared but absent');
  return attributeFixture(jsonDecode(file.specReadAsStringSync()))
      as Map<String, dynamic>;
}

String _sources() {
  final out = StringBuffer();
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      out.write(entity.readAsStringSync());
    }
  }
  return out.toString();
}

int _corpusStepTotal() {
  var total = 0;
  for (final name in _fixtures) {
    total += (_fixture(name)['steps'] as List).length;
  }
  return total;
}

EgressPolicy _policy(Map<String, dynamic> raw) => EgressPolicy(
      inflightLimit: raw['inflight_limit'] as int,
      retryBudget: raw['retry_budget'] as int,
      retryBase: raw['retry_base'] as int,
      retryCeiling: raw['retry_ceiling'] as int,
    );

// ---------------------------------------------------------------------------
// The flavor-neutral model
// ---------------------------------------------------------------------------

abstract interface class _EgressModel {
  int enqueue(int payload);
  EgressClaim<int> claim(int generation);
  EgressAck ack(int generation, int through);
  EgressFailure fail(int generation, int sequence);
  EgressRetryAction retryNow(int generation, int sequence);
  EgressReconnect reconnect(int generation);

  int get generation;
  int get nextSequence;

  /// Reactive reads; each also warms its reader's cache.
  List<EgressEnvelope<int>> pending();
  List<EgressEnvelope<int>> inflight();
  int? ackedThrough();
  EgressRetry? retry();

  /// `[pending, inflight, acked_through, retry]` cache validity. `false` means
  /// the reader is invalidated — the fixture's `invalidates: true`.
  List<bool> validity();
}

final class _SyncModel implements _EgressModel {
  _SyncModel(int generation, EgressPolicy policy)
      : ctx = Context(),
        _holder = [] {
    _holder.add(EgressCell<int>(ctx, generation, policy));
  }

  final Context ctx;
  final List<EgressCell<int>> _holder;
  EgressCell<int> get cell => _holder.first;

  @override
  int enqueue(int payload) => cell.enqueue(payload);
  @override
  EgressClaim<int> claim(int generation) => cell.claim(generation);
  @override
  EgressAck ack(int generation, int through) => cell.ack(generation, through);
  @override
  EgressFailure fail(int generation, int sequence) =>
      cell.fail(generation, sequence);
  @override
  EgressRetryAction retryNow(int generation, int sequence) =>
      cell.retryNow(generation, sequence);
  @override
  EgressReconnect reconnect(int generation) => cell.reconnect(generation);
  @override
  int get generation => cell.generation;
  @override
  int get nextSequence => cell.nextSequence;
  @override
  List<EgressEnvelope<int>> pending() => cell.pending();
  @override
  List<EgressEnvelope<int>> inflight() => cell.inflight();
  @override
  int? ackedThrough() => cell.ackedThrough();
  @override
  EgressRetry? retry() => cell.retry();
  @override
  List<bool> validity() => [
        ctx.contains(cell.pendingHandle),
        ctx.contains(cell.inflightHandle),
        ctx.contains(cell.ackedThroughHandle),
        ctx.contains(cell.retryHandle),
      ];
}

final class _ThreadSafeModel implements _EgressModel {
  _ThreadSafeModel(int generation, EgressPolicy policy)
      : ctx = ThreadSafeContext(),
        _holder = [] {
    _holder.add(ThreadSafeEgressCell<int>(ctx, generation, policy));
  }

  final ThreadSafeContext ctx;
  final List<ThreadSafeEgressCell<int>> _holder;
  ThreadSafeEgressCell<int> get cell => _holder.first;

  @override
  int enqueue(int payload) => cell.enqueue(payload);
  @override
  EgressClaim<int> claim(int generation) => cell.claim(generation);
  @override
  EgressAck ack(int generation, int through) => cell.ack(generation, through);
  @override
  EgressFailure fail(int generation, int sequence) =>
      cell.fail(generation, sequence);
  @override
  EgressRetryAction retryNow(int generation, int sequence) =>
      cell.retryNow(generation, sequence);
  @override
  EgressReconnect reconnect(int generation) => cell.reconnect(generation);
  @override
  int get generation => cell.generation;
  @override
  int get nextSequence => cell.nextSequence;
  @override
  List<EgressEnvelope<int>> pending() => cell.pending();
  @override
  List<EgressEnvelope<int>> inflight() => cell.inflight();
  @override
  int? ackedThrough() => cell.ackedThrough();
  @override
  EgressRetry? retry() => cell.retry();
  @override
  List<bool> validity() => [
        ctx.context.contains(cell.pendingHandle),
        ctx.context.contains(cell.inflightHandle),
        ctx.context.contains(cell.ackedThroughHandle),
        ctx.context.contains(cell.retryHandle),
      ];
}

final class _AsyncModel implements _EgressModel {
  _AsyncModel(int generation, EgressPolicy policy)
      : ctx = AsyncContext(),
        _holder = [] {
    _holder.add(AsyncEgressCell<int>(ctx, generation, policy));
  }

  final AsyncContext ctx;
  final List<AsyncEgressCell<int>> _holder;
  AsyncEgressCell<int> get cell => _holder.first;

  @override
  int enqueue(int payload) => cell.enqueue(payload);
  @override
  EgressClaim<int> claim(int generation) => cell.claim(generation);
  @override
  EgressAck ack(int generation, int through) => cell.ack(generation, through);
  @override
  EgressFailure fail(int generation, int sequence) =>
      cell.fail(generation, sequence);
  @override
  EgressRetryAction retryNow(int generation, int sequence) =>
      cell.retryNow(generation, sequence);
  @override
  EgressReconnect reconnect(int generation) => cell.reconnect(generation);
  @override
  int get generation => cell.generation;
  @override
  int get nextSequence => cell.nextSequence;
  @override
  List<EgressEnvelope<int>> pending() => cell.pending();
  @override
  List<EgressEnvelope<int>> inflight() => cell.inflight();
  @override
  int? ackedThrough() => cell.ackedThrough();
  @override
  EgressRetry? retry() => cell.retry();
  @override
  List<bool> validity() => [
        ctx.isSet(cell.pendingHandle),
        ctx.isSet(cell.inflightHandle),
        ctx.isSet(cell.ackedThroughHandle),
        ctx.isSet(cell.retryHandle),
      ];
}

const _builders = <_Flavor, _EgressModel Function(int, EgressPolicy)>{
  _Flavor.singleThreaded: _SyncModel.new,
  _Flavor.threadSafe: _ThreadSafeModel.new,
  _Flavor.async: _AsyncModel.new,
};

// ---------------------------------------------------------------------------
// Wire projections of what the run returned / observed
// ---------------------------------------------------------------------------

Map<String, dynamic> _envelope(EgressEnvelope<int> envelope) => {
      'generation': envelope.generation,
      'sequence': envelope.sequence,
      'attempt': envelope.attempt,
      'payload': envelope.payload,
    };

Map<String, dynamic>? _retry(EgressRetry? retry) => retry == null
    ? null
    : {
        'sequence': retry.sequence,
        'attempt': retry.attempt,
        'backoff': retry.backoff,
        'exhausted': retry.exhausted,
      };

Map<String, dynamic> _claimWire(EgressClaim<int> claim) => switch (claim) {
      EgressClaimed(:final envelope) => {
          'claim': 'claimed',
          'envelope': _envelope(envelope),
        },
      EgressClaimEmpty() => {'claim': 'empty'},
      EgressClaimWindowFull() => {'claim': 'window_full'},
      EgressClaimStaleGeneration(:final current) => {
          'claim': 'stale_generation',
          'current': current,
        },
    };

Map<String, dynamic> _ackWire(EgressAck ack) => switch (ack) {
      EgressAckAdvanced(:final through) => {
          'ack': 'advanced',
          'through': through,
        },
      EgressAckUnchanged(:final through) => {
          'ack': 'unchanged',
          'through': through,
        },
      EgressAckBeyondSent(:final nextSequence) => {
          'ack': 'beyond_sent',
          'next_sequence': nextSequence,
        },
      EgressAckStaleGeneration(:final current) => {
          'ack': 'stale_generation',
          'current': current,
        },
    };

Map<String, dynamic> _failureWire(EgressFailure failure) => switch (failure) {
      EgressFailureRetrying(:final retry) => {
          'failure': 'retrying',
          'retry': _retry(retry),
        },
      EgressFailureExhausted(:final retry) => {
          'failure': 'exhausted',
          'retry': _retry(retry),
        },
      EgressFailureUnknownSequence() => {'failure': 'unknown_sequence'},
      EgressFailureStaleGeneration(:final current) => {
          'failure': 'stale_generation',
          'current': current,
        },
    };

Map<String, dynamic> _retryActionWire(EgressRetryAction action) =>
    switch (action) {
      EgressRetryScheduled(:final sequence) => {
          'retry_action': 'scheduled',
          'sequence': sequence,
        },
      EgressRetryUnknownSequence() => {'retry_action': 'unknown_sequence'},
      EgressRetryStaleGeneration(:final current) => {
          'retry_action': 'stale_generation',
          'current': current,
        },
    };

Map<String, dynamic> _reconnectWire(EgressReconnect reconnect) =>
    switch (reconnect) {
      EgressReconnectAdvanced(:final generation, :final replayed) => {
          'reconnect': 'advanced',
          'generation': generation,
          'replayed': replayed,
        },
      EgressReconnectUnchanged(:final generation) => {
          'reconnect': 'unchanged',
          'generation': generation,
        },
      EgressReconnectStaleGeneration(:final current) => {
          'reconnect': 'stale_generation',
          'current': current,
        },
    };

Map<String, dynamic> _runOp(
        _EgressModel model, Map<String, dynamic> op, String where) =>
    switch (op['type']) {
      'enqueue' => {'sequence': model.enqueue(op['payload'] as int)},
      'claim' => _claimWire(model.claim(op['generation'] as int)),
      'ack' =>
        _ackWire(model.ack(op['generation'] as int, op['through'] as int)),
      'fail' => _failureWire(
          model.fail(op['generation'] as int, op['sequence'] as int)),
      'retry_now' => _retryActionWire(
          model.retryNow(op['generation'] as int, op['sequence'] as int)),
      'reconnect' => _reconnectWire(model.reconnect(op['generation'] as int)),
      final other => throw StateError('$where: unknown egress op `$other`'),
    };

void _materialize(_EgressModel model) {
  model.pending();
  model.inflight();
  model.ackedThrough();
  model.retry();
}

const _readerKinds = ['pending', 'inflight', 'acked_through', 'retry'];

// ---------------------------------------------------------------------------
// The replay
// ---------------------------------------------------------------------------

/// Replay one fixture against one flavor. Returns the number of steps
/// EXECUTED, counted inside the loop.
int _replay(_Flavor flavor, String name) {
  final fixture = _fixture(name);
  expect(fixture['kind'], 'Egress', reason: '$name: fixture kind');
  expect(fixture['model'], 'EgressCore', reason: '$name: fixture model');
  final steps = (fixture['steps'] as List).cast<Map<String, dynamic>>();
  expect(steps, isNotEmpty,
      reason: '$name has zero steps; loading it is not a replay');

  final model = _builders[flavor]!(
    fixture['generation'] as int,
    _policy(fixture['policy'] as Map<String, dynamic>),
  );
  _materialize(model);

  var executed = 0;
  for (var i = 0; i < steps.length; i++) {
    final step = steps[i];
    final op = step['op'] as Map<String, dynamic>;
    final where = '${flavor.label} $name step $i (${op['type']})';

    final before = model.validity();
    expect(before, everyElement(isTrue),
        reason: '$where: priming left a reader cold, so this step\'s '
            'invalidation probe would be vacuous');

    final returned = _runOp(model, op, where);
    expect(returned, equals(step['returns']), reason: '$where: returned');

    // Probe validity BEFORE reading any projection: a read re-warms the cache
    // and would erase the invalidation being measured.
    final after = model.validity();
    final observed = <String, dynamic>{
      'generation': model.generation,
      'next_sequence': model.nextSequence,
      'pending': model.pending().map(_envelope).toList(),
      'inflight': model.inflight().map(_envelope).toList(),
      'acked_through': model.ackedThrough(),
      'retry': _retry(model.retry()),
      'invalidates': {
        for (var k = 0; k < _readerKinds.length; k++)
          _readerKinds[k]: before[k] && !after[k],
      },
    };
    assertBlock(step['expected'], observed, '$name steps[$i].expected',
        '$where: projected state and invalidation set');
    _materialize(model);
    executed++;
  }

  expect(executed, equals(steps.length),
      reason: '$name: loaded ${steps.length} steps but executed $executed');
  return executed;
}

// ---------------------------------------------------------------------------
// Transport attachment fixtures (unit coverage beside the corpus)
// ---------------------------------------------------------------------------

final class _RecordingTransport implements EgressTransport<int> {
  final sent = <int>[];
  var failNext = false;

  @override
  bool send(EgressEnvelope<int> envelope) {
    if (failNext) {
      failNext = false;
      return false;
    }
    sent.add(envelope.sequence);
    return true;
  }
}

final class _AsyncRecordingTransport implements AsyncEgressTransport<int> {
  final sent = <int>[];

  @override
  Future<bool> send(EgressEnvelope<int> envelope) async {
    await Future<void>.delayed(Duration.zero);
    sent.add(envelope.sequence);
    return true;
  }
}

/// Settle every microtask and zero-duration timer the async attachment queued.
Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

// ---------------------------------------------------------------------------
// The gates
// ---------------------------------------------------------------------------

void main() {
  test('the egress corpus is present and non-trivial', () {
    for (final name in _fixtures) {
      expect(File('${_fixtureDir().path}/$name').existsSync(), isTrue,
          reason: '$name is declared but absent');
      expect((_fixture(name)['steps'] as List), isNotEmpty,
          reason: '$name: a fixture with no steps is a vacuous replay');
    }
    // No hard-coded step floor (#lzcorpusfloorguard): the per-flavor tests
    // compare EXECUTED against LOADED exactly, and corpus shrinkage is guarded
    // by lazily-spec's corpus-counts.json.
    expect(_corpusStepTotal(), greaterThan(0));
  });

  test('the egress ledger names three shipped flavors, in both directions', () {
    final sources = _sources();
    expect(sources, isNotEmpty,
        reason: 'source ledger read nothing and would be vacuous');
    expect(_ledger.map((row) => row.flavor).toSet(), _Flavor.values.toSet());
    for (final row in _ledger) {
      final defined = sources.contains(row.flavor.marker);
      expect(defined, row.shipped,
          reason: 'ledger row `${row.primitive}/${row.flavor.label}` claims '
              'shipped=${row.shipped} but `${row.flavor.marker}` '
              'defined=$defined');
    }
  });

  for (final flavor in _Flavor.values) {
    test('EgressCore canonical corpus (${flavor.label})', () {
      var steps = 0;
      for (final name in _fixtures) {
        steps += _replay(flavor, name);
      }
      expect(steps, greaterThan(0),
          reason: '${flavor.label} replayed zero steps');
      expect(steps, _corpusStepTotal(),
          reason: 'every corpus step must run against the ${flavor.label} '
              'flavor');
    });
  }

  /// The corpus asserts NEGATIVE invalidation, so the probe must be able to
  /// fail: a read warms the cache, an enqueue dirties only `pending`.
  for (final flavor in _Flavor.values) {
    test('the invalidation probe discriminates (${flavor.label})', () {
      final model = _builders[flavor]!(1, const EgressPolicy());
      _materialize(model);
      expect(model.validity(), [true, true, true, true]);
      model.enqueue(1);
      expect(model.validity(), [false, true, true, true]);
      _materialize(model);
      model.claim(7); // stale generation: dirties nothing
      expect(model.validity(), [true, true, true, true]);
    });
  }

  group('transport attachment (single-threaded)', () {
    test('one Effect projects pending to the transport and inflight', () {
      final ctx = Context();
      final egress = EgressCell<int>(ctx, 1);
      final transport = _RecordingTransport();
      final effect = egress.attachTransport(transport);
      egress.enqueue(10);
      egress.enqueue(20);
      expect(transport.sent, [0, 1]);
      expect(egress.pending(), isEmpty);
      expect(egress.inflight().map((e) => e.sequence), [0, 1]);
      effect.dispose();
    });

    test('an acknowledgement reopens the window and re-runs the attachment',
        () {
      final ctx = Context();
      final egress =
          EgressCell<int>(ctx, 1, const EgressPolicy(inflightLimit: 1));
      final transport = _RecordingTransport();
      final effect = egress.attachTransport(transport);
      egress.enqueue(10);
      egress.enqueue(20);
      expect(transport.sent, [0]);
      expect(egress.pending(), hasLength(1));
      expect(egress.ack(1, 0), const EgressAckAdvanced(0));
      expect(transport.sent, [0, 1]);
      expect(egress.pending(), isEmpty);
      effect.dispose();
    });

    test('reconnect makes the old attachment inert; a fresh one replays', () {
      final ctx = Context();
      final egress = EgressCell<int>(ctx, 3);
      final old = _RecordingTransport();
      final oldEffect = egress.attachTransport(old);
      egress.enqueue(10);
      expect(egress.reconnect(4), const EgressReconnectAdvanced(4, 1));
      egress.enqueue(20);
      expect(old.sent, [0], reason: 'the fenced attachment must not send');
      final fresh = _RecordingTransport();
      final freshEffect = egress.attachTransport(fresh);
      expect(fresh.sent, [0, 1],
          reason: 'the replacement replays the retained pending projection');
      // The fresh attachment must still be subscribed after its first run.
      egress.enqueue(30);
      expect(fresh.sent, [0, 1, 2]);
      expect(old.sent, [0]);
      oldEffect.dispose();
      freshEffect.dispose();
    });

    test('a failed send parks the record instead of spinning', () {
      final ctx = Context();
      final egress = EgressCell<int>(ctx, 1);
      final transport = _RecordingTransport()..failNext = true;
      final effect = egress.attachTransport(transport);
      egress.enqueue(10);
      expect(transport.sent, isEmpty);
      expect(
          egress.retry(),
          const EgressRetry(
              sequence: 0, attempt: 1, backoff: 10, exhausted: false));
      expect(egress.pending(), isEmpty);
      expect(egress.retryNow(1, 0), const EgressRetryScheduled(0));
      expect(transport.sent, [0],
          reason: 'rescheduling re-runs the attachment');
      effect.dispose();
    });
  });

  test('transport attachment (thread-safe) drives the shared projection', () {
    final ctx = ThreadSafeContext();
    final egress = ThreadSafeEgressCell<int>(ctx, 1);
    final transport = _RecordingTransport();
    final effect = egress.attachTransport(transport);
    egress.enqueue(7);
    expect(transport.sent, [0]);
    expect(egress.inflight(), hasLength(1));
    effect.dispose();
  });

  test('transport attachment (async) drives the projection asynchronously',
      () async {
    final ctx = AsyncContext();
    final egress = AsyncEgressCell<int>(ctx, 1);
    final transport = _AsyncRecordingTransport();
    final effect = egress.attachTransport(transport);
    egress.enqueue(7);
    egress.enqueue(8);
    await _settle();
    expect(transport.sent, [0, 1]);
    expect(egress.inflight(), hasLength(2));
    expect(egress.reconnect(2), const EgressReconnectAdvanced(2, 2));
    egress.enqueue(9);
    await _settle();
    expect(transport.sent, [0, 1], reason: 'the fenced attachment is inert');
    final fresh = _AsyncRecordingTransport();
    final freshEffect = egress.attachTransport(fresh);
    await _settle();
    expect(fresh.sent, [0, 1, 2]);
    await effect.disposeAsync();
    await freshEffect.disposeAsync();
  });

  /// Corpus gap, pinned here: no canonical fixture acknowledges a sequence that
  /// is still PENDING, so the cumulative ACK's pending-pruning arm was a
  /// surviving mutant under the corpus alone. A reconnect replays an in-flight
  /// record back to pending; a late cumulative ACK covering it must prune it
  /// there too, and say so through the `pending` reader.
  for (final flavor in _Flavor.values) {
    test('a cumulative ACK prunes replayed pending records (${flavor.label})',
        () {
      final model = _builders[flavor]!(1, const EgressPolicy());
      model.enqueue(10);
      model.enqueue(20);
      model.claim(1);
      expect(model.reconnect(2), const EgressReconnectAdvanced(2, 1));
      expect(model.pending().map((e) => e.sequence), [0, 1]);
      _materialize(model);
      expect(model.ack(2, 0), const EgressAckAdvanced(0));
      expect(model.validity(), [false, true, false, true],
          reason: 'pruning a pending record invalidates `pending` only '
              'beside the watermark');
      expect(model.pending().map((e) => e.sequence), [1]);
      expect(model.inflight(), isEmpty);
      expect(model.ackedThrough(), 0);
    });
  }

  /// Fix 1 unit pin: an ACK at or beyond `nextSequence` acknowledges data
  /// never assigned. It is refused without moving the watermark or dirtying a
  /// reader, so the record enqueued next is still deliverable.
  for (final flavor in _Flavor.values) {
    test('an ACK beyond the sent range is refused (${flavor.label})', () {
      final model = _builders[flavor]!(1, const EgressPolicy());
      model.enqueue(10);
      model.claim(1);
      _materialize(model);
      expect(model.ack(1, 1), const EgressAckBeyondSent(1));
      expect(model.ack(1, 7), const EgressAckBeyondSent(1));
      expect(model.validity(), [true, true, true, true],
          reason: 'a refused ACK invalidates nothing');
      expect(model.ackedThrough(), isNull);
      expect(model.enqueue(20), 1);
      expect(model.ack(1, 0), const EgressAckAdvanced(0));
      expect(model.claim(1), isA<EgressClaimed<int>>(),
          reason: 'the next record was not stranded below the watermark');
    });
  }

  /// Fix 2 unit pin: a reconnect that replays nothing still rewrites every
  /// retained never-claimed envelope to the new generation, so `pending` must
  /// be invalidated or a reader keeps serving stale-generation envelopes.
  for (final flavor in _Flavor.values) {
    test(
        'a reconnect with nothing to replay refreshes pending (${flavor.label})',
        () {
      final model = _builders[flavor]!(1, const EgressPolicy());
      model.enqueue(10);
      _materialize(model);
      expect(model.reconnect(2), const EgressReconnectAdvanced(2, 0));
      expect(model.validity(), [false, true, true, true]);
      expect(model.pending().single.generation, 2);
      _materialize(model);
      final empty = _builders[flavor]!(1, const EgressPolicy());
      _materialize(empty);
      expect(empty.reconnect(2), const EgressReconnectAdvanced(2, 0));
      expect(empty.validity(), [true, true, true, true],
          reason: 'with nothing retained the projection did not change');
    });
  }

  test('a policy no core can honour is refused', () {
    expect(() => EgressCore<int>(1, const EgressPolicy(inflightLimit: 0)),
        throwsA(isA<EgressConfigException>()));
    expect(() => EgressCore<int>(1, const EgressPolicy(retryBase: 0)),
        throwsA(isA<EgressConfigException>()));
    expect(
        () => EgressCore<int>(
            1, const EgressPolicy(retryBase: 10, retryCeiling: 5)),
        throwsA(isA<EgressConfigException>()));
  });

  test('backoff doubles and saturates at the ceiling', () {
    final core = EgressCore<int>(1,
        const EgressPolicy(retryBudget: 100, retryBase: 3, retryCeiling: 20));
    core.enqueue(1);
    final backoffs = <int>[];
    for (var i = 0; i < 6; i++) {
      core.claim(1);
      final (_, failure) = core.fail(1, 0);
      backoffs.add((failure as EgressFailureRetrying).retry.backoff);
      core.retryNow(1, 0);
    }
    expect(backoffs, [3, 6, 12, 20, 20, 20]);
  });
}
