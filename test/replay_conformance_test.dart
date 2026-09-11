/// Replay the canonical replay-equivalence corpus against `package:lazily`'s
/// `ReplayHarness` (`#lzreplaydart`).
///
/// Three fixtures, one obligation each
/// (`lazily-spec/docs/replay-equivalence.md`): the fingerprint is bound to its
/// log and that binding is revalidated before any value compare; a divergence
/// is reported at the first checkpoint where the values parted; the observation
/// encoding agrees with the family on which differences are differences.
///
/// The corpus declares its subjects in prose because a JSON fixture cannot
/// carry a reactive graph, so [_Accumulator] below is this binding's copy of
/// that declaration — kept to the letter, including that `observe` exposes
/// `sum` and `names` under exactly those labels.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

const _family = 'replay';

Map<String, dynamic> _fixture(String name) =>
    attributeFixture(jsonDecode(specReadFixture('$_family/$name')))
        as Map<String, dynamic>;

// ---------------------------------------------------------------------------
// The corpus's canonical subjects
// ---------------------------------------------------------------------------

/// `accumulator`, and `drifting_accumulator` when a drift is configured.
///
/// `apply`: `sum += event.payload`, then append `event.name` to `names`; when
/// the event's `seq` equals [driftAt], `sum += drift` afterwards. `observe`:
/// `{"sum": sum, "names": names}`.
///
/// `observe` hands out a COPY of `names`. A live view of the growing list would
/// leave every checkpoint holding the same object, so each one would digest the
/// final state and a divergence in the middle of the log could not be seen.
final class _Accumulator implements ReplayGraph {
  _Accumulator({this.driftAt, this.drift = 0});

  final int? driftAt;
  final int drift;

  int sum = 0;
  final List<String> names = <String>[];

  @override
  void apply(ReplayEvent event) {
    sum += event.payload! as int;
    names.add(event.name);
    if (driftAt != null && event.seq == driftAt) sum += drift;
  }

  @override
  Map<String, Object?> observe() => <String, Object?>{
        'sum': sum,
        'names': List<String>.of(names),
      };
}

ReplayEvent _event(Map<String, dynamic> entry) => ReplayEvent(
      seq: entry['seq'] as int,
      name: entry['name'] as String,
      payload: entry['payload'],
    );

ReplayLog _log(List<Object?> entries) => ReplayLog([
      for (final raw in entries) _event(raw! as Map<String, dynamic>),
    ]);

ReplayGraph Function() _build(
  Map<String, dynamic> config,
  Map<String, dynamic> op,
) {
  final subject = config['subject'] as String;
  switch (subject) {
    case 'accumulator':
      return _Accumulator.new;
    case 'drifting_accumulator':
      final driftAt = config['drift_at'] as int;
      final drift = (op['drift'] ?? 0) as int;
      return () => _Accumulator(driftAt: driftAt, drift: drift);
    default:
      throw StateError('unknown canonical replay subject "$subject"');
  }
}

/// What the subject itself observes after the whole log, driven by hand.
///
/// This is the independent half of the `record` cross-check: the fingerprint is
/// a digest of what the HARNESS saw, and comparing it against a subject driven
/// outside the harness is what stops the fixture from accepting a harness that
/// observed some other value entirely.
Map<String, Object?> _finalObservation(
  ReplayGraph Function() build,
  ReplayLog log,
) {
  final subject = build();
  for (final event in log.events) {
    subject.apply(event);
  }
  return subject.observe();
}

// ---------------------------------------------------------------------------
// Obligations 1 and 2
// ---------------------------------------------------------------------------

// Why there is no `minimumSteps` here any more (#lzcorpusfloorguard)
// -----------------------------------------------------------------
// `#lzreplayframing` grew `replay/canonical_encoding_equality.json` from 11
// steps to 14. Every binding kept a per-fixture minimum-steps floor hard-coded
// in its own runner, eight of nine were still pinned at 11, and the three new
// rows sat inside that slack — they would have reported green WITHOUT
// EXECUTING. Re-pinning the number by hand only restarts the same drift clock.
//
// What replaces the floor needs no number and cannot drift:
//   1. every step this runner LOADED is EXECUTED — counted in the dispatch
//      loop below and compared to the loaded length at the end;
//   2. an op type this runner does not implement is a HARD FAILURE, never a
//      silent skip, so "executed" cannot be inflated by a no-op arm.
//
// Those two close corpus GROWTH permanently. The one thing a floor did do —
// notice the corpus SHRINKING — now lives at the single place a shrink can
// happen, checked against a committed manifest rather than nine copies of a
// number: lazily-spec's `corpus-counts.json` + `scripts/check-corpus-floors.mjs`.

/// Dispatches exactly one step of a `ReplayHarness` fixture.
///
/// Returns normally only when the step was really handled. An unrecognized op
/// type throws: a permissive fall-through would let a corpus op this binding
/// never implemented count as executed, which is the executed-vs-loaded
/// assertion's only blind spot.
void _dispatchHarnessStep(
  String name,
  int index,
  Map<String, dynamic> step,
  Map<String, dynamic> config,
  Map<String, ReplayLog> logs,
  Map<String, ReplayFingerprint> fingerprints,
) {
  final op = step['op'] as Map<String, dynamic>;
  final type = op['type'] as String;
  final where = '$name step $index ($type)';
  // Bind the block whatever the op turns out to be: an `expected` block no
  // runner passes to the tracker is invisible to every guard in this repo.
  final expected = assertionsOf(step['expected'], where);

  if (type == 'log_digest_equal') {
    final equal = logs[op['left']]!.digest == logs[op['right']]!.digest;
    expect(step['returns'], equals(equal), reason: '$where: returns');
    return;
  }

  // `late` on purpose: these are evaluated on FIRST USE, so an op type no
  // branch below claims falls through to the throw at the end and is named
  // there. Evaluating them eagerly made an unknown op die on whichever cast
  // happened to run first ("type 'Null' is not a subtype of type 'String'"),
  // which is still fail-closed but tells the next reader nothing.
  late final build = _build(config, op);
  late final harness = ReplayHarness(
    build,
    stride: (op['stride'] ?? config['stride'] ?? 1) as int,
  );
  late final log = logs[op['log']]!;
  late final fingerprint = fingerprints[op['fingerprint'] as String]!;

  if (type == 'record') {
    final fingerprint = harness.record(log);
    fingerprints[op['into'] as String] = fingerprint;
    assertKey(expected, 'outcome', 'recorded', where);
    assertKey(
      expected,
      'checkpoint_seqs',
      [for (final checkpoint in fingerprint.checkpoints) checkpoint.seq],
      where,
    );
    assertKey(expected, 'stride', fingerprint.stride, where);

    final observed = _finalObservation(build, log);
    assertKey(expected, 'final_sum', observed['sum'], where);
    // The fingerprint must have observed the state the subject ends on, not
    // merely SOME state: this is the one place the digests and the declared
    // subject meet, and without it the fixture would accept a harness that
    // fingerprinted something else entirely.
    expect(
      fingerprint.finalCheckpoint.cells,
      equals(ReplayCheckpoint.of(log.events.last.seq, observed).cells),
      reason: '$where: the recorded final checkpoint is not a digest of the '
          "subject's own final observation",
    );
    return;
  }

  if (type == 'prove') {
    harness.prove(log, replays: op['replays'] as int);
    assertKey(expected, 'outcome', 'ok', where);
    assertKey(expected, 'divergences', 0, where);
    return;
  }

  if (type == 'verify') {
    var outcome = 'ok';
    ReplayDivergence? first;
    try {
      harness.verify(log, fingerprint);
    } on ReplayLogMismatchError {
      outcome = 'log_mismatch';
    } on ReplayStrideMismatchError {
      outcome = 'stride_mismatch';
    } on ReplayDivergenceError catch (error) {
      outcome = 'divergent';
      first = error.first;
    }
    assertKey(expected, 'outcome', outcome, where);
    if (first == null) {
      assertKey(expected, 'divergences', 0, where);
    } else {
      assertKey(expected, 'first_divergent_seq', first.seq, where);
      assertKey(expected, 'first_divergent_label', first.label, where);
      assertKey(expected, 'first_divergent_kind', first.kind.wireName, where);
    }
    return;
  }

  if (type == 'check') {
    try {
      final divergences = harness.check(log, fingerprint).length;
      assertKey(expected, 'outcome', 'ok', where);
      assertKey(expected, 'divergences', divergences, where);
    } on ReplayLogMismatchError {
      assertKey(expected, 'outcome', 'log_mismatch', where);
      assertKey(expected, 'divergences', 0, where);
    }
    return;
  }

  throw StateError('unknown canonical replay operation "$type" at $where; '
      'an op this runner cannot dispatch is a failure, never a skip');
}

void _driveHarnessFixture(String name) {
  final fixture = _fixture(name);
  expect(fixture['kind'], equals('Replay'), reason: '$name: kind');
  expect(fixture['model'], equals('ReplayHarness'), reason: '$name: model');
  final config = fixture['config'] as Map<String, dynamic>;
  final logs = <String, ReplayLog>{
    for (final entry in (config['logs'] as Map<String, dynamic>).entries)
      entry.key: _log(entry.value as List<Object?>),
  };
  final fingerprints = <String, ReplayFingerprint>{};
  final steps = fixture['steps'] as List<Object?>;
  expect(steps, isNotEmpty, reason: '$name: the fixture carries no steps');

  var executed = 0;
  for (var index = 0; index < steps.length; index++) {
    _dispatchHarnessStep(
      name,
      index,
      steps[index]! as Map<String, dynamic>,
      config,
      logs,
      fingerprints,
    );
    executed++;
  }

  expect(
    executed,
    equals(steps.length),
    reason: '$name: loaded ${steps.length} steps but executed $executed — the '
        'dispatch loop skipped ${steps.length - executed} of them',
  );
}

// ---------------------------------------------------------------------------
// Obligation 3
// ---------------------------------------------------------------------------

/// A value the encoding does not define, as the corpus's `opaque` tag.
final class _Opaque {}

Object? _value(Map<String, dynamic> tagged) {
  final tag = tagged['t'] as String;
  switch (tag) {
    case 'int':
      return int.parse(tagged['v'] as String);
    case 'str':
      return tagged['v'] as String;
    case 'float':
      return double.parse(tagged['v'] as String);
    case 'bool':
      return tagged['v'] as bool;
    case 'bytes':
      final hex = tagged['v'] as String;
      return Uint8List.fromList([
        for (var i = 0; i < hex.length; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
      ]);
    case 'seq':
      return <Object?>[
        for (final item in tagged['v'] as List<Object?>)
          _value(item! as Map<String, dynamic>),
      ];
    case 'set':
      return <Object?>{
        for (final item in tagged['v'] as List<Object?>)
          _value(item! as Map<String, dynamic>),
      };
    case 'map':
      return <String, Object?>{
        for (final pair in (tagged['v'] as List<Object?>)
            .map((raw) => raw! as List<Object?>))
          pair[0]! as String: _value(pair[1]! as Map<String, dynamic>),
      };
    case 'opaque':
      return _Opaque();
    default:
      throw StateError('unknown canonical value tag "$tag"');
  }
}

/// Dispatches exactly one step of a `CanonicalEncoding` fixture.
///
/// As with [_dispatchHarnessStep], an unrecognized op type throws rather than
/// falling through, so a step can never be counted as executed without having
/// been interpreted.
void _dispatchEncodingStep(
  String name,
  int index,
  Map<String, dynamic> step,
  Map<String, dynamic> values,
  Set<bool> outcomes,
) {
  final op = step['op'] as Map<String, dynamic>;
  final type = op['type'] as String;
  final where = '$name step $index ($type)';
  final expected = assertionsOf(step['expected'], where);

  if (type == 'digest_equal') {
    final equal = canonicalDigest(
          _value(values[op['left']]! as Map<String, dynamic>),
        ) ==
        canonicalDigest(_value(values[op['right']]! as Map<String, dynamic>));
    expect(step['returns'], equals(equal), reason: '$where: returns');
    outcomes.add(equal);
    return;
  }

  if (type == 'digest_defined') {
    var defined = true;
    try {
      canonicalDigest(_value(values[op['value']]! as Map<String, dynamic>));
    } on ReplayEncodingError {
      defined = false;
    }
    expect(step['returns'], equals(defined), reason: '$where: returns');
    assertKey(expected, 'outcome', 'encoding_error', where);
    return;
  }

  throw StateError('unknown canonical encoding operation "$type" at $where; '
      'an op this runner cannot dispatch is a failure, never a skip');
}

/// See the `#lzcorpusfloorguard` note above [_dispatchHarnessStep] for why this
/// takes no `minimumSteps`. This is the fixture the incident was found on: it
/// went 11 -> 14 steps and the floor did not notice.
void _driveEncodingFixture(String name) {
  final fixture = _fixture(name);
  expect(fixture['kind'], equals('Replay'), reason: '$name: kind');
  expect(fixture['model'], equals('CanonicalEncoding'), reason: '$name: model');
  final values = (fixture['config'] as Map<String, dynamic>)['values']
      as Map<String, dynamic>;
  final steps = fixture['steps'] as List<Object?>;
  expect(steps, isNotEmpty, reason: '$name: the fixture carries no steps');
  final outcomes = <bool>{};

  var executed = 0;
  for (var index = 0; index < steps.length; index++) {
    _dispatchEncodingStep(
      name,
      index,
      steps[index]! as Map<String, dynamic>,
      values,
      outcomes,
    );
    executed++;
  }

  expect(
    executed,
    equals(steps.length),
    reason: '$name: loaded ${steps.length} steps but executed $executed — the '
        'dispatch loop skipped ${steps.length - executed} of them',
  );

  // Both outcomes really occurred: a runner that only ever saw `false` would
  // pass every inequality claim with a broken encoding.
  expect(outcomes, equals(<bool>{true, false}),
      reason: '$name: the fixture must exercise BOTH equality outcomes');
}

void main() {
  final skipReason = specFamilySkipReason(_family);

  test('a fingerprint is bound to the log that produced it', () {
    _driveHarnessFixture('fingerprint_log_binding.json');
  }, skip: skipReason);

  test('a divergence is localized to its first checkpoint', () {
    _driveHarnessFixture('divergence_localization.json');
  }, skip: skipReason);

  test('the observation encoding agrees on the equality classes', () {
    _driveEncodingFixture('canonical_encoding_equality.json');
  }, skip: skipReason);

  // ---- Library-level obligations the corpus states but cannot carry --------

  test('a log refuses non-increasing sequence numbers but allows gaps', () {
    expect(
      () => ReplayLog([
        ReplayEvent(seq: 1, name: 'add', payload: 1),
        ReplayEvent(seq: 1, name: 'add', payload: 2),
      ]),
      throwsArgumentError,
    );
    // Non-contiguous is legal: an ack-truncated durable outbox replays real
    // epochs, and renumbering them would hide the truncated prefix.
    final sparse = ReplayLog([
      ReplayEvent(seq: 7, name: 'add', payload: 1),
      ReplayEvent(seq: 41, name: 'add', payload: 2),
    ]);
    expect(sparse.length, 2);
    expect(
      sparse.digest,
      isNot(equals(ReplayLog.fromRecords([('add', 1), ('add', 2)]).digest)),
      reason: 'the seqs are part of the log digest',
    );
  });

  test('a fingerprint round-trips through its wire form', () {
    final log = ReplayLog.fromRecords([('add', 1), ('add', 2)]);
    final harness = ReplayHarness(_Accumulator.new);
    final recorded = harness.record(log);
    final wire =
        jsonDecode(jsonEncode(recorded.toWire())) as Map<String, Object?>;
    final restored = ReplayFingerprint.fromWire(wire);
    expect(restored.digest, equals(recorded.digest));
    expect(harness.verify(log, restored).digest, equals(recorded.digest));
    expect(
      () => ReplayFingerprint.fromWire({...wire, 'schema_version': 99}),
      throwsA(isA<ReplayEncodingError>()),
    );
  });

  test('a graph that is not a function of its log fails prove()', () {
    var salt = 0;
    final harness =
        ReplayHarness(() => _Accumulator(driftAt: 0, drift: salt++));
    expect(
      () => harness.prove(ReplayLog.fromRecords([('add', 1)])),
      throwsA(isA<ReplayDivergenceError>()),
    );
  });

  // The member-framing obligation the corpus cannot carry for this binding
  // (`#lzreplayframing`). The corpus pins the equality CLASS and, with the
  // nested pair, the container length in a layout-independent way; the pair
  // that pins a member's OWN length has to spell the next member's tag, and a
  // binding MAY choose its tags, so only the binding can build it.
  //
  // This binding's layout is `<tag><decimal body length>:<body>` with the
  // string tag `s` — the reference layout of the spec table — so the corpus's
  // pair IS this binding's pair, and it is repeated here rather than replaced:
  //
  //   ['a','sbc'] -> l10:s1:as3:sbc      ['as','bc'] -> l10:s2:ass2:bc
  //
  // Delete `<decimal body length>:` from `_frame` and both sides concatenate
  // to `lsassbc`; the mapping analogue collapses to `msassb` and the nested
  // pair to `llsasb`. The equality-class pair ['a','bc'] vs ['ab','c'] does NOT
  // catch that mutation: unframed it is `lsasbc` against `lsabsc`, which still
  // differ, which is exactly why one row was never enough.
  //
  // The LAST inequality pair below pins the same length against the other
  // spelling of the mutation, where the digits go but the `:` delimiter stays:
  // there ['a','s:bc'] and ['as:','bc'] both become `l:s:as:s:bc`.
  test('a member length is pinned by a pair that spells the next tag', () {
    // Length dropped entirely: both sides would be `lsassbc`.
    expect(
      canonicalDigest(<Object?>['a', 'sbc']),
      isNot(equals(canonicalDigest(<Object?>['as', 'bc']))),
      reason: 'a member whose content spells the next member tag still needs '
          'its length',
    );
    expect(
      canonicalDigest(<String, Object?>{'a': 'sb'}),
      isNot(equals(canonicalDigest(<String, Object?>{'as': 'b'}))),
      reason: 'a mapping key is framed apart from its value',
    );
    expect(
      canonicalDigest(<Object?>[
        <Object?>['a'],
        'b',
      ]),
      isNot(equals(canonicalDigest(<Object?>[
        <Object?>['a', 'b'],
      ]))),
      reason: 'a nested container boundary survives concatenation',
    );

    // Digits dropped, delimiter kept: both sides would be `l:s:as:s:bc`.
    expect(
      canonicalDigest(<Object?>['a', 's:bc']),
      isNot(equals(canonicalDigest(<Object?>['as:', 'bc']))),
      reason: 'the decimal length, not the delimiter, is what frames a member',
    );

    // Asserted LAST on purpose: it is the anchor that documents the layout the
    // four pairs above are built against, and a first-line literal compare
    // would short-circuit the test before any of them ran.
    expect(
      utf8.decode(canonicalBytes(<Object?>['a', 'sbc'])),
      'l10:s1:as3:sbc',
      reason: 'the layout these pairs are built against',
    );
  });

  test('an observation label the fingerprint does not carry is reported', () {
    final log = ReplayLog.fromRecords([('add', 1)]);
    final recorded = ReplayHarness(_Accumulator.new).record(log);
    final trimmed = ReplayFingerprint(
      logDigest: recorded.logDigest,
      stride: recorded.stride,
      checkpoints: [
        for (final checkpoint in recorded.checkpoints)
          ReplayCheckpoint.ofDigests(checkpoint.seq, <String, String>{
            'sum': checkpoint.cells['sum']!,
          }),
      ],
    );
    final divergences = ReplayHarness(_Accumulator.new).check(log, trimmed);
    expect(divergences, isNotEmpty);
    expect(divergences.first.kind, ReplayDivergenceKind.unexpected);
    expect(divergences.first.label, 'names');
  });
}
