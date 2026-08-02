/// Manufactured identity for text — stable-id alignment.
///
/// Three layers of identity manufacturing:
/// 1. In-band **anchors** (exact, survive body rewrite).
/// 2. Content-derived **hashes** of whitespace-normalized text (survive
///    reflow/reorder, change on edit).
/// 3. Word-LCS **similarity alignment** (≥ 0.5 → Edited/key-inherited;
///    below → Inserted).
///
/// Keys carry an `a:`/`c:` prefix so anchored and content keyspaces never
/// collide. Mirrors `lazily-js/src/stable-id.js`. Conforms to `lazily-spec`
/// `conformance/collections/stableid_alignment.json`.
library;

import 'dart:typed_data' show BytesBuilder, Uint8List;

import 'fnv1a64.dart';
import 'int_width.dart';
import 'u64.dart';

/// The edit-similarity threshold below which a match is treated as an insert.
const double kEditThreshold = 0.5;

/// The anchored-key wire prefix.
const String kAnchorPrefix = 'a:';

/// The content-key wire prefix.
const String kContentPrefix = 'c:';

/// A text block, optionally anchored.
class Block {
  Block(this.text, {this.anchor});

  factory Block.text(String text) => Block(text);

  factory Block.anchored(String anchor, String text) =>
      Block(text, anchor: anchor);

  final String text;
  final String? anchor;

  @override
  String toString() => anchor != null ? 'Block($anchor:$text)' : 'Block($text)';
}

/// A manufactured block key: either anchored or content-derived.
class BlockKey {
  const BlockKey.anchored(this.value)
      : kind = 'anchored',
        _isContent = false;

  /// A content key from the 16-char zero-padded hex of the FNV-1a-64 digest.
  ///
  /// Hex rather than the packed `int` this used to take: the full 64-bit digest
  /// is not representable on a JavaScript target at all, so an `int`-valued
  /// content key could not cross a browser boundary without rounding into a
  /// different identity (`#lzdartwebcompile`). The hex string is the wire form
  /// already, and it compares and prints identically everywhere.
  const BlockKey.content(this.value)
      : kind = 'content',
        _isContent = true;

  final String kind;

  /// The anchor for an anchored key; the 16-char FNV-1a-64 hex for a content
  /// key. Both spellings are `String`, so equality is value equality on every
  /// target.
  final String value;

  final bool _isContent;

  bool get isAnchored => !_isContent;
  bool get isContent => _isContent;

  bool equals(BlockKey other) => kind == other.kind && value == other.value;

  /// Wire form: `a:<anchor>` or `c:` + 16-char zero-padded hex.
  String asString() {
    if (isAnchored) return '$kAnchorPrefix$value';
    return '$kContentPrefix$value';
  }

  @override
  String toString() => asString();
}

/// Normalize whitespace: split on `\s+`, drop empties, join with a single space.
String normalize(String text) {
  final parts = text.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  return parts.join(' ');
}

/// The FNV-1a-64 digest of the UTF-8 of `normalize(text)`, as two 32-bit
/// halves.
///
/// This is the portable spelling and the one every other API here is built on:
/// the halves are exact on the VM and on a JavaScript target alike, so the
/// digest is one value with one definition rather than a number that means
/// something different once compiled (`#lzdartwebcompile`).
Fnv1a64 contentDigest(String text) =>
    Fnv1a64()..addBytes(_utf8Bytes(normalize(text)));

/// FNV-1a 64-bit content hash of the UTF-8 of `normalize(text)`, as 16-char
/// zero-padded lowercase hex — the `c:` wire form without its prefix.
///
/// Cross-language stable (NOT Dart's `hashCode`) and, unlike [contentHash],
/// available on every target: hex has no representation limit where a packed
/// 64-bit `int` has one.
String contentHashHex(String text) {
  final digest = contentDigest(text);
  return u64Hex(digest.hi, digest.lo);
}

/// FNV-1a 64-bit content hash of the UTF-8 of `normalize(text)`, packed into a
/// signed 64-bit [int] whose bit pattern is the full unsigned digest.
///
/// **Native only.** On a JavaScript target `int` is a double, and a digest above
/// 2^53 - 1 — which is nearly all of them — cannot be packed without silently
/// becoming a different identity, so this THROWS [UnsupportedError] there rather
/// than rounding (`#lzdartintwidth` states the same refuse-never-round rule for
/// wire integers). Use [contentHashHex], which is what the wire form and
/// [BlockKey.content] both take, for code that has to run in a browser.
int contentHash(String text) {
  final digest = contentDigest(text);
  return u64ToInt(digest.hi, digest.lo);
}

/// Encode [s] as UTF-8 bytes without dart:convert (keep deps minimal).
///
/// Iterates Unicode scalars via [String.runes] (NOT `codeUnits`, which are
/// UTF-16 halves — supplementary-plane characters like emoji would otherwise
/// emit invalid 3-byte-per-surrogate sequences; `#lzdartutf8fix`). Builds a
/// compact [Uint8List] via [BytesBuilder].
Uint8List _utf8Bytes(String s) {
  final out = BytesBuilder();
  for (final cp in s.runes) {
    if (cp < 0x80) {
      out.addByte(cp);
    } else if (cp < 0x800) {
      out.addByte(0xC0 | (cp >> 6));
      out.addByte(0x80 | (cp & 0x3F));
    } else if (cp < 0x10000) {
      out.addByte(0xE0 | (cp >> 12));
      out.addByte(0x80 | ((cp >> 6) & 0x3F));
      out.addByte(0x80 | (cp & 0x3F));
    } else {
      out.addByte(0xF0 | (cp >> 18));
      out.addByte(0x80 | ((cp >> 12) & 0x3F));
      out.addByte(0x80 | ((cp >> 6) & 0x3F));
      out.addByte(0x80 | (cp & 0x3F));
    }
  }
  return out.toBytes();
}

/// Compute the manufactured key for [block]: anchor wins, else content hash.
BlockKey blockKey(Block block) {
  if (block.anchor != null) {
    return BlockKey.anchored(block.anchor!);
  }
  return BlockKey.content(contentHashHex(block.text));
}

/// Word-LCS length via rolling two-row DP.
int _lcsLen(List<String> a, List<String> b) {
  if (a.isEmpty || b.isEmpty) return 0;
  var prev = List<int>.filled(b.length + 1, 0);
  var curr = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    for (var j = 1; j <= b.length; j++) {
      if (a[i - 1] == b[j - 1]) {
        curr[j] = prev[j - 1] + 1;
      } else {
        curr[j] = prev[j] > curr[j - 1] ? prev[j] : curr[j - 1];
      }
    }
    final tmp = prev;
    prev = curr;
    curr = tmp;
    for (var j = 0; j <= b.length; j++) {
      curr[j] = 0;
    }
  }
  return prev[b.length];
}

List<String> _tokenize(String s) =>
    s.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();

/// Similarity in `[0, 1]`: `2·|word-LCS| / (|a| + |b|)`. Both-empty = 1.0.
double similarity(String a, String b) {
  final ta = _tokenize(a);
  final tb = _tokenize(b);
  if (ta.isEmpty && tb.isEmpty) return 1.0;
  if (ta.isEmpty || tb.isEmpty) return 0.0;
  final lcs = _lcsLen(ta, tb);
  return (2 * lcs) / (ta.length + tb.length);
}

/// The kind of match for a new block against the old set.
class Match {
  const Match._(this.kind, this.oldIndex, this.similarity);

  factory Match.same(int oldIndex) => Match._('same', oldIndex, 1.0);
  factory Match.edited(int oldIndex, double similarity) =>
      Match._('edited', oldIndex, similarity);
  factory Match.inserted() => Match._('inserted', -1, 0.0);

  final String kind; // 'same' | 'edited' | 'inserted'
  final int oldIndex; // -1 for inserted
  final double similarity;

  @override
  String toString() => kind == 'inserted'
      ? 'Inserted'
      : '${kind[0].toUpperCase()}${kind.substring(1)}:$oldIndex';
}

/// The alignment of new blocks against old, plus the set of removed indices.
class Alignment {
  const Alignment(this.newMatches, this.removed);

  final List<Match> newMatches; // one per new block
  final List<int> removed; // old indices not matched

  @override
  String toString() =>
      'Alignment(matches=${newMatches.map((m) => m.toString())}, removed=$removed)';
}

/// Align [newBlocks] against [oldBlocks]: exact-key match first, then
/// similarity (≥ threshold) with nearest-index tiebreak.
Alignment align(List<Block> oldBlocks, List<Block> newBlocks) {
  final oldKeys = oldBlocks.map(blockKey).toList();
  final newKeys = newBlocks.map(blockKey).toList();
  final oldUsed = List<bool>.filled(oldBlocks.length, false);
  final matches = List<Match?>.filled(newBlocks.length, null);

  // Pass 1: exact key match (lowest unused old index).
  for (var ni = 0; ni < newBlocks.length; ni++) {
    for (var oi = 0; oi < oldBlocks.length; oi++) {
      if (!oldUsed[oi] && newKeys[ni].equals(oldKeys[oi])) {
        matches[ni] = Match.same(oi);
        oldUsed[oi] = true;
        break;
      }
    }
  }

  // Pass 2: similarity match for unmatched new blocks.
  for (var ni = 0; ni < newBlocks.length; ni++) {
    if (matches[ni] != null) continue;
    var bestOi = -1;
    var bestSim = 0.0;
    // Nullable rather than a saturating sentinel: `0x7FFFFFFFFFFFFFFF` is an
    // integer literal dart2js refuses outright, so spelling "no candidate yet"
    // as a magnitude cost the whole library its browser build
    // (`#lzdartwebcompile`). `null` says the same thing and has no width.
    int? bestDist;
    for (var oi = 0; oi < oldBlocks.length; oi++) {
      if (oldUsed[oi]) continue;
      final sim = similarity(newBlocks[ni].text, oldBlocks[oi].text);
      final dist = (oi - ni).abs();
      if (sim > bestSim ||
          (sim == bestSim &&
              sim >= kEditThreshold &&
              (bestDist == null || dist < bestDist))) {
        bestSim = sim;
        bestOi = oi;
        bestDist = dist;
      }
    }
    if (bestOi >= 0 && bestSim >= kEditThreshold) {
      matches[ni] = Match.edited(bestOi, bestSim);
      oldUsed[bestOi] = true;
    } else {
      matches[ni] = Match.inserted();
    }
  }

  final removed = <int>[];
  for (var oi = 0; oi < oldBlocks.length; oi++) {
    if (!oldUsed[oi]) removed.add(oi);
  }

  return Alignment(matches.cast<Match>(), removed);
}

/// Assign stable keys to [newBlocks] by flowing identity through the alignment
/// with [oldBlocks]. Same/Edited inherit the predecessor's key; Inserted get a
/// fresh key.
List<String> assignStableKeys(List<Block> oldBlocks, List<Block> newBlocks) {
  final alignment = align(oldBlocks, newBlocks);
  final result = <String>[];
  for (var ni = 0; ni < newBlocks.length; ni++) {
    final m = alignment.newMatches[ni];
    if (m.kind == 'inserted') {
      result.add(blockKey(newBlocks[ni]).asString());
    } else {
      result.add(blockKey(oldBlocks[m.oldIndex]).asString());
    }
  }
  return result;
}
