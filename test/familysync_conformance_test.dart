import 'dart:convert';
import 'dart:io';

import 'package:lazily/ipc.dart';
import 'package:lazily/src/distributed.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

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

/// This runner's slice of the shared corpus. Root resolution — the
/// `LAZILY_SPEC_CONFORMANCE_DIR` override, the sibling-first-then-mirror
/// ordering, and the fail-closed behaviour when an explicit override cannot be
/// read — lives in `conformance_manifest.dart`, so every runner and the
/// coverage guard auditing them resolve ONE corpus (#lzoverrideallrunners).
const _family = 'familysync';

String _fixturePath(String name) => specFixturePath('$_family/$name');

Map<String, dynamic> _load(String name) => attributeFixture(
        jsonDecode(File(_fixturePath(name)).specReadAsStringSync()))
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
    for (final sc in scenariosOf(fixture)) {
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

        final expect_ = assertionsOf(sc['expect']);

        if (sc['reingest'] == true) {
          final reapplied = target.ingest(frame);
          assertKey(expect_, 'reingest_applied', reapplied,
              're-ingest is not idempotent');
        }

        // Membership propagation: exact key set (order-independent, by suffix).
        assertKeyWith(expect_, 'target_keys', (v) {
          final gotSuffixes =
              target.familyKeys(namespace).map(_suffixOf).toSet();
          expect(gotSuffixes, (v as List).cast<String>().toSet(),
              reason: 'family membership mismatch');
        });
        assertKey(expect_, 'target_present_count',
            target.familyKeys(namespace).length);

        // Value adoption / LWW convergence.
        // Keyed by family-member suffix, bounded by the membership the target
        // really materialized (`#lzsubblockkeyset`).
        assertKeysOf(expect_, 'target_values',
            target.familyKeys(namespace).map(_suffixOf), (suffix, want) {
          expect(target.familyValueLww(namespace, suffix), want as bool,
              reason: 'value for $namespace/$suffix diverged');
        },
            reason: '`target_values` names a family member the target does '
                'not carry');

        // Derived-aggregate transparency: count of `true` entries converges.
        assertKey(expect_, 'target_count_true',
            target.familyCountTrue(namespace), 'derived count_true diverged');

        // Membership epoch bumped on materialize.
        assertKeyWith(expect_, 'target_epoch_bumped', (v) {
          expect(target.membershipEpoch() > epochBefore, equals(v),
              reason: 'membership epoch bump mismatch');
        });
      });
    }
  });
}
