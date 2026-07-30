import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:lazily/ipc.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

/// Sibling-first (`#lzspecconf`) — this read the local mirror unconditionally,
/// so the canonical fixture was never consulted even when checked out.
Map<String, dynamic> _fixture() {
  const name = 'reliable-sync/outbox_store_protocol.json';
  for (final path in ['../lazily-spec/conformance/$name', 'test/conformance/$name']) {
    final file = File(path);
    if (file.existsSync()) {
      return attributeFixture(jsonDecode(file.specReadAsStringSync())) as Map<String, dynamic>;
    }
  }
  throw StateError('fixture not found: $name');
}

/// By-id lookup through the scenario ledger (`#lzscenariocoverage`).
Map<String, dynamic> _scenario(String name) => scenarioNamed(_fixture(), name);

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
    assertKey(
      assertionsOf(ordered['expect']),
      'epochs',
      store.scanAfter(ordered['scan_after'] as int).map((e) => e.$1).toList(),
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
    final expectMap = assertionsOf(monotone['expect']);
    assertKey(expectMap, 'cursor', outbox.ackedThrough);
    assertKey(expectMap, 'retained', outbox.retainedEpochs());
    assertKey(expectMap, 'replay_from_zero',
        _replayEpochs(outbox.replayFrom(0)));
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
    final expectMap = assertionsOf(restart['expect']);
    assertKey(expectMap, 'loaded_cursor', reopened.ackedThrough);
    assertKey(expectMap, 'retained', reopened.retainedEpochs());
    assertKey(expectMap, 'replay', _replayEpochs(reopened.replayFrom(0)));
  });

  test('stale file handle cannot regress serialized cursor', () {
    final scenario = _scenario('stale handle cannot regress serialized cursor');
    final directory = Directory.systemTemp.createTempSync('lazily-cursor-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/outbox.jsonl';
    final handles = <String, StoredOutbox<FileOutboxStore>>{
      'stale': StoredOutbox(FileOutboxStore(path)),
      'current': StoredOutbox(FileOutboxStore(path)),
    };
    for (final save in (scenario['save_cursor'] as List<dynamic>)
        .cast<Map<String, dynamic>>()) {
      handles[save['handle']]!.ackThrough(save['epoch'] as int);
    }
    final expect_ = assertionsOf(scenario['expect']);
    assertKey(expect_, 'loaded_cursor', handles['stale']!.ackedThrough);
    assertKey(expect_, 'loaded_cursor', FileOutboxStore(path).loadCursor());
  });
}
