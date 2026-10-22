import 'dart:io';

import 'package:lazily/async_context.dart';
import 'package:lazily/core.dart';

Never _fail(String message) {
  stderr.writeln('stale-handle mutation probe: $message');
  exit(1);
}

void _syncProbe() {
  final ctx = Context();
  final stale = Source<int>(ctx, 1);
  final staleIdentity = ctx.nodeIdentity(stale);
  ctx.disposeNode(stale);

  final successor = Source<int>(ctx, 2);
  final successorIdentity = ctx.nodeIdentity(successor);
  if (staleIdentity.slot != successorIdentity.slot ||
      staleIdentity.generation == successorIdentity.generation) {
    _fail('sync probe did not establish real allocator-slot reuse');
  }

  ctx.disposeNode(stale);
  successor.value = 3;
  if (successor.value != 3 || ctx.isNodeDisposed(successor)) {
    _fail('sync stale handle removed its same-kind successor');
  }
}

Future<void> _asyncProbe() async {
  final ctx = AsyncContext();
  final stale = ctx.cell<int>(1);
  final staleIdentity = ctx.nodeIdentity(stale);
  await ctx.disposeNode(stale);

  final successor = ctx.cell<int>(2);
  final successorIdentity = ctx.nodeIdentity(successor);
  if (staleIdentity.slot != successorIdentity.slot ||
      staleIdentity.generation == successorIdentity.generation) {
    _fail('async probe did not establish real allocator-slot reuse');
  }

  await ctx.disposeNode(stale);
  successor.set(3);
  if (successor.get() != 3 || ctx.isNodeDisposed(successor)) {
    _fail('async stale handle removed its same-kind successor');
  }
  await ctx.disposeAsync();
}

Future<void> main(List<String> args) async {
  final only = args.singleOrNull;
  if (only == null || only == '--sync-only') _syncProbe();
  if (only == null || only == '--async-only') await _asyncProbe();
  if (only != null && only != '--sync-only' && only != '--async-only') {
    _fail('unknown argument $only');
  }
}
