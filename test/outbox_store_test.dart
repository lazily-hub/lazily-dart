import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:lazily/ipc.dart';
import 'package:test/test.dart';

Map<String, dynamic> _fixture() => jsonDecode(
      File('test/conformance/reliable-sync/outbox_store_protocol.json')
          .readAsStringSync(),
    ) as Map<String, dynamic>;

Map<String, dynamic> _scenario(String name) =>
    (_fixture()['scenarios'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .firstWhere(
          (item) => item['name'] == name,
        );

IpcMessage _message(int epoch) =>
    IpcMessage.ofDelta(Delta(baseEpoch: epoch - 1, epoch: epoch));

List<int> _replayEpochs(List<OutboxFrame> frames) =>
    frames.map((frame) => frame.$1).toList();

void main() {
  test('OutboxStore protocol replays canonical fixture', () {
    final ordered = _scenario('unordered puts replay in ascending epoch order');
    final store = InMemoryStore();
    for (final epoch in (ordered['put_epochs'] as List<dynamic>).cast<int>()) {
      store.put(epoch, Uint8List.fromList([epoch]));
    }
    expect(
      store.scanAfter(ordered['scan_after'] as int).map((entry) => entry.$1),
      (ordered['expect'] as Map<String, dynamic>)['epochs'],
    );

    final monotone = _scenario('ack cursor is monotone and prune-safe');
    final outbox = StoredOutbox(InMemoryStore());
    for (final epoch in (monotone['put_epochs'] as List<dynamic>).cast<int>()) {
      outbox.append(epoch, _message(epoch));
    }
    for (final epoch
        in (monotone['ack_through'] as List<dynamic>).cast<int>()) {
      outbox.ackThrough(epoch);
    }
    final expectMap = monotone['expect'] as Map<String, dynamic>;
    expect(outbox.ackedThrough, expectMap['cursor']);
    expect(outbox.retainedEpochs(), expectMap['retained']);
    expect(_replayEpochs(outbox.replayFrom(0)), expectMap['replay_from_zero']);
  });

  test('file outbox reloads durable cursor and suffix', () {
    final restart = _scenario('restart reloads cursor and unacked suffix');
    final directory = Directory.systemTemp.createTempSync('lazily-outbox-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/outbox.jsonl';
    final first = FileOutbox(path);
    for (final epoch in (restart['put_epochs'] as List<dynamic>).cast<int>()) {
      first.append(epoch, _message(epoch));
    }
    for (final epoch in (restart['ack_through'] as List<dynamic>).cast<int>()) {
      first.ackThrough(epoch);
    }

    final reopened = FileOutbox(path);
    final expectMap = restart['expect'] as Map<String, dynamic>;
    expect(reopened.ackedThrough, expectMap['loaded_cursor']);
    expect(reopened.retainedEpochs(), expectMap['retained']);
    expect(_replayEpochs(reopened.replayFrom(0)), expectMap['replay']);
  });

  test('stale file handle cannot regress serialized cursor', () {
    final directory = Directory.systemTemp.createTempSync('lazily-cursor-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/outbox.jsonl';
    final stale = FileOutboxStore(path);
    final current = FileOutboxStore(path);
    current.saveCursor(9);
    stale.saveCursor(3);
    expect(FileOutboxStore(path).loadCursor(), 9);
  });
}
