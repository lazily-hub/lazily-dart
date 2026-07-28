#!/usr/bin/env bash
# Conformance-coverage guard (#lazilyupgradeconformance).
#
# Fails the build when a fixture in the canonical corpus at
# ../lazily-spec/conformance/ is not replayed by this repo's suite. That is the
# drift this guard exists for: a fixture lands upstream, every binding stays green,
# and nobody learns that one of them is not replaying it.
#
# This binding uses the RUNTIME manifest, not the static grep it started with. The
# test run records every file it actually reads from the conformance corpus, so a
# fixture named in a comment but hand-transcribed — the drift found in lazily-cpp's
# queue tests, and in lazily-rs's own topic tests where four `topiccell_*.json`
# fixtures were named and never opened — is caught here. A source grep cannot see
# that case at all: absent means not replayed, but present never meant replayed.
#
# A missing manifest is missing EVIDENCE and fails. It does not mean "no fixtures
# were read"; it means the suite ran without the recorder attached, and passing in
# that state is the vacuous green this guard exists to prevent.
#
# Run it AFTER the suite (`make check` orders it that way). The recorder lives in
# test/conformance_manifest.dart; the Makefile truncates the manifest once and
# exports an ABSOLUTE path for the test run.
set -euo pipefail

SPEC_DIR="${LAZILY_SPEC_CONFORMANCE_DIR:-../lazily-spec/conformance}"
if [ ! -d "$SPEC_DIR" ]; then
  echo "SKIP: canonical corpus not found at $SPEC_DIR (clone the lazily-spec sibling)" >&2
  exit 0
fi

# Fixtures deliberately not covered by this binding yet. Each entry is a claim that
# someone looked; shrinking this list is the work. Adding to it silently is how the
# guard rots, so keep a reason with any new entry.
#
# Every entry here survived the static-to-runtime upgrade unchanged: the suite
# opens exactly the 111 fixtures the grep said it named, so lazily-dart had no
# named-but-never-opened fixture to find.
KNOWN_UNCOVERED=(
  "agent-doc/delta_agent_doc_state.json"
  "agent-doc/snapshot_agent_doc_state.json"
  "arena_blob.json"
  "collections/topiccell_broadcast_cursor_isolation.json"
  "collections/topiccell_durable_replay_gc.json"
  "collections/topiccell_ephemeral_lifecycle.json"
  "collections/topiccell_offline_tail_bounds.json"
  "collections/workqueue_competing_delivery.json"
  "collections/workqueue_lease_deadletter.json"
  "distributed/crdt_sync_frames.json"
  "reliable-sync/coalesce_bounds_outbox.json"
  "reliable-sync/liveness_lease_eviction.json"
  "signaling/frames.json"
  # Portable stdlib APIs and their production fixture runners are staged.
  "stdlib/revision_barrier.json"
  "stdlib/timeout.json"
  "stdlib/timer.json"
)

MANIFEST="${LAZILY_CONFORMANCE_MANIFEST:-build/conformance-fixtures-loaded.txt}"

if [ ! -s "$MANIFEST" ]; then
  echo "FAIL: no conformance manifest at $MANIFEST." >&2
  echo "      Run the suite with LAZILY_CONFORMANCE_MANIFEST set so the recorder" >&2
  echo "      attaches (\`make test\`, or \`make check\` for the whole gate). An absent" >&2
  echo "      manifest is missing evidence, not evidence of absence." >&2
  exit 1
fi
OPENED="$(sort -u "$MANIFEST")"

missing=0
total=0
covered=0
while IFS= read -r fixture; do
  total=$((total + 1))
  # Here-string, NOT a pipe. With `set -o pipefail`, `printf ... | grep -q` reports
  # FAILURE when grep matches: grep -q exits immediately on the first hit, printf
  # takes SIGPIPE writing the rest, and pipefail surfaces printf's death as the
  # pipeline's status. The check then inverts — every covered fixture is reported
  # missing. That is exactly how it behaved before this line changed.
  if grep -qxF "$fixture" <<< "$OPENED"; then
    covered=$((covered + 1))
    continue
  fi
  excused=0
  for known in "${KNOWN_UNCOVERED[@]:-}"; do
    if [ "$known" = "$fixture" ]; then excused=1; break; fi
  done
  if [ "$excused" -eq 0 ]; then
    echo "ERROR: canonical fixture '$fixture' was NOT opened by the suite." >&2
    echo "       A runner may still name it in source while no longer reading it —" >&2
    echo "       that is the drift this manifest exists to catch. Replay it, or add" >&2
    echo "       it to KNOWN_UNCOVERED with a reason." >&2
    missing=$((missing + 1))
  fi
done < <(cd "$SPEC_DIR" && find . -name '*.json' | sed 's|^\./||' | sort)

# The evidence channel guards itself. Every recorded id is resolved against the
# corpus root, so an id naming no file means the manifest was corrupted in transit
# — which is not hypothetical here: Dart's FileMode.append is not O_APPEND and its
# fcntl locks do not span isolates, so the first two versions of the recorder wrote
# severed tails like `sure.json` and then reported the intact fixtures as never
# opened. Silent corruption manufactures drift that does not exist, and the usual
# fix for a guard that cries wolf is to switch it off.
while IFS= read -r id; do
  [ -n "$id" ] || continue
  if [ ! -f "$SPEC_DIR/$id" ]; then
    echo "ERROR: manifest records '$id', which names no file in $SPEC_DIR." >&2
    echo "       The recorder is dropping or interleaving writes; coverage computed" >&2
    echo "       from this manifest cannot be trusted." >&2
    missing=$((missing + 1))
  fi
done <<< "$OPENED"

# A stale allowlist is its own drift: an entry naming a fixture that no longer
# exists means the corpus moved and nobody updated the excuse.
for known in "${KNOWN_UNCOVERED[@]:-}"; do
  if [ ! -f "$SPEC_DIR/$known" ]; then
    echo "ERROR: KNOWN_UNCOVERED lists '$known', which is not in the canonical corpus." >&2
    missing=$((missing + 1))
  fi
done

if [ "$missing" -gt 0 ]; then
  echo "conformance coverage FAILED: $missing problem(s)" >&2
  exit 1
fi

echo "conformance coverage OK: $covered/$total canonical fixtures OPENED by the suite" \
     "(${#KNOWN_UNCOVERED[@]} listed as known-uncovered; runtime manifest — these bytes were really read)"
