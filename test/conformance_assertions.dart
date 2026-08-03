/// Unconsumed- and unasserted-assertion-key guard (`#lzassertunknownkeys`,
/// `#lzconsumednotasserted`).
///
/// A conformance runner that reads named keys out of a fixture's assertion
/// block and silently ignores the rest reports the fixture as replayed while
/// never checking the field the fixture exists for. The fixture round-trips,
/// the suite goes green, and the assertion proves nothing. This is a level
/// below the coverage guard in `conformance_manifest.dart`: that one proves the
/// fixture was OPENED, this one proves that, having opened it, every assertion
/// it carries was actually consumed.
///
/// The concrete find was in lazily-kt, whose `assertAssertions` let an
/// unrecognised key fall through with no error — `delta_zero_copy_arrow.json`
/// carries a `backend` discriminator the runner never read, so adding the
/// fixture would have passed while never testing the one thing it exists for.
/// Dart has the same hazard in a sharper form: `map['key']` returns null for a
/// missing key, and the `if (x != null)` guards this package is full of then
/// skip the assertion in silence.
///
/// The guard is a tracking map rather than a per-runner allowlist. An allowlist
/// records what a runner CLAIMS to evaluate; a tracking map records what it
/// actually read, so a key that is named in a `knownKeys` set but whose match
/// arm was deleted is still caught.
///
/// Usage is one substitution at the binding site:
///
/// ```dart
/// final expected = step['expected'] as Map<String, dynamic>;   // before
/// final expected = assertionsOf(step['expected'], 'step $i');  // after
/// ```
///
/// The returned object IS a `Map<String, dynamic>`, so every downstream read,
/// cast, and helper signature is unchanged. Verification is registered with
/// [addTearDown] on first use inside a test, so no runner needs a teardown of
/// its own.
///
/// ## Rung 3: consumed is not asserted (`#lzconsumednotasserted`)
///
/// Reading a key proves consumption, not assertion. A runner can read
/// `block[key]` — marking it consumed — and then `continue` past it, bind it to
/// a variable it never uses, or use it only as an `if` gate while asserting
/// against a hardcoded literal. In all three shapes the tracker above goes
/// green while the fixture's value never reaches a comparison; editing the
/// fixture changes nothing.
///
/// So the tracker records a second set. A key becomes ASSERTED only by passing
/// through [assertKey] / [assertKeyWith], which hand the fixture's own value to
/// the comparison, or [excuseKey], which records out loud why there is nothing
/// to compare here. Verification now has three failure modes:
///
/// - a key never read — rung 2, unchanged;
/// - a key read but never asserted — the read-then-discard shapes above;
/// - a stale excuse: a key both excused and asserted in the same run, so the
///   excuse is now hiding nothing. This is the same both-directions rule the
///   coverage guard's `KNOWN_UNCOVERED` allowlist already follows.
///
/// ## Rung 4: prose keys are discharged, never excused (`#lzprosekeyconvention`)
///
/// A few `assertions` keys carry an English paragraph — `clause`, `null_form`,
/// `anti_vacuity`, `theorem`, a top-level `note`. They state an obligation and
/// carry nothing a runner can compare, so neither [assertKey] nor [excuseKey]
/// fits: asserting one pins WORDING (a copy-edit reddens the run, a library
/// regression does not) and excusing one writes an unfalsifiable sentence that
/// no tracker can check. lazily-dart wrote the second shape, naming the
/// discharging assertion in free text — falsifiable in principle, checked by
/// nothing.
///
/// The corpus now declares which keys are prose, in `assertions.prose`, and a
/// runner DISCHARGES each one by naming the executable keys that carry its
/// obligation:
///
/// ```dart
/// proseKey(meta, 'epoch_disambiguation',
///     dischargedBy: ['frame_epoch', 'blob_epoch']);
/// ...
/// addTearDown(() => verifyProse(fixtureId));
/// ```
///
/// [verifyProse] then checks the naming, which is the whole point: "this key is
/// discharged by `frame_epoch` and `blob_epoch`" is a claim about the run, and
/// the ledger can refute it. The seven ways a run fails are listed on
/// [verifyProse].
///
/// The ledger is FIXTURE-scoped, not block-scoped: `epoch_disambiguation` sits
/// in the `assertions` block and is discharged by `expect.frame_epoch` /
/// `expect.blob_epoch`, asserted per scenario long after that block is finished.
/// A named key is therefore matched by NAME in any block of the same fixture,
/// and the comparison happens once the fixture's replay is over.
library;

import 'dart:collection';

import 'package:test/test.dart';

/// Reserved ANNOTATION names, exempt from consumption by name.
///
/// This is the ONLY allowlist in this file and it is deliberately tiny: a key
/// here must be documentation the corpus carries for a human reader. An
/// assertion a binding does not implement does NOT belong here — it belongs in
/// the binding.
///
/// The exemption is by name and therefore a place no runner can be made to
/// discharge anything, so it is safe only while these keys ANNOTATE. A key the
/// corpus lists in `assertions.prose` states an obligation, so the exemption is
/// switched off for it (see [_TrackedAssertions._exempt]) — that is what makes
/// the top-level `note` of `codec/frame_roundtrip_json.json` a discharge
/// obligation while the ~97 per-step `note`s of the reactive-graph corpus stay
/// annotations.
const _annotationKeys = <String>{
  'comment',
  'description',
  'note',
  'notes',
  'why',
};

/// The conformance fixture most recently opened in this isolate.
///
/// Set by `recordConformanceRead`, and correct only for the instant between the
/// read and the `jsonDecode` that follows it — several runners load every
/// fixture in the file while `main()` is still DECLARING tests, so by the time a
/// test body runs this names whichever fixture was loaded last. That is why the
/// attribution below happens at decode time, not at assertion time.
String? currentConformanceFixture;

/// Fixture id that owns each decoded object, by identity.
final Map<Object, String> _owners = LinkedHashMap<Object, String>(
  equals: identical,
  hashCode: identityHashCode,
);

/// Record [currentConformanceFixture] as the owner of every object in
/// [decoded], and return [decoded] unchanged.
///
/// Call this around the `jsonDecode` of a fixture:
///
/// ```dart
/// return attributeFixture(jsonDecode(f.specReadAsStringSync()))
///     as Map<String, dynamic>;
/// ```
///
/// A block's own contents cannot say which file it came from, and the runner
/// that binds it usually has only a scenario or step in scope. Walking once at
/// decode time — the one moment the path is unambiguous — lets every failure
/// message name the fixture without any call site threading it through.
T attributeFixture<T>(T decoded) {
  final id = currentConformanceFixture;
  if (id != null) _attribute(decoded, id, 0);
  return decoded;
}

/// The fixture id [attributeFixture] recorded as the owner of [node], or null
/// when [node] came from somewhere else.
///
/// Exposed for the scenario ledger (`#lzscenariocoverage`), which has a
/// scenario or a fixture root in hand and needs to name the file it came from.
/// Identity-keyed, so it answers for any object inside a decoded fixture.
String? fixtureOwnerOf(Object node) => _owners[node];

void _attribute(Object? node, String id, int depth) {
  // Fixtures are shallow; the bound only stops a pathological one from
  // recursing without end. JSON cannot cycle, so it is belt-and-braces.
  if (depth > 32) return;
  if (node is Map) {
    if (_owners.containsKey(node)) return;
    _owners[node] = id;
    for (final value in node.values) {
      _attribute(value, id, depth + 1);
    }
  } else if (node is List) {
    for (final value in node) {
      _attribute(value, id, depth + 1);
    }
  }
}

/// Blocks awaiting verification.
///
/// A block created while the file's `main()` is still DECLARING tests cannot
/// register a teardown of its own ([addTearDown] requires a running test), so
/// it waits here and is verified by the first teardown that does fire. Late is
/// still red.
final List<_TrackedAssertions> _pending = <_TrackedAssertions>[];

/// Trackers already handed out, keyed by the identity of the underlying map.
///
/// Several runners bind the same block more than once — `reliable_sync` reads
/// `(sc['expect'] as Map)['final_last_epoch']` inline at four sites, and
/// `command` passes one `expect` map to both `_assertProjection` and the test
/// body. Memoizing on identity makes those one tracker, so the reads union
/// instead of each wrapper accusing the others of leaving keys unread.
final Map<Map<dynamic, dynamic>, _TrackedAssertions> _trackers =
    LinkedHashMap<Map<dynamic, dynamic>, _TrackedAssertions>(
  equals: identical,
  hashCode: identityHashCode,
);

/// Wrap a fixture assertion block so that every key it carries must be read.
///
/// [raw] is the decoded block (`step['expected']`, `scenario['expect']`,
/// `fixture['assertions']`, ...). [where] locates the block within the fixture,
/// e.g. `'step 3'` or `'scenario resync_gap'`; it is only used in the failure
/// message.
Map<String, dynamic> assertionsOf(Object? raw, [String where = '']) {
  final tracked = _track(raw, where);
  if (tracked == null) {
    throw StateError('assertionsOf($where): expected a JSON object, got $raw');
  }
  return tracked;
}

/// [assertionsOf], but tolerating a block the fixture omits entirely.
///
/// Returns null when [raw] is null. An ABSENT block is a fixture's business; an
/// absent block is not the failure this guard exists to catch.
Map<String, dynamic>? assertionsOfOrNull(Object? raw, [String where = '']) =>
    raw == null ? null : _track(raw, where);

_TrackedAssertions? _track(Object? raw, String where) {
  if (raw is _TrackedAssertions) return raw;
  if (raw is! Map) return null;
  final existing = _trackers[raw];
  if (existing != null) return existing;
  final tracked = _TrackedAssertions(
    raw.cast<String, dynamic>(),
    where,
    _owners[raw] ?? currentConformanceFixture ?? '<unknown fixture>',
  );
  _trackers[raw] = tracked;
  _pending.add(tracked);
  _arm();
  return tracked;
}

var _armed = false;

/// Register the verification teardown for the currently running test.
///
/// [addTearDown] throws outside a test body; that is the declaration-phase case
/// the [_pending] list covers, so the throw is swallowed and the block is
/// verified by whichever test runs first.
void _arm() {
  if (_armed) return;
  try {
    addTearDown(verifyAssertionsConsumed);
    _armed = true;
  } catch (_) {
    // Declaration phase — see above.
  }
}

/// Assert [actual] equals the fixture's value for [key], marking [key] both
/// read and asserted.
///
/// This is the ONE path by which a key becomes asserted. A comparison written
/// by hand — `expect(actual, block['key'])` — still marks the key read, so it
/// will be reported as read-but-not-asserted; that is deliberate, because a
/// hand-written comparison is exactly where the fixture value silently stops
/// being the thing compared.
///
/// [where] is appended to the failure reason; it defaults to the key.
void assertKey(
  Map<String, dynamic> block,
  String key,
  Object? actual, [
  String? where,
]) {
  final expected = _markAsserted(block, key);
  expect(actual, equals(expected), reason: where ?? key);
}

/// [assertKey] for a comparison that is not equality — a tolerance, a set
/// containment, a regex, a derived projection.
///
/// Marks [key] read and asserted, then hands the fixture's value to [check].
/// The contract is that the fixture value reaches the comparison, not that the
/// comparison is `==`.
T assertKeyWith<T>(
  Map<String, dynamic> block,
  String key,
  T Function(dynamic expected) check,
) {
  final expected = _markAsserted(block, key);
  return check(expected);
}

/// [assertKeyWith], but a no-op when the block does not carry [key] at all.
///
/// Most fixture blocks are unions: a scenario carries whichever of a dozen
/// optional fields it cares about. An ABSENT key is the fixture's business and
/// was never this guard's concern — only a key the block DOES carry has to
/// reach a comparison.
void assertKeyIfPresent(
  Map<String, dynamic> block,
  String key,
  void Function(dynamic expected) check,
) {
  final inner = block is _TrackedAssertions ? block._inner : block;
  if (!inner.containsKey(key)) return;
  check(_markAsserted(block, key));
}

/// Declare that [key] cannot be asserted at this call site, and say why.
///
/// Marks [key] read and satisfied WITHOUT asserting it. [reason] must be
/// non-empty and should name where the fact is proven instead, or why it is
/// unprovable here.
///
/// The excuse is checked in BOTH directions: if the same run also asserts
/// [key], the excuse has gone stale and verification fails. An excuse that
/// hides nothing is worse than no excuse, because it reads as a known gap.
void excuseKey(Map<String, dynamic> block, String key, String reason) {
  if (reason.trim().isEmpty) {
    throw ArgumentError.value(reason, 'reason', 'excuseKey($key) needs a why');
  }
  final tracked = block is _TrackedAssertions ? block : _trackers[block];
  if (tracked == null) return;
  tracked._read.add(key);
  tracked._excused[key] = reason;
}

dynamic _markAsserted(Map<String, dynamic> block, String key) {
  final tracked = block is _TrackedAssertions ? block : _trackers[block];
  if (tracked == null) return block[key];
  tracked._read.add(key);
  tracked._asserted.add(key);
  _ledgerFor(tracked.fixture).asserted.add(key);
  return tracked._inner[key];
}

// ---------------------------------------------------------------------------
// Prose assertion keys (`#lzprosekeyconvention`)
// ---------------------------------------------------------------------------

/// Every fixture that has recorded a discharge claim or an assertion, by id.
final Map<String, _ProseLedger> _ledgers = <String, _ProseLedger>{};

_ProseLedger _ledgerFor(String fixture) =>
    _ledgers.putIfAbsent(fixture, () => _ProseLedger(fixture));

/// One fixture's discharge ledger.
///
/// [asserted] is the union of every key name the fixture's replay routed
/// through [assertKey] / [assertKeyWith] / [assertKeyIfPresent], in ANY block —
/// that is what makes a discharge naming `frame_epoch` checkable from the
/// `assertions` block, which never carries a `frame_epoch` of its own.
class _ProseLedger {
  _ProseLedger(this.fixture);

  final String fixture;
  final Set<String> asserted = <String>{};

  /// Blocks of this fixture that declared `prose` and recorded a discharge,
  /// awaiting [verifyProse]. Identity-keyed for the same reason [_trackers] is.
  final Set<_TrackedAssertions> blocks = LinkedHashSet<_TrackedAssertions>(
    equals: identical,
    hashCode: identityHashCode,
  );
}

/// Discharge [key] — a key the corpus declares prose in `assertions.prose` — by
/// naming the executable assertion keys that carry its obligation.
///
/// [key] is marked read and satisfied, and is NEITHER asserted nor excused: a
/// paragraph has no value to compare, and an excuse for one is a sentence no
/// tracker can check. [dischargedBy] must name keys the same fixture's replay
/// really asserts, which is what turns the old free-text excuse into a claim
/// [verifyProse] can refute.
///
/// The named keys are matched by NAME anywhere in the fixture, so a key of the
/// `assertions` block may be discharged by per-scenario `expect` keys asserted
/// later in the replay.
void proseKey(
  Map<String, dynamic> block,
  String key, {
  required List<String> dischargedBy,
}) {
  final tracked = block is _TrackedAssertions ? block : _trackers[block];
  if (tracked == null) {
    throw StateError('proseKey($key): the block is not tracked, so nothing '
        'would check the discharge. Wrap it with assertionsOf() first.');
  }
  tracked._read.add(key);
  tracked._discharged[key] = List<String>.unmodifiable(dischargedBy);
  _ledgerFor(tracked.fixture).blocks.add(tracked);
}

/// Verify every discharge claim recorded for [fixture], and consume the
/// `prose` declaration itself.
///
/// [fixture] is a fixture id (`'codec/frame_roundtrip_json.json'`) or any
/// object decoded out of that fixture — the decoded root is the usual one.
/// Register it with [addTearDown] AFTER the [proseKey] calls, so the per-
/// scenario assertions a discharge names have all run by the time it fires.
///
/// The run fails when:
///
///  1. a key listed in `assertions.prose` is ASSERTED — comparing a paragraph,
///     or a tally derived from one, to an English string pins wording;
///  2. a key listed in `assertions.prose` is EXCUSED with free text;
///  3. a key NOT listed in `assertions.prose` is discharged;
///  4. the set of discharged keys differs from `assertions.prose` — the
///     comparison that consumes `prose` itself, and what makes a forgotten key
///     fail rather than vanish;
///  5. a discharge names no keys;
///  6. a discharge names a key the same fixture's run did not assert;
///  7. a discharge names a key that is itself prose.
///
/// A block that declares `prose` and carries nothing else has nothing that
/// could discharge it, and is rejected for that too.
///
/// A claim never verified is reported by [verifyAssertionsConsumed], which is
/// registered before any of this and therefore always runs last: a run that
/// forgets to verify is as red as one that names the wrong key.
void verifyProse(Object fixture) {
  final id = _fixtureIdOf(fixture);
  final ledger = _ledgers[id];
  if (ledger == null || ledger.blocks.isEmpty) {
    fail('verifyProse($id): no prose discharge was recorded for this fixture. '
        'Either the runner never called proseKey — in which case a declared '
        '`prose` key is going unconsumed — or it verified twice.');
  }
  final complaints = _verifyProseLedger(ledger);
  _ledgers.remove(id);
  if (complaints.isNotEmpty) {
    fail('prose assertion key(s) mis-discharged in $id '
        '(`#lzprosekeyconvention`):\n  ${complaints.join('\n  ')}');
  }
}

String _fixtureIdOf(Object fixture) {
  if (fixture is String) return fixture;
  return fixtureOwnerOf(fixture) ??
      currentConformanceFixture ??
      '<unknown fixture>';
}

List<String> _verifyProseLedger(_ProseLedger ledger) {
  final complaints = <String>[];

  // Pass one: read every block's declaration. Reading it through _markAsserted
  // is what CONSUMES and ASSERTS `prose` — rule 4's comparison is the assertion.
  final declaredPerBlock = LinkedHashMap<_TrackedAssertions, Set<String>>(
    equals: identical,
    hashCode: identityHashCode,
  );
  // `prose` is not a discharge target either: it is the declaration, not an
  // obligation, and it self-lists in no fixture.
  final proseNames = <String>{'prose'};
  for (final block in ledger.blocks) {
    final raw = _markAsserted(block, 'prose');
    if (raw is! List) {
      complaints.add('${block.label}: `assertions.prose` must be an array of '
          'sibling key names, got $raw');
      declaredPerBlock[block] = <String>{};
      continue;
    }
    final declared = raw.map((k) => '$k').toSet();
    declaredPerBlock[block] = declared;
    proseNames.addAll(declared);
  }

  for (final entry in declaredPerBlock.entries) {
    final block = entry.key;
    final declared = entry.value;
    final at = block.label;
    final discharged = block._discharged.keys.toSet();

    // A block that is entirely prose has nothing that could discharge it.
    final executable = block._inner.keys
        .where((k) => k != 'prose' && !declared.contains(k))
        .toList();
    if (declared.isNotEmpty && executable.isEmpty) {
      complaints.add('$at: the block declares `prose` and carries no other '
          'key, so nothing in it could discharge anything');
    }

    for (final key in declared) {
      // Rule 1.
      if (block._asserted.contains(key)) {
        complaints.add('$at: `$key` is declared prose and was ASSERTED — '
            'comparing an English paragraph, or a tally derived from one, to a '
            'literal pins wording, not behaviour. Discharge it with proseKey '
            'instead.');
      }
      // Rule 2.
      if (block._excused.containsKey(key)) {
        complaints.add('$at: `$key` is declared prose and was EXCUSED — '
            '"${block._excused[key]}". An unfalsifiable reason is exactly the '
            'undocumented default this convention removes. Replace the '
            'excuseKey with a proseKey naming the assertions that carry it.');
      }
    }

    // Rule 3.
    for (final key in discharged.difference(declared)) {
      complaints.add('$at: `$key` was discharged but the corpus does not list '
          'it in `assertions.prose`. A binding does not decide what is prose.');
    }
    // Rule 4.
    final missing = declared.difference(discharged).toList()..sort();
    if (missing.isNotEmpty) {
      complaints.add('$at: declared prose key(s) $missing were never '
          'discharged. `assertions.prose` is the checklist; a key dropped from '
          'a runner has to fail rather than vanish.');
    }

    for (final key in block._discharged.keys) {
      final names = block._discharged[key]!;
      // Rule 5.
      if (names.isEmpty) {
        complaints.add('$at: `$key` is discharged by NOTHING. A discharge that '
            'names no assertion is the free-text excuse again, with the text '
            'removed.');
        continue;
      }
      // Rule 6 — the rule the whole convention exists for.
      final unasserted =
          names.where((n) => !ledger.asserted.contains(n)).toList()..sort();
      if (unasserted.isNotEmpty) {
        complaints.add('$at: `$key` claims to be discharged by $unasserted, '
            'which this fixture\'s run never asserted. The claim is false: '
            'nothing in the replay carries that obligation.');
      }
      // Rule 7.
      final prosy = names.where(proseNames.contains).toList()..sort();
      if (prosy.isNotEmpty) {
        complaints.add('$at: `$key` claims to be discharged by $prosy, which '
            'is itself prose. A paragraph cannot discharge a paragraph.');
      }
    }
  }

  ledger.blocks.clear();
  return complaints;
}

/// Fail if any tracked block carries a key no runner read, a key a runner read
/// but never asserted, or an excuse that has gone stale.
///
/// Registered automatically; exposed so a runner that builds blocks outside a
/// test can force the check.
void verifyAssertionsConsumed() {
  _armed = false;
  final blocks = List<_TrackedAssertions>.of(_pending);
  _pending.clear();
  _trackers.clear();
  // Discharge claims nobody verified (`#lzprosekeyconvention`). This function
  // is armed by the FIRST assertionsOf of a test, so it is always the last
  // teardown to run — which makes it the one place that can tell a runner that
  // forgot verifyProse from one that called it.
  final unverified = <String>[];
  for (final ledger in _ledgers.values) {
    for (final block in ledger.blocks) {
      unverified
          .add('${block.label}: ${block._discharged.keys.toList()..sort()}');
    }
  }
  _ledgers.clear();
  final unread = <String>[];
  final unasserted = <String>[];
  final stale = <String>[];
  for (final block in blocks) {
    if (block.unreadKeys.isNotEmpty) {
      unread.add('${block.label}: ${block.unreadKeys}');
    }
    if (block.unassertedKeys.isNotEmpty) {
      unasserted.add('${block.label}: ${block.unassertedKeys}');
    }
    for (final key in block.staleExcuses) {
      stale.add('${block.label}: $key — "${block._excused[key]}"');
    }
  }
  final complaints = <String>[];
  if (unverified.isNotEmpty) {
    complaints.add('unverified prose discharge claim(s) — the runner named the '
        'assertions that discharge a prose key and then never called '
        'verifyProse(fixture), so nothing checked the naming. An unverified '
        'claim is as bad as an unconsumed key:\n  ${unverified.join('\n  ')}');
  }
  if (unread.isNotEmpty) {
    complaints.add('unconsumed assertion key(s) — the fixture asserts '
        'something this runner never evaluated, so replaying it proves '
        'nothing about that field:\n  ${unread.join('\n  ')}');
  }
  if (unasserted.isNotEmpty) {
    complaints.add('unasserted assertion key(s) — the runner READ these keys '
        'but never compared the fixture value against anything, so editing '
        'the fixture would change nothing. Route them through assertKey / '
        'assertKeyWith, or declare an excuseKey with a '
        'reason:\n  ${unasserted.join('\n  ')}');
  }
  if (stale.isNotEmpty) {
    complaints.add('stale excuse(s) — these keys are excused AND asserted in '
        'the same run, so the excuse hides nothing and now misreports a '
        'covered field as a known gap. Delete the '
        'excuseKey:\n  ${stale.join('\n  ')}');
  }
  if (complaints.isEmpty) return;
  fail(complaints.join('\n\n'));
}

/// A fixture assertion block that remembers which of its keys were read.
///
/// [keys] deliberately does NOT count as a read: iterating the key set and
/// switching on it with a fall-through default is the exact bug this guards
/// against. Runners that iterate go on to read `block[key]`, which does count,
/// and the ones with a throwing default were already fail-closed.
class _TrackedAssertions extends MapBase<String, dynamic> {
  _TrackedAssertions(this._inner, this.where, this.fixture);

  final Map<String, dynamic> _inner;
  final String where;
  final String fixture;
  final Set<String> _read = <String>{};
  final Set<String> _asserted = <String>{};
  final Map<String, String> _excused = <String, String>{};

  /// Prose keys discharged here, each mapped to the executable keys claimed to
  /// carry it (`#lzprosekeyconvention`).
  final Map<String, List<String>> _discharged = <String, List<String>>{};

  /// This block's location, for a failure message.
  String get label => where.isEmpty ? fixture : '$fixture $where';

  /// Keys the corpus declares prose in THIS block, or empty when it declares
  /// none. Read straight off the raw value rather than through the tracker, so
  /// asking does not count as consuming `prose`.
  Set<String> get _declaredProse {
    final raw = _inner['prose'];
    return raw is List ? raw.map((k) => '$k').toSet() : const <String>{};
  }

  /// Whether [key] is exempt from consumption by NAME.
  ///
  /// A reserved annotation name stops being an annotation the moment the corpus
  /// declares it prose: `note` in a per-step block annotates, `note` listed in
  /// `assertions.prose` states an obligation, and only the second has to be
  /// discharged.
  bool _exempt(String key) =>
      _annotationKeys.contains(key) && !_declaredProse.contains(key);

  @override
  dynamic operator [](Object? key) {
    if (key is String) _read.add(key);
    return _inner[key];
  }

  @override
  void operator []=(String key, dynamic value) {
    _read.add(key);
    _inner[key] = value;
  }

  @override
  bool containsKey(Object? key) {
    if (key is String) _read.add(key);
    return _inner.containsKey(key);
  }

  @override
  dynamic remove(Object? key) {
    if (key is String) _read.add(key);
    return _inner.remove(key);
  }

  @override
  Iterable<String> get keys => _inner.keys;

  @override
  void clear() {
    _read.addAll(_inner.keys);
    _inner.clear();
  }

  List<String> get unreadKeys => [
        for (final key in _inner.keys)
          if (!_read.contains(key) && !_exempt(key)) key,
      ]..sort();

  /// Keys a runner read but never routed through [assertKey] / [assertKeyWith]
  /// / [excuseKey] / [proseKey] — the read-then-discard shapes.
  List<String> get unassertedKeys => [
        for (final key in _inner.keys)
          if (_read.contains(key) &&
              !_asserted.contains(key) &&
              !_excused.containsKey(key) &&
              !_discharged.containsKey(key) &&
              !_exempt(key))
            key,
      ]..sort();

  /// Keys carrying an excuse the same run also asserted.
  List<String> get staleExcuses => [
        for (final key in _excused.keys)
          if (_asserted.contains(key)) key,
      ]..sort();
}
