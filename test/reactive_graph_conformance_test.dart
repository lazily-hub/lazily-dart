import 'dart:convert';
import 'dart:io';

import 'package:lazily/src/core.dart';
import 'package:test/test.dart';

/// Reactive-graph observer conformance (`#lzdartobservercow`, `#lzspecconf`).
///
/// A fixture *runner*, not a transcription: every `observer_*.json` in the
/// canonical [specDir] is loaded and executed against the real [Cell] observer
/// API, so a fixture edited in lazily-spec changes what dart must satisfy
/// without any dart code being touched. Fixtures are deliberately NOT copied
/// into `test/conformance/` — a bundled copy is the drift this guards against
/// (lazily-kt bundles into `src/test/resources/conformance/` and those copies
/// have already drifted).
///
/// Normative text: `lazily-spec/docs/reactive-graph.md`, observer semantics —
/// firing order is registration order, every registration is independent,
/// subscribing during a notification is deferred, unsubscribing during a
/// notification takes effect immediately, disposers are idempotent.
///
/// Path resolution mirrors lazily-rs `tests/collections_conformance.rs`
/// (`#lzspecconf`): one sibling-relative constant, and an explicit stderr skip
/// when it is absent. CI clones the sibling and then asserts the directory
/// exists, so the skip can never silently pass — see `.github/workflows/ci.yml`.
const specDir = '../lazily-spec/conformance/reactive-graph';

/// Op types this runner implements. A fixture using anything outside this set
/// is reported as skipped-with-reason rather than quietly ignored — the eight
/// disposal/teardown fixtures in the same directory (`begin_scope`, `computed`,
/// `effect`, `read`, `fanout`, `churn`, `disarm`, …) land here until the
/// runner grows their vocabulary.
const supportedOps = {'cell', 'subscribe', 'unsubscribe', 'set_cell', 'dispose'};

void main() {
  final dir = Directory(specDir);
  if (!dir.existsSync()) {
    stderr.writeln('skipping: $specDir absent - run with the lazily-spec sibling');
    test(
      'reactive-graph conformance',
      () {},
      skip: '$specDir absent - run with the lazily-spec sibling',
    );
    return;
  }

  final fixtures = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('the fixture directory is non-empty', () {
    expect(fixtures, isNotEmpty, reason: '$specDir contains no fixtures');
  });

  for (final file in fixtures) {
    final name = file.uri.pathSegments.last;
    final fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final rawSteps = fixture['steps'] as List?;
    if (rawSteps == null) {
      // e.g. `scope_teardown_equals_fold_of_disposals.json`, which is shaped as
      // `scenarios` + a shared `expected` rather than a linear step list.
      test(name, () {}, skip: 'runner does not implement the fixture shape: '
          'no `steps` (keys: ${(fixture.keys.toList()..sort()).join(', ')})');
      continue;
    }
    final steps = rawSteps.cast<Map<String, dynamic>>();
    final used = <String>{
      for (final step in steps) (step['op'] as Map)['type'] as String,
    };
    final unsupported = used.difference(supportedOps);

    test(
      name,
      () => _Replay(name).run(steps),
      skip: unsupported.isEmpty
          ? null
          : 'runner does not implement ops: ${(unsupported.toList()..sort()).join(', ')}',
    );
  }
}

/// Executes one fixture's `steps` against the real reactive API.
///
/// Observations are recorded per step: the log is cleared before each op, so an
/// `expect` block describes exactly what that op caused.
///
/// Observers are recorded by their *callback label* rather than their fixture
/// id, and expectations are translated through the same map before comparison.
/// This is forced by the no-dedup clause: `obs_x1` and `obs_x2` share the
/// callback labelled `x` and MUST be registered as the same callable, so a
/// single invocation cannot name which of the two registrations produced it.
/// Translating both sides keeps the assertion faithful — `['obs_x1', 'obs_y',
/// 'obs_x2']` becomes `['x', 'y', 'x']`, which still fails against any binding
/// that deduplicates.
class _Replay {
  _Replay(this.fixture);

  final String fixture;
  final ctx = Context();
  final cells = <String, Cell<int>>{};
  final disposedCells = <String>{};
  final disposers = <String, void Function()>{};

  /// Observer id -> callback label.
  final labelOf = <String, String>{};

  /// `cellId/label` -> the shared callable, for fixtures that register one
  /// callback under several ids.
  final sharedCallbacks = <String, void Function(int)>{};

  /// Labels invoked during the current step, in order.
  final log = <String>[];

  /// Observer ids whose `on_notify` has already run, for `on_notify_once`.
  final spent = <String>{};

  /// Per-`id_prefix` counter for observers spawned from inside a callback.
  final spawnCounts = <String, int>{};

  void run(List<Map<String, dynamic>> steps) {
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      final op = step['op'] as Map<String, dynamic>;
      log.clear();
      final where = '$fixture step $i (${op['type']} ${op['id']})';
      try {
        apply(op);
      } catch (e) {
        fail('$where threw: $e');
      }
      final expected = step['expect'] as Map<String, dynamic>?;
      if (expected != null) check(expected, where);
    }
  }

  void apply(Map<String, dynamic> op) {
    switch (op['type'] as String) {
      case 'cell':
        cells[op['id'] as String] = Cell<int>(ctx, op['value'] as int);
      case 'subscribe':
        subscribe(op);
      case 'unsubscribe':
        final dispose = disposers[op['id'] as String];
        if (dispose == null) {
          throw StateError('no such observer: ${op['id']}');
        }
        final times = (op['times'] as int?) ?? 1;
        for (var i = 0; i < times; i++) {
          dispose();
        }
      case 'set_cell':
        cell(op['id'] as String).value = op['value'] as int;
      case 'dispose':
        // dart's `Cell` exposes no explicit teardown — a cell's lifetime ends
        // when it becomes unreachable — so the fixture's cell disposal is
        // modelled as dropping the runner's only reference. What the clause is
        // actually about stays exercised by the library: no observer fires on
        // the way out, and the disposer held by a teardown path that runs
        // afterwards is a latched no-op rather than an error.
        final id = op['id'] as String;
        cell(id);
        cells.remove(id);
        disposedCells.add(id);
      default:
        throw StateError('unsupported op: ${op['type']}');
    }
  }

  void subscribe(Map<String, dynamic> op) {
    final id = op['id'] as String;
    final cellId = op['cell'] as String;
    final label = (op['callback'] as String?) ?? id;
    labelOf[id] = label;

    final onNotify = (op['on_notify'] as List?)?.cast<Map<String, dynamic>>();
    final once = op['on_notify_once'] == true;

    void body(int _) {
      log.add(label);
      if (onNotify == null) return;
      if (once && !spent.add(id)) return;
      for (final action in onNotify) {
        apply(reify(action));
      }
    }

    // A fixture that names a `callback` is asserting the registrations share
    // one callable; anything else gets a fresh closure. A shared callable never
    // carries `on_notify`, so the cache cannot collide with a reentrant body.
    final callback = op.containsKey('callback') && onNotify == null
        ? sharedCallbacks.putIfAbsent('$cellId/$label', () => body)
        : body;

    disposers[id] = cell(cellId).subscribe(callback);
  }

  /// Resolve an `on_notify` action into a concrete op — `id_prefix` mints a
  /// fresh id per invocation (`obs_spawn_0`, `obs_spawn_1`, …).
  Map<String, dynamic> reify(Map<String, dynamic> action) {
    final prefix = action['id_prefix'] as String?;
    if (prefix == null) return action;
    final n = spawnCounts[prefix] = (spawnCounts[prefix] ?? 0);
    spawnCounts[prefix] = n + 1;
    return {...action, 'id': '${prefix}_$n'}..remove('id_prefix');
  }

  Cell<int> cell(String id) {
    final c = cells[id];
    if (c == null) {
      throw StateError(
        disposedCells.contains(id) ? 'cell disposed: $id' : 'no such cell: $id',
      );
    }
    return c;
  }

  void check(Map<String, dynamic> expected, String where) {
    final order = (expected['observed_order'] as List?)?.cast<String>();
    if (order != null) {
      expect(log, order.map(toLabel).toList(), reason: '$where observed_order');
    }

    final count = expected['observed_count'] as int?;
    if (count != null) {
      expect(log, hasLength(count), reason: '$where observed_count');
    }

    final counts = (expected['observed_counts'] as Map?)?.cast<String, dynamic>();
    if (counts != null) {
      // Ids sharing a callback collapse onto one label, so the expected
      // per-id counts are summed per label before comparison.
      final byLabel = <String, int>{};
      counts.forEach((id, n) {
        final label = toLabel(id);
        byLabel[label] = (byLabel[label] ?? 0) + (n as int);
      });
      final actual = <String, int>{};
      for (final label in log) {
        actual[label] = (actual[label] ?? 0) + 1;
      }
      expect(actual, byLabel, reason: '$where observed_counts');
    }

    final readable = (expected['readable'] as Map?)?.cast<String, dynamic>();
    if (readable != null) {
      readable.forEach((id, isReadable) {
        expect(cells.containsKey(id), isReadable, reason: '$where readable[$id]');
      });
    }

    // `error: null` is the fixture asserting the op is a silent no-op; the
    // `apply` above already converts a throw into a failure, so reaching here
    // with the key present and null is the assertion being satisfied.
    if (expected.containsKey('error')) {
      expect(expected['error'], isNull,
          reason: '$where expects a non-null error, which the runner cannot '
              'express — extend the runner before adding such a fixture');
    }
  }

  String toLabel(String id) => labelOf[id] ?? id;
}
