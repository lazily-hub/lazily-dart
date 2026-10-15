import 'dart:io';

import 'package:lazily/core.dart' as core;
import 'package:lazily/lazily.dart' as root;
import 'package:test/test.dart';

void main() {
  test('the Core facade preserves public identities', () {
    final rootContext = root.Context();
    final coreContext = core.Context();

    root.Context sameContext = coreContext;
    root.Source<int> sameSource = core.source(coreContext, 1);
    root.Computed<int> sameComputed = core.computed(
      coreContext,
      (cx) => cx.get(sameSource),
    );
    root.Effect sameEffect = coreContext.effect((cx) {
      cx.get(sameComputed);
      return null;
    });

    expect(sameContext.runtimeType, rootContext.runtimeType);
    expect(sameSource.get(), 1);
    expect(sameComputed.get(), 1);
    sameEffect.dispose();
  });

  test('the package tree contains the Core facade and metadata', () {
    for (final path in [
      'lib/core.dart',
      'lib/src/core.dart',
      'LICENSE',
      'NOTICE',
      'README.md',
      'pubspec.yaml',
    ]) {
      expect(File(path).existsSync(), isTrue, reason: 'missing $path');
    }
  });
}
