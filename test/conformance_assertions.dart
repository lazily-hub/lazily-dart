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
library;

import 'dart:collection';

import 'package:test/test.dart';

/// Keys that are prose, not assertions, and so are never expected to be
/// consumed by a runner.
///
/// This is the ONLY allowlist in this file and it is deliberately tiny: a key
/// here must be documentation the corpus carries for a human reader. An
/// assertion a binding does not implement does NOT belong here — it belongs in
/// the binding.
const _proseKeys = <String>{
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
  return tracked._inner[key];
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
  final unread = <String>[];
  final unasserted = <String>[];
  final stale = <String>[];
  for (final block in blocks) {
    final at = block.where.isEmpty ? '' : ' ${block.where}';
    final at_ = '${block.fixture}$at';
    if (block.unreadKeys.isNotEmpty) unread.add('$at_: ${block.unreadKeys}');
    if (block.unassertedKeys.isNotEmpty) {
      unasserted.add('$at_: ${block.unassertedKeys}');
    }
    for (final key in block.staleExcuses) {
      stale.add('$at_: $key — "${block._excused[key]}"');
    }
  }
  final complaints = <String>[];
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
          if (!_read.contains(key) && !_proseKeys.contains(key)) key,
      ]..sort();

  /// Keys a runner read but never routed through [assertKey] / [assertKeyWith]
  /// / [excuseKey] — the read-then-discard shapes.
  List<String> get unassertedKeys => [
        for (final key in _inner.keys)
          if (_read.contains(key) &&
              !_asserted.contains(key) &&
              !_excused.containsKey(key) &&
              !_proseKeys.contains(key))
            key,
      ]..sort();

  /// Keys carrying an excuse the same run also asserted.
  List<String> get staleExcuses => [
        for (final key in _excused.keys)
          if (_asserted.contains(key)) key,
      ]..sort();
}
