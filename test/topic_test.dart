import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

void main() {
  test('broadcast cursors are independent', () {
    final topic = TopicCell<String>(Context());
    expect(topic.subscribe('alice'), TopicSubscribeOutcome.subscribed);
    topic.subscribe('bob');
    expect(topic.publish('a'), 0);
    expect(topic.publish('b'), 1);
    topic.advance('alice');
    expect(topic.readStream('alice'), ['b']);
    expect(topic.readStream('bob'), ['a', 'b']);
  });

  test('offline durable subscriber replays and holds safe GC frontier', () {
    final topic = TopicCell<String>(Context());
    topic.subscribe('fast');
    topic.subscribe('slow');
    topic.publish('a');
    topic.publish('b');
    topic.advance('fast', 2);
    topic.advance('slow');
    topic.disconnect('slow');
    topic.publish('c');
    expect(topic.gc(), 1);
    expect(topic.baseOffset, 1);
    topic.reconnect('slow');
    expect(topic.readStream('slow'), ['b', 'c']);

    final restored = TopicCell<String>(Context(), topic.snapshot());
    expect(restored.baseOffset, topic.baseOffset);
    expect(restored.elements(), topic.elements());
  });

  test('ephemeral disconnect removes cursor from GC', () {
    final topic = TopicCell<String>(Context());
    topic.subscribe('durable');
    topic.subscribe('viewer', TopicDurability.ephemeral);
    topic.publish('a');
    topic.advance('durable');
    topic.disconnect('viewer');
    expect(topic.subscription('viewer'), isNull);
    expect(topic.gc(), 1);
    topic.subscribe('viewer', TopicDurability.ephemeral);
    expect(topic.subscription('viewer')!.cursor, topic.tailOffset);
  });
}
