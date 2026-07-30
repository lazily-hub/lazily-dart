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
library;

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
void _appendToManifest(String id) {
  final out = Platform.environment['LAZILY_CONFORMANCE_MANIFEST'];
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
    handle.writeStringSync('$id\n');
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
