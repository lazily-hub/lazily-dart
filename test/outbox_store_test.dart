import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:lazily/ipc.dart';
import 'package:test/test.dart';

import 'conformance_manifest.dart';

/// Corpus-relative fixture ids. Root resolution — the
/// `LAZILY_SPEC_CONFORMANCE_DIR` override, the sibling-first-then-mirror
/// ordering, and the fail-closed behaviour when an explicit override cannot be
/// read — lives in `conformance_manifest.dart` (#lzoverrideallrunners).
Map<String, dynamic> _fixture() => attributeFixture(
        jsonDecode(specReadFixture('reliable-sync/outbox_store_protocol.json')))
    as Map<String, dynamic>;

Map<String, dynamic> _journalFixture() => attributeFixture(
        jsonDecode(specReadFixture('reliable-sync/outbox_journal_decode.json')))
    as Map<String, dynamic>;

/// By-id lookup through the scenario ledger (`#lzscenariocoverage`).
Map<String, dynamic> _scenario(String name) => scenarioNamed(_fixture(), name);

IpcMessage _message(int epoch) =>
    IpcMessage.ofDelta(Delta(baseEpoch: epoch - 1, epoch: epoch));

List<int> _replayEpochs(List<OutboxFrame> frames) =>
    frames.map((frame) => frame.$1).toList();

void main() {
  test('OutboxStore protocol replays canonical fixture', () {
    final ordered = _scenario('unordered_puts_replay_in_epoch_order');
    final store = InMemoryStore();
    for (final epoch in (ordered['put_epochs'] as List<dynamic>).cast<int>()) {
      store.put(epoch, Uint8List.fromList([epoch]));
    }
    assertKey(
      assertionsOf(ordered['expect']),
      'epochs',
      store.scanAfter(ordered['scan_after'] as int).map((e) => e.$1).toList(),
    );

    final monotone = _scenario('ack_cursor_is_monotone_and_prune_safe');
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
    assertKey(
        expectMap, 'replay_from_zero', _replayEpochs(outbox.replayFrom(0)));
  });

  test('file outbox reloads durable cursor and suffix', () {
    final restart = _scenario('restart_reloads_cursor_and_unacked_suffix');
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
    final scenario = _scenario('stale_handle_cannot_regress_cursor');
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

  test('file journal decode replays canonical unknown/torn opposites', () {
    final fixture = _journalFixture();
    for (final name in [
      'unknown_interior_opcode_is_refused',
      'torn_trailing_record_is_forgiven',
    ]) {
      final scenario = scenarioNamed(fixture, name);
      final directory =
          Directory.systemTemp.createTempSync('lazily-journal-decode-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}/outbox.jsonl';
      final file = File(path)..createSync();
      final store = FileOutboxStore(path);

      for (final record in (scenario['records'] as List<dynamic>)
          .cast<Map<String, dynamic>>()) {
        final op = record['op'] as String;
        final epoch = record['epoch'] as int;
        switch (op) {
          case 'put':
            store.put(epoch,
                Uint8List.fromList((record['frame'] as List).cast<int>()));
          case 'delete':
            store.deleteThrough(epoch);
          case 'cursor':
            store.saveCursor(epoch);
          default:
            file.writeAsStringSync('${jsonEncode(record)}\n',
                mode: FileMode.append);
        }
      }

      if (scenario['tail_fault'] case final Map<String, dynamic> tail) {
        expect(tail['kind'], 'torn_record');
        final encoded = jsonEncode({
          'op': tail['op'],
          'epoch': tail['epoch'],
          'frame': tail['frame'],
        });
        final keepBytes = tail['keep_bytes'] as int;
        expect(keepBytes, inInclusiveRange(1, encoded.length - 1));
        file.writeAsStringSync(encoded.substring(0, keepBytes),
            mode: FileMode.append);
      }

      List<StoredOutboxFrame>? entries;
      Object? error;
      try {
        entries = store.scanAfter(scenario['scan_after'] as int);
      } on FormatException catch (caught) {
        error = caught;
      }

      final expected = assertionsOf(scenario['expect']);
      assertKey(expected, 'outcome', error == null ? 'accept' : 'reject');
      if (expected.containsKey('retained_epochs')) {
        assertKey(expected, 'retained_epochs',
            entries!.map((entry) => entry.$1).toList());
        assertKey(expected, 'retained_frames',
            entries.map((entry) => entry.$2.toList()).toList());
      } else {
        expect(error, isA<FormatException>());
      }
    }
  });
}
