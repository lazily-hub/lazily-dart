import 'dart:convert';
import 'dart:io';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

/// Corpus-relative fixture id. Root resolution — the
/// `LAZILY_SPEC_CONFORMANCE_DIR` override, the sibling-first-then-mirror
/// ordering, and the fail-closed behaviour when an explicit override cannot be
/// read — lives in `conformance_manifest.dart` (#lzoverrideallrunners).
String _fixturePath() =>
    specFixturePath('collections/dependency_reactive_availability.json');

Object _state(DependencyAvailability<int> state) =>
    state.isAvailable ? {'Available': state.value} : 'Unavailable';

void main() {
  test('exact-key dependency availability fixture', () {
    final fixture = attributeFixture(
      jsonDecode(File(_fixturePath()).specReadAsStringSync()),
    ) as Map<String, dynamic>;
    final key = fixture['key'] as String;
    final ctx = Context();
    final map = DependencyMap<String, int>(ctx);
    var recomputes = 0;
    final observed = Slot<DependencyAvailability<int>>(ctx, (cx) {
      recomputes += 1;
      return map.observeDependency(key, cx);
    });
    Object? identity;

    final steps = fixture['steps'] as List<dynamic>;
    expect(steps, isNotEmpty);
    for (var index = 0; index < steps.length; index++) {
      final step = steps[index] as Map<String, dynamic>;
      final op = step['op'] as Map<String, dynamic>;
      switch (op['type']) {
        case 'observe_dependency':
          observed.call();
          break;
        case 'publish':
          map.publish(op['key'] as String, op['value'] as int);
          break;
        case 'unpublish':
          map.unpublish(op['key'] as String);
          break;
        default:
          fail('unknown dependency operation: ${op['type']}');
      }

      final state = observed.call();
      identity ??= map.handle(key);
      final expected = assertionsOf(step['expected'], 'step $index');
      final projected = _state(state);
      if (projected is Map<String, int?>) {
        assertKeyDeep(expected, 'state', projected);
      } else {
        assertKey(expected, 'state', projected);
      }
      assertKey(expected, 'recomputes', recomputes);
      assertKey(expected, 'present_count', map.presentCount());
      assertKeyWith(expected, 'identity', (fixtureIdentity) {
        expect(fixtureIdentity, equals('$key-1'),
            reason: 'fixture identity is derived from the dependency key');
        expect(map.handle(key), same(identity),
            reason: 'the fixture identity must keep the same handle');
      });
    }
  });

  test('thread-safe and async flavors preserve exact-key source identity', () {
    final threadCtx = Context();
    final thread = ThreadSafeDependencyMap<String, int>(threadCtx);
    thread.observeDependency('wanted');
    final threadHandle = thread.handle('wanted');
    thread.publish('wanted', 7);
    expect(thread.handle('wanted'), same(threadHandle));
    expect(thread.observeDependency('wanted').value, 7);

    final asyncCtx = Context();
    final async = AsyncDependencyMap<String, int>(asyncCtx);
    async.observeDependency('wanted');
    final asyncHandle = async.handle('wanted');
    async.publish('wanted', 8);
    expect(async.handle('wanted'), same(asyncHandle));
    expect(async.observeDependency('wanted').value, 8);
  });
}
