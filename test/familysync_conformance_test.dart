import 'dart:convert';
import 'dart:io';

import 'package:lazily/ipc.dart';
import 'package:lazily/src/distributed.dart';
import 'package:test/test.dart';

/// Reactive family-granularity sync conformance (`#lzfamilysync`,
/// lazily-spec/conformance/familysync/).
///
/// A keyed op for a family entry that is NOT registered locally MATERIALIZES the
/// entry on ingest (seeded from the op's converged register) instead of being
/// dropped — membership propagates, values are adopted, a later last-writer-wins
/// update converges, re-ingest is idempotent, and a derived aggregate over the
/// family (a count of `true` entries) converges. Mirrors
/// `lazily-go/familysync_conformance_test.go` + `lazily-rs`
/// tests/familysync_conformance.rs, and the FamilySync.lean laws
/// (applyOp_eq_merge, applyOp_present, applyOp_absent_adopts, present_merge,
/// applyOp_idem, aggregate_converges).

final _localDir = Directory('test/conformance/familysync');
final _specDir = Directory('../lazily-spec/conformance/familysync');

String _fixturePath(String name) {
  final local = '${_localDir.path}/$name';
  if (File(local).existsSync()) return local;
  final sibling = '${_specDir.path}/$name';
  if (File(sibling).existsSync()) return sibling;
  throw StateError('fixture not found: $name (looked in $local, $sibling)');
}

Map<String, dynamic> _load(String name) =>
    jsonDecode(File(_fixturePath(name)).readAsStringSync())
        as Map<String, dynamic>;

/// The suffix after the last `/` of a full family key path.
String _suffixOf(String key) {
  final i = key.lastIndexOf('/');
  return i < 0 ? key : key.substring(i + 1);
}

void main() {
  group('reactive family sync conformance (#lzfamilysync)', () {
    final fixture = _load('materialize_on_ingest.json');
    final namespace = fixture['namespace'] as String;
    final scenarios =
        (fixture['scenarios'] as List).cast<Map<String, dynamic>>();

    for (final sc in scenarios) {
      test(sc['name'] as String, () {
        final origin = CrdtPlaneRuntime(sc['origin_peer'] as int)
          ..registerFamilyLww(namespace);
        final target = CrdtPlaneRuntime(sc['target_peer'] as int)
          ..registerFamilyLww(namespace);
        final epochBefore = target.membershipEpoch();

        for (final set
            in (sc['origin_sets'] as List).cast<Map<String, dynamic>>()) {
          origin.familySetLww(
            namespace,
            set['key'] as String,
            set['value'] as bool,
            set['now'] as int,
          );
        }

        final frame = origin.syncFrame();
        final applied = target.ingest(frame);
        expect(applied, greaterThan(0), reason: 'first ingest applied nothing');

        final expect_ = sc['expect'] as Map<String, dynamic>;

        if (sc['reingest'] == true) {
          final reapplied = target.ingest(frame);
          expect(reapplied, expect_['reingest_applied'] as int,
              reason: 're-ingest is not idempotent');
        }

        // Membership propagation: exact key set (order-independent, by suffix).
        final gotSuffixes = target.familyKeys(namespace).map(_suffixOf).toSet();
        final wantKeys =
            (expect_['target_keys'] as List).cast<String>().toSet();
        expect(gotSuffixes, wantKeys, reason: 'family membership mismatch');
        expect(target.familyKeys(namespace).length,
            expect_['target_present_count'] as int);

        // Value adoption / LWW convergence.
        final wantValues =
            (expect_['target_values'] as Map).cast<String, dynamic>();
        wantValues.forEach((suffix, want) {
          expect(target.familyValueLww(namespace, suffix), want as bool,
              reason: 'value for $namespace/$suffix diverged');
        });

        // Derived-aggregate transparency: count of `true` entries converges.
        expect(target.familyCountTrue(namespace),
            expect_['target_count_true'] as int,
            reason: 'derived count_true diverged');

        // Membership epoch bumped on materialize.
        if (expect_['target_epoch_bumped'] == true) {
          expect(target.membershipEpoch(), greaterThan(epochBefore),
              reason: 'membership epoch did not bump');
        }
      });
    }
  });
}
