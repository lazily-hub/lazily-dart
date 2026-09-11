/// Replay-equivalence proof for a reactive graph (`#lzreplaydart`).
///
/// `lazily-spec/docs/replay-safety.md` draws the line: the pure cores are
/// replay-safe, the reactive layer's *command ordering* is not, and cell
/// **values** are replay-stable either way. This library is the other half of
/// that statement — it makes the stable half **provable** instead of asserted:
///
///     Given the same [ReplayLog], a rebuilt graph observes the same values at
///     every checkpoint. Any deviation is a defect in the graph, not a
///     tolerance — the harness fails, loudly, at the first event where it
///     appears.
///
/// The contract is `lazily-spec/docs/replay-equivalence.md`. Its discipline is
/// taken from `tsift`, whose cached excerpts are trustworthy because every one
/// records a body hash and *revalidates it against the source bytes* before the
/// excerpt is returned: a stale body deterministically suppresses the cached
/// answer rather than returning a plausible-looking one. Here the event log is
/// the source bytes.
///
/// Three obligations follow, and they are what
/// `lazily-spec/conformance/replay/*.json` checks:
///
///  1. **The fingerprint is bound to the log that produced it.** [ReplayLog]
///     carries a digest over its canonical bytes, [ReplayFingerprint] records
///     it, and [ReplayHarness.verify] revalidates that binding *before* it
///     compares any observed value. A fingerprint recorded against a different
///     log throws [ReplayLogMismatchError] and is never compared — two
///     different logs can settle to the same final values (`[+1,+2,+3]` and
///     `[+3,+2,+1]` both sum to 6), so a value-only comparison would *pass* and
///     certify nothing about the log in front of it. [ReplayHarness.check], the
///     non-raising reporting form, refuses a stale fingerprint too: an
///     unanswerable question is not a report.
///  2. **Divergence is localized.** Every event is checkpointed by default, and
///     [ReplayDivergenceError.first] names the *first* diverging checkpoint's
///     sequence number and the label of the cell that differed. A fingerprint
///     covering only the final state says the graph is wrong but not where.
///     [ReplayHarness.stride] offers a coarser sampling for long logs and is
///     itself part of the fingerprint: a fingerprint recorded at one stride is
///     refused against a harness sampling at another
///     ([ReplayStrideMismatchError]), because equal log digest plus equal
///     stride is what makes two checkpoint sequences comparable at all.
///  3. **The observation encoding is canonical, or it fails.** [canonicalBytes]
///     is type-tagged and length-framed, mapping and set members are ordered by
///     their own encoded bytes, and a value with no defined encoding throws
///     [ReplayEncodingError] rather than falling back on
///     [Object.toString] — Dart's default rendering is `Instance of 'Foo'` for
///     every instance of a class alike, so such a fallback would fold two
///     genuinely different observations into one value while looking like it
///     worked.
///
/// ## What this covers, and what it cannot
///
/// Checkpoint **values** only. Sibling effect order is deliberately free across
/// the family (`replay-safety.md` clause 3), so the *sequence of effects a
/// replay fires* is not a stable thing to fingerprint and this library does not
/// ask you to. The obligation is narrower than "the replay is identical" and
/// stronger than "the values converge": at every checkpoint the same labels
/// carry the same values, and the first place that stops being true is named.
///
/// ## The digest
///
/// A binding **may** choose its own hash and its own byte layout — fingerprints
/// are pinned next to a test in one language and are never exchanged between
/// bindings, so there is nothing to agree on at the byte level. What every
/// binding must agree on is the equality *classes*, which [canonicalBytes]
/// owns.
///
/// This binding therefore uses no hash at all: [canonicalDigest] is the base64
/// of the **exact** canonical bytes. `package:lazily` has no runtime
/// dependencies and the Dart SDK ships no cryptographic hash (`package:crypto`
/// is a pub package, not a `dart:` library), and buying a dependency for every
/// consumer of this package to obtain collision resistance we can have for free
/// is a bad trade: identity is the degenerate strongest digest, with a
/// collision probability of exactly zero. The cost is size, which matters only
/// for a fingerprint pinned next to a test over a long log. Swapping in a hash
/// is a one-function change and breaks nothing outside this file, because no
/// fingerprint crosses a binding boundary.
///
/// ## Example
///
/// ```dart
/// final class Counter implements ReplayGraph {
///   int total = 0;
///
///   @override
///   void apply(ReplayEvent event) => total += event.payload as int;
///
///   @override
///   Map<String, Object?> observe() => {'total': total};
/// }
///
/// final log = ReplayLog.fromRecords([('add', 1), ('add', 2), ('add', 3)]);
/// final harness = ReplayHarness(Counter.new);
///
/// final fingerprint = harness.record(log); // pin it, or commit `toWire()`
/// harness.verify(log, fingerprint); // throws if the replay diverges
/// harness.prove(log); // record + re-replay in one call
/// ```
///
/// A real log is usually not hand-built. `DurableOutbox.replayFrom` in
/// `package:lazily/reliable_sync.dart` already *is* a replay source — the one a
/// reconnect drains — so mapping its retained frames to [ReplayEvent]s with the
/// outbox epoch as the `seq` is what turns them into a fingerprinted log.
/// Epochs are kept rather than renumbered on purpose: sequence numbers must
/// strictly increase but may be non-contiguous, and renumbering an
/// ack-truncated outbox would hide the truncated prefix that the log digest
/// otherwise catches.
library;

import 'dart:convert';
import 'dart:typed_data';

/// The checkpoint sequence number for the state before any event was applied.
const int replayInitialSeq = -1;

/// Schema version of [ReplayFingerprint.toWire].
const int _wireSchemaVersion = 1;

/// Depth beyond which [canonicalBytes] refuses to descend.
///
/// JSON cannot cycle but a Dart object graph can — a list that contains itself
/// encodes forever. A bounded refusal is a [ReplayEncodingError], which is the
/// same answer this encoding gives every other value it cannot represent.
const int _encodingDepthLimit = 64;

const int _colon = 0x3a;

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// A replay-equivalence proof could not be completed as stated.
///
/// Sealed, so a driver can `switch` over every way a proof fails and the
/// compiler checks the arms. Each subtype is a *different fault* with a
/// different remedy, which is why they are distinct types rather than one error
/// carrying a message a caller would have to match on.
sealed class ReplayProofError implements Exception {
  /// Creates an error described by [message].
  const ReplayProofError(this.message);

  /// Human-readable description of the fault.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// A value has no canonical byte encoding, so it cannot be fingerprinted.
///
/// Thrown instead of falling back on [Object.toString]. Dart's default
/// rendering is `Instance of 'Foo'`, which is *identical* for every instance of
/// a class: a fallback would silently fold two genuinely different observations
/// into one value and report a replay as equivalent when it is not — the exact
/// failure this library exists to make impossible.
final class ReplayEncodingError extends ReplayProofError {
  /// Creates an encoding error described by [message].
  const ReplayEncodingError(super.message);
}

/// The fingerprint was recorded against a different event log.
///
/// The tsift rule: revalidate the recorded digest against the source bytes and
/// deterministically suppress the cached answer when they disagree. A stale
/// fingerprint is never compared, so it can neither pass by coincidence nor be
/// misreported as a value divergence.
final class ReplayLogMismatchError extends ReplayProofError {
  /// Creates a log-binding mismatch between two log digests.
  ReplayLogMismatchError({
    required this.expectedDigest,
    required this.actualDigest,
  }) : super('fingerprint was recorded against a different event log '
            '(fingerprint logDigest=${_abbreviate(expectedDigest)}, replayed '
            'log digest=${_abbreviate(actualDigest)}); re-record the '
            'fingerprint against this log');

  /// The log digest the fingerprint carries.
  final String expectedDigest;

  /// The digest of the log that was actually replayed.
  final String actualDigest;
}

/// The fingerprint was recorded at a different checkpoint stride.
///
/// Separate from [ReplayLogMismatchError] because it is a different fault: the
/// log is the right one, but the two checkpoint sequences were never
/// comparable.
final class ReplayStrideMismatchError extends ReplayProofError {
  /// Creates a stride mismatch between a fingerprint and a harness.
  ReplayStrideMismatchError({
    required this.expectedStride,
    required this.actualStride,
  }) : super('fingerprint was recorded at stride $expectedStride but this '
            'harness samples at stride $actualStride; re-record it');

  /// The stride the fingerprint was sampled at.
  final int expectedStride;

  /// The stride this harness samples at.
  final int actualStride;
}

/// A replayed graph observed a different value than the fingerprint.
final class ReplayDivergenceError extends ReplayProofError {
  /// Creates a divergence error over a non-empty, first-diverging-first list.
  ReplayDivergenceError(Iterable<ReplayDivergence> divergences)
      : divergences = List<ReplayDivergence>.unmodifiable(divergences),
        super(_describe(divergences));

  static String _describe(Iterable<ReplayDivergence> divergences) {
    final list = divergences.toList(growable: false);
    if (list.isEmpty) {
      throw ArgumentError.value(
        divergences,
        'divergences',
        'ReplayDivergenceError requires at least one divergence',
      );
    }
    final extra = list.length - 1;
    final tail = extra > 0 ? ' (+$extra more)' : '';
    return 'replay diverged from the fingerprint: ${list.first}$tail';
  }

  /// Every divergence found at the first diverging checkpoint.
  final List<ReplayDivergence> divergences;

  /// The earliest divergence, which is the one worth reading.
  ReplayDivergence get first => divergences.first;
}

/// The replay produced a different NUMBER of checkpoints than the fingerprint.
///
/// Reached only once the log digest and the stride already agree, so it cannot
/// come from sampling: `apply` or `observe` changed how many checkpoints the
/// same log yields. Distinct from [ReplayDivergenceError] because no cell
/// diverged — there is no first diverging checkpoint to name.
final class ReplayCheckpointCountError extends ReplayProofError {
  /// Creates a checkpoint-count mismatch.
  ReplayCheckpointCountError({
    required this.expectedCount,
    required this.actualCount,
  }) : super('fingerprint has $expectedCount checkpoints but the replay '
            'produced $actualCount for the same log and stride');

  /// How many checkpoints the fingerprint carries.
  final int expectedCount;

  /// How many checkpoints the replay produced.
  final int actualCount;
}

String _abbreviate(String digest) =>
    digest.length <= 24 ? digest : '${digest.substring(0, 24)}…';

// ---------------------------------------------------------------------------
// Canonical encoding
// ---------------------------------------------------------------------------

/// A type that supplies its own canonical form for [canonicalBytes].
///
/// Opt-in, and deliberately not a fallback: a class that does not implement
/// this has *no* encoding and fails loudly. Return a value built only from
/// values [canonicalBytes] already defines, and include something that
/// discriminates the type if two different classes could otherwise produce the
/// same form.
abstract interface class ReplayEncodable {
  /// The value that stands for this object when it is fingerprinted.
  Object? get replayCanonicalForm;
}

/// Encode [value] to type-tagged, order-stable, length-framed bytes.
///
/// Every frame is `<tag><decimal body length>:<body>`, so no concatenation of
/// members can be confused for another — `['a', 'bc']` and `['ab', 'c']` are
/// different values, which is the row of the contract that is easiest to get
/// wrong. Tags separate the types, so `1`, `'1'`, `1.0`, `true` and the byte
/// string `1` are five different values.
///
/// Mapping entries and set members are sorted by their own encoded bytes, so
/// neither insertion order nor iteration order is part of the value. Sequence
/// order *is*.
///
/// | Dart value | Tag |
/// |---|---|
/// | `null` | `n` |
/// | `bool` | `b` |
/// | `int`, `BigInt` | `i` |
/// | `double` | `f`, the 8 IEEE-754 bytes, so `-0.0` and NaN payloads stay distinct |
/// | `String` | `s`, UTF-8 |
/// | `Uint8List` | `y` |
/// | [ReplayEncodable] | `v` over its own form |
/// | `Enum` | `e` |
/// | `Map` | `m` |
/// | `Set` | `t` |
/// | other `Iterable` | `l` |
///
/// `Uint8List` is checked before `Iterable` on purpose: it *is* a `List<int>`,
/// and a byte string is not the sequence of its byte values.
///
/// Anything else throws [ReplayEncodingError] naming the path that reached it.
Uint8List canonicalBytes(Object? value) => _encode(value, r'$', 0);

/// The base64 of [canonicalBytes] of [value].
///
/// Not a hash: see the library doc for why this binding keeps the exact bytes.
/// The property relied on is that two values digest equal exactly when they are
/// the same value, which identity has unconditionally.
String canonicalDigest(Object? value) => base64.encode(canonicalBytes(value));

Uint8List _frame(int tag, List<int> body) {
  final length = ascii.encode(body.length.toString());
  final out = Uint8List(1 + length.length + 1 + body.length);
  out[0] = tag;
  out.setRange(1, 1 + length.length, length);
  out[1 + length.length] = _colon;
  out.setRange(2 + length.length, out.length, body);
  return out;
}

Uint8List _concat(List<Uint8List> parts) {
  var total = 0;
  for (final part in parts) {
    total += part.length;
  }
  final out = Uint8List(total);
  var offset = 0;
  for (final part in parts) {
    out.setRange(offset, offset + part.length, part);
    offset += part.length;
  }
  return out;
}

/// Unsigned lexicographic byte order — the order Python's `bytes` and Rust's
/// `[u8]` already sort in, so a binding porting this file sorts the same way.
int _compareBytes(Uint8List left, Uint8List right) {
  final shared = left.length < right.length ? left.length : right.length;
  for (var i = 0; i < shared; i++) {
    if (left[i] != right[i]) return left[i] - right[i];
  }
  return left.length - right.length;
}

Uint8List _float64Bytes(double value) {
  final data = ByteData(8)..setFloat64(0, value);
  return data.buffer.asUint8List();
}

Uint8List _encode(Object? value, String path, int depth) {
  if (depth > _encodingDepthLimit) {
    throw ReplayEncodingError(
      '$path: canonical encoding stopped at depth $_encodingDepthLimit. A '
      'self-referential value has no canonical bytes; observe a finite value.',
    );
  }
  if (value == null) return _frame(0x6e, const <int>[]); // n
  if (value is bool) {
    return _frame(0x62, <int>[value ? 0x31 : 0x30]); // b
  }
  if (value is int) return _frame(0x69, ascii.encode(value.toString())); // i
  if (value is BigInt) {
    // The same tag and the same decimal body as `int`: `BigInt.from(1)` and `1`
    // are the same integer, and which of the two a host happens to hold is not
    // a property of the graph.
    return _frame(0x69, ascii.encode(value.toString()));
  }
  if (value is double) return _frame(0x66, _float64Bytes(value)); // f
  if (value is String) return _frame(0x73, utf8.encode(value)); // s
  if (value is Uint8List) return _frame(0x79, value); // y
  if (value is ReplayEncodable) {
    return _frame(
      0x76, // v
      _encode(
        value.replayCanonicalForm,
        '$path.replayCanonicalForm',
        depth + 1,
      ),
    );
  }
  if (value is Enum) {
    return _frame(
      0x65, // e
      _concat([
        _frame(0x73, utf8.encode(value.runtimeType.toString())),
        _frame(0x73, utf8.encode(value.name)),
      ]),
    );
  }
  if (value is Map) {
    final entries = <Uint8List>[];
    for (final entry in value.entries) {
      entries.add(_concat([
        _encode(entry.key, '$path[key]', depth + 1),
        _encode(entry.value, '$path[${entry.key}]', depth + 1),
      ]));
    }
    entries.sort(_compareBytes);
    return _frame(0x6d, _concat(entries)); // m
  }
  if (value is Set) {
    final members = <Uint8List>[
      for (final item in value) _encode(item, '$path{}', depth + 1),
    ]..sort(_compareBytes);
    return _frame(0x74, _concat(members)); // t
  }
  if (value is Iterable) {
    final members = <Uint8List>[];
    var index = 0;
    for (final item in value) {
      members.add(_encode(item, '$path[$index]', depth + 1));
      index++;
    }
    return _frame(0x6c, _concat(members)); // l
  }
  throw ReplayEncodingError(
    '$path: ${value.runtimeType} has no canonical encoding. Observe a plain '
    'value, an Enum, a Uint8List, or a Map/Set/Iterable of them, or implement '
    'ReplayEncodable. Falling back on toString() would render every instance of '
    "this class as \"Instance of '${value.runtimeType}'\" and fold genuinely "
    'different observations into one value.',
  );
}

// ---------------------------------------------------------------------------
// The log
// ---------------------------------------------------------------------------

/// One entry of an ordered event log.
final class ReplayEvent implements ReplayEncodable {
  /// Creates an event at [seq] named [name] carrying [payload].
  ReplayEvent({required this.seq, required this.name, this.payload}) {
    if (seq < 0) {
      throw ArgumentError.value(seq, 'seq', 'event seq must be non-negative');
    }
    if (name.isEmpty) {
      throw ArgumentError.value(name, 'name', 'event name must be non-empty');
    }
  }

  /// Position in the log. Strictly increasing, possibly non-contiguous.
  final int seq;

  /// What happened.
  final String name;

  /// The event's data, in whatever shape the graph applies.
  final Object? payload;

  @override
  Object? get replayCanonicalForm => <String, Object?>{
        '@': 'lazily.ReplayEvent',
        'seq': seq,
        'name': name,
        'payload': payload,
      };

  @override
  String toString() => 'ReplayEvent(seq: $seq, name: $name, payload: $payload)';
}

/// An ordered event log with a digest over its canonical bytes.
///
/// Sequence numbers must strictly increase; they do not have to be contiguous,
/// because an ack-truncated durable outbox replays real epochs and renumbering
/// them would hide a truncated prefix the [digest] otherwise catches.
final class ReplayLog {
  /// Creates a log from already-numbered [events].
  ReplayLog(Iterable<ReplayEvent> events)
      : events = List<ReplayEvent>.unmodifiable(events) {
    int? previous;
    for (final event in this.events) {
      if (previous != null && event.seq <= previous) {
        throw ArgumentError.value(
          event.seq,
          'events',
          'event log must be strictly increasing in seq, got ${event.seq} '
              'after $previous',
        );
      }
      previous = event.seq;
    }
    digest = canonicalDigest(this.events);
  }

  /// A log from `(name, payload)` pairs, numbered `0..n-1`.
  factory ReplayLog.fromRecords(Iterable<(String, Object?)> records) {
    var index = 0;
    return ReplayLog([
      for (final (name, payload) in records)
        ReplayEvent(seq: index++, name: name, payload: payload),
    ]);
  }

  /// The events, in order.
  final List<ReplayEvent> events;

  /// Digest over the canonical bytes of [events] — the log's identity.
  late final String digest;

  /// How many events the log carries.
  int get length => events.length;

  /// The event at [index].
  ReplayEvent operator [](int index) => events[index];

  @override
  String toString() =>
      'ReplayLog(${events.length} events, digest: ${_abbreviate(digest)})';
}

// ---------------------------------------------------------------------------
// The fingerprint
// ---------------------------------------------------------------------------

/// Per-cell digests observed after applying events through [seq].
///
/// [seq] is [replayInitialSeq] for the state before any event was applied.
final class ReplayCheckpoint implements ReplayEncodable {
  ReplayCheckpoint._(this.seq, this.cells);

  /// Digest every value of [observed] and record them under their labels.
  factory ReplayCheckpoint.of(int seq, Map<String, Object?> observed) {
    final labels = observed.keys.toList()..sort();
    return ReplayCheckpoint._(
      seq,
      Map<String, String>.unmodifiable(<String, String>{
        for (final label in labels) label: canonicalDigest(observed[label]),
      }),
    );
  }

  /// Rebuild a checkpoint from already-computed digests.
  factory ReplayCheckpoint.ofDigests(int seq, Map<String, String> cells) {
    final labels = cells.keys.toList()..sort();
    return ReplayCheckpoint._(
      seq,
      Map<String, String>.unmodifiable(<String, String>{
        for (final label in labels) label: cells[label]!,
      }),
    );
  }

  /// The event this checkpoint was taken after, or [replayInitialSeq].
  final int seq;

  /// Label to digest, in label order.
  final Map<String, String> cells;

  @override
  Object? get replayCanonicalForm => <String, Object?>{
        '@': 'lazily.ReplayCheckpoint',
        'seq': seq,
        'cells': cells,
      };

  @override
  String toString() => 'ReplayCheckpoint(seq: $seq, cells: ${cells.keys})';
}

/// A recorded, log-bound observation of a replayed graph.
final class ReplayFingerprint implements ReplayEncodable {
  /// Creates a fingerprint over [checkpoints] bound to [logDigest]/[stride].
  ReplayFingerprint({
    required this.logDigest,
    required this.stride,
    required Iterable<ReplayCheckpoint> checkpoints,
  }) : checkpoints = List<ReplayCheckpoint>.unmodifiable(checkpoints) {
    if (stride < 1) {
      throw ArgumentError.value(stride, 'stride', 'stride must be >= 1');
    }
    if (this.checkpoints.isEmpty) {
      throw ArgumentError.value(
        checkpoints,
        'checkpoints',
        'a fingerprint needs at least the initial checkpoint',
      );
    }
    digest = canonicalDigest(<Object?>[logDigest, stride, this.checkpoints]);
  }

  /// Rebuild from [toWire], rejecting an unknown schema version.
  factory ReplayFingerprint.fromWire(Map<String, Object?> wire) {
    final version = wire['schema_version'];
    if (version != _wireSchemaVersion) {
      throw ReplayEncodingError(
        'unsupported replay fingerprint schema_version $version, expected '
        '$_wireSchemaVersion',
      );
    }
    return ReplayFingerprint(
      logDigest: wire['log_digest']! as String,
      stride: wire['stride']! as int,
      checkpoints: [
        for (final raw in (wire['checkpoints']! as List<Object?>)
            .map((entry) => entry! as Map<Object?, Object?>))
          ReplayCheckpoint.ofDigests(
            raw['seq']! as int,
            <String, String>{
              for (final cell
                  in (raw['cells']! as Map<Object?, Object?>).entries)
                cell.key! as String: cell.value! as String,
            },
          ),
      ],
    );
  }

  /// Digest of the log this fingerprint was recorded against.
  final String logDigest;

  /// Checkpoint stride it was sampled at.
  final int stride;

  /// The checkpoints, oldest first.
  final List<ReplayCheckpoint> checkpoints;

  /// Digest over the whole fingerprint — for pinning it by one short value.
  late final String digest;

  /// The last checkpoint, which is the end state of the replay.
  ReplayCheckpoint get finalCheckpoint => checkpoints.last;

  /// A JSON-safe form, so a fingerprint can be committed next to a test.
  Map<String, Object?> toWire() => <String, Object?>{
        'schema_version': _wireSchemaVersion,
        'log_digest': logDigest,
        'stride': stride,
        'checkpoints': [
          for (final checkpoint in checkpoints)
            <String, Object?>{
              'seq': checkpoint.seq,
              'cells': Map<String, String>.of(checkpoint.cells),
            },
        ],
      };

  @override
  Object? get replayCanonicalForm => <String, Object?>{
        '@': 'lazily.ReplayFingerprint',
        'log_digest': logDigest,
        'stride': stride,
        'checkpoints': checkpoints,
      };

  @override
  String toString() => 'ReplayFingerprint(stride: $stride, '
      '${checkpoints.length} checkpoints, digest: ${_abbreviate(digest)})';
}

/// How one cell failed to replay to its recorded digest.
enum ReplayDivergenceKind {
  /// Both sides observed the cell and the digests differ.
  value('value'),

  /// The fingerprint carries the cell and the replay did not observe it.
  missing('missing'),

  /// The replay observed a cell the fingerprint does not carry.
  unexpected('unexpected');

  const ReplayDivergenceKind(this.wireName);

  /// The name the canonical corpus uses for this kind.
  final String wireName;
}

/// One cell that did not replay to its recorded digest.
final class ReplayDivergence {
  /// Creates a divergence at [seq] on [label].
  const ReplayDivergence({
    required this.seq,
    required this.label,
    required this.kind,
    this.expected,
    this.actual,
    this.preview,
  });

  /// The checkpoint it was found at, or [replayInitialSeq].
  final int seq;

  /// The cell label that differed.
  final String label;

  /// Which of the three ways it differed.
  final ReplayDivergenceKind kind;

  /// The digest the fingerprint carries, when it carries one.
  final String? expected;

  /// The digest the replay produced, when it produced one.
  final String? actual;

  /// A short rendering of the replayed value, for the failure message.
  final String? preview;

  @override
  String toString() {
    final where = seq == replayInitialSeq ? 'initial state' : 'event seq=$seq';
    switch (kind) {
      case ReplayDivergenceKind.missing:
        return '$where: cell "$label" was not observed on replay';
      case ReplayDivergenceKind.unexpected:
        return '$where: cell "$label" appeared on replay but is not in the '
            'fingerprint';
      case ReplayDivergenceKind.value:
        final shown = preview == null ? '' : ', observed $preview';
        return '$where: cell "$label" expected ${_abbreviate(expected ?? '')} '
            'but replayed ${_abbreviate(actual ?? '')}$shown';
    }
  }
}

// ---------------------------------------------------------------------------
// The graph under proof
// ---------------------------------------------------------------------------

/// What the harness needs from the graph it rebuilds.
abstract interface class ReplayGraph {
  /// Advance the graph by exactly one event.
  void apply(ReplayEvent event);

  /// The cell values the fingerprint covers, keyed by a stable label.
  ///
  /// Return a snapshot, not a live view: the harness digests what it is handed
  /// at the moment it is handed it, and a mutable collection that keeps
  /// changing underneath is not a checkpoint.
  Map<String, Object?> observe();
}

/// Rebuild a graph from an event log and prove it replays identically.
final class ReplayHarness {
  /// Creates a harness that calls [build] once per replay.
  ///
  /// [build] must return a *fresh* graph. A harness that reuses one instance
  /// proves nothing, because the state it would compare against is the state it
  /// already has.
  ///
  /// [stride] checkpoints every `stride`-th event; the initial state and the
  /// final state are always checkpointed. It is recorded in the fingerprint, so
  /// a fingerprint cannot be compared against a replay that sampled
  /// differently.
  ReplayHarness(this._build, {int stride = 1}) : _stride = stride {
    if (stride < 1) {
      throw ArgumentError.value(stride, 'stride', 'stride must be >= 1');
    }
  }

  final ReplayGraph Function() _build;
  final int _stride;

  /// How often a checkpoint is taken.
  int get stride => _stride;

  /// Replay [log] once and record what the graph observed.
  ReplayFingerprint record(ReplayLog log) => _replay(log).fingerprint;

  /// Replay [log] and return the divergences from [fingerprint].
  ///
  /// Non-raising for value divergence, so a caller can report all of them.
  /// Still throws [ReplayLogMismatchError] for a fingerprint recorded against a
  /// different log and [ReplayStrideMismatchError] for one recorded at a
  /// different stride: comparing either would answer a question nobody asked.
  List<ReplayDivergence> check(ReplayLog log, ReplayFingerprint fingerprint) {
    final replayed = _replay(log);
    _revalidate(fingerprint, replayed.fingerprint);
    return _compare(fingerprint, replayed);
  }

  /// Replay [log] and throw unless it matches [fingerprint] exactly.
  ///
  /// Returns the freshly recorded fingerprint, which equals [fingerprint].
  ReplayFingerprint verify(ReplayLog log, ReplayFingerprint fingerprint) {
    final replayed = _replay(log);
    _revalidate(fingerprint, replayed.fingerprint);
    final divergences = _compare(fingerprint, replayed);
    if (divergences.isNotEmpty) throw ReplayDivergenceError(divergences);
    return replayed.fingerprint;
  }

  /// Record [log] and re-replay it, throwing on any divergence.
  ///
  /// The self-check: no external fingerprint is needed to catch a graph that is
  /// not a pure function of its log, because two replays of the same log in the
  /// same process already disagree.
  ReplayFingerprint prove(ReplayLog log, {int replays = 2}) {
    if (replays < 2) {
      throw ArgumentError.value(
        replays,
        'replays',
        'prove needs at least 2 replays to compare',
      );
    }
    final fingerprint = record(log);
    for (var i = 1; i < replays; i++) {
      verify(log, fingerprint);
    }
    return fingerprint;
  }

  /// Bind the fingerprint to these exact log bytes before comparing anything.
  static void _revalidate(
    ReplayFingerprint fingerprint,
    ReplayFingerprint replayed,
  ) {
    if (fingerprint.logDigest != replayed.logDigest) {
      throw ReplayLogMismatchError(
        expectedDigest: fingerprint.logDigest,
        actualDigest: replayed.logDigest,
      );
    }
    if (fingerprint.stride != replayed.stride) {
      throw ReplayStrideMismatchError(
        expectedStride: fingerprint.stride,
        actualStride: replayed.stride,
      );
    }
  }

  _Replay _replay(ReplayLog log) {
    final graph = _build();
    var sample = Map<String, Object?>.of(graph.observe());
    final checkpoints = <ReplayCheckpoint>[
      ReplayCheckpoint.of(replayInitialSeq, sample),
    ];
    final observed = <Map<String, Object?>>[sample];
    final total = log.length;
    for (var index = 0; index < total; index++) {
      final event = log[index];
      graph.apply(event);
      if ((index + 1) % _stride == 0 || index + 1 == total) {
        sample = Map<String, Object?>.of(graph.observe());
        checkpoints.add(ReplayCheckpoint.of(event.seq, sample));
        observed.add(sample);
      }
    }
    return _Replay(
      ReplayFingerprint(
        logDigest: log.digest,
        stride: _stride,
        checkpoints: checkpoints,
      ),
      observed,
    );
  }

  static List<ReplayDivergence> _compare(
    ReplayFingerprint expected,
    _Replay replayed,
  ) {
    final actual = replayed.fingerprint;
    final divergences = <ReplayDivergence>[];
    final shared = expected.checkpoints.length < actual.checkpoints.length
        ? expected.checkpoints.length
        : actual.checkpoints.length;
    for (var index = 0; index < shared; index++) {
      final want = expected.checkpoints[index];
      final got = actual.checkpoints[index];
      final labels = <String>{...want.cells.keys, ...got.cells.keys}.toList()
        ..sort();
      for (final label in labels) {
        final wantDigest = want.cells[label];
        final gotDigest = got.cells[label];
        if (wantDigest == gotDigest) continue;
        final kind = gotDigest == null
            ? ReplayDivergenceKind.missing
            : wantDigest == null
                ? ReplayDivergenceKind.unexpected
                : ReplayDivergenceKind.value;
        final sample = index < replayed.observed.length
            ? replayed.observed[index]
            : const <String, Object?>{};
        divergences.add(ReplayDivergence(
          seq: want.seq,
          label: label,
          kind: kind,
          expected: wantDigest,
          actual: gotDigest,
          preview: sample.containsKey(label) ? _preview(sample[label]) : null,
        ));
      }
      // The first diverging checkpoint is the actionable one; later ones are
      // almost always the same defect carried forward.
      if (divergences.isNotEmpty) break;
    }
    if (divergences.isEmpty &&
        expected.checkpoints.length != actual.checkpoints.length) {
      throw ReplayCheckpointCountError(
        expectedCount: expected.checkpoints.length,
        actualCount: actual.checkpoints.length,
      );
    }
    return divergences;
  }
}

const int _previewLimit = 120;

String _preview(Object? value) {
  final String text;
  try {
    text = '$value';
  } on Object {
    return '<unprintable>';
  }
  if (text.length > _previewLimit) {
    return '${text.substring(0, _previewLimit - 1)}…';
  }
  return text;
}

/// One replay: the fingerprint it produced and the raw samples behind it.
final class _Replay {
  const _Replay(this.fingerprint, this.observed);

  final ReplayFingerprint fingerprint;
  final List<Map<String, Object?>> observed;
}
