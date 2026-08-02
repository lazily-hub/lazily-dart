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

# A missing corpus is a legitimate LOCAL state and an illegitimate CI state
# (#lzvacuousrun). Every rung below reasons about fixtures the run OPENED, so an
# absent corpus makes all of them vacuously true and this script reports OK
# having examined zero fixtures — a CI job with a wrong checkout would announce
# conformance coverage it never measured. Under CI that is missing EVIDENCE, not
# evidence of absence, and it fails the same way a missing manifest already does
# below. Locally it stays a skip, because a contributor without the lazily-spec
# sibling is not making a false claim.
if [ ! -d "$SPEC_DIR" ]; then
  if [ -n "${CI:-}" ]; then
    echo "ERROR: canonical corpus not found at $SPEC_DIR, and CI is set." >&2
    echo "       The checkout is wrong, not the corpus. Exiting 0 here would report" >&2
    echo "       conformance coverage OK having opened zero fixtures, which is the" >&2
    echo "       vacuous green this guard exists to prevent (#lzvacuousrun)." >&2
    exit 1
  fi
  echo "SKIP: canonical corpus not found at $SPEC_DIR (clone the lazily-spec sibling)" >&2
  echo "      Local checkout only — this is a hard failure under CI." >&2
  exit 0
fi

# Fixtures deliberately not covered by this binding yet. Each entry is a claim that
# someone looked; shrinking this list is the work. Adding to it silently is how the
# guard rots, so keep a reason with any new entry.
#
# Every entry here survived the static-to-runtime upgrade unchanged: the suite
# opened exactly the 111 fixtures the grep said it named, so lazily-dart had no
# named-but-never-opened fixture to find.
#
# This list is the FLOOR, and it only ever shrinks. Deleting an entry raises the
# bar for good: the loop below walks the whole corpus and fails on any fixture
# that is neither opened nor excused, so a replay that is later removed or
# short-circuited fails here immediately. `codec/frame_roundtrip_msgpack.json`
# left the list when lazily-dart implemented the `msgpack` wire
# (`#lzmsgpackseven`); putting it back to make a gate green would be lowering a
# floor.
#
# It did have the opposite rot (#lzcovallowlistrot). Seven entries named fixtures
# the suite replays — the four `collections/topiccell_*` and two
# `collections/workqueue_*` scenarios that queue_family_conformance_test.dart
# replays across all three flavors, and `signaling/frames.json`, whose every
# frame distributed_conformance_test.dart round-trips or rejects. Nothing
# complained because the error understated coverage, and an excuse list that is
# half fiction is one nobody can read the real gaps out of. The stale-entry check
# at the bottom of this file now fails on that direction too.
KNOWN_UNCOVERED=(
  "agent-doc/delta_agent_doc_state.json"
  "agent-doc/snapshot_agent_doc_state.json"
  "arena_blob.json"
  # Not a bookkeeping gap, and not the sentence above it: its
  # `crdt_sync_frontier_suppressed` frame OMITS `frontier`, which
  # schemas/distributed.json makes optional (an omitted frontier means
  # "unchanged since the last accepted frame"), and this binding's
  # `CrdtSync.fromWire` throws `frontier must be an array, got null` on it. The
  # other three frames decode and round-trip today; replaying the file means
  # implementing frontier suppression first, so this entry names a real library
  # gap rather than a missing runner.
  "distributed/crdt_sync_frames.json"
  "reliable-sync/coalesce_bounds_outbox.json"
  "reliable-sync/liveness_lease_eviction.json"
)

# Scenarios deliberately not replayed by this binding (#lzscenariocoverage).
#
# One rung below KNOWN_UNCOVERED, and read the same way: that list names files
# this binding does not open, this one names SCENARIOS inside files it does.
# Both live here so there is one place to read what lazily-dart does not prove.
#
# Format: `fixture|scenario-id|reason`. The id resolves the same way the ledger
# resolves it — `id`, else `name`, else `#<index>`.
#
# Checked in BOTH directions, exactly like KNOWN_UNCOVERED: an entry naming a
# scenario the run DID replay fails as stale, and so does one naming an id the
# fixture does not carry. An excuse needs a reason that says what this binding
# cannot express; "not implemented yet" is not one — implement it.
#
# Empty, and that is the point. The one real gap this ledger found —
# `liveness_orset_lww.json`'s fourth scenario,
# `derived_live_doc_aggregate_converges_under_retry`, which
# reliable_sync_conformance_test.dart reached past for three named scenarios and
# never replayed — was IMPLEMENTED rather than excused. Scenarios inside a
# fixture KNOWN_UNCOVERED already excuses are not listed twice; the check below
# only looks inside fixtures the manifest says were opened.
KNOWN_UNREPLAYED_SCENARIOS=()

MANIFEST="${LAZILY_CONFORMANCE_MANIFEST:-build/conformance-fixtures-loaded.txt}"
SCENARIOS="${LAZILY_CONFORMANCE_SCENARIOS:-build/conformance-scenarios-replayed.txt}"

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

# A stale allowlist is its own drift, in two directions.
#
# (1) An entry naming a fixture that no longer exists means the corpus moved and
#     nobody updated the excuse.
# (2) An entry naming a fixture the suite DOES open means the gap was closed and
#     nobody deleted the excuse. This one understates coverage, so nothing ever
#     complains: no bug gets filed about coverage you are told you lack, and a
#     bloated excuse list buries the real gaps. The comparison below is the exact
#     `grep -qxF <<< "$OPENED"` the covered-check uses, so the two can never
#     disagree about what "opened" means.
for known in "${KNOWN_UNCOVERED[@]:-}"; do
  if [ ! -f "$SPEC_DIR/$known" ]; then
    echo "ERROR: KNOWN_UNCOVERED lists '$known', which is not in the canonical corpus." >&2
    missing=$((missing + 1))
    continue
  fi
  if grep -qxF "$known" <<< "$OPENED"; then
    echo "ERROR: KNOWN_UNCOVERED lists '$known', but the suite DID open it." >&2
    echo "       The excuse is stale — the fixture is covered. Delete the entry from" >&2
    echo "       KNOWN_UNCOVERED so the list keeps naming only real gaps." >&2
    missing=$((missing + 1))
  fi
done

# ---------------------------------------------------------------------------
# Per-scenario replay accounting (#lzscenariocoverage)
# ---------------------------------------------------------------------------
#
# One rung below everything above. A fixture with four named scenarios can be
# PARTIALLY replayed and every guard in this repo stays green: the coverage
# check above asks only whether the FILE was opened, and the key guards in
# test/conformance_assertions.dart only bind blocks a runner actually reaches,
# so an unreplayed scenario contributes no unconsumed key and no unasserted key.
# Skipping a whole scenario is invisible to a guard that only inspects the
# scenarios you ran.
#
# The ledger is written at the point of replay by `scenariosOf` /
# `scenarioNamed` in test/conformance_manifest.dart — evidence, not a
# declaration. A hand-authored "scenarios this runner covers" list is the thing
# being guarded against: it is a claim, and a claim rots.
if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required to read the corpus's scenario ids." >&2
  echo "      Skipping this check would report a partially replayed fixture as" >&2
  echo "      fully covered, which is the vacuous green it exists to prevent." >&2
  exit 1
fi

if [ ! -f "$SCENARIOS" ]; then
  echo "FAIL: no scenario ledger at $SCENARIOS." >&2
  echo "      Run the suite with LAZILY_CONFORMANCE_SCENARIOS set (\`make test\`)." >&2
  echo "      An absent ledger is missing evidence, not evidence of absence." >&2
  exit 1
fi
REPLAYED="$(sort -u "$SCENARIOS")"

# Every scenario id the corpus carries, for the fixtures the suite OPENED, in
# the same `fixture<TAB>id` shape the ledger uses. Resolution order — `id`, else
# `name` — matches `scenarioIdOf` in test/conformance_manifest.dart exactly; if
# the two ever disagree the ledger stops matching and this check fails closed.
#
# There is no positional fallback (#lzspecscenarioids): an id derived from a
# POSITION silently rebinds to a different scenario when the corpus array is
# reordered, so an unidentified scenario is marked and reported rather than
# given an invented id.
EXPECTED="$(
  while IFS= read -r fixture; do
    [ -n "$fixture" ] || continue
    [ -f "$SPEC_DIR/$fixture" ] || continue
    jq -r --arg f "$fixture" '
      def identifier: if type == "string" and (gsub("\\s"; "") != "") then . else null end;
      if (.scenarios | type) == "array"
      then .scenarios | to_entries[]
           | "\($f)\t\((.value.id? | identifier) // (.value.name? | identifier) // "!UNIDENTIFIED!\(.key)")"
      else empty end' "$SPEC_DIR/$fixture"
  done <<< "$OPENED"
)"

SCENARIO_TOTAL=0
SCENARIO_REPLAYED=0
while IFS= read -r want; do
  [ -n "$want" ] || continue
  SCENARIO_TOTAL=$((SCENARIO_TOTAL + 1))
  # An unidentified scenario is a corpus defect, not an id to invent
  # (#lzspecscenarioids). Booking it by POSITION would silently rebind that
  # ledger entry to a different scenario on any corpus reorder.
  case "$want" in
    *$'\t'"!UNIDENTIFIED!"*)
      echo "ERROR: '${want%%$'\t'*}' scenario at index ${want##*!UNIDENTIFIED!} carries" >&2
      echo "       neither \`id\` nor \`name\`. The ledger would record it by POSITION," >&2
      echo "       which silently rebinds on a corpus reorder. Give it a stable id" >&2
      echo "       upstream in lazily-spec (#lzspecscenarioids)." >&2
      missing=$((missing + 1))
      continue
      ;;
  esac
  if grep -qxF "$want" <<< "$REPLAYED"; then
    SCENARIO_REPLAYED=$((SCENARIO_REPLAYED + 1))
    continue
  fi
  excused=0
  for known in "${KNOWN_UNREPLAYED_SCENARIOS[@]:-}"; do
    [ -n "$known" ] || continue
    entry="${known%|*}"
    if [ "${entry%%|*}"$'\t'"${entry#*|}" = "$want" ]; then excused=1; break; fi
  done
  if [ "$excused" -eq 0 ]; then
    echo "ERROR: scenario '${want#*$'\t'}' of '${want%%$'\t'*}' was NOT replayed." >&2
    echo "       The fixture WAS opened, so every other guard is green — a" >&2
    echo "       partially replayed fixture is exactly what this ledger exists to" >&2
    echo "       catch. Replay it, or add it to KNOWN_UNREPLAYED_SCENARIOS with a" >&2
    echo "       reason this binding cannot express it." >&2
    missing=$((missing + 1))
  fi
done <<< "$EXPECTED"

# The evidence channel guards itself, as the manifest's does: an id the corpus
# does not carry means the ledger was corrupted in transit or a runner recorded
# something it did not replay, and coverage computed from it cannot be trusted.
while IFS= read -r have; do
  [ -n "$have" ] || continue
  grep -qxF "$have" <<< "$EXPECTED" && continue
  # A fixture outside the OPENED set is not evidence of corruption: the ledger
  # also records replays that resolved to the vendored mirror, which the
  # manifest deliberately ignores.
  grep -qxF "${have%%$'\t'*}" <<< "$OPENED" || continue
  echo "ERROR: the scenario ledger records '${have#*$'\t'}' for '${have%%$'\t'*}'," >&2
  echo "       which carries no such scenario. Either the ledger is dropping or" >&2
  echo "       interleaving writes, or a runner recorded a scenario it invented." >&2
  missing=$((missing + 1))
done <<< "$REPLAYED"

# A stale excuse, in the same two directions the KNOWN_UNCOVERED check uses.
for known in "${KNOWN_UNREPLAYED_SCENARIOS[@]:-}"; do
  [ -n "$known" ] || continue
  entry="${known%|*}"
  reason="${known##*|}"
  key="${entry%%|*}"$'\t'"${entry#*|}"
  if [ -z "${reason//[[:space:]]/}" ]; then
    echo "ERROR: KNOWN_UNREPLAYED_SCENARIOS entry '$entry' carries no reason." >&2
    echo "       An excuse without a why is a gap nobody can act on." >&2
    missing=$((missing + 1))
  fi
  if ! grep -qxF "$key" <<< "$EXPECTED"; then
    echo "ERROR: KNOWN_UNREPLAYED_SCENARIOS names '${entry#*|}' in '${entry%%|*}'," >&2
    echo "       which is not a scenario that fixture carries (or the fixture is" >&2
    echo "       not opened at all). The excuse is stale — delete or correct it." >&2
    missing=$((missing + 1))
    continue
  fi
  if grep -qxF "$key" <<< "$REPLAYED"; then
    echo "ERROR: KNOWN_UNREPLAYED_SCENARIOS names '${entry#*|}' in '${entry%%|*}'," >&2
    echo "       but the suite DID replay it. The excuse is stale — it now" >&2
    echo "       misreports a covered scenario as a known gap. Delete the entry." >&2
    missing=$((missing + 1))
  fi
done

if [ "$missing" -gt 0 ]; then
  echo "conformance coverage FAILED: $missing problem(s)" >&2
  exit 1
fi

# ---- Positive-evidence floors (#lzvacuousrun) ----
#
# Everything above is a NEGATIVE check: it reasons about fixtures the run
# OPENED and scenarios the run REPLAYED, so all of it is vacuously satisfied by
# an empty population. Zero opened fixtures means zero uncovered fixtures, zero
# unreplayed scenarios, and zero stale excuses — nothing in this file can
# contradict a run that examined nothing. `missing -eq 0` cannot tell "nothing
# is wrong" apart from "nothing was measured", so assert the MAGNITUDE before
# printing OK.
#
# The constants are calibrated from a real green run of `make check` on this
# binding (133 of 139 canonical fixtures opened, 126 scenarios replayed) and sit
# slightly under it, so ordinary corpus churn does not trip them while a
# collapse does. Do NOT lower them to make a red run green: a drop here means
# the corpus shrank or the recorder detached mid-run, and that is the finding,
# not the obstacle.
#
# They RISE with coverage: the blob-backend discriminator fixture added one
# fixture and eight scenarios, so leaving the old floors in place would have
# left room to silently drop the new replay again.
MIN_FIXTURES="${MIN_FIXTURES:-129}"
MIN_SCENARIOS="${MIN_SCENARIOS:-120}"

if [ "$total" -eq 0 ]; then
  echo "ERROR: the corpus at $SPEC_DIR listed ZERO fixtures." >&2
  echo "       Every check above is vacuously green over an empty population, so" >&2
  echo "       this run proves nothing about conformance (#lzvacuousrun)." >&2
  exit 1
fi
if [ "$covered" -lt "$MIN_FIXTURES" ]; then
  echo "ERROR: only $covered distinct canonical fixtures were OPENED, expected >= $MIN_FIXTURES." >&2
  echo "       A replay was removed, renamed, or short-circuited, or the recorder" >&2
  echo "       detached mid-run. Do not lower MIN_FIXTURES to fix this." >&2
  exit 1
fi
if [ "$SCENARIO_TOTAL" -eq 0 ]; then
  echo "ERROR: ZERO scenarios were found across the OPENED fixtures." >&2
  echo "       The per-scenario rung above compared nothing and reported no gaps." >&2
  exit 1
fi
if [ "$SCENARIO_REPLAYED" -lt "$MIN_SCENARIOS" ]; then
  echo "ERROR: only $SCENARIO_REPLAYED scenarios were REPLAYED, expected >= $MIN_SCENARIOS." >&2
  echo "       A scenario dispatch stopped matching, or the ledger detached." >&2
  echo "       Do not lower MIN_SCENARIOS to fix this." >&2
  exit 1
fi

echo "conformance coverage OK: $covered/$total canonical fixtures OPENED by the suite" \
     "(${#KNOWN_UNCOVERED[@]} listed as known-uncovered; runtime manifest — these bytes were really read)"
echo "scenario replay OK: $SCENARIO_REPLAYED/$SCENARIO_TOTAL scenarios of the OPENED fixtures" \
     "were REPLAYED (${#KNOWN_UNREPLAYED_SCENARIOS[@]} excused; runtime ledger)"

