import 'package:lazily/lazily.dart';

final class ConsumerSchema {
  const ConsumerSchema(this.label);
  final String label;
}

void main() {
  final ctx = Context();
  final source = Source<int>(ctx, 1);
  final computed = Computed<int>(ctx, (cx) => cx.get(source) * 2);
  var runs = 0;
  final scope = ctx.scope();
  scope.effect((cx) {
    if (cx.get(computed) < 2)
      throw StateError('computed value was not observable');
    runs++;
    return null;
  });
  ctx.batch(() {
    source.value = 2;
    source.value = 3;
  });
  if (computed.value != 6 || runs != 2) {
    throw StateError('batch result = ${computed.value}, runs = $runs');
  }
  scope.end();
  source.value = 4;
  if (runs != 2) throw StateError('closed scope still observed updates');
  final typed = Source<ConsumerSchema>(ctx, const ConsumerSchema('typed'));
  if (typed.value.label != 'typed')
    throw StateError('typed value was not preserved');
  print('lazily-dart artifact consumer: OK');
}
