/// FNV-1a-64, computed so the result is identical on every Dart target
/// (`#lzdartwebcompile`).
///
/// The obvious spelling — `var hash = 0xcbf29ce484222325; hash = (hash * prime)
/// & 0xFFFFFFFFFFFFFFFF;` — does not merely produce the wrong answer under
/// `dart compile js`; it does not COMPILE. dart2js rejects an integer literal it
/// cannot represent exactly, so every library reachable from a browser entry
/// point that spelled the FNV constants that way was unbuildable for the web,
/// which is why lazily-dart's IPC surface had no browser gate at all.
///
/// The arithmetic lives in [U64], which every 64-bit operation in this binding
/// shares. One multiply, not one per hash: two implementations of the same
/// 64-bit product is a drift surface, and on the VM only one of them would ever
/// be reachable by a test.
library;

import 'u64.dart';

/// FNV-1a-64 offset basis `0xcbf29ce484222325`, high half.
const int fnvOffsetBasisHigh = 0xcbf29ce4;

/// FNV-1a-64 offset basis `0xcbf29ce484222325`, low half.
const int fnvOffsetBasisLow = 0x84222325;

/// FNV-1a-64 prime `0x00000100000001B3`, high half.
const int fnvPrimeHigh = 0x00000100;

/// FNV-1a-64 prime `0x00000100000001B3`, low half.
const int fnvPrimeLow = 0x000001b3;

/// An FNV-1a-64 accumulator, held as two 32-bit halves.
///
/// Feed bytes with [addByte] / [addBytes]; read the digest as [hi] and [lo], or
/// through `u64Hex(digest.hi, digest.lo)` for the wire form.
class Fnv1a64 extends U64 {
  /// A fresh accumulator seeded with the offset basis.
  Fnv1a64() : super(fnvOffsetBasisHigh, fnvOffsetBasisLow);

  /// Mix one byte: `hash ^= byte; hash *= prime`, wrapping at 2^64.
  ///
  /// The xor lands entirely in the low half and both operands are below 2^32,
  /// so it is exact under JS's 32-bit bitwise semantics as well as the VM's.
  void addByte(int byte) {
    lo ^= byte & 0xFF;
    multiply(fnvPrimeHigh, fnvPrimeLow);
  }

  /// Mix every byte of [bytes], low index first.
  void addBytes(List<int> bytes) {
    for (var i = 0; i < bytes.length; i++) {
      addByte(bytes[i]);
    }
  }
}
