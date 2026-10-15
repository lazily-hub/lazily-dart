import 'package:lazily/core.dart' as core;
import 'package:test/test.dart';

void main() {
  test('generation 1 profile symbols compile through the focused facade', () {
    final context = core.Context();
    final core.Source<int> source = core.source(context, 1);
    final core.Computed<int> computed = core.computed(
      context,
      (cx) => cx.get(source) * 2,
    );
    final core.Effect effect = context.effect((cx) {
      cx.get(computed);
      return null;
    });
    final core.TeardownScope scope = context.scope();

    context.batch(() => source.set(2));

    expect(source.get(), 2);
    expect(computed.get(), 4);
    expect(effect.isActive, isTrue);
    scope.end();
    effect.dispose();
  });
}
