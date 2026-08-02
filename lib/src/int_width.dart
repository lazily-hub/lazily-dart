/// The runtime integer-width policy (`#lzdartintwidth`, `#lzdartwebcompile`).
///
/// Dart's `int` is 64-bit two's complement on the VM and an IEEE-754 double on
/// every JavaScript target. Values above 2^53 - 1 survive the first exactly and
/// the second not at all, and the loss is SILENT: `jsonDecode` rounds
/// 9007199254740993 to 9007199254740992 without an error, so a corrupted node id
/// decodes cleanly and is undetectable downstream.
///
/// The policy this file states is therefore platform-based rather than
/// magnitude-based, and it is *refuse, never round*. A magnitude-only rule would
/// either corrupt on web (too loose) or reject frames the VM carries correctly
/// (too strict); only the split does neither.
///
/// This lives in its own library, rather than inside `ipc.dart` where it was
/// first written, because `stable_id.dart` needs the same predicate and belongs
/// to the reactive core — importing the whole IPC surface to reach one boolean
/// would drag the wire types into every consumer of `package:lazily/lazily.dart`.
library;

/// True when this runtime represents `int` as an IEEE-754 double — every
/// JavaScript target, and nothing else. On the VM `1` and `1.0` are distinct
/// objects; compiled to JS they are the same double (#lzdartintwidth).
const bool intsAreDoubles = identical(1, 1.0);

/// Largest integer a double represents exactly: 2^53 - 1.
const int maxExactInt = 9007199254740991;

/// High 32 bits of [maxExactInt]. A `u64` carried as two halves is outside the
/// exact range exactly when its high half exceeds this, since the low half's
/// full 32-bit range is already included in 2^53 - 1 == `0x001FFFFF_FFFFFFFF`.
const int maxExactHighHalf = 0x001FFFFF;

/// Whether [value] is outside the range this runtime represents exactly.
///
/// [intsAreDoubles] is a parameter rather than a read of the top-level constant
/// so the POLICY is executable. On the VM that constant is `false` and the
/// guarded branch is compiled out, so a test running there cannot reach it —
/// and a rule no test can reach is prose, which is the failure mode this
/// codebase's conformance ladder exists to remove. Callers pass the constant;
/// tests pass both values.
bool exceedsExactIntRange(int value, {required bool intsAreDoubles}) =>
    intsAreDoubles && value > maxExactInt;

/// [exceedsExactIntRange] for a `u64` carried as two 32-bit halves.
///
/// A full-width 64-bit value cannot be *formed* on a JS target in order to be
/// tested, so the split-half form is the only way to ask the question there
/// without first committing the rounding the guard exists to prevent. Same
/// parameterized-predicate shape, same reason.
bool u64ExceedsExactIntRange(
  int hi,
  int lo, {
  required bool intsAreDoubles,
}) =>
    intsAreDoubles && hi > maxExactHighHalf;

/// Pack a `u64` carried as two 32-bit halves into an `int`, refusing rather
/// than rounding when this runtime cannot represent it.
///
/// Multiplication rather than `hi << 32`: on the VM `*` wraps at 64 bits, so
/// the product carries the full unsigned bit pattern in a signed `int` exactly
/// as the shift would, and on web — where the guard above has already confined
/// `hi` to 21 bits — the product stays under 2^53 and is exact. One expression,
/// correct on both, instead of a platform branch no test can reach.
int u64ToInt(int hi, int lo) {
  if (u64ExceedsExactIntRange(hi, lo, intsAreDoubles: intsAreDoubles)) {
    throw UnsupportedError(
      'a 64-bit value (0x${hi.toRadixString(16).padLeft(8, '0')}'
      '${lo.toRadixString(16).padLeft(8, '0')}) is outside the '
      'exactly-representable integer range on this runtime (max $maxExactInt); '
      'a JavaScript target cannot carry it without silently rounding',
    );
  }
  return hi * 0x100000000 + lo;
}

/// Fold a `u64` carried as two 32-bit halves into the non-negative range EVERY
/// Dart target represents exactly: the low 53 bits.
///
/// For a value that only has to be self-consistent — an internal checksum, not
/// a cross-language identity — folding is honest where [u64ToInt] would have to
/// refuse. 53 bits rather than the VM's 63 because a checksum that means a
/// different thing on web than on the VM is a checksum with two definitions.
int u64FoldToExactRange(int hi, int lo) => (hi % 0x200000) * 0x100000000 + lo;
