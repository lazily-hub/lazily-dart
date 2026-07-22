/// `computedRippleWhen` (#lzcellkernel) — a guarded computed with an explicit,
/// PURE change predicate (`true` = propagate). Mirrors lazily-rs
/// `tests/computed_ripple_when.rs`. Covers the two motivating shapes: a custom
/// significance policy (a bucket proxy), and "propagate every N" where the
/// increment evidence lives in the value (so the predicate stays pure).
/// `computed(f)` == `computedRippleWhen(f, !=)`; the pass-through slot always
/// propagates.
import 'package:test/test.dart';
import 'package:lazily/lazily.dart';

void main() {
  group('computedRippleWhen', () {
    test('custom significance propagates only on proxy (bucket) change', () {
      final ctx = Context();
      final input = Source<int>(ctx, 0);

      // Derived value carries a `bucket` proxy; propagate only when the bucket
      // changes, ignoring the raw payload.
      final derived = computedRippleWhen<(int, int)>(
        ctx,
        (c) {
          final v = input.value;
          return (v, v ~/ 10); // (payload, bucket)
        },
        (old, neu) => old.$2 != neu.$2, // propagate when bucket changed
      );

      var recomputes = 0;
      final observer = computed<int>(ctx, (c) {
        recomputes += 1;
        return derived.value.$1;
      });

      expect(observer.value, 0);
      final base = recomputes;

      // Same bucket (0..9): dependent stays cached.
      input.value = 3;
      expect(observer.value, 0, reason: 'suppressed: proxy bucket unchanged');
      expect(recomputes, base, reason: 'no dependent recompute within a bucket');

      // Crossing a bucket boundary propagates.
      input.value = 12;
      expect(observer.value, 12, reason: 'propagated: bucket changed');
      expect(recomputes, base + 1);
    });

    test('propagate every N via a value-carried counter', () {
      final ctx = Context();
      final input = Source<int>(ctx, 0);

      // "Propagate every 3rd increment" — evidence (the counter) is IN the
      // value, so the predicate is a pure function of (old, new): propagate only
      // when the count crosses a size-3 window boundary.
      final sampled = computedRippleWhen<int>(
        ctx,
        (c) => input.value,
        (old, neu) => neu ~/ 3 != old ~/ 3,
      );

      var seen = 0;
      final observer = computed<int>(ctx, (c) {
        seen += 1;
        return sampled.value;
      });

      expect(observer.value, 0);
      final base = seen;

      // 0 -> 1 -> 2 stay in window [0,3): suppressed.
      input.value = 1;
      input.value = 2;
      expect(observer.value, 0);
      expect(seen, base, reason: 'window not crossed yet');

      // 3 crosses into [3,6): propagate.
      input.value = 3;
      expect(observer.value, 3);
      expect(seen, base + 1);
    });

    test('computed(f) behaves as computedRippleWhen(f, !=)', () {
      final ctx = Context();
      final input = Source<int>(ctx, 0);

      int min1(int v) => v < 1 ? v : 1;
      final viaComputed = computed<int>(ctx, (c) => min1(input.value));
      final viaWhen = computedRippleWhen<int>(
        ctx,
        (c) => min1(input.value),
        (o, n) => o != n,
      );

      var a = 0;
      var b = 0;
      final obsA = computed<int>(ctx, (c) {
        a += 1;
        return viaComputed.value;
      });
      final obsB = computed<int>(ctx, (c) {
        b += 1;
        return viaWhen.value;
      });
      expect(obsA.value, 0);
      expect(obsB.value, 0);
      final baseA = a;
      final baseB = b;

      // 0 -> 5 both clamp to 1: both guards suppress identically.
      input.value = 5;
      expect(obsA.value, 1);
      expect(obsB.value, 1);
      expect(a, baseA + 1);
      expect(b, baseB + 1);

      // 5 -> 9 both stay 1: both suppress the dependent.
      input.value = 9;
      expect(obsA.value, 1);
      expect(obsB.value, 1);
      expect(a, baseA + 1, reason: 'computed suppressed equal recompute');
      expect(b, baseB + 1,
          reason: 'computedRippleWhen(!=) matches computed');
    });

    test('pass-through always propagates (changed == true)', () {
      final ctx = Context();
      final input = Source<int>(ctx, 0);

      // Always-true predicate installs no suppression: even an equal recompute
      // propagates — the `slot(f)` pass-through identity.
      final passthrough = computedRippleWhen<int>(
        ctx,
        (c) {
          input.value; // depend on input, but always yield the same value
          return 0;
        },
        (_, __) => true,
      );

      var recomputes = 0;
      final observer = computed<int>(ctx, (c) {
        recomputes += 1;
        return passthrough.value;
      });

      expect(observer.value, 0);
      final base = recomputes;

      // Value stays 0, but the pass-through has no suppression, so the dependent
      // re-fires.
      input.value = 5;
      expect(observer.value, 0);
      expect(recomputes, greaterThan(base),
          reason: 'pass-through propagates even when the value is unchanged');
    });
  });
}
