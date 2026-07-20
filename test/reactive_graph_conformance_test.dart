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
/// ## Op coverage
///
/// The whole corpus: `cell`, `computed`, `effect`, `read`, `set_cell`,
/// `dispose`, `begin_scope`, `end_scope`, `disarm`, `fanout`, `dispose_fanout`,
/// `churn`, and `dispose_stale_handle`; both the `steps` and the `scenarios`
/// shapes. Runnability is still derived from each fixture's own op stream
/// rather than from a fixture allow-list, so an op added upstream skips *by
/// name* instead of failing obscurely or — worse — being silently dropped.
///
/// ## Positive assertion (found vs executed)
///
/// The trap this guards is specific and was hit before: the fixture DIRECTORY
/// is non-empty, so "loaded something" is satisfied even when every case skips.
/// A previous dart runner was removed for exactly that reason — at the time
/// every remaining fixture needed ops dart lacked, so an on-disk-non-empty
/// assertion would have been vacuously green.
///
/// So the ledger counts fixtures **executed**, and a fixture only enters
/// `executed` after it has actually replayed ops AND evaluated assertions
/// (`ops > 0 && checks > 0`) — not when its file is found, not when it is
/// parsed, not when it is dispatched. The corpus assertion then requires the
/// on-disk fixture set to equal [expectedFixtures] exactly, requires every one
/// of them to have been replayed, requires the transitive-depth fixture by name
/// (the one pinning `c91a32a`), and requires non-zero total ops and checks.
///
/// ## Divergence ledger
///
/// A fixture assertion the implementation does not satisfy is recorded, not
/// silently tolerated, and the observed set must equal [knownDivergences]
/// *exactly*. That asserts in both directions: a new divergence fails the
/// build, and a fixed one fails it until its entry is deleted. Neither can pass
/// unnoticed, and neither is ever addressed by relaxing a fixture.
const specDir = '../lazily-spec/conformance/reactive-graph';

/// The canonical fixture set, asserted against the directory listing so a
/// fixture added or renamed upstream fails loudly instead of going unrun.
const expectedFixtures = {
  'churn_returns_to_baseline.json',
  'cross_scope_teardown_hazard.json',
  'disarm_disposes_nothing.json',
  'dispose_detaches_edges_both_directions.json',
  'read_after_dispose_is_an_error.json',
  'recycled_id_inherits_nothing.json',
  'scope_teardown_equals_fold_of_disposals.json',
  'scoping_bounds_teardown_not_visibility.json',
  'transitive_invalidation_reaches_depth.json',
};

/// Ops this package can model. Anything else in a fixture skips it, by name.
const supportedOps = {
  'begin_scope',
  'cell',
  'churn',
  'computed',
  'disarm',
  'dispose',
  'dispose_fanout',
  'dispose_stale_handle',
  'effect',
  'end_scope',
  'fanout',
  'read',
  'set_cell',
};

/// Assertion keys understood by [_replay]. `note` is prose. An unrecognised key
/// is a hard failure, never a skip — otherwise a fixture could tighten its
/// expectations and dart would keep reporting green against the loose ones.
const knownExpectKeys = {
  'cleanup_order',
  'dependencies_of',
  'dependents_of',
  'error',
  'note',
  'observed_by',
  'observed_count',
  'read',
  'readable',
  'scope_owned_count',
  'value',
};

/// Fixture assertions an execution model does not satisfy today, as
/// `<model>/<fixture>[<scenario>]: <detail>`.
///
/// Each entry would be a finding against the implementation, never a
/// relaxation of a fixture. Empty, and it must stay empty unless a real
/// divergence is found.
const knownDivergences = <String>{};

/// The kind of a node, as the corpus distinguishes them. `dispose_stale_handle`
/// is the only op that needs it: tearing down through a handle whose id has
/// been recycled onto a node of another kind must be a no-op, so the kind is
/// read from the graph rather than remembered by the caller.
enum _Kind { cell, slot, effect }

/// One execution model. Uniformly async so the sync and async contexts replay
/// through one engine and cannot drift apart.
///
/// The model owns the id -> node registry rather than handing typed handles
/// back to the engine. Dart's two graphs have unrelated node types
/// ([GraphNode] vs [AsyncGraphNode]) with no common supertype, and making the
/// engine generic over them would buy nothing: every op the corpus names is
/// addressed by fixture id anyway.
abstract class _Model {
  String get name;

  /// Effect names, in the order their bodies ran.
  List<String> get runLog;

  /// Effect names, in the order their cleanups ran. Cumulative for the whole
  /// replay — the individual-disposal scenario spreads three disposals over
  /// three steps and pins the whole order on the last one.
  List<String> get cleanupLog;

  void defineCell(String id, num value, String? scope);

  void defineComputed(String id, List<String> reads, num offset, String? scope);

  void defineEffect(String id, List<String> reads, String? scope);

  /// Throws [DisposedNodeError] when the node — or a node it reads through —
  /// has been disposed. That throw is the corpus's `read_after_dispose`.
  Future<num> read(String id);

  Future<void> setCell(String id, num value);

  Future<void> disposeId(String id);

  _Kind kindOf(String id);

  bool isEffectActive(String id);

  int dependentsOf(String id);

  int dependenciesOf(String id);

  void beginScope(String name);

  Future<void> endScope(String name);

  void disarmScope(String name);

  int scopeOwned(String name);

  /// Drive the model to quiescence before assertions are evaluated.
  ///
  /// Synchronous models are already quiescent when an op returns. Async effects
  /// are driven by futures, so the async model must let the event loop run them
  /// before `observed_by`, `observed_count`, or any degree assertion can mean
  /// anything. This changes *when* assertions are evaluated, never *what* they
  /// assert: an effect that never runs still fails.
  Future<void> settle();

  Future<void> dispose();
}

/// The synchronous [Context] with lazy [Slot]s, [Cell]s, [Effect]s, and
/// [TeardownScope]s.
class _SyncModel implements _Model {
  final Context ctx = Context();
  final Map<String, GraphNode> nodes = {};
  final Map<String, TeardownScope> scopes = {};

  @override
  final List<String> runLog = [];
  @override
  final List<String> cleanupLog = [];

  @override
  String get name => 'Context';

  @override
  void defineCell(String id, num value, String? scope) {
    final cell = Cell<num>(ctx, value);
    if (scope != null) scopes[scope]!.adopt(cell);
    nodes[id] = cell;
  }

  @override
  void defineComputed(
      String id, List<String> reads, num offset, String? scope) {
    final slot = Slot<num>(ctx, (_) {
      var sum = offset;
      for (final r in reads) {
        sum += _readNode(r);
      }
      return sum;
    }, name: id);
    if (scope != null) scopes[scope]!.adopt(slot);
    nodes[id] = slot;
  }

  @override
  void defineEffect(String id, List<String> reads, String? scope) {
    final effect = Effect(ctx, (_) {
      runLog.add(id);
      // Swallowed, not propagated: an effect that reads through a disposed node
      // must not turn the publish that scheduled it into a throw. The corpus
      // asserts read-after-dispose at top-level reads.
      try {
        for (final r in reads) {
          _readNode(r);
        }
      } on DisposedNodeError {
        // Observed by the top-level read that names the same node.
      }
      return () => cleanupLog.add(id);
    });
    if (scope != null) scopes[scope]!.adopt(effect);
    nodes[id] = effect;
  }

  num _readNode(String id) {
    final node = nodes[id];
    if (node is Cell<num>) return node.value;
    if (node is Slot<num>) return node();
    throw StateError('unknown or unreadable node $id');
  }

  @override
  Future<num> read(String id) async => _readNode(id);

  @override
  Future<void> setCell(String id, num value) async {
    final cell = nodes[id];
    if (cell is! Cell<num>) throw StateError('set_cell on non-cell $id');
    cell.value = value;
  }

  @override
  Future<void> disposeId(String id) async {
    // The entry stays in the map: a disposed node remains readable-as-an-error,
    // and disposing it again must be a no-op.
    ctx.disposeNode(nodes[id]!);
  }

  @override
  _Kind kindOf(String id) {
    final node = nodes[id];
    if (node is Cell) return _Kind.cell;
    if (node is Effect) return _Kind.effect;
    return _Kind.slot;
  }

  @override
  bool isEffectActive(String id) => (nodes[id] as Effect).isActive;

  @override
  int dependentsOf(String id) => ctx.dependentCount(nodes[id]!);

  @override
  int dependenciesOf(String id) => ctx.dependencyCount(nodes[id]!);

  @override
  void beginScope(String name) => scopes[name] = ctx.scope();

  @override
  Future<void> endScope(String name) async => scopes[name]!.end();

  @override
  void disarmScope(String name) => scopes[name]!.disarm();

  @override
  int scopeOwned(String name) => scopes[name]!.length;

  @override
  Future<void> settle() async {}

  @override
  Future<void> dispose() async {}
}

/// The [AsyncContext] — the path where the cascade defect fixed in `c91a32a`
/// actually lived, and the one where a disposal leak is hardest to notice.
class _AsyncModel implements _Model {
  final AsyncContext ctx = AsyncContext();
  final Map<String, AsyncGraphNode> nodes = {};
  final Map<String, AsyncTeardownScope> scopes = {};

  @override
  final List<String> runLog = [];
  @override
  final List<String> cleanupLog = [];

  @override
  String get name => 'AsyncContext';

  @override
  void defineCell(String id, num value, String? scope) {
    final cell = ctx.cell<num>(value);
    if (scope != null) scopes[scope]!.adopt(cell);
    nodes[id] = cell;
  }

  @override
  void defineComputed(
      String id, List<String> reads, num offset, String? scope) {
    final slot = ctx.computedAsync<num>((cc) async {
      var sum = offset;
      for (final r in reads) {
        sum += await _readNode(cc, r);
      }
      return sum;
    });
    if (scope != null) scopes[scope]!.adopt(slot);
    nodes[id] = slot;
  }

  @override
  void defineEffect(String id, List<String> reads, String? scope) {
    final effect = ctx.effectAsync((cc) async {
      runLog.add(id);
      try {
        for (final r in reads) {
          await _readNode(cc, r);
        }
      } on DisposedNodeError {
        // See the sync model.
      }
      return () async => cleanupLog.add(id);
    });
    if (scope != null) scopes[scope]!.adopt(effect);
    nodes[id] = effect;
  }

  Future<num> _readNode(AsyncComputeContext cc, String id) async {
    final node = nodes[id];
    if (node is AsyncCellHandle<num>) return cc.getCell(node);
    if (node is AsyncSlotHandle<num>) return cc.getAsync(node);
    throw StateError('unknown or unreadable node $id');
  }

  @override
  Future<num> read(String id) async {
    final node = nodes[id];
    if (node is AsyncCellHandle<num>) return node.get();
    if (node is AsyncSlotHandle<num>) return node.getAsync();
    throw StateError('unknown or unreadable node $id');
  }

  @override
  Future<void> setCell(String id, num value) async {
    final cell = nodes[id];
    if (cell is! AsyncCellHandle<num>) {
      throw StateError('set_cell on non-cell $id');
    }
    ctx.setCell(cell, value);
  }

  @override
  Future<void> disposeId(String id) => ctx.disposeNode(nodes[id]!);

  @override
  _Kind kindOf(String id) {
    final node = nodes[id];
    if (node is AsyncCellHandle) return _Kind.cell;
    if (node is AsyncEffectHandle) return _Kind.effect;
    return _Kind.slot;
  }

  @override
  bool isEffectActive(String id) =>
      ctx.isEffectActive(nodes[id] as AsyncEffectHandle);

  @override
  int dependentsOf(String id) => ctx.dependentCount(nodes[id]!);

  @override
  int dependenciesOf(String id) => ctx.dependencyCount(nodes[id]!);

  @override
  void beginScope(String name) => scopes[name] = ctx.scope();

  @override
  Future<void> endScope(String name) => scopes[name]!.end();

  @override
  void disarmScope(String name) => scopes[name]!.disarm();

  @override
  int scopeOwned(String name) => scopes[name]!.length;

  /// Pump the event loop until the async graph is quiescent. Each
  /// `Future.delayed(Duration.zero)` drains the whole microtask queue, so a
  /// handful of turns covers an effect body that awaits a chain of slots.
  @override
  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  @override
  Future<void> dispose() => ctx.disposeAsync();
}

/// Everything a scenario leaves behind that `observationally_equal` compares.
class _Observation {
  List<String> cleanupOrder = const [];
  final Map<String, bool> readable = {};
  final Map<String, Object?> reads = {};
  List<String> afterPublishObserved = const [];
  final Map<String, Object?> afterPublishReads = {};
  final Map<String, int> degrees = {};

  String describe() => jsonEncode({
        'cleanup_order': cleanupOrder,
        'readable': _sorted(readable),
        'reads': _sorted(reads),
        'after_publish_observed': afterPublishObserved,
        'after_publish_reads': _sorted(afterPublishReads),
        'degrees': _sorted(degrees),
      });

  static Map<String, Object?> _sorted(Map<String, Object?> m) =>
      {for (final k in m.keys.toList()..sort()) k: m[k]};
}

/// What a single fixture replay actually did. `ops`/`checks` are what promote a
/// fixture from "found" to "executed".
class _Report {
  int ops = 0;
  int checks = 0;
  final List<String> failures = [];
  final _Observation observation = _Observation();
}

List<Map<String, dynamic>> _stepsOf(Map<String, dynamic> node) =>
    (node['steps'] as List).cast<Map<String, dynamic>>();

List<Map<String, dynamic>> _scenariosOf(Map<String, dynamic> fx) =>
    (fx['scenarios'] as List).cast<Map<String, dynamic>>();

Set<String> _opsOf(Map<String, dynamic> fx) {
  final shape = fx['shape'];
  final out = <String>{};
  if (shape == 'steps') {
    for (final step in _stepsOf(fx)) {
      out.add((step['op'] as Map)['type'] as String);
    }
  } else if (shape == 'scenarios') {
    for (final sc in _scenariosOf(fx)) {
      for (final step in _stepsOf(sc)) {
        out.add((step['op'] as Map)['type'] as String);
      }
    }
  } else {
    throw StateError('unknown fixture shape $shape');
  }
  return out;
}

List<String> _strs(Object? v) =>
    (v as List?)?.cast<String>().toList() ?? const [];

/// Replay one op stream. [tail] is the `scenarios` shape's `expected` block,
/// evaluated against the final world state when present.
Future<_Report> _replay(
  _Model model,
  String fixture,
  List<Map<String, dynamic>> steps,
  Map<String, dynamic>? tail,
) async {
  final report = _Report();
  var stepIdx = 0;

  void check(String key, Object? got, Object? want) {
    report.checks++;
    final g = got is List ? got.join(',') : got;
    final w = want is List ? want.join(',') : want;
    if (g != w) {
      report.failures.add('#$stepIdx:$key — got $got, want $want');
    }
  }

  // A top-level read. A DisposedNodeError — thrown by the node itself or by a
  // node it recomputes through — is the corpus's `read_after_dispose`.
  Future<(num?, bool)> readId(String id) async {
    try {
      return (await model.read(id), false);
    } on DisposedNodeError {
      return (null, true);
    }
  }

  /// `readable` is "can this node still be observed", which for an effect is
  /// registration rather than a value.
  Future<bool> alive(String id) async {
    if (model.kindOf(id) == _Kind.effect) return model.isEffectActive(id);
    final (_, err) = await readId(id);
    return !err;
  }

  for (var i = 0; i < steps.length; i++) {
    stepIdx = i;
    final step = steps[i];
    final op = (step['op'] as Map).cast<String, dynamic>();
    final type = op['type'] as String;
    final scope = op['scope'] as String?;
    final runsBefore = model.runLog.length;
    num? opValue;
    var opError = false;
    report.ops++;

    switch (type) {
      case 'cell':
        model.defineCell(op['id'] as String, op['value'] as num, scope);
      case 'computed':
        model.defineComputed(
          op['id'] as String,
          (op['reads'] as List).cast<String>(),
          (op['offset'] as num?) ?? 0,
          scope,
        );
      case 'effect':
        model.defineEffect(
          op['id'] as String,
          (op['reads'] as List).cast<String>(),
          scope,
        );
      case 'read':
        final (value, err) = await readId(op['id'] as String);
        opValue = value;
        opError = err;
      case 'set_cell':
        await model.setCell(op['id'] as String, op['value'] as num);
      case 'dispose':
        await model.disposeId(op['id'] as String);
      case 'fanout':
        // Subscribers are effects, not derived slots: the corpus asserts
        // `observed_count` on a publish, and in a lazy binding only an eager
        // reader observes a publish without being pulled.
        final prefix = op['id_prefix'] as String;
        final reads = (op['reads'] as List).cast<String>();
        for (var n = 0; n < (op['count'] as num); n++) {
          model.defineEffect('${prefix}_$n', reads, null);
        }
      case 'dispose_fanout':
        final prefix = op['id_prefix'] as String;
        for (var n = 0; n < (op['count'] as num); n++) {
          await model.disposeId('${prefix}_$n');
        }
      case 'churn':
        await _churn(model, op);
      case 'begin_scope':
        model.beginScope(op['scope'] as String);
      case 'end_scope':
        await model.endScope(op['scope'] as String);
      case 'disarm':
        // A disarmed scope owns nothing; it stays open under the same name so a
        // later `end_scope` is the no-op the fixture asserts.
        model.disarmScope(op['scope'] as String);
      case 'dispose_stale_handle':
        final of = op['handle_of'] as String;
        final want = op['handle_kind'] as String;
        expect(model.kindOf(of).name, want,
            reason: '$fixture#$i: handle_kind does not match recorded handle');
        await model.disposeId(of);
      default:
        throw StateError('$fixture#$i: unsupported op $type reached the '
            'engine — the runnability filter should have skipped this fixture');
    }

    await model.settle();
    final observed = model.runLog.sublist(runsBefore);

    final expect_ = (step['expect'] as Map?)?.cast<String, dynamic>();
    if (expect_ == null) continue;

    final unknown = expect_.keys.toSet().difference(knownExpectKeys);
    if (unknown.isNotEmpty) {
      throw StateError('$fixture#$i: unrecognised assertion key(s) '
          '${unknown.toList()..sort()} — refusing to report green against an '
          'assertion this runner does not evaluate');
    }

    // Sorted so evaluation order is deterministic and matches the reference
    // runner's. It is load-bearing, not cosmetic: `dependents_of` sorts before
    // `read`, and a lazy binding re-registers edges when it recomputes, so
    // reading first would change the degree the same step then asserts.
    for (final key in expect_.keys.toList()..sort()) {
      final want = expect_[key];
      switch (key) {
        case 'note':
          break;
        case 'dependents_of':
          final m = (want as Map).cast<String, dynamic>();
          for (final id in m.keys.toList()..sort()) {
            check('dependents_of.$id', model.dependentsOf(id), m[id]);
          }
        case 'dependencies_of':
          final m = (want as Map).cast<String, dynamic>();
          for (final id in m.keys.toList()..sort()) {
            check('dependencies_of.$id', model.dependenciesOf(id), m[id]);
          }
        case 'error':
          if (want == null) {
            check('error', opError, false);
          } else if (want == 'read_after_dispose') {
            check('error', opError, true);
          } else {
            throw StateError('$fixture#$i: unknown expected error $want');
          }
        case 'value':
          if (expect_['error'] == null) {
            check('value', opError ? 'read_after_dispose' : opValue, want);
          }
        case 'read':
          final m = (want as Map).cast<String, dynamic>();
          for (final id in m.keys.toList()..sort()) {
            final (value, err) = await readId(id);
            check('read.$id', err ? 'read_after_dispose' : value, m[id]);
          }
        case 'readable':
          final m = (want as Map).cast<String, dynamic>();
          for (final id in m.keys.toList()..sort()) {
            check('readable.$id', await alive(id), m[id]);
          }
        case 'observed_by':
          check('observed_by', observed, _strs(want));
        case 'observed_count':
          check('observed_count', observed.length, want);
        case 'cleanup_order':
          // Only effects run a cleanup callback, so the expected order is
          // projected onto its effect entries.
          final wanted = _strs(want)
              .where((id) => model.kindOf(id) == _Kind.effect)
              .toList();
          check('cleanup_order', model.cleanupLog, wanted);
        case 'scope_owned_count':
          final m = (want as Map).cast<String, dynamic>();
          for (final n in m.keys.toList()..sort()) {
            check('scope_owned_count.$n', model.scopeOwned(n), m[n]);
          }
        default:
          throw StateError('$fixture#$i: unhandled assertion key $key');
      }
    }
  }

  // -- `scenarios`-shaped tail ----------------------------------------------
  report.observation.cleanupOrder = List.of(model.cleanupLog);
  if (tail == null) return report;

  stepIdx = -1; // the `expected` tail is not a numbered step
  final finalState = (tail['final_state'] as Map?)?.cast<String, dynamic>();
  if (finalState != null) {
    final degrees =
        (finalState['dependents_of'] as Map?)?.cast<String, dynamic>() ?? {};
    for (final id in degrees.keys.toList()..sort()) {
      final got = model.dependentsOf(id);
      check('final.dependents_of.$id', got, degrees[id]);
      report.observation.degrees[id] = got;
    }
    final readable =
        (finalState['readable'] as Map?)?.cast<String, dynamic>() ?? {};
    for (final id in readable.keys.toList()..sort()) {
      final ok = await alive(id);
      check('final.readable.$id', ok, readable[id]);
      report.observation.readable[id] = ok;
    }
    final reads = (finalState['read'] as Map?)?.cast<String, dynamic>() ?? {};
    for (final id in reads.keys.toList()..sort()) {
      final (value, err) = await readId(id);
      final got = err ? 'read_after_dispose' : value;
      check('final.read.$id', got, reads[id]);
      report.observation.reads[id] = got;
    }
  }

  final publish = (tail['after_publish'] as Map?)?.cast<String, dynamic>();
  final publishOp = (publish?['op'] as Map?)?.cast<String, dynamic>();
  if (publish != null && publishOp != null) {
    final before = model.runLog.length;
    await model.setCell(publishOp['id'] as String, publishOp['value'] as num);
    await model.settle();
    report.observation.afterPublishObserved = model.runLog.sublist(before);
    check('after_publish.observed_by', report.observation.afterPublishObserved,
        _strs(publish['observed_by']));
    // Order matches the reference runner: reads (which re-register edges in a
    // lazy binding) precede the degree assertions that count them.
    final reads = (publish['read'] as Map?)?.cast<String, dynamic>() ?? {};
    for (final id in reads.keys.toList()..sort()) {
      final (value, err) = await readId(id);
      final got = err ? 'read_after_dispose' : value;
      check('after_publish.read.$id', got, reads[id]);
      report.observation.afterPublishReads[id] = got;
    }
    final degrees =
        (publish['dependents_of'] as Map?)?.cast<String, dynamic>() ?? {};
    for (final id in degrees.keys.toList()..sort()) {
      check('after_publish.dependents_of.$id', model.dependentsOf(id),
          degrees[id]);
    }
  }

  return report;
}

Future<void> _churn(_Model model, Map<String, dynamic> op) async {
  final source = op['source'] as String;
  final prefix = op['id_prefix'] as String;
  final width = (op['live_width'] as num).toInt();
  final cycles = (op['cycles'] as num).toInt();
  switch (op['mode'] as String) {
    // Hold `live_width` subscribers; each cycle disposes one and creates its
    // replacement, so the live count is invariant.
    case 'dispose_then_create':
      for (var c = 0; c < cycles; c++) {
        final id = '${prefix}_${c % width}';
        await model.disposeId(id);
        model.defineEffect(id, [source], null);
      }
    // One teardown scope per cycle; its subscriber is gone by the end of its
    // own cycle, so it contributes nothing to the steady-state count.
    case 'scope_per_cycle':
      final scopeName = '${prefix}_scoped';
      for (var c = 0; c < cycles; c++) {
        model.beginScope(scopeName);
        model.defineEffect('${prefix}_scoped_member', [source], scopeName);
        await model.endScope(scopeName);
      }
    default:
      throw StateError('unknown churn mode ${op['mode']}');
  }
}

/// Replay the whole corpus against one execution model.
Future<void> _runCorpus(_Model Function() create, String modelName) async {
  final files = Directory(specDir)
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .map((f) => f.uri.pathSegments.last)
      .toSet();

  expect(files, equals(expectedFixtures),
      reason: 'reactive-graph fixture set drifted; every fixture must be '
          'replayed by this runner');

  final executed = <String>{};
  final skipped = <String, List<String>>{};
  final divergences = <String>{};
  var totalOps = 0;
  var totalChecks = 0;

  for (final name in expectedFixtures.toList()..sort()) {
    final fx = (jsonDecode(File('$specDir/$name').readAsStringSync()) as Map)
        .cast<String, dynamic>();
    final unsupported = _opsOf(fx).difference(supportedOps).toList()..sort();
    if (unsupported.isNotEmpty) {
      skipped[name] = unsupported;
      stderr.writeln('reactive-graph[$modelName] SKIP $name — unsupported '
          'op(s): ${unsupported.join(', ')}');
      continue;
    }

    // Dispatch on the fixture's declared `shape`, not on its filename: a
    // filename special case goes stale the moment a second scenarios-shaped
    // fixture is added. An unrecognised shape is a hard error.
    final shape = fx['shape'];
    final models = <_Model>[];
    final reports = <_Report>[];
    try {
      if (shape == 'steps') {
        final model = create();
        models.add(model);
        reports.add(await _replay(model, name, _stepsOf(fx), null));
      } else if (shape == 'scenarios') {
        final tail = (fx['expected'] as Map?)?.cast<String, dynamic>();
        for (final sc in _scenariosOf(fx)) {
          // Each scenario gets its own context: `observationally_equal` is a
          // claim about two independent worlds, not about one world twice.
          final model = create();
          models.add(model);
          reports.add(await _replay(model, name, _stepsOf(sc), tail));
        }
      } else {
        throw StateError('$name: unknown fixture shape $shape');
      }

      // `observationally_equal`: the named scenarios must agree on every
      // observable, not merely each satisfy `expected` independently. This is
      // the whole reason the `scenarios` shape exists — a relation between two
      // op streams is not expressible in a single `steps` array.
      final pair = _strs((fx['expected'] as Map?)?['observationally_equal']);
      if (pair.isNotEmpty) {
        final names = _scenariosOf(fx).map((s) => s['name'] as String).toList();
        final idx = pair.map((p) {
          final at = names.indexOf(p);
          if (at < 0) throw StateError('$name: unknown scenario $p');
          return at;
        }).toList();
        for (var w = 1; w < idx.length; w++) {
          final a = reports[idx[w - 1]].observation.describe();
          final b = reports[idx[w]].observation.describe();
          if (a != b) {
            reports[idx[w]].failures.add(
                '#observationally_equal — ${pair[w - 1]} $a != ${pair[w]} $b');
          }
        }
        totalChecks++;
      }
    } finally {
      for (final model in models) {
        await model.dispose();
      }
    }

    final ops = reports.fold(0, (a, r) => a + r.ops);
    final checks = reports.fold(0, (a, r) => a + r.checks);
    expect(ops, greaterThan(0), reason: '$modelName/$name: replayed zero ops');
    expect(checks, greaterThan(0),
        reason: '$modelName/$name: replayed zero assertions');

    for (var si = 0; si < reports.length; si++) {
      for (final f in reports[si].failures) {
        final tag = reports.length > 1 ? '[$si]' : '';
        final entry = '$modelName/$name$tag$f';
        stderr.writeln('  DIVERGENCE $entry');
        divergences.add(entry);
      }
    }

    // Promotion to `executed` happens HERE and only here: after ops ran and
    // assertions were evaluated. Finding the file is not enough.
    executed.add(name);
    totalOps += ops;
    totalChecks += checks;
    stderr.writeln(
        'reactive-graph[$modelName] $name: $ops ops, $checks assertions');
  }

  stderr.writeln('reactive-graph[$modelName]: ${executed.length}/'
      '${expectedFixtures.length} fixtures replayed, $totalOps ops, '
      '$totalChecks assertions, ${skipped.length} skipped, '
      '${divergences.length} divergences');

  // Divergence ledger: the observed set must equal the documented one, so a new
  // divergence fails the build and a fixed one forces its entry to be deleted.
  // A divergence is a FINDING against the implementation. Never relax the
  // fixture to make this pass.
  final documented =
      knownDivergences.where((d) => d.startsWith('$modelName/')).toSet();
  expect(divergences, equals(documented),
      reason: '$modelName: divergence ledger is stale — update '
          'knownDivergences (left = observed, right = documented)');

  expect(executed, equals(expectedFixtures),
      reason: 'found ${expectedFixtures.length} fixture file(s) under $specDir '
          'but did not replay them all. A non-empty fixture directory is not '
          'evidence of coverage — skipped: $skipped');
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
      () => _runCorpus(_SyncModel.new, 'Context'),
      timeout: const Timeout(Duration(minutes: 2)));

  test('reactive-graph conformance [AsyncContext]',
      () => _runCorpus(_AsyncModel.new, 'AsyncContext'),
      timeout: const Timeout(Duration(minutes: 10)));

  test('divergence ledger names only known models', () {
    const models = {'Context', 'AsyncContext'};
    for (final entry in knownDivergences) {
      expect(models, contains(entry.split('/').first),
          reason: 'knownDivergences names an unknown model');
    }
  });
}
