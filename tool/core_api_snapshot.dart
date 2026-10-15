// ignore_for_file: deprecated_member_use

import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';

const _generation = 1;

Future<void> main(List<String> arguments) async {
  var write = false;
  var libraryPath = 'lib/core.dart';
  var snapshotPath = 'api/core-api-v1.txt';

  for (var index = 0; index < arguments.length; index++) {
    switch (arguments[index]) {
      case '--write':
        write = true;
      case '--library':
        libraryPath = _nextArgument(arguments, ++index, '--library');
      case '--snapshot':
        snapshotPath = _nextArgument(arguments, ++index, '--snapshot');
      default:
        stderr.writeln('unknown argument: ${arguments[index]}');
        exitCode = 64;
        return;
    }
  }

  final root = Directory.current.absolute;
  final library = File(_absolute(root, libraryPath));
  final snapshot = File(_absolute(root, snapshotPath));
  final surface = await _deriveSurface(root, library);
  final rendered = '${surface.lines.join('\n')}\n';

  if (write) {
    snapshot.parent.createSync(recursive: true);
    snapshot.writeAsStringSync(rendered);
  } else {
    if (!snapshot.existsSync()) {
      stderr.writeln('Core API snapshot is missing: ${snapshot.path}');
      exitCode = 1;
      return;
    }
    final expected = snapshot.readAsStringSync();
    if (expected != rendered) {
      stderr.writeln('Core API generation $_generation changed.');
      _printDiff(expected, rendered);
      stderr.writeln(
        'Review compatibility, then run: '
        'dart run tool/core_api_snapshot.dart --write',
      );
      exitCode = 1;
      return;
    }
  }

  _validateDeprecations(root, surface.deprecatedSymbols);
  _validateModuleCompatibility(root);
  stdout.writeln(
    'Core API generation $_generation: ${surface.lines.length - 3} entries OK',
  );
}

String _nextArgument(List<String> arguments, int index, String option) {
  if (index >= arguments.length) {
    stderr.writeln('$option requires a path');
    exit(64);
  }
  return arguments[index];
}

String _absolute(Directory root, String path) =>
    File(path).isAbsolute ? path : '${root.path}/$path';

Future<_Surface> _deriveSurface(Directory root, File library) async {
  if (!library.existsSync()) {
    throw StateError('Core library is missing: ${library.path}');
  }

  final collection = AnalysisContextCollection(includedPaths: [root.path]);
  final context = collection.contextFor(library.path);
  final result = await context.currentSession.getResolvedLibrary(library.path);
  if (result is! ResolvedLibraryResult) {
    throw StateError('Could not resolve ${library.path}: $result');
  }

  final errors = result.units
      .expand((unit) => unit.errors)
      .where(
        (error) => error.errorCode.errorSeverity == ErrorSeverity.ERROR,
      )
      .toList();
  if (errors.isNotEmpty) {
    for (final error in errors) {
      stderr.writeln(
          '${error.source.fullName}:${error.offset}: ${error.message}');
    }
    throw StateError('Core library has analyzer errors');
  }

  final lines = <String>[
    '# lazily Dart Core API',
    'format 1',
    'core_api_generation $_generation',
  ];
  final deprecated = <String>{};
  final exports = result.element.exportNamespace.definedNames.entries.toList()
    ..sort((left, right) => left.key.compareTo(right.key));

  for (final export in exports) {
    final element = export.value;
    if (element.isPrivate) continue;
    lines.add(_signature('export ${export.key}', element));
    if (element.hasDeprecated) deprecated.add(export.key);

    if (element is InterfaceElement) {
      _appendInterface(lines, deprecated, export.key, element);
    }
  }

  return _Surface(lines, deprecated);
}

void _appendInterface(
  List<String> lines,
  Set<String> deprecated,
  String owner,
  InterfaceElement element,
) {
  final hierarchy = <String>[];
  if (element.supertype case final supertype?) {
    hierarchy
        .add('extends ${supertype.getDisplayString(withNullability: true)}');
  }
  hierarchy.addAll(
    element.mixins.map(
      (type) => 'with ${type.getDisplayString(withNullability: true)}',
    ),
  );
  hierarchy.addAll(
    element.interfaces.map(
      (type) => 'implements ${type.getDisplayString(withNullability: true)}',
    ),
  );
  if (hierarchy.isNotEmpty) {
    lines.add('hierarchy $owner | ${hierarchy.join(' | ')}');
  }

  final members = <Element>[
    ...element.constructors.where((member) => !member.isPrivate),
    ...element.fields.where((member) => !member.isSynthetic),
    ...element.accessors.where((member) => !member.isSynthetic),
    ...element.methods,
  ].where((member) => !member.isPrivate).toList()
    ..sort((left, right) {
      final byName = left.displayName.compareTo(right.displayName);
      if (byName != 0) return byName;
      return left.kind.displayName.compareTo(right.kind.displayName);
    });

  for (final member in members) {
    final path = '$owner.${member.displayName}';
    lines.add(_signature('member $path', member));
    if (member.hasDeprecated) deprecated.add(path);
  }
}

String _signature(String prefix, Element element) {
  final display = element
      .getDisplayString(withNullability: true, multiline: false)
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return '$prefix | ${element.kind.displayName} | $display | '
      'deprecated=${element.hasDeprecated}';
}

void _validateDeprecations(Directory root, Set<String> deprecatedSymbols) {
  final file = File('${root.path}/api/core-deprecations.json');
  final document = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  _expect(document['schema_version'] == 1, 'unsupported deprecation schema');
  _expect(
    document['core_api_generation'] == _generation,
    'deprecation generation does not match snapshot',
  );

  final policy = document['policy'] as Map<String, Object?>;
  _expect(
    (policy['minimum_compatible_cohorts'] as int) >= 2,
    'deprecation policy must preserve at least two compatible cohorts',
  );
  _expect(
    (policy['minimum_days'] as int) >= 90,
    'deprecation policy must preserve at least 90 days',
  );

  final records = document['deprecations'] as List<Object?>;
  final recorded = <String>{};
  for (final value in records) {
    final record = value as Map<String, Object?>;
    final symbol = _requiredString(record, 'symbol');
    recorded.add(symbol);
    for (final field in [
      'introduced',
      'deprecated_since',
      'replacement',
      'earliest_removal',
    ]) {
      _requiredString(record, field);
    }
    _expect(
      record['minimum_compatible_cohorts'] ==
          policy['minimum_compatible_cohorts'],
      '$symbol must carry the policy cohort window',
    );
    _expect(
      record['minimum_days'] == policy['minimum_days'],
      '$symbol must carry the policy day window',
    );
  }

  _expect(
    recorded.length == records.length,
    'deprecation metadata contains duplicate symbols',
  );
  _expect(
    recorded.containsAll(deprecatedSymbols) &&
        deprecatedSymbols.containsAll(recorded),
    'deprecation metadata mismatch: analyzer=$deprecatedSymbols metadata=$recorded',
  );
}

void _validateModuleCompatibility(Directory root) {
  final file = File('${root.path}/api/core-module-compatibility.json');
  final document = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  _expect(document['schema_version'] == 1, 'unsupported module schema');
  _expect(
    document['core_api_generation'] == _generation,
    'module compatibility generation does not match snapshot',
  );
  final modules = document['independently_shipped_modules'] as List<Object?>;
  if (modules.isEmpty) {
    _requiredString(document, 'not_applicable_reason');
    return;
  }
  for (final value in modules) {
    final module = value as Map<String, Object?>;
    final name = _requiredString(module, 'name');
    _requiredString(module, 'minimum_core_api_generation');
    _requiredString(module, 'maximum_core_api_generation');
    _requiredString(module, 'oldest_supported_test');
    _requiredString(module, 'current_test');
    _expect(name.isNotEmpty, 'module name must not be empty');
  }
}

String _requiredString(Map<String, Object?> value, String field) {
  final result = value[field];
  _expect(result is String && result.trim().isNotEmpty, '$field is required');
  return result as String;
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void _printDiff(String expected, String actual) {
  final expectedLines = const LineSplitter().convert(expected);
  final actualLines = const LineSplitter().convert(actual);
  final count = expectedLines.length > actualLines.length
      ? expectedLines.length
      : actualLines.length;
  var shown = 0;
  for (var index = 0; index < count && shown < 20; index++) {
    final oldLine = index < expectedLines.length ? expectedLines[index] : null;
    final newLine = index < actualLines.length ? actualLines[index] : null;
    if (oldLine == newLine) continue;
    stderr.writeln('- ${oldLine ?? '<missing>'}');
    stderr.writeln('+ ${newLine ?? '<missing>'}');
    shown++;
  }
  if (shown == 20) stderr.writeln('... diff truncated ...');
}

final class _Surface {
  const _Surface(this.lines, this.deprecatedSymbols);

  final List<String> lines;
  final Set<String> deprecatedSymbols;
}
