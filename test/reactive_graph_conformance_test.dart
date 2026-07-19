import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:lazily/lazily.dart';

/// Cross-language conformance for the reactive-graph corpus
/// (`#lzspecconf`, `#lzspecedgeindex`) — `lazily-spec/conformance/reactive-graph/*.json`.
///
/// ## Why this runner exists
///
/// `transitive_invalidation_reaches_depth.json` encodes exactly the defect that
/// shipped in this package's [AsyncContext] and was fixed in `c91a32a`: a chain
/// `cell -> a -> b -> c` served a stale value at depth forever. The fixture was
/// already in the shared corpus and dart replayed nothing from it. A binding
/// that only replays the corpus against its *default* context can pass while
/// its async path is broken, which is why every fixture here runs against BOTH
/// [Context] and [AsyncContext].
///
/// ## Resolution (`#lzspecconf`)
///
/// One sibling-relative path constant, no bundled copies. Absent sibling means
/// an explicit skip with the path named — never a silent green.
///
/// ## Partial op support
///
/// dart does not ship the teardown-scope plane (`begin_scope` / `end_scope` /
/// `dispose` / `disarm` / `effect` teardown ordering / `fanout` / `churn`), so
/// most of this corpus cannot run here yet. Those fixtures SKIP with the
/// unsupported ops NAMED in the skip message. A fixture is never silently
/// dropped, and a fixture that becomes runnable (because dart grew the op, or
/// because upstream simplified it) starts executing without anyone editing a
/// list.
///
/// ## Positive assertion (found vs executed)
///
/// The trap this guards is specific and was hit before: the fixture DIRECTORY
/// is non-empty, so "loaded something" is satisfied even when every case skips.
/// A previous dart runner was removed for exactly that reason — at the time
/// every remaining fixture needed ops dart lacks, so an on-disk-non-empty
/// assertion would have been vacuously green.
///
/// So the ledger counts fixtures **executed**, and a fixture only enters
/// `executed` after it has actually replayed ops AND evaluated assertions
/// (`ops > 0 && checks > 0`) — not when its file is found, not when it is
/// parsed, not when it is dispatched. The corpus assertion then requires a
/// non-empty executed set, requires the transitive-depth fixture by name (the
/// one pinning `c91a32a`), and requires non-zero total ops and checks.
const specDir = '../lazily-spec/conformance/reactive-graph';

/// Ops this package can model today. Anything else in a fixture skips it, by
/// name. Deliberately not a fixture allow-list: the runner derives runnability
/// from the fixture's own op stream.
const supportedOps = {'cell', 'computed', 'read', 'set_cell'};

/// Assertion keys understood by [_replay]. `note` is prose. An unrecognised key
/// is a hard failure, never a skip — otherwise a fixture could tighten its
/// expectations and dart would keep reporting green against the loose ones.
const knownExpectKeys = {'value', 'read', 'note'};

/// One execution model. Uniformly async so the sync and async contexts replay
/// through one engine and cannot drift apart.
abstract class _Model {
  String get name;

  void defineCell(String id, num value);

  void defineComputed(String id, List<String> reads, num offset);

  Future<num> read(String id);

  Future<void> setCell(String id, num value);

  Future<void> dispose() async {}
}

/// The synchronous [Context] with lazy [Slot]s and [Cell]s.
class _SyncModel implements _Model {
  final Context ctx = Context();
  final Map<String, Cell<num>> cells = {};
  final Map<String, Slot<num>> slots = {};

  @override
  String get name => 'Context';

  @override
  void defineCell(String id, num value) => cells[id] = Cell<num>(ctx, value);

  @override
  void defineComputed(String id, List<String> reads, num offset) {
    slots[id] = Slot<num>(ctx, (_) {
      var sum = offset;
      for (final r in reads) {
        sum += _readNode(r);
      }
      return sum;
    });
  }

  num _readNode(String id) {
    final cell = cells[id];
    if (cell != null) return cell.value;
    final slot = slots[id];
    if (slot != null) return slot();
    throw StateError('unknown node $id');
  }

  @override
  Future<num> read(String id) async => _readNode(id);

  @override
  Future<void> setCell(String id, num value) async {
    final cell = cells[id];
    if (cell == null) throw StateError('set_cell on unknown cell $id');
    cell.value = value;
  }

  @override
  Future<void> dispose() async {}
}

/// The [AsyncContext] — the path where the cascade defect fixed in `c91a32a`
/// actually lived.
class _AsyncModel implements _Model {
  final AsyncContext ctx = AsyncContext();
  final Map<String, AsyncCellHandle<num>> cells = {};
  final Map<String, AsyncSlotHandle<num>> slots = {};

  @override
  String get name => 'AsyncContext';

  @override
  void defineCell(String id, num value) => cells[id] = ctx.cell<num>(value);

  @override
  void defineComputed(String id, List<String> reads, num offset) {
    slots[id] = ctx.computedAsync<num>((cc) async {
      var sum = offset;
      for (final r in reads) {
        final cell = cells[r];
        if (cell != null) {
          sum += cc.getCell(cell);
          continue;
        }
        final slot = slots[r];
        if (slot == null) throw StateError('unknown node $r');
        sum += await cc.getAsync(slot);
      }
      return sum;
    });
  }

  @override
  Future<num> read(String id) async {
    final cell = cells[id];
    if (cell != null) return cell.get();
    final slot = slots[id];
    if (slot != null) return slot.getAsync();
    throw StateError('unknown node $id');
  }

  @override
  Future<void> setCell(String id, num value) async {
    final cell = cells[id];
    if (cell == null) throw StateError('set_cell on unknown cell $id');
    ctx.setCell(cell, value);
  }

  @override
  Future<void> dispose() => ctx.disposeAsync();
}

/// What a single fixture replay actually did. `ops`/`checks` are what promote a
/// fixture from "found" to "executed".
class _Report {
  int ops = 0;
  int checks = 0;
  final List<String> failures = [];
}

List<Map<String, dynamic>> _steps(Map<String, dynamic> fx) =>
    (fx['steps'] as List).cast<Map<String, dynamic>>();

Set<String> _opsOf(Map<String, dynamic> fx) {
  final shape = fx['shape'];
  final out = <String>{};
  if (shape == 'steps') {
    for (final step in _steps(fx)) {
      out.add((step['op'] as Map)['type'] as String);
    }
  } else if (shape == 'scenarios') {
    for (final sc in (fx['scenarios'] as List).cast<Map<String, dynamic>>()) {
      for (final step in (sc['steps'] as List).cast<Map<String, dynamic>>()) {
        out.add((step['op'] as Map)['type'] as String);
      }
    }
  } else {
    throw StateError('unknown fixture shape $shape');
  }
  return out;
}

Future<_Report> _replay(
    _Model model, String fixture, List<Map<String, dynamic>> steps) async {
  final report = _Report();

  for (var i = 0; i < steps.length; i++) {
    final step = steps[i];
    final op = (step['op'] as Map).cast<String, dynamic>();
    final type = op['type'] as String;
    final id = op['id'] as String;
    num? lastRead;

    switch (type) {
      case 'cell':
        model.defineCell(id, op['value'] as num);
      case 'computed':
        model.defineComputed(
          id,
          (op['reads'] as List).cast<String>(),
          (op['offset'] as num?) ?? 0,
        );
      case 'read':
        lastRead = await model.read(id);
      case 'set_cell':
        await model.setCell(id, op['value'] as num);
      default:
        throw StateError('$fixture#$i: unsupported op $type reached the '
            'engine — the runnability filter should have skipped this fixture');
    }
    report.ops++;

    final expect_ = (step['expect'] as Map?)?.cast<String, dynamic>();
    if (expect_ == null) continue;

    final unknown = expect_.keys.toSet().difference(knownExpectKeys);
    if (unknown.isNotEmpty) {
      throw StateError('$fixture#$i: unrecognised assertion key(s) '
          '${unknown.toList()..sort()} — refusing to report green against an '
          'assertion this runner does not evaluate');
    }

    if (expect_.containsKey('value')) {
      if (lastRead == null) {
        throw StateError('$fixture#$i: `value` asserted on a non-read op');
      }
      final want = expect_['value'] as num;
      if (lastRead != want) {
        report.failures.add('$fixture#$i:value — read($id) = $lastRead, '
            'expected $want');
      }
      report.checks++;
    }

    if (expect_.containsKey('read')) {
      final wants = (expect_['read'] as Map).cast<String, dynamic>();
      // Sorted so a divergence list is stable across runs.
      for (final key in wants.keys.toList()..sort()) {
        final got = await model.read(key);
        final want = wants[key] as num;
        if (got != want) {
          report.failures
              .add('$fixture#$i:read[$key] — got $got, expected $want');
        }
        report.checks++;
      }
    }
  }

  return report;
}

/// Replay the whole corpus against one execution model.
Future<void> _runCorpus(_Model Function() create, String modelName) async {
  final files = Directory(specDir)
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .map((f) => f.uri.pathSegments.last)
      .toList()
    ..sort();

  expect(files, isNotEmpty,
      reason: '$specDir contains no fixtures — the corpus would be vacuous');

  final executed = <String>{};
  final skipped = <String, List<String>>{};
  final failures = <String>[];
  var totalOps = 0;
  var totalChecks = 0;

  for (final name in files) {
    final fx = (jsonDecode(File('$specDir/$name').readAsStringSync()) as Map)
        .cast<String, dynamic>();
    final unsupported = _opsOf(fx).difference(supportedOps).toList()..sort();
    if (unsupported.isNotEmpty) {
      skipped[name] = unsupported;
      stderr.writeln('reactive-graph[$modelName] SKIP $name — unsupported '
          'op(s): ${unsupported.join(', ')}');
      continue;
    }
    if (fx['shape'] != 'steps') {
      skipped[name] = ['shape:${fx['shape']}'];
      stderr.writeln('reactive-graph[$modelName] SKIP $name — unsupported '
          'fixture shape ${fx['shape']}');
      continue;
    }

    final model = create();
    try {
      final report = await _replay(model, name, _steps(fx));
      failures.addAll(report.failures.map((f) => '$modelName/$f'));
      // Promotion to `executed` happens HERE and only here: after ops ran and
      // assertions were evaluated. Finding the file is not enough.
      if (report.ops > 0 && report.checks > 0) executed.add(name);
      totalOps += report.ops;
      totalChecks += report.checks;
      stderr.writeln('reactive-graph[$modelName] $name: ${report.ops} ops, '
          '${report.checks} assertions');
    } finally {
      await model.dispose();
    }
  }

  stderr.writeln('reactive-graph[$modelName]: ${executed.length}/'
      '${files.length} fixtures replayed, $totalOps ops, $totalChecks '
      'assertions, ${skipped.length} skipped');

  // A divergence is a FINDING against the implementation. Never relax the
  // fixture to make this pass.
  expect(failures, isEmpty,
      reason: 'reactive-graph divergence(s) against $modelName');

  expect(executed, isNotEmpty,
      reason: 'found ${files.length} fixture file(s) under $specDir but '
          'REPLAYED ZERO. A non-empty fixture directory is not evidence of '
          'coverage — skipped: $skipped');
  expect(executed, contains('transitive_invalidation_reaches_depth.json'),
      reason: 'the transitive-depth fixture pins the async invalidation '
          'cascade fixed in c91a32a and must run against every context');
  expect(totalOps, greaterThan(0), reason: 'executed zero ops');
  expect(totalChecks, greaterThan(0), reason: 'executed zero assertions');
}

void main() {
  if (!Directory(specDir).existsSync()) {
    stderr.writeln('skipping: $specDir absent - run with the lazily-spec '
        'sibling checked out');
    test(
      'reactive-graph conformance',
      () {},
      skip: '$specDir absent - clone lazily-spec as a sibling to run the '
          'reactive-graph fixtures',
    );
    return;
  }

  test('reactive-graph conformance [Context]',
      () => _runCorpus(_SyncModel.new, 'Context'));

  test('reactive-graph conformance [AsyncContext]',
      () => _runCorpus(_AsyncModel.new, 'AsyncContext'));
}
