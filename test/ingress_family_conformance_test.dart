/// The transport-agnostic ingress contract (`#designimplementtransport`),
/// replayed against **every flavor this binding ships** — with a ledger that is
/// *enforced* rather than advisory.
///
/// lazily-dart ships all three: `IngressCell` / `ThreadSafeIngressCell` /
/// `AsyncIngressCell`, matching the three coverage rows and the contract
/// `lazily-spec/docs/transport-ingress.md` declares REQUIRED of every binding ×
/// every flavor.
///
/// The flavor axis lives in the **runner**, not the corpus: the fixtures carry a
/// `model` field naming the primitive and no execution-model field, and one
/// [_IngressModel] interface replays the same JSON against each shell. Nothing
/// in the interface is async-coloured, which is the finding rather than an
/// oversight — an admission decision is a function of the fence, the watermark,
/// the reorder buffer, and the observed clock, so there is nothing to await and
/// no `settle` step anywhere below.
///
/// Three things keep this suite from reporting green while testing nothing —
/// each one a failure mode this family of suites has actually shipped:
///
///  * The ledger test greps `lib/` for each flavor's class declaration, in
///    **both** directions. A row marked shipped whose class does not exist
///    fails; a class that exists while its row says unshipped fails and names
///    the runner to extend. The ledger cannot rot, because the filesystem
///    enforces it.
///  * Every replay returns its step count, and every flavor asserts that count
///    is non-zero and equal to the corpus total. An absence guard proves the
///    fixtures exist on disk; only a positive count proves this process opened
///    them (and `specReadAsStringSync` records the read for the coverage guard).
///  * `invalidates` is asserted in **both** directions through a cache-validity
///    probe per reader kind. A step expecting `false` fails if the shell
///    invalidated anyway, so over-invalidation is as visible as under-. It is
///    asserted per CHANNEL and never by receipt count: a stale cache recomputes
///    to the right count, so a count-only gate reports green.
///
/// Every gate below was mutation-checked; the file tail lists the seven probes
/// and what each one turned red.
library;

import 'dart:convert';
import 'dart:io';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

/// Every fixture the ingress corpus ships. Named explicitly rather than globbed:
/// a fixture added to the corpus and not to this list is a *missing replay*, and
/// the conformance-coverage guard is what should notice, not a silently shorter
/// run.
const _fixtures = [
  'ingress_ordered_delivery.json',
  'ingress_reorder_and_duplication.json',
  'ingress_reorder_window_overflow.json',
  'ingress_disconnect_replay.json',
  'ingress_backpressure.json',
  'ingress_generation_handoff.json',
  'ingress_freshness_and_retry.json',
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
        _Flavor.singleThreaded => 'class IngressCell',
        _Flavor.threadSafe => 'class ThreadSafeIngressCell',
        _Flavor.async => 'class AsyncIngressCell',
      };
}

/// One ledger row per (primitive, flavor) pair this binding claims.
const _ledger = <({String primitive, _Flavor flavor, bool shipped})>[
  (primitive: 'IngressCell', flavor: _Flavor.singleThreaded, shipped: true),
  (primitive: 'IngressCell', flavor: _Flavor.threadSafe, shipped: true),
  (primitive: 'IngressCell', flavor: _Flavor.async, shipped: true),
];

// ---------------------------------------------------------------------------
// Corpus loading
// ---------------------------------------------------------------------------

Directory _fixtureDir() {
  for (final path in [
    '../lazily-spec/conformance/ingress',
    'test/conformance/ingress',
  ]) {
    final dir = Directory(path);
    if (dir.existsSync()) return dir;
  }
  throw StateError(
    'canonical ingress corpus is absent; a skipped flavor replay would report '
    'a false green',
  );
}

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

// ---------------------------------------------------------------------------
// Fixture decoding
// ---------------------------------------------------------------------------

Overflow _overflow(String text) => switch (text) {
      'block' => Overflow.block,
      'drop_newest' => Overflow.dropNewest,
      'drop_oldest' => Overflow.dropOldest,
      'conflate' => Overflow.conflate,
      'spill' => Overflow.spill,
      _ => throw StateError('unknown overflow `$text`'),
    };

IngressTransportKind _transport(String text) => switch (text) {
      'event_channel' => IngressTransportKind.eventChannel,
      'rpc_triggered' => IngressTransportKind.rpcTriggered,
      'bounded_polling' => IngressTransportKind.boundedPolling,
      _ => throw StateError('unknown transport `$text`'),
    };

MergePolicy<int> _merge(String text) => switch (text) {
      'sum' => sum(),
      'keep_latest' => keepLatest<int>(),
      'max' => max(),
      _ => throw StateError('unknown merge `$text`'),
    };

IngressError _error(String text) => IngressError.values.firstWhere(
      (value) => value.wire == text,
      orElse: () => throw StateError('unknown error `$text`'),
    );

IngressDropReason _dropReason(String text) =>
    IngressDropReason.values.firstWhere(
      (value) => value.wire == text,
      orElse: () => throw StateError('unknown drop reason `$text`'),
    );

IngressLifecycle _lifecycle(String text) => IngressLifecycle.values.firstWhere(
      (value) => value.wire == text,
      orElse: () => throw StateError('unknown lifecycle `$text`'),
    );

IngressReadiness _readiness(String text) => IngressReadiness.values.firstWhere(
      (value) => value.wire == text,
      orElse: () => throw StateError('unknown readiness `$text`'),
    );

IngressPolicy _policy(Map<String, dynamic> value) => IngressPolicy(
      reorderWindow: value['reorder_window'] as int,
      freshnessHorizon: value['freshness_horizon'] as int,
      highWater: value['high_water'] as int,
      overflow: _overflow(value['overflow'] as String),
      receiptCapacity: value['receipt_capacity'] as int,
      retryBase: value['retry_base'] as int,
      retryCeiling: value['retry_ceiling'] as int,
    );

IngressAdmission _expectedAdmission(Map<String, dynamic> value) =>
    switch (value['admission'] as String) {
      'accepted' => IngressAccepted(value['delivered_through'] as int),
      'conflated' => IngressConflated(value['delivered_through'] as int),
      'buffered' => IngressBuffered(value['gap_from'] as int),
      'generation_handoff' =>
        IngressGenerationHandoff(value['from'] as int, value['to'] as int),
      'dropped' => IngressDropped(_dropReason(value['reason'] as String)),
      'blocked' => const IngressBlocked(),
      final other => throw StateError('unknown admission `$other`'),
    };

ReplayRequest? _expectedReplay(Object? value) {
  if (value == null) return null;
  final map = value as Map<String, dynamic>;
  return ReplayRequest(
    map['generation'] as int,
    map['from_sequence'] as int,
  );
}

// ---------------------------------------------------------------------------
// The flavor-neutral model
// ---------------------------------------------------------------------------

/// What every ingress flavor must be able to do for the corpus to replay against
/// it.
///
/// The reader-kind probes (`*IsValid`) are the whole reason this is an interface
/// rather than three copies of the runner: `invalidates` is a claim about the
/// *graph*, and only the shell can answer it.
abstract interface class _IngressModel {
  void open(String key, int generation);
  IngressAdmission admit(IngressEnvelope<String, int> envelope);
  ReplayRequest? suspend(String key);
  ReplayRequest reconnect(String key, int generation);
  void close(String key);
  void fail(String key, IngressError error);
  void tick(int now);
  int? drain(String key);

  /// Reactive reads; each also materializes its reader's cache, which is what
  /// makes the next step's validity probe meaningful.
  int? value(String key);
  IngressReadiness readiness(String key);
  IngressAuthority? authority(String key);
  IngressRetry? retry(String key);
  int acceptedLen();
  int droppedLen();
  int errorsLen();
  IngressSchedule schedule();

  /// `false` when the reader is invalidated — which is what the fixture's
  /// `invalidates: true` means.
  bool valueIsValid(String key);
  bool readinessIsValid(String key);
  bool authorityIsValid(String key);
  bool retryIsValid(String key);
  bool acceptedIsValid();
  bool droppedIsValid();
  bool errorsIsValid();

  ScopeView? view(String key);
}

typedef _Build = _IngressModel Function(
  IngressPolicy policy,
  MergePolicy<int> mergePolicy,
  IngressTransportKind transport,
  int pollInterval,
);

// -- Flavor 1 — single-threaded ---------------------------------------------

final class _SyncModel implements _IngressModel {
  _SyncModel(
    IngressPolicy policy,
    MergePolicy<int> mergePolicy,
    IngressTransportKind transport,
    int pollInterval,
  )   : ctx = Context(),
        _cellHolder = [] {
    _cellHolder.add(IngressCell<String, int>(
      ctx,
      policy: policy,
      mergePolicy: mergePolicy,
      transport: transport,
      pollInterval: pollInterval,
    ));
  }

  final Context ctx;
  final List<IngressCell<String, int>> _cellHolder;

  IngressCell<String, int> get cell => _cellHolder.first;

  @override
  void open(String key, int generation) => cell.open(key, generation);
  @override
  IngressAdmission admit(IngressEnvelope<String, int> envelope) =>
      cell.admit(envelope);
  @override
  ReplayRequest? suspend(String key) => cell.suspend(key);
  @override
  ReplayRequest reconnect(String key, int generation) =>
      cell.reconnect(key, generation);
  @override
  void close(String key) => cell.close(key);
  @override
  void fail(String key, IngressError error) => cell.fail(key, error);
  @override
  void tick(int now) => cell.tick(now);
  @override
  int? drain(String key) => cell.drain(key);

  @override
  int? value(String key) => cell.value(key);
  @override
  IngressReadiness readiness(String key) => cell.readiness(key);
  @override
  IngressAuthority? authority(String key) => cell.authority(key);
  @override
  IngressRetry? retry(String key) => cell.retry(key);
  @override
  int acceptedLen() => cell.accepted().length;
  @override
  int droppedLen() => cell.dropped().length;
  @override
  int errorsLen() => cell.errors().length;
  @override
  IngressSchedule schedule() => cell.schedule();

  @override
  bool valueIsValid(String key) => ctx.contains(cell.readers(key).value);
  @override
  bool readinessIsValid(String key) =>
      ctx.contains(cell.readers(key).readiness);
  @override
  bool authorityIsValid(String key) =>
      ctx.contains(cell.readers(key).authority);
  @override
  bool retryIsValid(String key) => ctx.contains(cell.readers(key).retry);
  @override
  bool acceptedIsValid() => ctx.contains(cell.acceptedHandle);
  @override
  bool droppedIsValid() => ctx.contains(cell.droppedHandle);
  @override
  bool errorsIsValid() => ctx.contains(cell.errorsHandle);

  @override
  ScopeView? view(String key) => cell.view(key);
}

// -- Flavor 2 — thread-safe (run-to-completion guard) -----------------------

final class _ThreadSafeModel implements _IngressModel {
  _ThreadSafeModel(
    IngressPolicy policy,
    MergePolicy<int> mergePolicy,
    IngressTransportKind transport,
    int pollInterval,
  )   : ctx = ThreadSafeContext(),
        _cellHolder = [] {
    _cellHolder.add(ThreadSafeIngressCell<String, int>(
      ctx,
      policy: policy,
      mergePolicy: mergePolicy,
      transport: transport,
      pollInterval: pollInterval,
    ));
  }

  final ThreadSafeContext ctx;
  final List<ThreadSafeIngressCell<String, int>> _cellHolder;

  ThreadSafeIngressCell<String, int> get cell => _cellHolder.first;

  @override
  void open(String key, int generation) => cell.open(key, generation);
  @override
  IngressAdmission admit(IngressEnvelope<String, int> envelope) =>
      cell.admit(envelope);
  @override
  ReplayRequest? suspend(String key) => cell.suspend(key);
  @override
  ReplayRequest reconnect(String key, int generation) =>
      cell.reconnect(key, generation);
  @override
  void close(String key) => cell.close(key);
  @override
  void fail(String key, IngressError error) => cell.fail(key, error);
  @override
  void tick(int now) => cell.tick(now);
  @override
  int? drain(String key) => cell.drain(key);

  @override
  int? value(String key) => cell.value(key);
  @override
  IngressReadiness readiness(String key) => cell.readiness(key);
  @override
  IngressAuthority? authority(String key) => cell.authority(key);
  @override
  IngressRetry? retry(String key) => cell.retry(key);
  @override
  int acceptedLen() => cell.accepted().length;
  @override
  int droppedLen() => cell.dropped().length;
  @override
  int errorsLen() => cell.errors().length;
  @override
  IngressSchedule schedule() => cell.schedule();

  @override
  bool valueIsValid(String key) =>
      ctx.context.contains(cell.readers(key).value);
  @override
  bool readinessIsValid(String key) =>
      ctx.context.contains(cell.readers(key).readiness);
  @override
  bool authorityIsValid(String key) =>
      ctx.context.contains(cell.readers(key).authority);
  @override
  bool retryIsValid(String key) =>
      ctx.context.contains(cell.readers(key).retry);
  @override
  bool acceptedIsValid() => ctx.context.contains(cell.acceptedHandle);
  @override
  bool droppedIsValid() => ctx.context.contains(cell.droppedHandle);
  @override
  bool errorsIsValid() => ctx.context.contains(cell.errorsHandle);

  @override
  ScopeView? view(String key) => cell.view(key);
}

// -- Flavor 3 — async --------------------------------------------------------

final class _AsyncModel implements _IngressModel {
  _AsyncModel(
    IngressPolicy policy,
    MergePolicy<int> mergePolicy,
    IngressTransportKind transport,
    int pollInterval,
  )   : ctx = AsyncContext(),
        _cellHolder = [] {
    _cellHolder.add(AsyncIngressCell<String, int>(
      ctx,
      policy: policy,
      mergePolicy: mergePolicy,
      transport: transport,
      pollInterval: pollInterval,
    ));
  }

  final AsyncContext ctx;
  final List<AsyncIngressCell<String, int>> _cellHolder;

  AsyncIngressCell<String, int> get cell => _cellHolder.first;

  @override
  void open(String key, int generation) => cell.open(key, generation);
  @override
  IngressAdmission admit(IngressEnvelope<String, int> envelope) =>
      cell.admit(envelope);
  @override
  ReplayRequest? suspend(String key) => cell.suspend(key);
  @override
  ReplayRequest reconnect(String key, int generation) =>
      cell.reconnect(key, generation);
  @override
  void close(String key) => cell.close(key);
  @override
  void fail(String key, IngressError error) => cell.fail(key, error);
  @override
  void tick(int now) => cell.tick(now);
  @override
  int? drain(String key) => cell.drain(key);

  @override
  int? value(String key) => cell.value(key);
  @override
  IngressReadiness readiness(String key) => cell.readiness(key);
  @override
  IngressAuthority? authority(String key) => cell.authority(key);
  @override
  IngressRetry? retry(String key) => cell.retry(key);
  @override
  int acceptedLen() => cell.accepted().length;
  @override
  int droppedLen() => cell.dropped().length;
  @override
  int errorsLen() => cell.errors().length;
  @override
  IngressSchedule schedule() => cell.schedule();

  @override
  bool valueIsValid(String key) => ctx.isSet(cell.readers(key).value);
  @override
  bool readinessIsValid(String key) => ctx.isSet(cell.readers(key).readiness);
  @override
  bool authorityIsValid(String key) => ctx.isSet(cell.readers(key).authority);
  @override
  bool retryIsValid(String key) => ctx.isSet(cell.readers(key).retry);
  @override
  bool acceptedIsValid() => ctx.isSet(cell.acceptedHandle);
  @override
  bool droppedIsValid() => ctx.isSet(cell.droppedHandle);
  @override
  bool errorsIsValid() => ctx.isSet(cell.errorsHandle);

  @override
  ScopeView? view(String key) => cell.view(key);
}

const _builders = <_Flavor, _Build>{
  _Flavor.singleThreaded: _SyncModel.new,
  _Flavor.threadSafe: _ThreadSafeModel.new,
  _Flavor.async: _AsyncModel.new,
};

// ---------------------------------------------------------------------------
// The replay
// ---------------------------------------------------------------------------

/// Cache-validity snapshot of every reader kind the fixture can speak about.
final class _Validity {
  _Validity(this.scopes, this.receipts);

  /// Per-key `[value, readiness, authority, retry]`.
  final Map<String, List<bool>> scopes;

  /// `[accepted, dropped, error]`.
  final List<bool> receipts;
}

_Validity _snapshot(_IngressModel model, List<String> keys) => _Validity(
      {
        for (final key in keys)
          key: [
            model.valueIsValid(key),
            model.readinessIsValid(key),
            model.authorityIsValid(key),
            model.retryIsValid(key),
          ],
      },
      [
        model.acceptedIsValid(),
        model.droppedIsValid(),
        model.errorsIsValid(),
      ],
    );

/// Read every reader kind, so the caches are warm and the next step's validity
/// probe measures *that step's* invalidation and nothing else.
void _materialize(_IngressModel model, List<String> keys) {
  for (final key in keys) {
    model.value(key);
    model.readiness(key);
    model.authority(key);
    model.retry(key);
  }
  model.acceptedLen();
  model.droppedLen();
  model.errorsLen();
  model.schedule();
}

/// Every scope key the fixture's OPS name.
///
/// Derived from the op stream alone (`#lzsubblockkeyset`). It used to also
/// scrape `expected.scopes`, which made this population the very expectation
/// blocks it is used to bound: a scope key planted in `expected.scopes` added
/// itself to the probed set and then found itself there, and the check passed.
List<String> _keysOf(Map<String, dynamic> fixture) {
  final keys = <String>[];
  for (final raw in fixture['steps'] as List) {
    final step = raw as Map<String, dynamic>;
    final key = (step['op'] as Map<String, dynamic>)['key'];
    if (key is String && !keys.contains(key)) keys.add(key);
  }
  return keys;
}

/// Replay one fixture against one flavor. Returns the number of steps executed,
/// so a caller can prove this process actually opened the corpus.
int _replay(_Flavor flavor, String name) {
  final fixture = _fixture(name);
  expect(fixture['model'], 'IngressCell', reason: '$name: fixture model');
  final steps = (fixture['steps'] as List).cast<Map<String, dynamic>>();
  expect(steps, isNotEmpty,
      reason: '$name has zero steps; loading it is not a replay');

  final model = _builders[flavor]!(
    _policy(fixture['policy'] as Map<String, dynamic>),
    _merge(fixture['merge'] as String),
    _transport(fixture['transport'] as String),
    fixture['poll_interval'] as int,
  );

  // Every key the fixture ever mentions, so a reader exists (and is probed)
  // from the first step — an absent reader would silently pass a `false`
  // invalidation expectation.
  final keys = _keysOf(fixture);
  _materialize(model, keys);

  for (var i = 0; i < steps.length; i++) {
    final step = steps[i];
    final op = step['op'] as Map<String, dynamic>;
    final where = '${flavor.label} $name step $i (${op['type']})';
    final before = _snapshot(model, keys);

    // The probe must be able to fail: a `before` that is already invalid would
    // make `before && !after` vacuously false and pass every `invalidates:
    // false` expectation for free.
    for (final key in keys) {
      expect(before.scopes[key], everyElement(isTrue),
          reason: '$where: priming left $key cold, so the invalidation probe '
              'for this step would be vacuous');
    }
    expect(before.receipts, everyElement(isTrue),
        reason: '$where: priming left a receipt reader cold');

    final returns = step['returns'] as Map<String, dynamic>?;
    switch (op['type'] as String) {
      case 'admit':
        final admission = model.admit(IngressEnvelope<String, int>(
          op['key'] as String,
          op['generation'] as int,
          op['sequence'] as int,
          op['stamped_at'] as int,
          op['payload'] as int,
        ));
        if (returns != null) {
          expect(admission, _expectedAdmission(returns),
              reason: '$where: admission');
        }
      case 'open':
        model.open(op['key'] as String, op['generation'] as int);
      case 'drain':
        final drained = model.drain(op['key'] as String);
        if (returns != null) {
          expect(drained, returns['drained'], reason: '$where: drained value');
        }
      case 'suspend':
        final request = model.suspend(op['key'] as String);
        if (returns != null) {
          expect(request, _expectedReplay(returns['replay']),
              reason: '$where: replay request');
        }
      case 'reconnect':
        final request =
            model.reconnect(op['key'] as String, op['generation'] as int);
        if (returns != null) {
          expect(request, _expectedReplay(returns['replay']),
              reason: '$where: replay request');
        }
      case 'close':
        model.close(op['key'] as String);
      case 'fail':
        model.fail(op['key'] as String, _error(op['error'] as String));
      case 'tick':
        model.tick(op['now'] as int);
      case final other:
        throw StateError('$where: unknown op `$other`');
    }

    final after = _snapshot(model, keys);
    _assertState(model, step, keys, where);
    _assertInvalidation(step, before, after, keys, where);
    _materialize(model, keys);
  }

  return steps.length;
}

void _assertState(_IngressModel model, Map<String, dynamic> step,
    List<String> keys, String where) {
  final expected = assertionsOf(step['expected']);
  // Three nesting levels, each DESCENDED into (`#lzsubblockkeyset`): the
  // `scopes` map keyed by scope, the per-scope record, and the `authority` /
  // `retry` records inside it. Every one of them used to be read by naming its
  // fields, so a field added at any level was compared by nothing.
  final scopes = subKey(expected, 'scopes', '$where scopes');
  final unknownScopes = scopes.keys.where((key) => !keys.contains(key)).toList()
    ..sort();
  expect(unknownScopes, isEmpty,
      reason: '$where: `scopes` names $unknownScopes, which no op in this '
          'fixture ever opened');
  for (final key in scopes.keys.toList()) {
    final want = subKey(scopes, key, '$where scope $key');
    final view = model.view(key);
    expect(view, isNotNull, reason: '$where: scope $key absent');
    assertKeyWith<void>(
        want,
        'lifecycle',
        (v) => expect(view!.lifecycle, _lifecycle(v as String),
            reason: '$where: $key lifecycle'));
    assertKey(want, 'generation', view!.generation, '$where: $key generation');
    assertKey(want, 'delivered_through', view.deliveredThrough,
        '$where: $key watermark');
    assertKey(want, 'buffered', view.buffered, '$where: $key buffered');
    assertKey(want, 'consecutive_errors', view.consecutiveErrors,
        '$where: $key consecutive errors');
    assertKey(want, 'window', model.value(key), '$where: $key window');
    assertKeyWith<void>(
        want,
        'readiness',
        (v) => expect(model.readiness(key), _readiness(v as String),
            reason: '$where: $key readiness'));

    if (want['authority'] == null) {
      assertKey(
          want, 'authority', model.authority(key), '$where: $key authority');
    } else {
      final wantAuthority = subKey(want, 'authority', '$where $key authority');
      final authority = model.authority(key);
      expect(authority, isNotNull, reason: '$where: $key authority');
      assertKey(wantAuthority, 'generation', authority!.generation,
          '$where: $key authority generation');
      assertKey(wantAuthority, 'delivered_through', authority.deliveredThrough,
          '$where: $key authority watermark');
      assertKey(wantAuthority, 'stamped_at', authority.stampedAt,
          '$where: $key authority stamp');
    }

    if (want['retry'] == null) {
      assertKey(want, 'retry', model.retry(key), '$where: $key retry');
    } else {
      final wantRetry = subKey(want, 'retry', '$where $key retry');
      final retry = model.retry(key);
      expect(retry, isNotNull, reason: '$where: $key retry');
      assertKey(
          wantRetry, 'attempt', retry!.attempt, '$where: $key retry attempt');
      assertKey(
          wantRetry, 'backoff', retry.backoff, '$where: $key retry backoff');
      assertKey(wantRetry, 'resume_from', retry.resumeFrom,
          '$where: $key retry resume');
    }
  }

  final receipts = subKey(expected, 'receipts', '$where receipts');
  assertKey(
      receipts, 'accepted', model.acceptedLen(), '$where: accepted receipts');
  assertKey(
      receipts, 'dropped', model.droppedLen(), '$where: dropped receipts');
  assertKey(receipts, 'error', model.errorsLen(), '$where: error receipts');
}

/// Assert `invalidates` in both directions. `true` means the reader's cache went
/// from valid to invalid across the op; `false` means it stayed valid.
void _assertInvalidation(
  Map<String, dynamic> step,
  _Validity before,
  _Validity after,
  List<String> keys,
  String where,
) {
  const kinds = ['value', 'readiness', 'authority', 'retry'];
  const channels = ['accepted', 'dropped', 'error'];
  // Descended at all three levels (`#lzsubblockkeyset`), for the same reason
  // `_assertState` is: `invalidates`, the per-scope matrix, and the receipts
  // matrix were each read by naming their fields.
  final want = subKey(
      assertionsOf(step['expected']), 'invalidates', '$where invalidates');
  final wantScopes = subKey(want, 'scopes', '$where invalidates.scopes');
  final unknownScopes =
      wantScopes.keys.where((key) => !keys.contains(key)).toList()..sort();
  expect(unknownScopes, isEmpty,
      reason: '$where: $unknownScopes were never probed; the expectation is '
          'vacuous');
  for (final key in wantScopes.keys.toList()) {
    final wantScope = subKey(wantScopes, key, '$where invalidates.scopes.$key');
    for (var slot = 0; slot < kinds.length; slot++) {
      final invalidated =
          before.scopes[key]![slot] && !after.scopes[key]![slot];
      assertKey(
          wantScope,
          kinds[slot],
          invalidated,
          '$where: $key.${kinds[slot]} invalidation '
          '(was valid=${before.scopes[key]![slot]}, '
          'now valid=${after.scopes[key]![slot]})');
    }
  }
  final wantReceipts = subKey(want, 'receipts', '$where invalidates.receipts');
  for (var slot = 0; slot < channels.length; slot++) {
    final invalidated = before.receipts[slot] && !after.receipts[slot];
    assertKey(wantReceipts, channels[slot], invalidated,
        '$where: receipts.${channels[slot]} invalidation');
  }
}

// ---------------------------------------------------------------------------
// The gates
// ---------------------------------------------------------------------------

void main() {
  test('the ingress corpus is present and non-trivial', () {
    for (final name in _fixtures) {
      expect(File('${_fixtureDir().path}/$name').existsSync(), isTrue,
          reason: '$name is declared but absent');
    }
    final total = _corpusStepTotal();
    expect(total, greaterThanOrEqualTo(30),
        reason: 'the ingress corpus replays only $total steps; that is not the '
            'named schedule set');
  });

  test('the ingress ledger names three shipped flavors, in both directions',
      () {
    final sources = _sources();
    expect(sources, isNotEmpty,
        reason: 'source ledger read nothing and would be vacuous');
    expect(_ledger.length, 3, reason: 'one row per flavor this family defines');
    expect(_ledger.map((row) => row.flavor).toSet(), _Flavor.values.toSet(),
        reason: 'a flavor the runner replays with no ledger row could ship '
            'unrecorded');
    expect(_ledger.any((row) => row.shipped), isTrue,
        reason: 'a ledger of nothing-shipped is not coverage');
    for (final row in _ledger) {
      // `class X` — the declaration, not a doc-comment mention.
      final defined = sources.contains(row.flavor.marker);
      expect(defined, row.shipped,
          reason: 'ledger row `${row.primitive}/${row.flavor.label}` claims '
              'shipped=${row.shipped} but `${row.flavor.marker}` '
              'defined=$defined; fix the ledger or extend the runner');
    }
  });

  for (final flavor in _Flavor.values) {
    test('IngressCell canonical corpus (${flavor.label})', () {
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

  /// The corpus asserts negative invalidation, so the probe itself must be able
  /// to fail. This pins the probe: reading warms the cache, an op that dirties
  /// the reader clears it, and one that does not leaves it warm.
  for (final flavor in _Flavor.values) {
    test('the invalidation probe discriminates (${flavor.label})', () {
      final model = _builders[flavor]!(
        const IngressPolicy(),
        sum(),
        IngressTransportKind.eventChannel,
        25,
      );
      const key = 'alpha';
      model.value(key);
      expect(model.valueIsValid(key), isTrue,
          reason: 'reading warms the cache');

      model.admit(const IngressEnvelope<String, int>(key, 1, 0, 0, 1));
      expect(model.valueIsValid(key), isFalse,
          reason: 'a delivery must invalidate the value reader');

      model.value(key);
      model.admit(const IngressEnvelope<String, int>(key, 1, 5, 0, 1));
      expect(model.valueIsValid(key), isTrue,
          reason: 'a buffered envelope must NOT invalidate the value reader');
    });
  }
}

// Mutation-check record (`#designimplementtransport`). Each deliberate defect was
// introduced into `lib/`, the gate run, and the defect reverted from an original-bytes
// snapshot with an mtime bump — a restore that preserves mtime lets a build system
// reuse the MUTATED artifact and report a false green. All seven were killed, and
// every one of the first five plus the seventh went red in ALL THREE flavors:
//
//  * fence checked after dedupe → `ingress_generation_handoff` step 2 reports
//    `duplicate_sequence` where the corpus expects `stale_generation`.
//  * handoff keeps the superseded window → `ingress_generation_handoff` step 3
//    reads window `5` where the corpus expects `null`.
//  * `Buffered` marks every reader dirty → `ingress_reorder_and_duplication`
//    step 0 fails on `alpha.value invalidation` (expected false, observed true).
//    This is the OVER-invalidation direction: every value the fixture asserts is
//    still correct, so only the per-reader-kind probe can see it.
//  * `tick` marks readiness unconditionally → `ingress_freshness_and_retry`
//    step 1 fails on `alpha.readiness invalidation` for the in-horizon tick.
//  * `Block` advances the watermark → `ingress_backpressure` step 1 reads
//    watermark `1` where the corpus expects `0`, so the retry after the drain
//    would read as a duplicate.
//  * the shell's `_apply` clears one root at a time instead of handing the whole
//    set to `Context.invalidateSlots` / `AsyncContext.clearSlots` → the
//    frontier-walk gates in `ingress_test.dart` fail in all three flavors (two
//    effect runs for one admission). Dart's thread-safe flavor wraps the same
//    `IngressCell`, so the single-threaded mutation covers both, and the async
//    shell was mutated alongside it.
//  * the error-receipt channel is never cleared → `ingress_disconnect_replay`
//    step 4 fails. NOTE the Dart divergence from the Rust record here: this
//    binding's receipt reader caches the LIST, so a stale cache also reports the
//    wrong count and the count assertion trips first. The per-channel
//    invalidation gate is nonetheless load-bearing and was verified
//    independently with an eighth, over-clearing probe (clear `_errors` on every
//    op): `ingress_ordered_delivery` step 0 fails on `receipts.error
//    invalidation` (expected false, observed true) while every receipt COUNT is
//    correct. That is why `invalidates` is asserted per channel and never by
//    receipt count.
