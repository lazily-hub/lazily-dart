import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'conformance_manifest.dart';

/// The queue-family flavor ledger — enforced against the source, not a comment.
///
/// `queue_conformance_test.dart` replays the canonical `queuecell_*.json` corpus
/// against the single-threaded `QueueCell`. That is currently the only flavor: no
/// binding in the family ships a thread-safe or async queue primitive, and
/// `cell-model.md` § "Core surface vs. binding extensions (queue family)" now
/// makes those Core, so their absence is a conformance gap rather than an
/// unfinished nicety.
///
/// A three-flavor replay written today would skip two of three flavors entirely,
/// and a suite that skips almost everything while reporting green is exactly the
/// failure this file prevents. So the ledger is wired to the source: it greps
/// `lib/` for each unshipped flavor's class name, and the moment one appears this
/// goes red and names the runner to extend.
///
/// Mirrors `lazily-rs/tests/queue_family_conformance.rs`.

const queueFixtures = [
  'queuecell_spsc_push_pop.json',
  'queuecell_popped_head_observation.json',
  'queuecell_mpsc_multi_writer.json',
  'queuecell_bounded_backpressure.json',
  'queuecell_closure_lifecycle.json',
];

/// The marker is grepped, not referenced: referencing a class that does not exist
/// would not compile, and a ledger you cannot write until the work is done is no
/// ledger at all.
const ledger = <({String name, String marker, bool shipped})>[
  (name: 'single-threaded', marker: 'class QueueCell', shipped: true),
  (name: 'thread-safe', marker: 'ThreadSafeQueueCell', shipped: false),
  (name: 'async', marker: 'AsyncQueueCell', shipped: false),
];

String _sources() {
  final buffer = StringBuffer();
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      buffer.write(entity.specReadAsStringSync());
    }
  }
  return buffer.toString();
}

Directory? _fixtureDir() {
  for (final path in [
    '../lazily-spec/conformance/collections',
    'test/conformance/collections',
  ]) {
    final dir = Directory(path);
    if (dir.existsSync()) return dir;
  }
  return null;
}

void main() {
  test('queue ledger: unshipped flavors are really absent', () {
    final sources = _sources();
    expect(sources, isNotEmpty,
        reason: 'read no sources from lib/; the ledger check would be vacuous');

    for (final flavor in ledger) {
      final defined = sources.contains(flavor.marker);
      if (flavor.shipped) {
        expect(defined, isTrue,
            reason: 'flavor ${flavor.name} is recorded as shipped but '
                '${flavor.marker} is not defined in lib/ — the ledger claims '
                'coverage this package does not have');
      } else {
        expect(defined, isFalse,
            reason: 'flavor ${flavor.name} now EXISTS in lib/ (${flavor.marker}) '
                'but the queue-family ledger still records it as unshipped, so the '
                'canonical corpus is not being replayed against it. Fix: flip '
                'shipped for ${flavor.name} in `ledger` AND extend the replay to '
                'drive it, as collections_family_conformance_test.dart drives all '
                'three map flavors. Do NOT flip the flag alone — that restores the '
                'false green this test prevents.');
      }
    }
  });

  test('queue ledger: is not all skips', () {
    // In a summary line, "skipped" and "passed" are indistinguishable.
    expect(ledger.any((f) => f.shipped), isTrue,
        reason: 'every queue flavor is recorded as unshipped, so this suite would '
            'assert nothing while still reporting success');
    expect(ledger.length, 3,
        reason: 'the ledger must cover all three execution flavors; a missing '
            'entry is an unscored gap, not an absent one');
  });

  test('queue ledger: shipped flavor replays the corpus', () {
    final dir = _fixtureDir();
    if (dir == null) {
      markTestSkipped('canonical collections fixtures not found');
      return;
    }

    var fixturesRead = 0;
    var stepsSeen = 0;
    var matricesSeen = 0;

    for (final name in queueFixtures) {
      final file = File('${dir.path}/$name');
      expect(file.existsSync(), isTrue,
          reason: '$name: declared queue fixture is missing');
      final fixture = jsonDecode(file.specReadAsStringSync()) as Map<String, dynamic>;
      fixturesRead += 1;

      final steps = (fixture['steps'] as List?) ?? const [];
      expect(steps, isNotEmpty,
          reason: '$name: fixture has no steps - a vacuous replay would report green');
      stepsSeen += steps.length;

      for (var i = 0; i < steps.length; i++) {
        final step = steps[i] as Map<String, dynamic>;
        // The matrix nests under `expected`, NOT on the step. lazily-rs's MAP
        // runner read it off the step, so it was always absent and the assertion
        // never ran once. Pin the nesting so that cannot recur here.
        expect(step.containsKey('invalidates'), isFalse,
            reason: '$name step $i: `invalidates` appears at STEP level; the '
                'runners read expected.invalidates, so a step-level copy is '
                'silently ignored');
        final expected = step['expected'] as Map<String, dynamic>?;
        expect(expected, isNotNull, reason: '$name step $i: no expected block');
        if (expected!.containsKey('invalidates')) matricesSeen += 1;
      }
    }

    expect(fixturesRead, queueFixtures.length,
        reason: 'did not read every declared queue fixture');
    expect(stepsSeen, greaterThan(0), reason: 'read the corpus but saw zero steps');
    expect(matricesSeen, greaterThan(0),
        reason: 'no fixture carried an expected.invalidates matrix - the '
            'reader-kind independence contract would be unasserted');
  });
}
