import 'dart:typed_data';

import 'package:lazily/lazily.dart';
import 'package:test/test.dart';

/// Split-word 64-bit arithmetic (`#lzdartwebcompile`).
///
/// The VM can do every one of these operations natively, which is what makes
/// this suite worth more than a table of golden numbers: the native result is an
/// INDEPENDENT oracle, so each test states "the portable spelling agrees with
/// the arithmetic it replaced" rather than "the portable spelling returns what I
/// wrote down". A JS target has no such oracle — it cannot form the 64-bit value
/// to compare against — so this equivalence has to be proven here, and the
/// browser entry point then only has to prove the same code runs there.
void main() {
  // A corpus that reaches every carry boundary the limb multiply has: zero, the
  // limb edges, the half-word edges, the sign bit, and values whose product
  // wraps.
  final corpus = <int>[
    0,
    1,
    2,
    0xFFFF,
    0x10000,
    0xFFFFFFFF,
    0x100000000,
    0x123456789ABCDEF,
    0x7FFFFFFFFFFFFFFF,
    -1,
    -2,
    -0x80000000,
    -0x100000000,
    9007199254740991, // 2^53 - 1
    9007199254740993, // 2^53 + 1
  ];

  U64 splitOf(int value) => U64(highHalfOf(value), lowHalfOf(value));
  int joinOf(U64 v) => v.hi * 0x100000000 + v.lo;

  group('half splitting', () {
    test('round-trips every value, including negatives', () {
      for (final value in corpus) {
        final parts = splitOf(value);
        expect(parts.hi, inInclusiveRange(0, 0xFFFFFFFF), reason: '$value hi');
        expect(parts.lo, inInclusiveRange(0, 0xFFFFFFFF), reason: '$value lo');
        // The join wraps back through the VM's signed 64-bit `int`, so this is
        // an identity on the bit pattern, not merely on the magnitude.
        expect(joinOf(parts), value, reason: 'round trip of $value');
      }
    });

    test('agrees with the bitwise spelling it replaced', () {
      for (final value in corpus) {
        expect(highHalfOf(value), (value >>> 32) & 0xFFFFFFFF,
            reason: 'high half of $value');
        expect(lowHalfOf(value), value & 0xFFFFFFFF,
            reason: 'low half of $value');
      }
    });
  });

  group('arithmetic agrees with native 64-bit int', () {
    test('add', () {
      for (final a in corpus) {
        for (final b in corpus) {
          final v = splitOf(a)..add(highHalfOf(b), lowHalfOf(b));
          expect(joinOf(v), a + b, reason: '$a + $b');
        }
      }
    });

    test('multiply', () {
      for (final a in corpus) {
        for (final b in corpus) {
          final v = splitOf(a)..multiply(highHalfOf(b), lowHalfOf(b));
          expect(joinOf(v), a * b, reason: '$a * $b');
        }
      }
    });

    test('xor', () {
      for (final a in corpus) {
        for (final b in corpus) {
          final v = splitOf(a)..xor(highHalfOf(b), lowHalfOf(b));
          expect(joinOf(v), a ^ b, reason: '$a ^ $b');
        }
      }
    });

    test('logical shift right, every width', () {
      for (final a in corpus) {
        for (var bits = 0; bits < 64; bits++) {
          expect(joinOf(splitOf(a).shiftedRight(bits)), a >>> bits,
              reason: '$a >>> $bits');
        }
      }
    });

    test('xor-shift-right, the SplitMix mixing step', () {
      for (final a in corpus) {
        for (final bits in <int>[27, 30, 31]) {
          final v = splitOf(a)..xorShiftRight(bits);
          expect(joinOf(v), a ^ (a >>> bits), reason: '$a mix $bits');
        }
      }
    });
  });

  group('FNV-1a-64', () {
    // Canonical FNV-1a-64 vectors, and the same literals the browser entry
    // point pins. A digest that drifts on either side of the compile boundary
    // reddens one of the two.
    const vectors = <String, String>{
      '': 'cbf29ce484222325',
      'a': 'af63dc4c8601ec8c',
      'hello world': '779a65e7023cd2e7',
      'the quick brown fox': '59aeb7b40bd8c122',
      'ünïcödé 😀': '2636b0bae56c1307',
    };

    test('matches the canonical digests', () {
      vectors.forEach((text, expected) {
        expect(contentHashHex(text), expected, reason: 'digest of "$text"');
      });
    });

    test('agrees with the native fixed-width loop it replaced', () {
      // The exact arithmetic that used to live in `contentHash`, kept here as
      // an oracle. It cannot be compiled for the web — that is the whole reason
      // it moved — but on the VM it is the ground truth the limb version has to
      // reproduce.
      int nativeFnv1a(List<int> bytes) {
        var hash = 0xcbf29ce4 * 0x100000000 + 0x84222325;
        const prime = 0x100000001b3;
        for (final b in bytes) {
          hash = hash ^ b;
          hash = hash * prime;
        }
        return hash;
      }

      for (final text in <String>[
        '',
        'a',
        'hello world',
        'the quick brown fox jumps over the lazy dog',
        'ünïcödé 😀',
        'x' * 257,
      ]) {
        final digest = contentDigest(text);
        final native = nativeFnv1a(_utf8(normalize(text)));
        expect(digest.hi * 0x100000000 + digest.lo, native,
            reason: 'FNV-1a-64 of "$text"');
      }
    });

    test('the packed int form still matches on the VM', () {
      expect(intsAreDoubles, isFalse,
          reason: 'the VM suite must not be running as a JS target');
      for (final text in vectors.keys) {
        final packed = contentHash(text);
        expect(u64Hex(highHalfOf(packed), lowHalfOf(packed)), vectors[text]);
      }
    });
  });

  group('big-endian halves are the bytes the 64-bit accessors wrote', () {
    // What the msgpack packer now does instead of `setUint64` / `setInt64`,
    // which dart2js leaves unimplemented. Both accessors exist on the VM, so
    // this is a byte-for-byte equivalence rather than an assertion about
    // intent — and it covers the signed branch, which no conforming frame can
    // reach through a public entry point (every wire integer is non-negative).
    test('for every value, signed and unsigned', () {
      final halves = ByteData(8);
      final native = ByteData(8);
      for (final value in corpus) {
        halves.setUint32(0, highHalfOf(value));
        halves.setUint32(4, lowHalfOf(value));

        native.setInt64(0, value);
        expect(halves.buffer.asUint8List(), native.buffer.asUint8List(),
            reason: 'setInt64($value)');

        if (value >= 0) {
          native.setUint64(0, value);
          expect(halves.buffer.asUint8List(), native.buffer.asUint8List(),
              reason: 'setUint64($value)');
        }
      }
    });
  });

  group('exact-range packing', () {
    test('u64ToInt refuses above 2^53 - 1 on a double-int runtime', () {
      // The predicate the refusal is built on, exercised for BOTH platforms —
      // the VM cannot reach the guarded branch of `u64ToInt` itself.
      expect(
        u64ExceedsExactIntRange(maxExactHighHalf, 0xFFFFFFFF,
            intsAreDoubles: true),
        isFalse,
        reason: 'exactly 2^53 - 1 is representable',
      );
      expect(
        u64ExceedsExactIntRange(maxExactHighHalf + 1, 0, intsAreDoubles: true),
        isTrue,
      );
      expect(
        u64ExceedsExactIntRange(0xFFFFFFFF, 0xFFFFFFFF, intsAreDoubles: false),
        isFalse,
        reason: 'the VM carries the full 64-bit range and must keep doing so',
      );
    });

    test('u64ToInt packs the full range on the VM', () {
      for (final value in corpus) {
        expect(u64ToInt(highHalfOf(value), lowHalfOf(value)), value);
      }
    });

    test('u64FoldToExactRange lands in [0, 2^53 - 1] for every input', () {
      for (final value in corpus) {
        final folded = u64FoldToExactRange(highHalfOf(value), lowHalfOf(value));
        expect(folded, inInclusiveRange(0, maxExactInt), reason: '$value');
      }
      // And it is a fold, not a hash: the low 53 bits pass through unchanged.
      expect(u64FoldToExactRange(0, 12345), 12345);
      expect(u64FoldToExactRange(0x1FFFFF, 0xFFFFFFFF), maxExactInt);
    });
  });
}

/// UTF-8 of [s] over Unicode scalars — the same encoding `stable_id.dart` uses.
List<int> _utf8(String s) {
  final out = <int>[];
  for (final cp in s.runes) {
    if (cp < 0x80) {
      out.add(cp);
    } else if (cp < 0x800) {
      out.addAll(<int>[0xC0 | (cp >> 6), 0x80 | (cp & 0x3F)]);
    } else if (cp < 0x10000) {
      out.addAll(<int>[
        0xE0 | (cp >> 12),
        0x80 | ((cp >> 6) & 0x3F),
        0x80 | (cp & 0x3F),
      ]);
    } else {
      out.addAll(<int>[
        0xF0 | (cp >> 18),
        0x80 | ((cp >> 12) & 0x3F),
        0x80 | ((cp >> 6) & 0x3F),
        0x80 | (cp & 0x3F),
      ]);
    }
  }
  return Uint8List.fromList(out);
}
