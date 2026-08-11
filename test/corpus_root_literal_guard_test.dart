/// Corpus-root regression guard (`#lzcorpusrootguards`).
///
/// `LAZILY_SPEC_CONFORMANCE_DIR` repoints the WHOLE suite at another copy of
/// the conformance corpus, and `conformance_manifest.dart` is the one place
/// that resolves it. A runner that builds its own path to the sibling checkout
/// instead never sees the override — and that failure is SILENT, because a
/// runner reading the default corpus while believing it was redirected is green
/// either way. The measurement is the whole reason this exists: in lazily-zig
/// fourteen hardcoded roots across twelve areas meant truncating fourteen
/// fixtures in a scratch corpus reddened ZERO tests; lazily-rs was worse, 0 of
/// 25 areas. This binding measured CLEAN — 24 of 24 areas reddened under a
/// perturbed corpus — so this guard prevents a regression rather than fixing a
/// live bug. Until now that cleanliness was CONVENTION: the prose above
/// [defaultSpecCorpusPath] asserts "no test file spells the sibling path
/// itself", and nothing enforced it.
///
/// ## What counts as spelling it
///
/// Two forms, because guarding only the first is evadable and was in fact
/// evaded — lazily-go's and lazily-js's guards both grepped for the whole path
/// as one string and both were proven to miss segments joined at runtime:
///
///   1. the single literal, a string containing the default root; and
///   2. the JOINED-SEGMENT form — separate literals combined by a path join, by
///      `+`, or by adjacency, plus any literal naming the sibling repo in path
///      position, which is what every join form must contain somewhere. A run
///      split MID-WORD leaves no intact segment either, so runs of fragments are
///      also reassembled with the separators squashed out.
///
/// Comments are skipped. Several runners legitimately quote the corpus path
/// while explaining where their fixtures come from, and `specCorpusPath`'s own
/// error messages name the sibling in prose; forcing them to stop describing it
/// would trade a real explanation for a lint.
///
/// The target is READ FROM THE SEAM rather than spelled here, so this file is
/// subject to its own rule and needs no allowlist entry of its own, and so the
/// guard follows the default if it ever changes.
///
/// ## Positive evidence
///
/// A walk that examines zero files must FAIL. A scan that reports OK over an
/// empty set is the vacuous green this family's guards exist to prevent, so
/// [scanForCorpusRootSpellings] throws rather than returning a clean report.
library;

import 'dart:io';

import 'package:test/test.dart';

import 'conformance_manifest.dart';

// ---------------------------------------------------------------------------
// Scan configuration
// ---------------------------------------------------------------------------

/// Directories walked for Dart sources.
const _scanRoots = <String>['test', 'lib', 'tool', 'bin', 'benchmark'];

/// The ONE file allowed to spell the corpus root: the seam that defines it and
/// resolves the override for every runner.
const _allowlist = <String>{'test/conformance_manifest.dart'};

/// Never descended into. `test/conformance` is the vendored fixture MIRROR —
/// data, not source.
const _skipDirs = <String>{'test/conformance'};

/// Floor on files examined. Not a magic number: the suite alone is 60+ files,
/// so anything near zero means the walk lost the tree rather than that the tree
/// shrank.
const _minimumFilesExamined = 40;

// ---------------------------------------------------------------------------
// Findings
// ---------------------------------------------------------------------------

/// One offending spelling of the corpus root.
class CorpusRootHit {
  const CorpusRootHit({
    required this.file,
    required this.line,
    required this.rule,
    required this.text,
  });

  /// Path of the offending source, relative to the package root.
  final String file;

  /// 1-based line of the first literal involved.
  final int line;

  /// Which form was matched: `single-literal`, `joined-segments`, or
  /// `sibling-segment`.
  final String rule;

  /// The reassembled text that matched, for the failure message.
  final String text;

  @override
  String toString() => '$file:$line [$rule] $text';
}

/// Result of one walk. [filesExamined] is the positive evidence.
class CorpusRootScan {
  const CorpusRootScan({required this.filesExamined, required this.hits});

  final int filesExamined;
  final List<CorpusRootHit> hits;
}

// ---------------------------------------------------------------------------
// Path shapes derived from the seam
// ---------------------------------------------------------------------------

String _normalizePath(String value) {
  final slashed = value.replaceAll(r'\', '/');
  return slashed.replaceAll(RegExp('/+'), '/');
}

/// The default corpus root, normalized. Read from the seam, never spelled here.
String get _targetRoot => _normalizePath(defaultSpecCorpusPath);

/// Segments that identify the sibling checkout.
///
/// `..` is not distinctive and the LAST segment is a common word this repo also
/// uses for its own directories, so neither can be flagged on its own. What is
/// left names the sibling repository, and every way of building the root — one
/// literal, a join, a `+` chain — has to produce it somewhere.
List<String> get _siblingSegments {
  final segments = _targetRoot.split('/');
  if (segments.length < 2) return const [];
  return segments
      .sublist(0, segments.length - 1)
      .where((s) => s.isNotEmpty && s != '..' && s != '.')
      .toList(growable: false);
}

/// Whether [haystack] contains [segment] as a whole path segment.
///
/// Bounded by separators or by the ends of the literal, which is what separates
/// `'../lazily-spec'` (a path being built) from prose like `run with the
/// lazily-spec sibling` (a message being written).
bool _containsPathSegment(String haystack, String segment) {
  final text = _normalizePath(haystack);
  var index = text.indexOf(segment);
  while (index >= 0) {
    final beforeOk = index == 0 || text[index - 1] == '/';
    final after = index + segment.length;
    final afterOk = after == text.length || text[after] == '/';
    if (beforeOk && afterOk) return true;
    index = text.indexOf(segment, index + 1);
  }
  return false;
}

bool _spellsSibling(String text) =>
    _siblingSegments.any((segment) => _containsPathSegment(text, segment));

/// The same text with every path separator and `.` removed.
///
/// This is what defeats a decomposition no single literal survives —
/// `'laz' 'ily' '-sp' 'ec'` fed to a join. Squashed, any reassembly of the root
/// out of parts contains the squashed root, whatever separators the join put
/// between the pieces.
String _squash(String value) => value.replaceAll(RegExp(r'[/\\.]'), '');

bool _hasSpace(String value) => value.contains(RegExp(r'\s'));

// ---------------------------------------------------------------------------
// Dart string-literal extraction
// ---------------------------------------------------------------------------

class _Literal {
  _Literal({required this.content, required this.start, required this.end});

  final String content;
  final int start;
  final int end;
}

final _identifierChar = RegExp(r'[A-Za-z0-9_$]');

bool _isIdentifierChar(String c) => _identifierChar.hasMatch(c);

int _skipBlockComment(String src, int i) {
  var index = i + 2;
  var depth = 1;
  while (index < src.length && depth > 0) {
    if (src.startsWith('/*', index)) {
      depth++;
      index += 2;
    } else if (src.startsWith('*/', index)) {
      depth--;
      index += 2;
    } else {
      index++;
    }
  }
  return index;
}

class _StringToken {
  const _StringToken({required this.end, required this.content});

  final int end;
  final String content;
}

/// Scan code from [i], collecting every string literal into [out].
///
/// Line and block comments are consumed without contributing literals, which is
/// how a doc comment quoting the corpus path stays legal. When
/// [stopAtCloseBrace] is set the scan is inside a `${...}` interpolation and
/// returns just past the matching brace, so literals nested in interpolations
/// are collected too.
int _scanCode(
  String src,
  int i,
  List<_Literal> out, {
  required bool stopAtCloseBrace,
}) {
  var index = i;
  var depth = 0;
  while (index < src.length) {
    if (src.startsWith('//', index)) {
      while (index < src.length && src[index] != '\n') {
        index++;
      }
      continue;
    }
    if (src.startsWith('/*', index)) {
      index = _skipBlockComment(src, index);
      continue;
    }
    final c = src[index];
    if (stopAtCloseBrace) {
      if (c == '{') {
        depth++;
        index++;
        continue;
      }
      if (c == '}') {
        if (depth == 0) return index + 1;
        depth--;
        index++;
        continue;
      }
    }
    final raw = c == 'r' &&
        index + 1 < src.length &&
        (src[index + 1] == "'" || src[index + 1] == '"') &&
        (index == 0 || !_isIdentifierChar(src[index - 1]));
    if (c == "'" || c == '"' || raw) {
      final quoteStart = raw ? index + 1 : index;
      final token = _scanString(src, quoteStart, raw, out);
      out.add(
        _Literal(content: token.content, start: index, end: token.end),
      );
      index = token.end;
      continue;
    }
    index++;
  }
  return index;
}

/// Scan one string literal starting at its opening quote.
///
/// Handles single/double quotes, triple quotes, raw strings, escapes, and
/// `${...}` interpolations (whose own literals land in [out]).
_StringToken _scanString(
  String src,
  int quoteStart,
  bool raw,
  List<_Literal> out,
) {
  final quote = src[quoteStart];
  final closer = src.startsWith(quote * 3, quoteStart) ? quote * 3 : quote;
  var index = quoteStart + closer.length;
  final buffer = StringBuffer();
  while (index < src.length) {
    if (src.startsWith(closer, index)) {
      index += closer.length;
      break;
    }
    final c = src[index];
    if (!raw && c == r'\') {
      if (index + 1 < src.length) {
        buffer.write(src[index + 1]);
        index += 2;
      } else {
        index++;
      }
      continue;
    }
    if (!raw && c == r'$' && index + 1 < src.length && src[index + 1] == '{') {
      index = _scanCode(src, index + 2, out, stopAtCloseBrace: true);
      continue;
    }
    buffer.write(c);
    index++;
  }
  return _StringToken(end: index, content: buffer.toString());
}

List<_Literal> _stringLiterals(String source) {
  final literals = <_Literal>[];
  _scanCode(source, 0, literals, stopAtCloseBrace: false);
  literals.sort((a, b) => a.start.compareTo(b.start));
  return literals;
}

/// Text between two literals with comments removed.
String _gapText(String source, int from, int to) {
  if (to <= from) return '';
  return source
      .substring(from, to)
      .replaceAll(RegExp(r'//[^\n]*'), '')
      .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
}

/// Literals that are only separated by concatenation punctuation belong to one
/// group: adjacency (`'a' 'b'`), `+`, and the comma between join arguments.
final _concatenationGap = RegExp(r'^[\s,+]*$');

int _lineOf(String source, int offset) {
  var line = 1;
  for (var i = 0; i < offset && i < source.length; i++) {
    if (source[i] == '\n') line++;
  }
  return line;
}

// ---------------------------------------------------------------------------
// The scan
// ---------------------------------------------------------------------------

/// Findings for one source file's text.
///
/// Exposed so the detector can be exercised against synthetic sources without
/// writing files.
List<CorpusRootHit> findCorpusRootSpellings(String path, String source) {
  final hits = <CorpusRootHit>[];
  final literals = _stringLiterals(source);

  // Rung 1 + the sibling segment: one literal at a time.
  for (final literal in literals) {
    final text = _normalizePath(literal.content);
    if (text.contains(_targetRoot)) {
      hits.add(
        CorpusRootHit(
          file: path,
          line: _lineOf(source, literal.start),
          rule: 'single-literal',
          text: literal.content,
        ),
      );
    } else if (_spellsSibling(literal.content)) {
      hits.add(
        CorpusRootHit(
          file: path,
          line: _lineOf(source, literal.start),
          rule: 'sibling-segment',
          text: literal.content,
        ),
      );
    }
  }

  // Rung 2: literals combined at runtime. Each maximal run of literals
  // separated only by concatenation punctuation is reassembled every way a path
  // can be built from parts — glued (`+`, adjacency), joined by the separator
  // (`p.join`, `List.join`), and squashed so a run split mid-word still shows
  // the root.
  var start = 0;
  while (start < literals.length) {
    var end = start + 1;
    while (end < literals.length &&
        _concatenationGap.hasMatch(
          _gapText(source, literals[end - 1].end, literals[end].start),
        )) {
      end++;
    }
    if (end - start >= 2) {
      final parts = literals
          .sublist(start, end)
          .map((literal) => literal.content)
          .toList(growable: false);
      // A run of path fragments never contains whitespace; a long message split
      // across adjacent literals does. Only the fragment case gets the loosest
      // rung, so an error string that names the sibling in prose stays legal.
      final looksLikePath = parts.every((part) => !_hasSpace(part));
      final squashedGlue = _squash(parts.join());

      for (final candidate in <String>[parts.join(), parts.join('/')]) {
        final text = _normalizePath(candidate);
        if (text.contains(_targetRoot) ||
            _spellsSibling(text) ||
            squashedGlue.contains(_squash(_targetRoot)) ||
            (looksLikePath &&
                _siblingSegments.any(
                  (segment) => squashedGlue.contains(_squash(segment)),
                ))) {
          final alreadyReported = hits.any(
            (hit) => hit.line == _lineOf(source, literals[start].start),
          );
          if (!alreadyReported) {
            hits.add(
              CorpusRootHit(
                file: path,
                line: _lineOf(source, literals[start].start),
                rule: 'joined-segments',
                text: parts.join(' + '),
              ),
            );
          }
          break;
        }
      }
    }
    start = end;
  }

  return hits;
}

/// Walk [roots] and report every source outside [allowlist] that spells the
/// default corpus root.
///
/// Throws [StateError] when the walk examined nothing: reporting a clean tree
/// after reading no files is the vacuous pass this guard exists to refuse.
CorpusRootScan scanForCorpusRootSpellings({
  List<String> roots = _scanRoots,
  Set<String> allowlist = _allowlist,
  Set<String> skipDirs = _skipDirs,
}) {
  final hits = <CorpusRootHit>[];
  var examined = 0;

  for (final root in roots) {
    final directory = Directory(root);
    if (!directory.existsSync()) continue;
    final entries = directory.listSync(recursive: true).whereType<File>();
    for (final file in entries) {
      final relative = file.path.replaceAll(r'\', '/');
      if (!relative.endsWith('.dart')) continue;
      final segments = relative.split('/');
      if (segments.any((s) => s.startsWith('.') && s.length > 1)) continue;
      if (skipDirs.any((dir) => relative.startsWith('$dir/'))) continue;
      examined++;
      if (allowlist.contains(relative)) continue;
      hits.addAll(findCorpusRootSpellings(relative, file.readAsStringSync()));
    }
  }

  if (examined == 0) {
    throw StateError(
      'corpus-root guard examined 0 Dart sources under ${roots.join(', ')}. '
      'Reporting OK here would be a pass over nothing: the walk lost the tree, '
      'so the guard proved nothing about it (#lzcorpusrootguards).',
    );
  }

  return CorpusRootScan(filesExamined: examined, hits: hits);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// A synthetic source built from the seam's own default, so this file never
/// spells the corpus root and is therefore subject to its own rule.
List<String> get _rootSegments => _targetRoot.split('/');

void main() {
  group('corpus-root regression guard (#lzcorpusrootguards)', () {
    test('no source outside the seam spells the corpus root', () {
      final scan = scanForCorpusRootSpellings();

      expect(
        scan.hits,
        isEmpty,
        reason: 'These sources build a path to the canonical corpus instead of '
            'resolving it through conformance_manifest.dart, so '
            '$specCorpusEnvVar would not reach them and a corpus-perturbation '
            'probe would read them as unfalsifiable:\n'
            '  ${scan.hits.join('\n  ')}\n'
            'Use specFixturePath / specCorpusSubdir / specFamilyDir instead.',
      );

      // Positive evidence: the walk really covered the suite.
      expect(
        scan.filesExamined,
        greaterThanOrEqualTo(_minimumFilesExamined),
        reason: 'the walk examined only ${scan.filesExamined} sources',
      );
    });

    test('a walk that examines nothing FAILS', () {
      final empty = Directory.systemTemp.createTempSync('lz-corpus-root-guard');
      addTearDown(() => empty.deleteSync(recursive: true));

      expect(
        () => scanForCorpusRootSpellings(roots: [empty.path]),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('examined 0'), contains('pass over nothing')),
          ),
        ),
      );

      expect(
        () => scanForCorpusRootSpellings(
          roots: ['${empty.path}/does-not-exist'],
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('the single-literal form is caught', () {
      final source = "final path = '$_targetRoot/collections/queue.json';\n";
      final hits = findCorpusRootSpellings('synthetic.dart', source);

      expect(hits, hasLength(1));
      expect(hits.single.rule, 'single-literal');
      expect(hits.single.line, 1);
    });

    test('the joined-segment form is caught', () {
      // The form lazily-go's and lazily-js's guards both missed: no single
      // literal contains the root, so a whole-path grep finds nothing.
      final segments = _rootSegments.map((s) => "'$s'").join(', ');
      final source = 'final path = p.join($segments, "collections");\n';
      final hits = findCorpusRootSpellings('synthetic.dart', source);

      expect(hits, isNotEmpty);
      expect(
        hits.map((hit) => hit.rule),
        anyElement(anyOf('joined-segments', 'sibling-segment')),
      );
    });

    test('the `+` concatenation form is caught', () {
      final head = _rootSegments.sublist(0, _rootSegments.length - 1).join('/');
      final tail = _rootSegments.last;
      final source = "final path = '$head' + '/$tail';\n";

      expect(findCorpusRootSpellings('synthetic.dart', source), isNotEmpty);
    });

    test('adjacent literal juxtaposition is caught', () {
      final head = _rootSegments.sublist(0, _rootSegments.length - 1).join('/');
      final tail = _rootSegments.last;
      final source = "final path = '$head'\n    '/$tail';\n";

      expect(findCorpusRootSpellings('synthetic.dart', source), isNotEmpty);
    });

    test('a run split mid-word is caught', () {
      // The hardest evasion: no literal holds an intact segment, so both a
      // whole-path grep AND a segment match come up empty.
      final pieces = _siblingSegments
          .expand((segment) {
            final half = segment.length ~/ 2;
            return [segment.substring(0, half), segment.substring(half)];
          })
          .map((piece) => "'$piece'")
          .join(' ');
      final source =
          "final path = p.join('..', $pieces, '${_rootSegments.last}');\n";

      expect(findCorpusRootSpellings('synthetic.dart', source), isNotEmpty);
    });

    test('prose split across adjacent literals is not a path', () {
      // Long messages are written this way in this suite, and one of them names
      // the sibling. Whitespace in a fragment is what tells them apart.
      final sibling = _siblingSegments.join(' ');
      final source = "throw StateError('corpus absent - clone the $sibling '\n"
          "    'sibling next to this checkout');";

      expect(findCorpusRootSpellings('synthetic.dart', source), isEmpty);
    });

    test('comments and doc comments are skipped', () {
      final source = '''
/// Fixtures mirror $_targetRoot/presence/ byte-identically.
// see $_targetRoot/presence/
/* $_targetRoot/presence/ */
final path = specFixturePath('presence/heartbeat.json');
''';

      expect(findCorpusRootSpellings('synthetic.dart', source), isEmpty);
    });

    test('prose naming the sibling is not a path', () {
      // `specCorpusPath`'s diagnostics say this in real messages; a guard that
      // banned the word would push runners into worse error text.
      final sibling = _siblingSegments.join(' ');
      final source = "throw StateError('absent - clone the $sibling sibling');";

      expect(findCorpusRootSpellings('synthetic.dart', source), isEmpty);
    });
  });
}
