import 'dart:io';

import 'package:test/test.dart';

void main() {
  for (final target in ['fmt', 'fmt-fix']) {
    test('make $target resolves package metadata before formatting', () async {
      final result = await Process.run(
        'make',
        ['-n', target],
        workingDirectory: Directory.current.path,
        runInShell: false,
      );

      expect(
        result.exitCode,
        0,
        reason: 'make -n $target failed:\n${result.stdout}\n${result.stderr}',
      );

      final commands = result.stdout.toString().split('\n');
      final pubGet =
          commands.indexWhere((line) => line.trim() == 'dart pub get');
      final format = commands.indexWhere(
        (line) => line.trim().startsWith('dart format '),
      );

      expect(pubGet, isNonNegative,
          reason: '`make $target` must run `dart pub get`');
      expect(format, greaterThan(pubGet),
          reason: '`dart format` must run after package metadata is resolved');
    });
  }
}
