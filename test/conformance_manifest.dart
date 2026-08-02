/// Runtime conformance manifest (`#lazilyupgradeconformance`).
///
/// The static coverage guard greps test sources for fixture filenames. That
/// catches a fixture nobody mentions, but not one mentioned in a comment and
/// hand-transcribed — the drift found in lazily-cpp's queue tests, and in
/// lazily-rs's own topic tests, where the source named four `topiccell_*.json`
/// fixtures that nothing ever opened. Only observing the read proves the corpus
/// was replayed.
///
/// Dart gives us a clean seam: every test file can import this library, so one
/// helper serves all of them and the substitution at each read site is a single
/// token — `readAsStringSync()` becomes `specReadAsStringSync()`.
///
/// Reads outside the conformance corpus pass straight through and are not
/// recorded, so routing every read through this is harmless.
///
/// One read site is deliberately NOT routed here:
/// `conformance_fixture_drift_test.dart` opens each canonical fixture to
/// byte-compare it against its mirror. That read proves the mirror is current;
/// it does not replay the scenario. Recording it would let the drift test claim
/// coverage for every mirrored fixture and hand this guard back the vacuous
/// green it exists to prevent. lazily-go's `vendored_fixture_drift_test.go`
/// stays on the raw read for the same reason.
///
/// ## Rung 4: which SCENARIOS were replayed (`#lzscenariocoverage`)
///
/// Opening a fixture is not replaying it. A fixture carrying four named
/// scenarios can be partially replayed and every guard in this repo stays
/// green: this manifest asks only whether the FILE was read, and the key
/// guards in `conformance_assertions.dart` only bind blocks a runner actually
/// reaches, so an unreplayed scenario contributes no unconsumed key and no
/// unasserted key. Skipping a whole scenario is invisible to a guard that only
/// inspects the scenarios you ran.
///
/// So there is a second ledger, written the same way and for the same reason —
/// at the point of replay, by [scenariosOf] / [scenarioNamed], never declared.
/// `scripts/check-conformance-coverage.sh` reads it and compares, for every
/// fixture the manifest says was opened, the ledger's ids against the ids the
/// fixture carries on disk.
library;

import 'dart:collection';
import 'dart:io';

import 'conformance_assertions.dart';

/// Re-exported so every runner that already imports this library also gets the
/// unconsumed-assertion-key guard (`#lzassertunknownkeys`) with no new import.
/// The two guards are the same idea one level apart: this file proves a fixture
/// was OPENED, `conformance_assertions.dart` proves its assertions were READ.
export 'conformance_assertions.dart';

/// Everything after this marker in a resolved path is the fixture's id, so the
/// manifest is keyed the same way the canonical corpus listing is.
const _conformanceMarker = 'lazily-spec/conformance/';

/// Ids already appended by THIS process. Deduplication is per-process only; the
/// manifest is a union across processes and the guard sorts and uniques it.
final Set<String> _recorded = <String>{};

/// [File.readAsStringSync] plus a record of any conformance fixture it opens.
extension SpecConformanceRead on File {
  String specReadAsStringSync() {
    recordConformanceRead(path);
    return readAsStringSync();
  }
}

/// Path-taking form, for call sites that do not already hold a [File].
String specReadFileSync(String path) => File(path).specReadAsStringSync();

/// Record [path] if it names a file inside the canonical conformance corpus.
///
/// The path is resolved to an absolute one first: test processes may run from a
/// different working directory than the package root, and the ids must be
/// comparable to the corpus listing regardless.
void recordConformanceRead(String path) {
  final absolute = File(path).absolute.path.replaceAll(r'\', '/');
  // Name the fixture for the unconsumed-key guard's failure message. Recorded
  // for the vendored mirrors too (`test/conformance/...`), which the manifest
  // below deliberately ignores: the manifest measures the canonical corpus,
  // this only labels an error.
  final vendored = absolute.indexOf('/conformance/');
  if (vendored != -1) {
    currentConformanceFixture = absolute.substring(vendored + 13);
  }
  final index = absolute.indexOf(_conformanceMarker);
  if (index == -1) return;
  final id = absolute.substring(index + _conformanceMarker.length);
  if (!_recorded.add(id)) return;
  _appendToManifest(id);
}

// ---------------------------------------------------------------------------
// Scenario ledger (`#lzscenariocoverage`)
// ---------------------------------------------------------------------------

/// Scenario ids already appended by THIS process, as `fixture\tid`.
final Set<String> _replayed = <String>{};

/// The id of one scenario, resolved the way every binding resolves it.
///
/// Fixed order, so a ledger written by one binding names the same scenarios as
/// a ledger written by any other:
///
///  1. `id`;
///  2. else `name`.
///
/// There is no third step (`#lzspecscenarioids`). The positional `#<n>` fallback
/// let the ledger record a scenario BY POSITION, where inserting one ahead of it
/// silently rebinds that entry — and any excuse naming it — to a different
/// scenario, with nothing turning red: the guard compares "index 1 was replayed"
/// against whatever now sits at index 1 and agrees with itself.
///
/// It was load-bearing for exactly one fixture,
/// `collections/mergecell_algebra.json`, whose three scenarios were
/// distinguished by `policy` alone. They carry ids now, and lazily-spec's
/// `scenario-identity-check` keeps every scenario identified — so this is a hole
/// with no users, which is one waiting to become load-bearing again.
///
/// A blank identifier is refused for the same reason: it would file every
/// blank-id scenario under one ledger entry, which reads as "replayed" the moment
/// any one of them runs.
String scenarioIdOf(Map<String, dynamic> scenario, int index) {
  final id = scenario['id'];
  if (id is String && id.trim().isNotEmpty) return id;
  final name = scenario['name'];
  if (name is String && name.trim().isNotEmpty) return name;
  throw StateError(
    'scenario at index $index carries neither `id` nor `name`. The replay ledger '
    'would have to record it by POSITION, where inserting a scenario ahead of it '
    'silently rebinds that entry to a different scenario. Give it a stable id '
    'upstream in lazily-spec (#lzspecscenarioids).',
  );
}

/// Record that [scenario] — the [index]th of [fixture] — was replayed.
///
/// The fixture is named from the decode-time attribution
/// ([fixtureOwnerOf]), falling back to the most recently read fixture. When
/// neither answers, nothing is recorded and the guard reports the scenario as
/// unreplayed: the ledger is EVIDENCE, and unattributable evidence is none.
///
/// Prefer [scenariosOf] / [scenarioNamed], which call this at the point of
/// replay so a runner cannot forget it.
void recordScenario(
  Map<String, dynamic> fixture,
  Map<String, dynamic> scenario,
  int index,
) {
  final owner = fixtureOwnerOf(fixture) ??
      fixtureOwnerOf(scenario) ??
      currentConformanceFixture;
  if (owner == null) return;
  final line = '$owner\t${scenarioIdOf(scenario, index)}';
  if (!_replayed.add(line)) return;
  _appendEvidence('LAZILY_CONFORMANCE_SCENARIOS', line);
}

/// Every scenario of [fixture], recording each id as it is YIELDED.
///
/// This is the seam the scenario guard hangs on. A fixture carrying four
/// scenarios of which a runner replays three is green under every other guard
/// in this repo — the coverage guard only asks whether the FILE was opened, and
/// the key guards only bind blocks a runner actually reaches, so an unreplayed
/// scenario contributes no unconsumed key. Recording here makes the skip
/// visible without any runner having to declare anything.
///
/// Yielding is NOT replaying (`#lzscenariobodyskip`). This used to book each
/// scenario as it handed it over, which cannot tell a loop body that ran from
/// one that `continue`d — the iterator sees the same thing either way — so a
/// skipped scenario booked itself and this rung stayed silent about the very
/// defect it exists for. lazily-py proved that against the contract's own probe.
///
/// The booking now rides on the scenario MAP: reading a payload key (`steps`,
/// `ops`, `frames`, `expect`, …) books it, while the keys in
/// [scenarioLabelKeys] stay silent, so a dispatch chain that reads `id`, matches
/// no arm and falls through books nothing. That makes booking intrinsic rather
/// than something a runner must remember: a `break` leaves the rest unbooked, a
/// `continue` past the payload leaves that one unbooked, and a body that returns
/// before touching the payload books nothing at all.
Iterable<Map<String, dynamic>> scenariosOf(Map<String, dynamic> fixture) sync* {
  final scenarios = (fixture['scenarios'] as List).cast<Map<String, dynamic>>();
  for (var i = 0; i < scenarios.length; i++) {
    yield _BookingScenario(fixture, scenarios[i], i);
  }
}

/// Keys that IDENTIFY or narrate a scenario rather than drive one.
///
/// Reading only these is *looking at the label*, not replaying: a dispatch chain
/// that reads `name`, matches no arm and falls through has replayed nothing, and
/// a by-id lookup walks past every scenario ahead of its match. Booking on those
/// reads is what let a skipped body book itself. Shared verbatim with every
/// other binding.
const scenarioLabelKeys = <String>{
  'comment',
  'description',
  'id',
  'label',
  'name',
  'note',
  'notes',
  'reason',
  'why',
};

/// One scenario, booked on the first read of its PAYLOAD.
///
/// A full `Map<String, dynamic>` (via [MapMixin]) so every runner keeps working
/// unchanged — `scenario['steps']` books, `scenario['id']` does not, and
/// `keys`/`containsKey`/`length` stay silent because inspecting a scenario's
/// SHAPE is not replaying it either.
class _BookingScenario with MapMixin<String, dynamic> {
  _BookingScenario(this._fixture, this._scenario, this._index);

  final Map<String, dynamic> _fixture;
  final Map<String, dynamic> _scenario;
  final int _index;
  bool _booked = false;

  @override
  dynamic operator [](Object? key) {
    if (!scenarioLabelKeys.contains(key)) _book();
    return _scenario[key];
  }

  /// Read a payload key WITHOUT booking. For a runner that must inspect a
  /// scenario it is not replaying.
  dynamic peek(String key) => _scenario[key];

  void _book() {
    if (_booked) return;
    _booked = true;
    recordScenario(_fixture, _scenario, _index);
  }

  @override
  Iterable<String> get keys => _scenario.keys;

  @override
  void operator []=(String key, dynamic value) => _scenario[key] = value;

  @override
  dynamic remove(Object? key) => _scenario.remove(key);

  @override
  void clear() => _scenario.clear();
}

/// The one scenario of [fixture] whose resolved id is [id], recording it.
///
/// For runners that reach for scenarios by name rather than iterating. Throws
/// when the fixture carries no such scenario, so a renamed scenario upstream
/// fails loudly instead of quietly replaying nothing — `firstWhere` without an
/// `orElse` already threw, and this keeps that while naming the ids on offer.
Map<String, dynamic> scenarioNamed(Map<String, dynamic> fixture, String id) {
  final scenarios = (fixture['scenarios'] as List).cast<Map<String, dynamic>>();
  for (var i = 0; i < scenarios.length; i++) {
    if (scenarioIdOf(scenarios[i], i) == id) {
      // The LOOKUP does not book (`#lzscenariobodyskip`): matching on the id
      // walks past every scenario ahead of it, and a caller could select one
      // and then return. The returned map books when its payload is read.
      return _BookingScenario(fixture, scenarios[i], i);
    }
  }
  throw StateError(
    'no scenario "$id" in ${fixtureOwnerOf(fixture) ?? currentConformanceFixture}'
    ' — it carries '
    '${[
      for (var i = 0; i < scenarios.length; i++) scenarioIdOf(scenarios[i], i)
    ]}',
  );
}

/// Append one id to the path in `LAZILY_CONFORMANCE_MANIFEST`.
///
/// APPEND, never truncate: `dart test` runs the suites concurrently and every
/// one of them must contribute to a single union. Appending on each recorded
/// read rather than at exit is deliberate — the test runner offers no reliable
/// per-suite exit hook, and a per-read append needs none.
///
/// The variable must hold an ABSOLUTE path (the Makefile passes `$(CURDIR)/...`);
/// a relative one would scatter partial manifests across whatever working
/// directory each runner process happens to use. Unset means the recorder is a
/// no-op, so a bare `dart test` is unaffected.
///
/// LOCK, THEN SEEK, THEN WRITE — and the lock is a lock FILE, not [RandomAccessFile.lockSync].
/// None of that is paranoia; each part was forced by a measured failure:
///
///  * Dart's [FileMode.append] does NOT give POSIX `O_APPEND` semantics. The
///    end-of-file offset is taken when the handle opens, so concurrent writers
///    land on the same offset and clobber one another. The first run of this
///    recorder emitted `sure.json`, `play_after_crash.json`, and
///    `_and_leaf_edit.json` — severed tails of three real fixture ids, whose
///    full lines were then reported as never opened. Hence the explicit
///    seek-to-length under the lock.
///  * `lockSync(FileLock.blockingExclusive)` is an fcntl lock, which is held per
///    PROCESS. `dart test` runs each suite in its own ISOLATE of one process, so
///    it grants no mutual exclusion there and instead throws `EDEADLK` when a
///    second isolate asks for a lock the process already holds. Swallowed, that
///    silently drops the record; the second run still lost one line.
///  * `File.createSync(exclusive: true)` is `O_EXCL`, one syscall, and therefore
///    exclusive across isolates AND processes alike.
///
/// Measured on 4 processes x 4 isolates writing 3200 lines: plain append kept
/// 2009 lines with 199 mangled, fcntl+seek kept 953 with 25 mangled, and
/// lockfile+seek kept 3200 with 0 mangled.
///
/// The spin has a deadline. A crashed writer must not wedge the suite, so after
/// it expires this writes anyway and accepts the small risk of a mangled line —
/// a stale lock is a worse failure than a racy one.
///
/// A write failure is swallowed. It surfaces downstream as missing evidence,
/// which is correct; failing a suite over bookkeeping is not.
void _appendToManifest(String id) => _appendEvidence(
      'LAZILY_CONFORMANCE_MANIFEST',
      id,
    );

void _appendEvidence(String variable, String line) {
  final out = Platform.environment[variable];
  if (out == null || out.isEmpty) return;
  final lock = File('$out.lock');
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  var held = false;
  while (true) {
    try {
      lock.createSync(exclusive: true);
      held = true;
      break;
    } catch (_) {
      if (!DateTime.now().isBefore(deadline)) break;
      sleep(const Duration(microseconds: 200));
    }
  }
  RandomAccessFile? handle;
  try {
    handle = File(out).openSync(mode: FileMode.append);
    handle.setPositionSync(handle.lengthSync());
    handle.writeStringSync('$line\n');
    handle.flushSync();
  } catch (_) {
    // Intentionally ignored — see above.
  } finally {
    try {
      handle?.closeSync();
    } catch (_) {
      // Intentionally ignored — see above.
    }
    if (held) {
      try {
        lock.deleteSync();
      } catch (_) {
        // Intentionally ignored — see above.
      }
    }
  }
}
