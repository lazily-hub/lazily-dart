import 'dart:convert';

import 'package:lazily/stdlib.dart';

/// Compile-only browser entry point for the portable stdlib surface.
///
/// Keeping this entry point free of VM-only imports makes `dart compile js` a
/// direct guard that the production logical-clock and Future adapters remain
/// usable by browser consumers.
Future<void> main() async {
  final timer = Timer(maxUint64 - BigInt.one, BigInt.one);
  final encoded = jsonEncode(timer.initial.toJson());
  if (!encoded.contains('"${maxUint64.toString()}"')) {
    throw StateError('uint64 JSON projection lost browser precision');
  }
  await timer.wait((deadline) => deadline);

  final timeout = Timeout<String>(BigInt.zero, BigInt.from(2));
  await timeout.pollFuture(
    BigInt.one,
    () => const TimeoutOperation.completed('ok'),
    () => TimeoutCancellation.pending,
  );

  final barrier = RevisionBarrier(
    revision: BigInt.zero,
    requiredRevision: BigInt.one,
  );
  await barrier.observeFuture(
    BigInt.zero,
    false,
    () => TimeoutCancellation.pending,
  );
}
