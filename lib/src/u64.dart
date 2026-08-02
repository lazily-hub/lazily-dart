/// 64-bit unsigned arithmetic carried as two 32-bit halves
/// (`#lzdartwebcompile`).
///
/// Dart's `int` is 64-bit two's complement on the VM and an IEEE-754 double
/// everywhere else, and the difference is not merely a precision one: dart2js
/// REFUSES an integer literal it cannot represent, so `0xcbf29ce484222325`
/// makes its whole library unbuildable for the web. Every 64-bit constant and
/// every 64-bit operation in this binding therefore lives here, as halves.
///
/// The rule that makes this exact rather than approximately right: no
/// intermediate may reach 2^53. Products are formed from 16-bit limbs, so the
/// widest partial sum is under 2^34; carries are propagated with `~/` and `%`
/// rather than shifts and masks, whose behaviour above 2^32 differs between the
/// two representations of `int`. The result is that the VM and a JavaScript
/// target agree bit for bit, which is what lets a hash be one value with one
/// definition instead of one per runtime.
///
/// [U64] is MUTABLE and its operations are in place. That is deliberate: these
/// run per byte inside hash loops, and an immutable value type would allocate
/// on every step — the cost that made the [BigInt] spelling this replaced
/// 10-50x slower than fixed-width `int` math.
library;

/// A 64-bit unsigned value held as two 32-bit halves.
class U64 {
  /// A value from its high and low 32-bit halves.
  U64(this.hi, this.lo);

  /// Zero.
  U64.zero()
      : hi = 0,
        lo = 0;

  /// A copy of [other].
  U64.from(U64 other)
      : hi = other.hi,
        lo = other.lo;

  /// High 32 bits.
  int hi;

  /// Low 32 bits.
  int lo;

  /// Overwrite with [other]'s halves.
  void setFrom(U64 other) {
    hi = other.hi;
    lo = other.lo;
  }

  /// `this += other`, wrapping at 2^64.
  void add(int otherHi, int otherLo) {
    final sumLo = lo + otherLo;
    lo = sumLo % 0x100000000;
    hi = (hi + otherHi + sumLo ~/ 0x100000000) % 0x100000000;
  }

  /// `this ^= other`.
  ///
  /// Each half is below 2^32, so JS's 32-bit bitwise semantics and the VM's
  /// 64-bit ones agree on the halves even though they would not agree on the
  /// whole.
  void xor(int otherHi, int otherLo) {
    hi ^= otherHi;
    lo ^= otherLo;
  }

  /// `this ^= this >>> bits`, for `0 < bits < 64` — the mixing step of a
  /// SplitMix-family generator.
  void xorShiftRight(int bits) {
    final shifted = shiftedRight(bits);
    xor(shifted.hi, shifted.lo);
  }

  /// `this >>> bits` as a new value, for `0 <= bits < 64`. Logical (unsigned)
  /// shift: the value is unsigned, so there is no sign to extend.
  U64 shiftedRight(int bits) {
    if (bits == 0) return U64.from(this);
    if (bits >= 32) {
      final n = bits - 32;
      return U64(0, n == 0 ? hi : hi ~/ _pow2(n));
    }
    final divisor = _pow2(bits);
    return U64(
      hi ~/ divisor,
      (hi % divisor) * _pow2(32 - bits) + lo ~/ divisor,
    );
  }

  /// `this *= other`, wrapping at 2^64.
  ///
  /// Schoolbook product over four 16-bit limbs per operand. Limbs above 2^64
  /// are dropped, which is what the `& 0xFFFFFFFFFFFFFFFF` of the fixed-width
  /// spelling did.
  void multiply(int otherHi, int otherLo) {
    final a0 = lo % 0x10000;
    final a1 = lo ~/ 0x10000;
    final a2 = hi % 0x10000;
    final a3 = hi ~/ 0x10000;
    final b0 = otherLo % 0x10000;
    final b1 = otherLo ~/ 0x10000;
    final b2 = otherHi % 0x10000;
    final b3 = otherHi ~/ 0x10000;

    var t0 = a0 * b0;
    var t1 = a0 * b1 + a1 * b0;
    var t2 = a0 * b2 + a1 * b1 + a2 * b0;
    var t3 = a0 * b3 + a1 * b2 + a2 * b1 + a3 * b0;

    t1 += t0 ~/ 0x10000;
    t2 += t1 ~/ 0x10000;
    t3 += t2 ~/ 0x10000;

    lo = (t1 % 0x10000) * 0x10000 + t0 % 0x10000;
    hi = (t3 % 0x10000) * 0x10000 + t2 % 0x10000;
  }

  /// The value as a `double`, for the `[0, 1)` normalization a generator ends
  /// with. Exact only below 2^53 — call on a value already shifted into that
  /// range.
  double toDouble() => hi * 4294967296.0 + lo;

  @override
  String toString() => '0x${u64Hex(hi, lo)}';
}

/// `2^n` for `0 <= n <= 32`, without a shift whose behaviour differs by target.
int _pow2(int n) => _powersOfTwo[n];

const List<int> _powersOfTwo = <int>[
  1, 2, 4, 8, 16, 32, 64, 128, //
  256, 512, 1024, 2048, 4096, 8192, 16384, 32768,
  65536, 131072, 262144, 524288, 1048576, 2097152, 4194304, 8388608,
  16777216, 33554432, 67108864, 134217728, 268435456, 536870912, 1073741824,
  2147483648, 4294967296,
];

/// The low 32 bits of [value]'s two's-complement representation.
///
/// Dart's `%` is the Euclidean remainder — non-negative for a negative left
/// operand on every target — so this is the unsigned low word for negatives as
/// well, without a shift or mask whose width differs between the VM and JS.
int lowHalfOf(int value) => value % 0x100000000;

/// The high 32 bits of [value]'s two's-complement representation, unsigned.
///
/// `(value - lowHalfOf(value))` is an exact multiple of 2^32 on both
/// representations of `int` — no rounding to undo — so dividing it out and
/// reducing recovers the high word for negative values too. The bitwise
/// spelling (`value >>> 32`) would be correct on the VM and wrong on a JS
/// target, which is the whole class of bug this library exists to remove.
int highHalfOf(int value) =>
    ((value - lowHalfOf(value)) ~/ 0x100000000) % 0x100000000;

/// 16-char zero-padded lowercase hex of a `u64` carried as two 32-bit halves.
///
/// Each half is non-negative and below 2^32, so [int.toRadixString] never emits
/// a sign and the result is identical on every target — which is what makes the
/// hex form, and not a packed `int`, the portable spelling of a 64-bit identity.
String u64Hex(int hi, int lo) => '${hi.toRadixString(16).padLeft(8, '0')}'
    '${lo.toRadixString(16).padLeft(8, '0')}';
