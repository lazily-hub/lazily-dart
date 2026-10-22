import 'dart:io';

import 'package:test/test.dart';

Future<ProcessResult> _probe([String? flavor]) => Process.run(
      Platform.resolvedExecutable,
      [
        if (flavor != null) '-Dlazily.unsafe_stale_handle_disposal=true',
        'run',
        'tool/stale_handle_mutation_probe.dart',
        if (flavor != null) '--$flavor-only',
      ],
      workingDirectory: Directory.current.path,
    );

void main() {
  test('stale-handle probe establishes real allocator reuse', () async {
    final result = await _probe();
    expect(
      result.exitCode,
      0,
      reason: 'baseline probe failed:\n${result.stdout}\n${result.stderr}',
    );
  });

  for (final flavor in ['sync', 'async']) {
    test('$flavor generation-fence mutant is killed', () async {
      final result = await _probe(flavor);
      expect(
        result.exitCode,
        isNot(0),
        reason: '$flavor mutant survived real same-kind slot reuse',
      );
      expect(
        '${result.stdout}\n${result.stderr}',
        contains('read after dispose'),
        reason: '$flavor mutant failed without removing the successor',
      );
    });
  }
}
