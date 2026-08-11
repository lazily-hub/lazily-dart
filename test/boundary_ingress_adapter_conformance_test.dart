library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'conformance_manifest.dart';

const _fixture = 'ingress/boundary_ingress_adapter.json';

class _Delivery {
  _Delivery(this.id, Iterable<String> members) : targets = members.toSet();

  final String id;
  final Set<String> targets;
  final Set<String> acked = {};
}

class _Model {
  _Model(this.maxBuffered, this.freshnessHorizon);

  final int maxBuffered;
  final int freshnessHorizon;
  String phase = 'detached';
  int generation = 0;
  int? cursor;
  final Map<int, Map<String, Object?>> buffered = {};
  Set<String> sourceKeys = {};
  Set<String> members = {};
  String validation = 'valid';
  int? replayFrom;
  int staleEvents = 0;
  _Delivery? delivery;
  int? lastStampedAt;
  int now = 0;
  int revision = 0;

  void _changed() => revision++;

  void _applyPayload(Map<String, Object?> op) {
    switch (op['action']) {
      case 'upsert':
        sourceKeys.add(op['key']! as String);
      case 'remove':
        sourceKeys.remove(op['key']! as String);
      case 'validate':
        validation = op['validation']! as String;
      default:
        throw StateError('unknown boundary event action ${op['action']}');
    }
    cursor = op['cursor']! as int;
    lastStampedAt = op['stamped_at']! as int;
    phase = validation == 'valid' ? 'live' : 'invalid';
    replayFrom = null;
  }

  void _drain() {
    while (cursor != null && buffered.containsKey(cursor! + 1)) {
      _applyPayload(buffered.remove(cursor! + 1)!);
    }
    if (buffered.isNotEmpty) {
      phase = 'replay_required';
      replayFrom = cursor! + 1;
    }
  }

  void apply(Map<String, Object?> op) {
    switch (op['type']) {
      case 'subscribe':
        final nextGeneration = op['generation']! as int;
        if (nextGeneration < generation) return;
        generation = nextGeneration;
        cursor = null;
        buffered.clear();
        sourceKeys.clear();
        members.clear();
        validation = 'valid';
        replayFrom = null;
        phase = 'bootstrapping';
        _changed();
      case 'snapshot':
        final nextGeneration = op['generation']! as int;
        if (nextGeneration < generation) {
          staleEvents++;
          _changed();
          return;
        }
        if (nextGeneration > generation) {
          generation = nextGeneration;
          buffered.clear();
        }
        cursor = op['cursor']! as int;
        lastStampedAt = op['stamped_at']! as int;
        sourceKeys = (op['source_keys']! as List).cast<String>().toSet();
        members = (op['members']! as List).cast<String>().toSet();
        validation = op['validation']! as String;
        phase = validation == 'valid' ? 'live' : 'invalid';
        replayFrom = null;
        buffered.removeWhere((candidate, _) => candidate <= cursor!);
        _drain();
        _changed();
      case 'event':
        final nextGeneration = op['generation']! as int;
        final eventCursor = op['cursor']! as int;
        if (nextGeneration < generation) {
          staleEvents++;
          _changed();
          return;
        }
        if (nextGeneration > generation) {
          generation = nextGeneration;
          cursor = null;
          buffered.clear();
          sourceKeys.clear();
          members.clear();
          phase = 'bootstrapping';
          replayFrom = null;
        }
        if (cursor == null) {
          if (buffered.length >= maxBuffered &&
              !buffered.containsKey(eventCursor)) {
            phase = 'backpressured';
            replayFrom = 0;
            _changed();
            return;
          }
          if (!buffered.containsKey(eventCursor)) {
            buffered[eventCursor] = op;
            _changed();
          }
          return;
        }
        if (eventCursor <= cursor! || buffered.containsKey(eventCursor)) return;
        if (eventCursor == cursor! + 1) {
          _applyPayload(op);
          _drain();
          _changed();
          return;
        }
        if (buffered.length >= maxBuffered) {
          phase = 'backpressured';
          replayFrom = cursor! + 1;
          _changed();
          return;
        }
        buffered[eventCursor] = op;
        phase = 'replay_required';
        replayFrom = cursor! + 1;
        _changed();
      case 'member_join':
        final member = op['member']! as String;
        if (!members.add(member)) return;
        if (delivery case final open? when open.targets.isEmpty) {
          open.targets.add(member);
        }
        _changed();
      case 'member_leave':
        if (members.remove(op['member']! as String)) _changed();
      case 'open_receipt':
        delivery = _Delivery(op['receipt_id']! as String, members);
        _changed();
      case 'ack':
        final open = delivery;
        if (open == null || open.id != op['receipt_id']) return;
        final member = op['member']! as String;
        if (open.targets.contains(member) && open.acked.add(member)) _changed();
      case 'tick':
        final before = fresh;
        now = op['now']! as int;
        if (fresh != before) _changed();
      default:
        throw StateError('unknown boundary ingress op ${op['type']}');
    }
  }

  bool get fresh =>
      lastStampedAt != null && now - lastStampedAt! <= freshnessHorizon;

  Map<String, Object?> projection() {
    final open = delivery;
    final deliveryProjection = open == null
        ? null
        : <String, Object?>{
            'receipt_id': open.id,
            'targets': open.targets.toList()..sort(),
            'acked': open.acked.toList()..sort(),
            'converged': open.targets.isNotEmpty &&
                open.targets.difference(open.acked).isEmpty,
          };
    return {
      'phase': phase,
      'generation': generation,
      'cursor': cursor,
      'buffered_cursors': buffered.keys.toList()..sort(),
      'source_keys': sourceKeys.toList()..sort(),
      'members': members.toList()..sort(),
      'validation': validation,
      'replay_from': replayFrom,
      'stale_events': staleEvents,
      'delivery': deliveryProjection,
      'ready': phase == 'live' && validation == 'valid',
      'fresh': fresh,
      'observation_revision': revision,
      'revision': revision,
    };
  }
}

void main() {
  test('boundary ingress adapter replays the canonical contract', () {
    // Corpus-relative fixture id. Root resolution — the
    // `LAZILY_SPEC_CONFORMANCE_DIR` override, the sibling-first-then-mirror
    // ordering, and the fail-closed behaviour when an explicit override cannot
    // be read — lives in `conformance_manifest.dart` (#lzoverrideallrunners).
    final file = File(specFixturePath(_fixture));
    final fixture =
        (attributeFixture(jsonDecode(file.specReadAsStringSync())) as Map)
            .cast<String, dynamic>();
    var replayed = 0;
    for (final scenario in scenariosOf(fixture)) {
      final policy = <String, Object?>{
        ...((fixture['policy'] as Map).cast<String, Object?>()),
        ...?((scenario['policy'] as Map?)?.cast<String, Object?>()),
      };
      final model = _Model(
        policy['max_buffered']! as int,
        policy['freshness_horizon']! as int,
      );
      var index = 0;
      for (final rawStep in scenario['steps'] as List) {
        final step = (rawStep as Map).cast<String, Object?>();
        model.apply((step['op']! as Map).cast<String, Object?>());
        final actual = model.projection();
        // Bound through the tracker, not read raw (`#lzunboundblockguard`).
        // The loop below already asserts every key it carries, but nothing
        // recorded that this block was ever looked at, so a step whose
        // `expected` stopped being reached would have gone unnoticed.
        final expected =
            assertionsOf(step['expected'], '${scenario['id']} step $index');
        final raw = (step['expected']! as Map).cast<String, Object?>();
        for (final key in expected.keys.cast<String>().toList()) {
          final where = '${scenario['id']} step $index';
          // An object-valued key goes through the whole-object channel
          // (`#lzsubblockkeyset`): `delivery` carries four sub-fields, and a
          // fifth added upstream would be compared by nothing if this were a
          // plain assertKey.
          if (raw[key] is Map) {
            assertKeyDeep(expected, key, actual[key], where);
          } else {
            assertKey(expected, key, actual[key], where);
          }
        }
        replayed++;
        index++;
      }
    }
    expect(replayed, greaterThan(0));
  });
}
