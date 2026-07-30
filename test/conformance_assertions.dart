/// Unconsumed-assertion-key guard (`#lzassertunknownkeys`).
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

/// Fail if any tracked block still carries a key no runner read.
///
/// Registered automatically; exposed so a runner that builds blocks outside a
/// test can force the check.
void verifyAssertionsConsumed() {
  _armed = false;
  final blocks = List<_TrackedAssertions>.of(_pending);
  _pending.clear();
  _trackers.clear();
  final complaints = <String>[];
  for (final block in blocks) {
    final unread = block.unreadKeys;
    if (unread.isEmpty) continue;
    final at = block.where.isEmpty ? '' : ' ${block.where}';
    complaints.add('${block.fixture}$at: $unread');
  }
  if (complaints.isEmpty) return;
  fail('unconsumed assertion key(s) — the fixture asserts something this '
      'runner never evaluated, so replaying it proves nothing about that '
      'field:\n  ${complaints.join('\n  ')}');
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
}
