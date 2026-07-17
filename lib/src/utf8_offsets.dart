/// UTF-8 wire offset conversion (`#lzlosstree`).
///
/// The lossless-tree protocol carries leaf-local text offsets as **UTF-8 byte
/// offsets** (lazily-spec § Offset policy): agent-doc documents are UTF-8 files
/// and parser spans are byte ranges. No binding may treat UTF-16 code units as
/// wire offsets. Dart's `String` is UTF-16, and [TextCrdt] is code-point
/// granular (one element per Unicode scalar), so the byte-taking mutators must
/// convert a wire byte offset to the host index model here:
///
/// - [byteToUtf16] — UTF-8 byte offset → UTF-16 code-unit index.
/// - [byteToCodePoint] / [codePointToUtf16] — UTF-8 byte offset → Unicode
///   scalar count (the wire `at_char`), and back to a UTF-16 index.
///
/// Every conversion rejects an offset that is out of range or does not land on a
/// UTF-8 character boundary (returns `null`), so a bad offset fails closed
/// rather than silently corrupting text.
///
/// Mirrors `lazily-kt/src/main/kotlin/io/github/lazily/Utf8Offsets.kt`.
library;

/// UTF-8 byte length of the character whose code point is [cp].
@pragma('vm:prefer-inline')
int _utf8Len(int cp) {
  if (cp < 0x80) return 1;
  if (cp < 0x800) return 2;
  if (cp < 0x10000) return 3;
  return 4;
}

/// UTF-8 byte offset [byte] into [s] → the UTF-16 code-unit index at that
/// position, or `null` if [byte] is out of range or not on a char boundary.
int? byteToUtf16(String s, int byte) {
  if (byte < 0) return null;
  var b = 0;
  var i = 0;
  final runes = s.runes.iterator;
  while (b < byte) {
    if (!runes.moveNext()) return null; // past end
    final cp = runes.current;
    b += _utf8Len(cp);
    i += cp >= 0x10000 ? 2 : 1; // UTF-16 code-unit count
    if (b > byte) return null; // offset falls inside this character
  }
  return i;
}

/// UTF-8 byte offset [byte] into [s] → the number of Unicode scalars (code
/// points) before it — the wire `at_char` value — or `null` if [byte] is out of
/// range or not on a char boundary.
int? byteToCodePoint(String s, int byte) {
  if (byte < 0) return null;
  var b = 0;
  var cp = 0;
  final runes = s.runes.iterator;
  while (b < byte) {
    if (!runes.moveNext()) return null;
    final c = runes.current;
    b += _utf8Len(c);
    cp += 1;
    if (b > byte) return null;
  }
  return cp;
}

/// A Unicode scalar (code-point) count [cpCount] → the UTF-16 code-unit index
/// in [s], clamped into range (matching the reference's `at_char.min(len)`).
int codePointToUtf16(String s, int cpCount) {
  final total = s.runes.length;
  final n = cpCount < 0 ? 0 : (cpCount > total ? total : cpCount);
  return String.fromCharCodes(s.runes.take(n)).length;
}
