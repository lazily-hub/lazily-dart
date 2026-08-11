import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lazily/stdlib.dart' as stdlib;
import 'package:test/test.dart';

import 'conformance_manifest.dart';

/// Corpus-relative fixture ids. Root resolution — the
/// `LAZILY_SPEC_CONFORMANCE_DIR` override, the sibling-first-then-mirror
/// ordering, and the fail-closed behaviour when an explicit override cannot be
/// read — lives in `conformance_manifest.dart` (#lzoverrideallrunners).
const _family = 'stdlib';

/// The three stdlib fixtures, in the order the canonical runner replays them.
const _fixtureNames = <String>[
  'timer.json',
  'timeout.json',
  'revision_barrier.json',
];

Map<String, dynamic> _fixture(String name) {
  final source = specReadFixture('$_family/$name');
  return attributeFixture(jsonDecode(source)) as Map<String, dynamic>;
}

/// The same bytes, WITHOUT the assertion-key tracker and WITHOUT the scenario
/// ledger (#lzstdlibmutantsallbindings).
///
/// The independent interpreter below replays every scenario several times —
/// once unperturbed and once per declared operator — and most of those replays
/// are EXPECTED to diverge from the fixture. Routing them through
/// `attributeFixture`/`assertBlock` would book every key as asserted on the
/// strength of a run whose whole point is that it does not conform, and would
/// book scenarios into the replay ledger for a model that is not the shipped
/// library. The tracked reading of these fixtures is the three canonical
/// replays above; this one is deliberately raw.
///
/// It also records no fixture OPEN, so it creates no new assertion block for
/// `scripts/check-unbound-blocks.py` to demand a binding for: every `expect`
/// block of these three fixtures is already bound by the canonical replays
/// through [assertBlock] (`#lzunboundblockguard`).
///
/// The path still comes from the manifest seam, so `LAZILY_SPEC_CONFORMANCE_DIR`
/// repoints this reader exactly like every other one (#lzoverrideallrunners,
/// #lzcorpusrootguards).
Map<String, dynamic> _plainFixture(String name) =>
    jsonDecode(File(specFixturePath('$_family/$name')).readAsStringSync())
        as Map<String, dynamic>;

BigInt _logicalUint(Object? value) {
  if (value is int) return BigInt.from(value);
  if (value is double && value.isFinite && value == value.truncateToDouble()) {
    return BigInt.parse(value.toStringAsFixed(0));
  }
  if (value is String) return BigInt.parse(value);
  throw FormatException('expected logical uint64, got $value');
}

stdlib.TimeoutCancellation _cancellation(Object? value) => switch (value) {
      'pending' => stdlib.TimeoutCancellation.pending,
      'cancelled' => stdlib.TimeoutCancellation.cancelled,
      _ => stdlib.TimeoutCancellation.unavailable,
    };

Map<String, Object?> _timerStep(
  Map<String, dynamic> step,
  List<stdlib.Timer?> holder,
) {
  switch (step['op']) {
    case 'start':
      try {
        final timer = stdlib.Timer(
          _logicalUint(step['now']),
          _logicalUint(step['duration']),
        );
        holder[0] = timer;
        return timer.initial.toJson();
      } on stdlib.StdlibUnavailable catch (error) {
        holder[0] = null;
        return {'outcome': 'unavailable', 'reason': error.reason};
      }
    case 'observe':
      return holder.single!.observe(_logicalUint(step['now'])).toJson();
    default:
      throw StateError('unknown timer step ${step['op']}');
  }
}

Map<String, Object?> _timeoutStep(
  Map<String, dynamic> step,
  List<stdlib.Timeout<String>?> holder,
) {
  switch (step['op']) {
    case 'start':
      try {
        final timeout = stdlib.Timeout<String>(
          _logicalUint(step['now']),
          _logicalUint(step['duration']),
        );
        holder[0] = timeout;
        return timeout.initial.toJson();
      } on stdlib.StdlibUnavailable catch (error) {
        holder[0] = null;
        return {'outcome': 'unavailable', 'reason': error.reason};
      }
    case 'poll':
      var operationCalls = 0;
      var cancellationCalls = 0;
      final observation = holder.single!.poll(
        _logicalUint(step['now']),
        () {
          operationCalls++;
          return switch (step['operation']) {
            'pending' => const stdlib.TimeoutOperation<String>.pending(),
            'completed' => stdlib.TimeoutOperation<String>.completed(
                step['value'] as String,
              ),
            _ => const stdlib.TimeoutOperation<String>.unavailable(),
          };
        },
        () {
          cancellationCalls++;
          return _cancellation(step['cancellation']);
        },
      ).toJson();
      return {
        ...observation,
        'operation_calls': operationCalls,
        'cancellation_calls': cancellationCalls,
      };
    default:
      throw StateError('unknown timeout step ${step['op']}');
  }
}

Map<String, Object?> _barrierStep(
  Map<String, dynamic> step,
  List<stdlib.RevisionBarrier?> holder,
) {
  var cancellationCalls = 0;
  late stdlib.RevisionBarrierObservation observation;
  switch (step['op']) {
    case 'start':
      final deadline = step['deadline'];
      final barrier = stdlib.RevisionBarrier(
        revision: _logicalUint(step['revision']),
        requiredRevision: _logicalUint(step['required_revision']),
        deadline: deadline == null ? null : _logicalUint(deadline),
      );
      holder[0] = barrier;
      observation = barrier.initial;
      break;
    case 'observe':
      observation = holder.single!.observe(
        _logicalUint(step['now']),
        step['predicate'] as bool,
        () {
          cancellationCalls++;
          return _cancellation(step['cancellation']);
        },
      );
      break;
    case 'register_recheck':
      observation = holder.single!.registerRecheck(
        _logicalUint(step['now']),
        _logicalUint(step['observed_revision']),
        step['predicate'] as bool,
      );
      break;
    case 'advance':
      observation = holder.single!.advance(
        _logicalUint(step['revision']),
        step['predicate'] as bool,
      );
      break;
    case 'dispose':
      observation = holder.single!.dispose();
      break;
    case 'receipt':
      observation = holder.single!.receipt(step['key'] as String);
      break;
    default:
      throw StateError('unknown barrier step ${step['op']}');
  }
  return {
    ...observation.toJson(),
    if (step['op'] == 'observe') 'cancellation_calls': cancellationCalls,
  };
}

/// What one canonical replay actually DID, as opposed to what the file says.
///
/// The three floors are compared against these two counters, never against the
/// fixture: a floor computed from the file it is supposed to bound is a
/// tautology (#lzstdlibmutantsallbindings).
class _ReplayTally {
  int scenarios = 0;
  int assertions = 0;

  /// Count the KEYS a block compares, at the point of comparison.
  ///
  /// Counting STEPS is the tempting shape and it is wrong: timer.json carries
  /// 14 steps against an `assertion_floor` of 15, so a per-step counter fails
  /// the floor it is meant to satisfy, and the three fixtures compare 29/53/76
  /// keys against floors of 15/24/70. lazily-py hit the same fork from the
  /// other side — `isinstance(expect, dict)` was FALSE there because its
  /// scenario views are Mappings and not dicts, so the naive check silently
  /// counted 1 per step. Dart's equivalent trap is the reverse: `scenariosOf`
  /// hands out a booking wrapper, but `scenario['steps']` yields the RAW step
  /// maps, so `expect` here really is a plain `Map` and `length` is the honest
  /// key count. Read it from the block, not from the wrapper.
  void countBlock(Object? expect) {
    assertions += expect is Map ? expect.length : 1;
  }
}

/// The referential check plus the three floors the schema requires and nothing
/// in this binding read (#lzstdlibmutantsallbindings).
///
/// `mutations` was not read AT ALL here: a repo-wide search for `must_fail`
/// returned zero files, so `scenario_floor: 99` against a six-scenario fixture
/// was green and an operator rebound to a scenario it does not break was green.
/// `mutation_floor` bounds the ledger's SIZE and that is all it can do; whether
/// each entry's central claim holds is decided by the independent interpreter
/// below.
void _auditFixture(
  String name,
  Map<String, dynamic> fixture,
  _ReplayTally tally,
) {
  final ids = <String>{
    for (final scenario in (fixture['scenarios'] as List))
      (scenario as Map)['id'] as String,
  };
  final mutations = (fixture['mutations'] as List).cast<Map<String, dynamic>>();
  expect(mutations, isNotEmpty,
      reason: '$_family/$name: empty mutation ledger');
  for (final mutation in mutations) {
    final operator = mutation['operator'] as String;
    final mustFail = (mutation['must_fail'] as List).cast<String>();
    expect(mustFail, isNotEmpty,
        reason: '$_family/$name: mutation "$operator" names no scenario');
    for (final id in mustFail) {
      expect(ids, contains(id),
          reason: '$_family/$name: mutation "$operator" names must_fail '
              'scenario "$id", which this fixture does not carry');
    }
  }

  expect(
    tally.scenarios,
    greaterThanOrEqualTo(fixture['scenario_floor'] as int),
    reason: '$_family/$name: replayed ${tally.scenarios} scenarios, below the '
        'declared scenario_floor ${fixture['scenario_floor']}',
  );
  expect(
    tally.assertions,
    greaterThanOrEqualTo(fixture['assertion_floor'] as int),
    reason: '$_family/$name: made ${tally.assertions} assertions, below the '
        'declared assertion_floor ${fixture['assertion_floor']}',
  );
  expect(
    mutations.length,
    greaterThanOrEqualTo(fixture['mutation_floor'] as int),
    reason: '$_family/$name: carries ${mutations.length} mutations, below the '
        'declared mutation_floor ${fixture['mutation_floor']}',
  );
}

void main() {
  final skipReason = specFamilySkipReason(_family);
  if (skipReason != null) {
    test(
      'portable stdlib canonical fixtures',
      () {},
      skip: skipReason,
    );
    return;
  }

  test('Timer replays stdlib/timer.json', () {
    final fixture = _fixture('timer.json');
    final tally = _ReplayTally();
    for (final scenario in scenariosOf(fixture)) {
      final holder = <stdlib.Timer?>[null];
      for (final step
          in (scenario['steps'] as List).cast<Map<String, dynamic>>()) {
        // Whole-block deep equality, routed through the tracker so the
        // block enters the bound-block ledger (`#lzunboundblockguard`). The
        // comparison is unchanged; what was missing is evidence that anything
        // ever looked at this block.
        final expected = step['expect'];
        tally.countBlock(expected);
        assertBlock(
          expected,
          _timerStep(step, holder),
          '${scenario['id']} step',
        );
      }
      tally.scenarios++;
    }
    _auditFixture('timer.json', fixture, tally);
  });

  test('Timeout replays stdlib/timeout.json', () {
    final fixture = _fixture('timeout.json');
    final tally = _ReplayTally();
    for (final scenario in scenariosOf(fixture)) {
      final holder = <stdlib.Timeout<String>?>[null];
      for (final step
          in (scenario['steps'] as List).cast<Map<String, dynamic>>()) {
        // Whole-block deep equality, routed through the tracker so the
        // block enters the bound-block ledger (`#lzunboundblockguard`). The
        // comparison is unchanged; what was missing is evidence that anything
        // ever looked at this block.
        final expected = step['expect'];
        tally.countBlock(expected);
        assertBlock(
          expected,
          _timeoutStep(step, holder),
          '${scenario['id']} step',
        );
      }
      tally.scenarios++;
    }
    _auditFixture('timeout.json', fixture, tally);
  });

  test('RevisionBarrier replays stdlib/revision_barrier.json', () {
    final fixture = _fixture('revision_barrier.json');
    final tally = _ReplayTally();
    for (final scenario in scenariosOf(fixture)) {
      final holder = <stdlib.RevisionBarrier?>[null];
      for (final step
          in (scenario['steps'] as List).cast<Map<String, dynamic>>()) {
        // Whole-block deep equality, routed through the tracker so the
        // block enters the bound-block ledger (`#lzunboundblockguard`). The
        // comparison is unchanged; what was missing is evidence that anything
        // ever looked at this block.
        final expected = step['expect'];
        tally.countBlock(expected);
        assertBlock(
          expected,
          _barrierStep(step, holder),
          '${scenario['id']} step',
        );
      }
      tally.scenarios++;
    }
    _auditFixture('revision_barrier.json', fixture, tally);
  });

  test('independent interpreter agrees with the unperturbed corpus', () {
    // The non-vacuity control. Without it a mutation proves nothing: a scenario
    // that diverges whether or not the operator is applied is not evidence that
    // the operator broke it.
    for (final name in _fixtureNames) {
      final fixture = _plainFixture(name);
      expect(fixture['scenarios'] as List, isNotEmpty,
          reason: '$_family/$name: no scenarios to replay');
      final run = _independentFailures(fixture, null);
      expect(
        run.failed,
        isEmpty,
        reason: '$_family/$name: the independent model diverged from the '
            'canonical corpus with NO operator applied, on '
            '${run.failed.toList()..sort()}',
      );
    }
  });

  test('every declared mutation is observed by the independent interpreter',
      () {
    var pairs = 0;
    for (final name in _fixtureNames) {
      final fixture = _plainFixture(name);
      final baseline = _independentFailures(fixture, null).failed;
      expect(baseline, isEmpty,
          reason: '$_family/$name: unperturbed replay already fails');
      final mutations =
          (fixture['mutations'] as List).cast<Map<String, dynamic>>();
      expect(mutations, isNotEmpty,
          reason: '$_family/$name: empty mutation ledger');
      var fixturePairs = 0;
      for (final mutation in mutations) {
        final operator = mutation['operator'] as String;
        final mustFail = (mutation['must_fail'] as List).cast<String>().toSet();
        expect(mustFail, isNotEmpty,
            reason: '$_family/$name: "$operator" names no scenario');
        final run = _independentFailures(fixture, operator);
        // An operator with no interpreter arm is a HARD failure, never a skip.
        // The set of implemented operators is DERIVED from the branches this
        // replay really consulted; a hand-maintained registry would be one more
        // piece of bookkeeping to drift, which is the same defect one level up.
        expect(
          run.consulted,
          contains(operator),
          reason:
              '$_family/$name: mutation operator "$operator" is declared by '
              'the corpus but no arm of the independent interpreter implements '
              'it; the replay consulted ${run.consulted.toList()..sort()}',
        );
        final escaped = mustFail.difference(run.failed);
        expect(
          escaped,
          isEmpty,
          reason: '$_family/$name: mutation "$operator" did NOT break '
              '${escaped.toList()..sort()} — the ledger claims those scenarios '
              'detect it',
        );
        // Redundant given the empty baseline, but it names the PAIR rather than
        // the fixture when it fires.
        final stillGreen = mustFail.intersection(baseline);
        expect(
          stillGreen,
          isEmpty,
          reason: '$_family/$name: "$operator"/${stillGreen.toList()..sort()} '
              'fail with the operator applied AND without it, so the mutation '
              'proves nothing',
        );
        fixturePairs += mustFail.length;
      }
      // Every entry contributes at least one (operator, scenario) pair, so the
      // corpus's own `mutation_floor` is also a floor on what this run applied.
      expect(
          fixturePairs, greaterThanOrEqualTo(fixture['mutation_floor'] as int),
          reason: '$_family/$name: applied $fixturePairs pairs, below '
              'mutation_floor ${fixture['mutation_floor']}');
      pairs += fixturePairs;
    }
    // timer 4 + timeout 5 + revision_barrier 6. A floor, not an equality: the
    // corpus may grow pairs, and this run must never apply fewer than it does
    // today (#lzstdlibmutantsallbindings).
    expect(pairs, greaterThanOrEqualTo(15),
        reason: 'applied only $pairs (operator, scenario) pairs');
  });

  test('the complement is not asserted because the corpus does not support it',
      () {
    // The obvious complement — "a scenario NOT named in `must_fail` survives the
    // operator" — is FALSE for this corpus, and asserting it would invent a
    // claim the fixtures never make. `deadline_strict_greater` on timer.json
    // also breaks `clock_regression_is_rejected_without_state_change`, whose
    // final step observes exactly at the deadline; `must_fail` is a LOWER BOUND
    // on detection ("these scenarios catch it"), not a partition. lazily-rs and
    // lazily-py make the same choice — subset, never equality.
    //
    // Recorded as a test rather than a comment so the day the corpus DOES become
    // a partition, this stops being true and someone has to decide deliberately
    // whether to tighten the assertion above.
    final fixture = _plainFixture('timer.json');
    final failed = _independentFailures(fixture, 'deadline_strict_greater');
    final entry = (fixture['mutations'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((m) => m['operator'] == 'deadline_strict_greater');
    expect(
      failed.failed
          .difference((entry['must_fail'] as List).cast<String>().toSet()),
      {'clock_regression_is_rejected_without_state_change'},
    );
  });

  test('checked uint64 clock boundaries stay exact', () {
    final timer = stdlib.Timer(stdlib.maxUint64 - BigInt.one, BigInt.one);
    expect(timer.initial.deadline, stdlib.maxUint64);
    expect(timer.observe(stdlib.maxUint64).firedAt, stdlib.maxUint64);
    expect(
      () => stdlib.Timer(stdlib.maxUint64, BigInt.one),
      throwsA(
        isA<stdlib.StdlibUnavailable>().having(
          (error) => error.reason,
          'reason',
          'deadline_overflow',
        ),
      ),
    );
  });

  test('browser-safe JSON projection preserves uint64 precision', () {
    final timer = stdlib.Timer(stdlib.maxUint64 - BigInt.one, BigInt.one);
    final pending = timer.initial.toJson();
    expect(pending['deadline'], stdlib.maxUint64.toString());
    expect(
      (jsonDecode(jsonEncode(pending)) as Map)['deadline'],
      stdlib.maxUint64.toString(),
    );
    final fired = timer.observe(stdlib.maxUint64).toJson();
    expect(fired['fired_at'], stdlib.maxUint64.toString());

    final barrier = stdlib.RevisionBarrier(
      revision: stdlib.maxUint64,
      requiredRevision: stdlib.maxUint64,
    );
    expect(
      barrier.initial.toJson()['revision'],
      stdlib.maxUint64.toString(),
    );

    // Canonical fixture-sized values remain JSON numbers.
    expect(
      stdlib.Timer(BigInt.zero, BigInt.one).initial.toJson()['deadline'],
      1,
    );
  });

  test('RevisionBarrier rejects regression without counter/callback mutation',
      () {
    final barrier = stdlib.RevisionBarrier(
      revision: BigInt.zero,
      requiredRevision: BigInt.from(3),
    );
    var initialCancellationCalls = 0;
    expect(
      barrier.observe(BigInt.from(5), false, () {
        initialCancellationCalls++;
        return stdlib.TimeoutCancellation.pending;
      }).outcome,
      'pending',
    );
    expect(initialCancellationCalls, 1);
    expect(barrier.advance(BigInt.one, false).generation, BigInt.one);

    var regressionCancellationCalls = 0;
    final regressed = barrier.observe(BigInt.from(4), true, () {
      regressionCancellationCalls++;
      return stdlib.TimeoutCancellation.cancelled;
    });
    expect(
      regressed.toJson(),
      {
        'outcome': 'unavailable',
        'revision': 1,
        'generation': 1,
        'reason': 'clock_regression',
      },
    );
    expect(regressionCancellationCalls, 0);

    final registerRegression = barrier.registerRecheck(
      BigInt.from(3),
      BigInt.from(9),
      true,
    );
    expect(registerRegression.toJson(), regressed.toJson());

    // Neither regression advanced the hidden clock nor accepted a revision;
    // the typed unavailable result is terminal.
    final latched = barrier.registerRecheck(
      BigInt.from(5),
      BigInt.from(3),
      true,
    );
    expect(latched.toJson(), regressed.toJson());
  });

  test('RevisionBarrier first register establishes its clock frontier', () {
    final barrier = stdlib.RevisionBarrier(
      revision: BigInt.zero,
      requiredRevision: BigInt.from(2),
    );
    expect(
      barrier.registerRecheck(BigInt.from(7), BigInt.one, false).outcome,
      'pending',
    );
    var cancellationCalls = 0;
    final regressed = barrier.observe(BigInt.from(6), false, () {
      cancellationCalls++;
      return stdlib.TimeoutCancellation.pending;
    });
    expect(regressed.reason, 'clock_regression');
    expect(regressed.revision, BigInt.one);
    expect(regressed.generation, BigInt.one);
    expect(cancellationCalls, 0);
  });

  test('RevisionBarrier sync cancellation preserves reentrant terminal', () {
    final barrier = stdlib.RevisionBarrier(
      revision: BigInt.zero,
      requiredRevision: BigInt.one,
    );
    final result = barrier.observe(BigInt.zero, false, () {
      expect(barrier.dispose().outcome, 'disposed');
      return stdlib.TimeoutCancellation.cancelled;
    });
    expect(result.outcome, 'disposed');
    expect(
      barrier.initial.toJson(),
      {'outcome': 'disposed', 'revision': 0, 'generation': 0},
    );
  });

  test('RevisionBarrier Future cancellation preserves earlier terminal',
      () async {
    final barrier = stdlib.RevisionBarrier(
      revision: BigInt.zero,
      requiredRevision: BigInt.one,
    );
    final cancellation = Completer<stdlib.TimeoutCancellation>();
    final pending = barrier.observeFuture(
      BigInt.zero,
      false,
      () => cancellation.future,
    );
    expect(barrier.dispose().outcome, 'disposed');
    cancellation.complete(stdlib.TimeoutCancellation.cancelled);
    expect((await pending).outcome, 'disposed');
  });

  test('Timer Future wait seam is caller-driven and terminal-latched',
      () async {
    final timer = stdlib.Timer(BigInt.zero, BigInt.from(5));
    var calls = 0;
    final fired = await timer.wait((deadline) async {
      calls++;
      expect(deadline, BigInt.from(5));
      return deadline;
    });
    expect(fired.toJson(), {'outcome': 'fired', 'fired_at': 5});
    await timer.wait((_) {
      calls++;
      return BigInt.from(99);
    });
    expect(calls, 1);
  });

  test('Timeout Future adapters preserve exactly-once precedence', () async {
    final timeout = stdlib.Timeout<String>(BigInt.zero, BigInt.from(10));
    var operationCalls = 0;
    var cancellationCalls = 0;
    final result = await timeout.pollFuture(
      BigInt.one,
      () async {
        operationCalls++;
        return const stdlib.TimeoutOperation.completed('winner');
      },
      () async {
        cancellationCalls++;
        return stdlib.TimeoutCancellation.cancelled;
      },
    );
    expect(result.toJson(), {'outcome': 'completed', 'value': 'winner'});
    expect(operationCalls, 1);
    expect(cancellationCalls, 1);
  });

  test('RevisionBarrier Future cancellation seam honors early exits', () async {
    final satisfied = stdlib.RevisionBarrier(
      revision: BigInt.one,
      requiredRevision: BigInt.one,
    );
    var cancellationCalls = 0;
    expect(
      (await satisfied.observeFuture(BigInt.zero, true, () async {
        cancellationCalls++;
        return stdlib.TimeoutCancellation.cancelled;
      }))
          .outcome,
      'satisfied',
    );
    expect(cancellationCalls, 0);

    final cancelled = stdlib.RevisionBarrier(
      revision: BigInt.zero,
      requiredRevision: BigInt.one,
    );
    expect(
      (await cancelled.observeFuture(BigInt.zero, false, () async {
        cancellationCalls++;
        return stdlib.TimeoutCancellation.cancelled;
      }))
          .outcome,
      'cancelled',
    );
    expect(cancellationCalls, 1);
  });
}

// ---------------------------------------------------------------------------
// The independent interpreter (#lzstdlibmutantsallbindings)
//
// Each fixture declares a `mutations` ledger: "mutate the implementation THIS
// named way and exactly these scenarios must fail". This binding read NONE of
// it — `test/stdlib_conformance_test.dart` replayed scenarios only, and a
// repo-wide search for `must_fail` returned zero files, so nothing checked that
// the ledger's ids even resolve, let alone that its central claim holds. An
// operator rebound to a scenario it does not break stayed green.
//
// The reference shape is lazily-py `tests/test_stdlib_conformance.py` (ed812ab)
// and lazily-rs `tests/stdlib_conformance.rs` (`independent_failures`). The
// design point worth restating: the operator perturbs an INDEPENDENT model of
// the feature, never the shipped `package:lazily/stdlib.dart`. Mutating
// production code to test the corpus would test the mutation harness, would
// need the library to carry seams that exist only for tests, and would say
// nothing about whether the corpus can TELL a correct implementation from a
// wrong one — which is the only thing the ledger claims.
// ---------------------------------------------------------------------------

/// The operator under test, consulted BY NAME at every perturbable branch.
///
/// [consulted] is what makes an unimplemented operator loud rather than silent.
/// A registry of "operators this file implements" would be one more piece of
/// bookkeeping to drift; this set is PRODUCED by the branches the replay really
/// evaluated, so an operator no arm knows about ends the run naming itself.
class _Mutation {
  _Mutation(this.operator);

  final String? operator;
  final Set<String> consulted = <String>{};

  bool call(String name) {
    consulted.add(name);
    return operator == name;
  }
}

/// One perturbed replay: which scenarios diverged, and which operator names the
/// replay's branches consulted.
class _IndependentRun {
  _IndependentRun(this.failed, this.consulted);

  final Set<String> failed;
  final Set<String> consulted;
}

BigInt _uint(Object? value) => _logicalUint(value);

BigInt _maxBig(BigInt a, BigInt b) => a >= b ? a : b;

/// The step's op, read and CHECKED against the ops this model implements.
///
/// The models test `op == 'start'` and then dispatch; letting anything else
/// fall through to the second op would replay an op this model does not
/// implement as an observe/poll, compare the fixture's `expect` against the
/// wrong transition, and name nothing (`#lzscenariobodyskip`).
String _modelOp(Map<String, dynamic> step, List<String> known) {
  final op = step['op'];
  if (op is! String || !known.contains(op)) {
    throw StateError('unknown model op $op (known: $known) in $step');
  }
  return op;
}

/// The latched observation: whatever this feature carries, plus no calls.
Map<String, Object?> _terminal(
  Map<String, Object?> state, {
  required bool adapterCounts,
}) {
  final result = <String, Object?>{'outcome': state['status']};
  for (final key in const ['fired_at', 'value', 'reason']) {
    if (state.containsKey(key)) result[key] = state[key];
  }
  if (adapterCounts) {
    result['operation_calls'] = BigInt.zero;
    result['cancellation_calls'] = BigInt.zero;
  }
  return result;
}

Map<String, Object?> _modelTimer(
  Map<String, Object?> state,
  Map<String, dynamic> step,
  _Mutation mutated,
) {
  if (_modelOp(step, const ['start', 'observe']) == 'start') {
    final now = _uint(step['now']);
    final deadline = now + _uint(step['duration']);
    if (deadline > stdlib.maxUint64) {
      state['status'] = 'unavailable';
      state['reason'] = 'deadline_overflow';
      return _terminal(state, adapterCounts: false);
    }
    state['status'] = 'pending';
    state['deadline'] = deadline;
    state['last_now'] = now;
    return {'outcome': 'pending', 'deadline': deadline};
  }
  if (mutated('fixture_bookkeeping')) {
    return {'outcome': 'pending', 'deadline': state['deadline']};
  }
  final latched = mutated('terminal_not_latched');
  if (state['status'] != 'pending' && !latched) {
    return _terminal(state, adapterCounts: false);
  }
  if (latched) state['status'] = 'pending';
  final now = _uint(step['now']);
  if (now < (state['last_now'] as BigInt)) {
    return {
      'outcome': 'unavailable',
      'reason': 'clock_regression',
      'deadline': state['deadline'],
    };
  }
  state['last_now'] = now;
  final deadline = state['deadline'] as BigInt;
  final reached =
      mutated('deadline_strict_greater') ? now > deadline : now >= deadline;
  if (!reached) return {'outcome': 'pending', 'deadline': deadline};
  state['status'] = 'fired';
  state['fired_at'] = now;
  return _terminal(state, adapterCounts: false);
}

Map<String, Object?> _modelTimeout(
  Map<String, Object?> state,
  Map<String, dynamic> step,
  _Mutation mutated,
) {
  if (_modelOp(step, const ['start', 'poll']) == 'start') {
    final now = _uint(step['now']);
    final deadline = now + _uint(step['duration']);
    if (deadline > stdlib.maxUint64) {
      state['status'] = 'unavailable';
      state['reason'] = 'deadline_overflow';
      return _terminal(state, adapterCounts: false);
    }
    state['status'] = 'pending';
    state['deadline'] = deadline;
    state['last_now'] = now;
    return {'outcome': 'pending', 'deadline': deadline};
  }
  if (mutated('fixture_bookkeeping')) {
    return {
      'outcome': 'pending',
      'deadline': state['deadline'],
      'operation_calls': BigInt.zero,
      'cancellation_calls': BigInt.zero,
    };
  }
  final latched = mutated('terminal_not_latched');
  if (state['status'] != 'pending' && !latched) {
    return _terminal(state, adapterCounts: true);
  }
  if (latched) state['status'] = 'pending';
  final now = _uint(step['now']);
  final deadline = state['deadline'] as BigInt;
  if (now < (state['last_now'] as BigInt)) {
    state['status'] = 'unavailable';
    state['reason'] = 'clock_regression';
    return {
      'outcome': 'unavailable',
      'reason': 'clock_regression',
      'operation_calls': BigInt.zero,
      'cancellation_calls': BigInt.zero,
    };
  }
  state['last_now'] = now;
  final reached =
      mutated('deadline_strict_greater') ? now > deadline : now >= deadline;
  if (reached) {
    state['status'] = 'timed_out';
    return {
      'outcome': 'timed_out',
      'operation_calls': BigInt.zero,
      'cancellation_calls': BigInt.zero,
    };
  }
  // Both drive if-chains whose tail ASSUMES `pending`; validate the spelling so
  // an unknown one names itself instead of quietly meaning "pending"
  // (`#lzscenariobodyskip`).
  final operation = step['operation'];
  if (operation != 'completed' &&
      operation != 'pending' &&
      operation != 'unavailable') {
    throw StateError('unknown operation $operation in $step');
  }
  final cancellation = step['cancellation'];
  if (cancellation != 'cancelled' &&
      cancellation != 'pending' &&
      cancellation != 'unavailable') {
    throw StateError('unknown cancellation $cancellation in $step');
  }
  if (mutated('cancellation_before_completion') &&
      cancellation == 'cancelled') {
    state['status'] = 'cancelled';
    return {
      'outcome': 'cancelled',
      'operation_calls': BigInt.one,
      'cancellation_calls': BigInt.one,
    };
  }
  if (operation == 'completed') {
    state['status'] = 'completed';
    state['value'] = step['value'];
    return {
      'outcome': 'completed',
      'value': step['value'],
      'operation_calls': BigInt.one,
      'cancellation_calls': BigInt.one,
    };
  }
  if (operation == 'unavailable') {
    state['status'] = 'unavailable';
    state['reason'] = 'operation_unavailable';
    return {
      'outcome': 'unavailable',
      'reason': 'operation_unavailable',
      'operation_calls': BigInt.one,
      'cancellation_calls': BigInt.one,
    };
  }
  if (cancellation == 'cancelled') {
    state['status'] = 'cancelled';
    return {
      'outcome': 'cancelled',
      'operation_calls': BigInt.one,
      'cancellation_calls': BigInt.one,
    };
  }
  if (cancellation == 'unavailable') {
    state['status'] = 'unavailable';
    state['reason'] = 'cancellation_unavailable';
    return {
      'outcome': 'unavailable',
      'reason': 'cancellation_unavailable',
      'operation_calls': BigInt.one,
      'cancellation_calls': BigInt.one,
    };
  }
  return {
    'outcome': 'pending',
    'deadline': deadline,
    'operation_calls': BigInt.one,
    'cancellation_calls': BigInt.one,
  };
}

Map<String, Object?> _barrierObservation(Map<String, Object?> state) {
  final result = <String, Object?>{
    'outcome': state['status'],
    'revision': state['revision'],
    'generation': state['generation'],
  };
  if (state.containsKey('reason')) result['reason'] = state['reason'];
  return result;
}

Map<String, Object?> _modelBarrier(
  Map<String, Object?> state,
  Map<String, dynamic> step,
  _Mutation mutated,
) {
  final op = _modelOp(step, const [
    'start',
    'register_recheck',
    'advance',
    'observe',
    'dispose',
    'receipt',
  ]);
  if (op == 'start') {
    state['status'] = 'pending';
    state['revision'] = _uint(step['revision']);
    state['generation'] = BigInt.zero;
    state['required'] = _uint(step['required_revision']);
    state['deadline'] =
        step['deadline'] == null ? null : _uint(step['deadline']);
    state['last_now'] = null;
    return _barrierObservation(state);
  }
  if (mutated('fixture_bookkeeping')) {
    state['status'] = 'pending';
    return _barrierObservation(state);
  }
  final latched = mutated('terminal_not_latched');
  if (state['status'] != 'pending' && !latched) {
    final result = _barrierObservation(state);
    if (op == 'observe') result['cancellation_calls'] = BigInt.zero;
    return result;
  }
  if (latched) state['status'] = 'pending';
  if (op == 'dispose') {
    state['status'] = 'disposed';
    return _barrierObservation(state);
  }
  if (op == 'receipt') {
    // An application-owned effect receipt is NOT barrier authority: it wakes the
    // waiter and changes no revision. The operator makes it authority.
    if (mutated('receipt_is_authority')) {
      state['revision'] = state['required'];
      state['generation'] = (state['generation'] as BigInt) + BigInt.one;
      state['status'] = 'satisfied';
    }
    return _barrierObservation(state);
  }
  if (op == 'advance') {
    final revision =
        _maxBig(state['revision'] as BigInt, _uint(step['revision']));
    state['revision'] = revision;
    state['generation'] = (state['generation'] as BigInt) + BigInt.one;
    if (revision >= (state['required'] as BigInt) &&
        step['predicate'] == true) {
      state['status'] = 'satisfied';
    }
    return _barrierObservation(state);
  }
  final now = _uint(step['now']);
  final lastNow = state['last_now'] as BigInt?;
  final regressed = lastNow != null && now < lastNow;
  if (regressed && !mutated('barrier_accept_clock_regression')) {
    state['status'] = 'unavailable';
    state['reason'] = 'clock_regression';
    final result = _barrierObservation(state);
    if (op == 'observe') result['cancellation_calls'] = BigInt.zero;
    return result;
  }
  state['last_now'] = now;
  if (op == 'register_recheck') {
    state['generation'] = (state['generation'] as BigInt) + BigInt.one;
    if (!mutated('barrier_skip_post_registration_recheck')) {
      final revision = _maxBig(
        state['revision'] as BigInt,
        _uint(step['observed_revision']),
      );
      state['revision'] = revision;
      if (revision >= (state['required'] as BigInt) &&
          step['predicate'] == true) {
        state['status'] = 'satisfied';
      }
    }
    return _barrierObservation(state);
  }
  final deadline = state['deadline'] as BigInt?;
  final bool reached;
  if (deadline == null) {
    reached = false;
  } else if (mutated('deadline_strict_greater')) {
    reached = now > deadline;
  } else {
    reached = now >= deadline;
  }
  if (reached) {
    state['status'] = 'timed_out';
    final result = _barrierObservation(state);
    result['cancellation_calls'] = BigInt.zero;
    return result;
  }
  if ((state['revision'] as BigInt) >= (state['required'] as BigInt) &&
      step['predicate'] == true) {
    state['status'] = 'satisfied';
    final result = _barrierObservation(state);
    result['cancellation_calls'] = BigInt.zero;
    return result;
  }
  // Fail-closed tail (`#lzscenariobodyskip`): a cancellation spelling this model
  // does not know must not behave like `pending`.
  final cancellation = step['cancellation'];
  if (cancellation == 'cancelled') {
    state['status'] = 'cancelled';
  } else if (cancellation == 'unavailable') {
    state['status'] = 'unavailable';
    state['reason'] = 'cancellation_unavailable';
  } else if (cancellation != 'pending') {
    throw StateError('unknown cancellation $cancellation in $step');
  }
  final result = _barrierObservation(state);
  result['cancellation_calls'] = BigInt.one;
  return result;
}

const _models = <String,
    Map<String, Object?> Function(
        Map<String, Object?>, Map<String, dynamic>, _Mutation)>{
  'stdlib_timer_v1': _modelTimer,
  'stdlib_timeout_v1': _modelTimeout,
  'stdlib_revision_barrier_v1': _modelBarrier,
};

/// Integral value of [value] as a [BigInt], or null when it is not a number.
///
/// The models carry every logical uint64 as a [BigInt] — one canonical `now` in
/// timer.json is 2^64 - 2, past both `int` and the double mantissa — while the
/// fixture's `expect` blocks decode as plain `int`. Both sides go through this
/// on the way into the comparison so `BigInt.from(10)` and `10` agree, and a
/// STRING "10" still does not: it stays a string and compares as one.
BigInt? _asIntegral(Object? value) {
  if (value is BigInt) return value;
  if (value is int) return BigInt.from(value);
  if (value is double && value.isFinite && value == value.truncateToDouble()) {
    return BigInt.parse(value.toStringAsFixed(0));
  }
  return null;
}

bool _sameValue(Object? a, Object? b) {
  final numericA = _asIntegral(a);
  final numericB = _asIntegral(b);
  if (numericA != null || numericB != null) {
    return numericA != null && numericB != null && numericA == numericB;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key)) return false;
      if (!_sameValue(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameValue(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// Replay every scenario of [fixture] through the model, perturbed by
/// [operator], and report the ids that DIVERGED from their declared `expect`
/// alongside the operator names the replay's branches consulted.
_IndependentRun _independentFailures(
  Map<String, dynamic> fixture,
  String? operator,
) {
  final feature = fixture['feature'] as String;
  final model = _models[feature];
  if (model == null) throw StateError('unknown stdlib feature $feature');
  final mutated = _Mutation(operator);
  final failed = <String>{};
  for (final scenario in (fixture['scenarios'] as List)) {
    final id = (scenario as Map)['id'] as String;
    final state = <String, Object?>{};
    for (final step
        in (scenario['steps'] as List).cast<Map<String, dynamic>>()) {
      if (!_sameValue(model(state, step, mutated), step['expect'])) {
        failed.add(id);
      }
    }
  }
  return _IndependentRun(failed, mutated.consulted);
}
