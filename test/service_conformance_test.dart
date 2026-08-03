import 'dart:convert';
import 'dart:io';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

/// Cross-language conformance tests for the embedded-service plane (`#lzservice`,
/// `lazily-spec/conformance/service/`). Each model projects its composed view
/// onto a reactive [Cell]; a [Slot] wrapping that cell lets us observe
/// invalidation via `ctx.contains` — the reader stays cached unless the
/// projection actually changed.
///
/// Fixtures mirror `lazily-spec/conformance/service/` byte-identically; when
/// that source tree is reachable on disk (sibling repo) it is preferred so this
/// harness also guards against fixture drift across the family.

final _specDir = Directory('../lazily-spec/conformance/service');

Map<String, dynamic> _loadFixture(String name) {
  final src = _specDir.existsSync()
      ? File(_specDir.resolveSymbolicLinksSync() + '/$name')
          .specReadAsStringSync()
      : File('test/conformance/service/$name').specReadAsStringSync();
  return attributeFixture(jsonDecode(src)) as Map<String, dynamic>;
}

/// Observe a cell through a slot; returns the slot primed (cached).
Slot<Object?> _observe(Context ctx, Cell cell) {
  final slot = Slot<Object?>(ctx, (cx) => cx.get(cell));
  slot();
  return slot;
}

/// Read the slot, returning whether the read triggered a recompute (i.e. the
/// reader had been invalidated).
bool _invalidated(Context ctx, Slot slot) {
  final wasCached = ctx.contains(slot);
  slot();
  return !wasCached;
}

Health _health(String label) {
  switch (label) {
    case 'Healthy':
      return Health.healthy;
    case 'Degraded':
      return Health.degraded;
    case 'Unhealthy':
      return Health.unhealthy;
    default:
      throw ArgumentError('unknown health label: $label');
  }
}

void main() {
  test('HealthCell', () {
    final fx = _loadFixture('health.json');
    final ctx = Context();
    final h = HealthCell(ctx);
    final observed = _observe(ctx, h.healthCell);

    for (final step in (fx['steps'] as List).cast<Map<String, dynamic>>()) {
      final op = step['op'] as Map<String, dynamic>;
      final expected = assertionsOf(step['expected']);
      h.set(op['name'] as String, op['up'] as bool, op['critical'] as bool);
      assertKeyWith(expected, 'health',
          (v) => expect(h.health(), equals(_health(v as String))));
      assertKey(subKey(expected, 'invalidates'), 'health',
          _invalidated(ctx, observed), 'health invalidation');
    }
  });

  test('ReadinessCell', () {
    final fx = _loadFixture('readiness.json');
    final ctx = Context();
    final r = ReadinessCell(ctx);
    final observed = _observe(ctx, r.readyCell);

    for (final step in (fx['steps'] as List).cast<Map<String, dynamic>>()) {
      final op = step['op'] as Map<String, dynamic>;
      final expected = assertionsOf(step['expected']);
      r.set(op['name'] as String, op['ready'] as bool);
      assertKey(expected, 'ready', r.ready());
      assertKey(subKey(expected, 'invalidates'), 'ready',
          _invalidated(ctx, observed), 'ready invalidation');
    }
  });

  test('DiscoveryCell', () {
    final fx = _loadFixture('discovery.json');
    final ctx = Context();
    final d = DiscoveryCell<int>(ctx);
    final observed = _observe(ctx, d.discoveryCell);

    for (final step in (fx['steps'] as List).cast<Map<String, dynamic>>()) {
      final op = step['op'] as Map<String, dynamic>;
      final expected = assertionsOf(step['expected']);
      switch (op['type'] as String) {
        case 'register':
          d.register(op['service'] as String, op['endpoint'] as String,
              op['peer'] as int);
        case 'deregister':
          d.deregister(op['service'] as String);
        case 'evict':
          d.evict(op['peer'] as int);
        case 'resolve':
          expect(d.resolve(op['service'] as String), equals(step['returns']));
        // Fail closed on an unrecognised op (`#lzscenariobodyskip`): the
        // defaultless switch silently replayed nothing, and `step['returns']`
        // for a `resolve` the runner skipped was never compared.
        default:
          fail('DiscoveryCell: unknown op type `${op['type']}`');
      }
      assertKeyDeep(expected, 'discovery', d.discovery());
      assertKey(subKey(expected, 'invalidates'), 'discovery',
          _invalidated(ctx, observed), 'discovery invalidation');
    }
  });

  test('ServiceRegistry', () {
    final fx = _loadFixture('service_registry.json');
    final ctx = Context();
    final reg = ServiceRegistry(ctx);
    final observed = _observe(ctx, reg.projectionCell);

    for (final step in (fx['steps'] as List).cast<Map<String, dynamic>>()) {
      final op = step['op'] as Map<String, dynamic>;
      final expected = assertionsOf(step['expected']);
      switch (op['type'] as String) {
        case 'register':
          reg.register(op['service'] as String, op['endpoint'] as String);
        case 'deregister':
          reg.deregister(op['service'] as String);
        case 'replay':
          reg.replay();
        // Fail closed on an unrecognised op (`#lzscenariobodyskip`).
        default:
          fail('ServiceRegistry: unknown op type `${op['type']}`');
      }
      assertKeyDeep(expected, 'projection', reg.projection());
      assertKey(subKey(expected, 'invalidates'), 'projection',
          _invalidated(ctx, observed), 'projection invalidation');
    }
  });
}
