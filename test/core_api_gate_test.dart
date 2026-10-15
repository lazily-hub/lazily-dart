import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('Core API gate rejects a removed public symbol', () async {
    final source = File('lib/src/core.dart').readAsStringSync();
    const declaration = 'Source<T> source<T>(Context ctx, T initialValue) =>';
    expect(source, contains(declaration));

    final directory = Directory('build/core-api-negative')
      ..createSync(recursive: true);
    final mutated = File('${directory.path}/core.dart');
    mutated.writeAsStringSync(
      source.replaceFirst(
          declaration, declaration.replaceFirst('source', 'removedSource')),
    );

    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'tool/core_api_snapshot.dart',
      '--library',
      mutated.path,
    ]);

    expect(result.exitCode, isNot(0));
    expect(
      '${result.stdout}\n${result.stderr}',
      contains('Core API generation 1 changed'),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
