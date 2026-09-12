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

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# ---------------------------------------------------------------------------
# Rung 0: fixture-flag hygiene (#lzsiblingrunnermasking)
# ---------------------------------------------------------------------------
#
# FIRST, and deliberately ABOVE the missing-corpus gate below: this rung reads
# only this repo's own sources, so it must run in a checkout without the
# lazily-spec sibling too. Every rung after this one reasons about fixtures the
# run OPENED and is vacuous without the corpus; this one is not, and skipping it
# with the rest would mean the ban only ever ran where the corpus happened to be
# present.
#
# `#lzflagcoercion` fixed every coerced fixture-flag read in the suite and left
# nothing to stop the next one. In lazily-rs and lazily-kt the ONLY thing that
# caught the coercion was a second runner over the same fixture happening to be
# strict — coverage by accident of which runners exist, gone the moment one is
# deleted, split, renamed or skipped. lazily-cpp's `97790fd` answered this by
# DELETING the weak accessor so the spelling became a compile error; Dart has no
# accessor to delete and no custom-lint plugin here, so the local equivalent is
# this scan plus the strict funnel (`flagOf` / `flagAt`) everything was
# converted to.
#
# The scan accumulates: every banned site in every file, plus both scan-reach
# floors, report together in one run rather than one-per-invocation.
"$ROOT/scripts/check-flag-hygiene.py" "$ROOT"

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
  # Register CRDTs (LWW / MV / PnCounter + the CellCrdt projection bit) are
  # implemented here, but this binding has no canonical replay for the new
  # registers corpus yet; the Registers coverage row is `~` until it does.
  "collections/registers_convergence.json"
  # Reactive egress is currently Rust-only; Dart has no egress replay runner.
  "egress/egress_generation_fence.json"
  "egress/egress_inflight_window.json"
  "egress/egress_ordered_ack.json"
  "egress/egress_retry_budget.json"
  # Experimental protobuf-v1 generation is piloted in Rust/Kotlin/TypeScript;
  # Dart must negotiate the capability before replaying this typed trace.
  "protobuf/graph_boundary_traces.json"
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

# ---------------------------------------------------------------------------
# Rung 1: the evidence belongs to THIS invocation (#lzstalemanifest)
# ---------------------------------------------------------------------------
#
# Every rung below says "these bytes were really read". None of them could say
# WHEN. Measured on this repo before this rung existed: `make
# conformance-coverage` with NO test run in the invocation printed
# "conformance coverage OK: 144/156 ... these bytes were really read" and
# "scenario replay OK: 153/153" off the previous run's files, and a five-test
# `dart test test/topic_test.dart` appending to those same files printed the
# identical verdict. `dart test` caches nothing, so the hole here is not kt's
# `> Task :test UP-TO-DATE`; it is the LEFTOVER FILE — a finished or aborted
# earlier run, or one of the 69 single-file runs #lzsiblingrunnermasking did,
# read by a guard that believes it describes the whole suite.
#
# A truncated-then-PARTIAL file was already refused: `covered` is asserted EQUAL
# to the corpus listing minus KNOWN_UNCOVERED (#lzdartcoveragefloors), and a
# 5-line manifest fails that by 139. So the undetected shape was the stale
# COMPLETE file, which is exactly what a green run leaves behind.
#
# PLACEMENT, and why it differs from rung 0's. Rung 0 (flag hygiene) sits ABOVE
# the missing-corpus gate because it reads only this repo and must run in a
# checkout without the lazily-spec sibling. This rung has the opposite
# requirement in two ways: it needs `LAZILY_CONFORMANCE_RUN_ID`, which only a
# `make` invocation or a CI job supplies, and it judges EVIDENCE FILES, which
# the gate above has just established this checkout may legitimately never have
# produced — with no corpus the recorder attributes no read and the manifest
# comes out EMPTY. Above the gate it would turn a contributor's honest local
# skip into a failure. So it sits here, with the evidence, and each file is
# checked at the point it is first read.
#
# There is no opt-out flag, deliberately. The only two callers of this script
# are the Makefile and .github/workflows/ci.yml, and both supply the id; a
# hand-run `./scripts/check-conformance-coverage.sh` SHOULD refuse, because it
# has no way to know which run wrote build/.
RUN_ID_PREFIX="# lazily-run-id "
RUN_ID="${LAZILY_CONFORMANCE_RUN_ID:-}"
if [ -z "$RUN_ID" ]; then
  echo "FAIL: LAZILY_CONFORMANCE_RUN_ID is not set (#lzstalemanifest)." >&2
  echo "      This guard reads evidence files written by a SEPARATE process (the" >&2
  echo "      \`dart test\` children), so it can only tell this run's evidence from" >&2
  echo "      last run's by the id both sides carry. Refusing rather than skipping:" >&2
  echo "      a guard that accepts unstamped evidence when the variable is unset is" >&2
  echo "      the same stale-evidence hole with one extra step." >&2
  echo "      Run \`make check\` (or \`make conformance-coverage\`), which generates" >&2
  echo "      one id per invocation and exports it." >&2
  exit 1
fi

# Require the stamp the recorder in test/conformance_manifest.dart writes as the
# first line of each evidence file, and fail by NAME: the file, the id found,
# the id wanted. A missing stamp fails too — an evidence file predating this
# change carries none, and so does one written by a suite run without the
# variable set.
require_run_id() {
  local file="$1" label="$2" first found
  first="$(head -n 1 "$file")"
  case "$first" in
    "$RUN_ID_PREFIX"*) ;;
    *)
      echo "FAIL: $label at $file carries no run-id stamp (#lzstalemanifest)." >&2
      echo "      wanted first line: ${RUN_ID_PREFIX}${RUN_ID}" >&2
      echo "      found first line:  ${first}" >&2
      echo "      The file was written by a suite run with no" >&2
      echo "      LAZILY_CONFORMANCE_RUN_ID in its environment, or it predates the" >&2
      echo "      stamp entirely. Either way it is not evidence about this run." >&2
      exit 1 ;;
  esac
  found="${first#"$RUN_ID_PREFIX"}"
  if [ "$found" != "$RUN_ID" ]; then
    echo "FAIL: $label at $file is STALE (#lzstalemanifest)." >&2
    echo "      run id in the file:   $found" >&2
    echo "      run id of this gate:  $RUN_ID" >&2
    echo "      It was written by an earlier invocation — a previous \`make check\`," >&2
    echo "      an aborted run, or a single-file \`dart test\`. Re-run the suite in" >&2
    echo "      this invocation (\`make check\`); do NOT read it as coverage." >&2
    exit 1
  fi
}

if [ ! -s "$MANIFEST" ]; then
  echo "FAIL: no conformance manifest at $MANIFEST." >&2
  echo "      Run the suite with LAZILY_CONFORMANCE_MANIFEST set so the recorder" >&2
  echo "      attaches (\`make test\`, or \`make check\` for the whole gate). An absent" >&2
  echo "      manifest is missing evidence, not evidence of absence." >&2
  exit 1
fi
require_run_id "$MANIFEST" "conformance manifest"
# `sed`, not `grep -v`: with `set -o pipefail` a grep that matches every line
# exits 1 and kills the substitution. The stamp is stripped rather than skipped
# over because the corruption check below resolves EVERY recorded id against the
# corpus root, and would report the stamp line as a severed fixture name.
OPENED="$(sed "/^$RUN_ID_PREFIX/d" "$MANIFEST" | sort -u)"

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
require_run_id "$SCENARIOS" "scenario replay ledger"
REPLAYED="$(sed "/^$RUN_ID_PREFIX/d" "$SCENARIOS" | sort -u)"

# Every scenario id the corpus carries, for the fixtures the suite OPENED, in
# the same `fixture<TAB>id` shape the ledger uses. Resolution order — `id`, else
# `name` — matches `scenarioIdOf` in test/conformance_manifest.dart exactly; if
# the two ever disagree the ledger stops matching and this check fails closed.
#
# There is no positional fallback (#lzspecscenarioids): an id derived from a
# POSITION silently rebinds to a different scenario when the corpus array is
# reordered, so an unidentified scenario is marked and reported rather than
# given an invented id.
#
# ONE function, TWO callers (#lzdartcoveragefloors). The walk below runs it over
# the fixtures the MANIFEST says were opened; the derived scenario expectation at
# the foot of this file runs it over the CORPUS LISTING minus KNOWN_UNCOVERED. A
# second copy of this jq would be a second definition of what a scenario is, and
# the two would disagree the first time the corpus grew a shape — which would
# then read as a coverage gap rather than as the drift it is.
scenario_ids() {
  jq -r --arg f "$1" '
    def identifier: if type == "string" and (gsub("\\s"; "") != "") then . else null end;
    if (.scenarios | type) == "array"
    then .scenarios | to_entries[]
         | "\($f)\t\((.value.id? | identifier) // (.value.name? | identifier) // "!UNIDENTIFIED!\(.key)")"
    else empty end' "$SPEC_DIR/$1"
}

EXPECTED="$(
  while IFS= read -r fixture; do
    [ -n "$fixture" ] || continue
    [ -f "$SPEC_DIR/$fixture" ] || continue
    scenario_ids "$fixture"
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

# ---- Positive evidence: DERIVED magnitudes, asserted EQUAL ----
#
# Everything above is a NEGATIVE check: it reasons about fixtures the run
# OPENED and scenarios the run REPLAYED, so all of it is vacuously satisfied by
# an empty population. Zero opened fixtures means zero uncovered fixtures, zero
# unreplayed scenarios, and zero stale excuses — nothing in this file can
# contradict a run that examined nothing. `missing -eq 0` cannot tell "nothing
# is wrong" apart from "nothing was measured", so assert the MAGNITUDE before
# printing OK.
#
# Both magnitudes used to be numbers typed into this file and compared with a
# `-lt` floor, re-pinned by hand from a green run (#lzdartcoveragefloors). Both
# halves of that shape were wrong, in the way the assertion-block magnitude in
# check-unbound-blocks.py already was (#lzblocksitepin):
#
#   * a TYPED number is re-pinned by hand, so it drifts by hand. The comment that
#     used to sit here spelled the ritual out — re-read the coverage lines from a
#     green run and set the number to that total — and a ritual nobody performs
#     on a green run is how that file's block floor sat 3 below reality;
#   * a FLOOR cannot see a shrink that stays above it, and a shrink is exactly
#     what a detached recorder looks like. These two had sat at 130/131 against
#     an actual 138/149 once already, so 8 fixtures and 18 scenarios could have
#     detached silently.
#
# They were also not what catches a SHRINKING CORPUS, which is the job a floor
# looks like it is doing. `lazily-spec/corpus-counts.json` pins the fixture total
# and `lazily-spec/scripts/check-corpus-floors.mjs` asserts it EQUAL across every
# binding, so a corpus that loses a fixture is refused centrally at one edit
# site — verified against a scratch copy with one fixture removed rather than
# assumed: "the corpus carries 155 fixtures; corpus-counts.json pins 156", exit
# 1. Ten hand-typed floors were the weaker half of that pair.
#
# The expectation is now the corpus listing minus this binding's own
# KNOWN_UNCOVERED, asserted EQUAL in both directions. The two loops above
# already enforce that composition fixture by fixture — every corpus fixture is
# opened or excused, and every excuse names a corpus fixture the run did NOT
# open — so `corpus \ KNOWN_UNCOVERED` IS the opened set and its CARDINALITY
# needs no second source of truth.
#
# What the equality adds over those two loops is the ARITHMETIC: a DUPLICATED
# excuse entry passes both directions — the fixture is in the corpus and the
# suite does not open it, once per copy — while the derived count drops by one
# per repeat. Nothing else in this file sees that; `KNOWN_UNREPLAYED_SCENARIOS`
# being empty and the "not listed twice" note above are a convention, not a
# check. That case is the equality's whole marginal value, and it is also the
# case whose equality message is misleading, which is why the duplicate checks
# come FIRST.
#
# Do not re-spell either retired constant in its assignment form anywhere under
# scripts/. check-corpus-floors.mjs greps this whole directory for that literal
# shape, so a commented-out example keeps the central audit comparing a number
# that no longer runs — the trap lazily-py fell into and lazily-rs shipped,
# where two retired spellings were still being read as declared floors of 150
# and 166 and passed only because the derivation happened to agree.

# The fixture-ledger duplicate check, AHEAD of the equality it protects.
uniq_known=0
if [ "${#KNOWN_UNCOVERED[@]}" -gt 0 ]; then
  dupes="$(printf '%s\n' "${KNOWN_UNCOVERED[@]}" | grep -v '^$' | sort | uniq -d || true)"
  if [ -n "$dupes" ]; then
    echo "ERROR: KNOWN_UNCOVERED lists the same fixture more than once:" >&2
    printf '         %s\n' $dupes >&2
    echo "       Both directions above still pass on a duplicate — the fixture is in" >&2
    echo "       the corpus and the suite does not open it, once per copy — while the" >&2
    echo "       derived opened count below silently drops by one per repeat. Delete" >&2
    echo "       the duplicates." >&2
    exit 1
  fi
  uniq_known="$(printf '%s\n' "${KNOWN_UNCOVERED[@]}" | grep -v '^$' | sort -u | wc -l)"
fi

if [ "$total" -eq 0 ]; then
  echo "ERROR: the corpus at $SPEC_DIR listed ZERO fixtures." >&2
  echo "       Every check above is vacuously green over an empty population, so" >&2
  echo "       this run proves nothing about conformance (#lzvacuousrun)." >&2
  exit 1
fi
expected_opened=$((total - uniq_known))
if [ "$expected_opened" -le 0 ]; then
  echo "ERROR: the corpus at $SPEC_DIR minus KNOWN_UNCOVERED derives $expected_opened" >&2
  echo "       fixtures to open. An expectation of zero is satisfied by opening" >&2
  echo "       nothing, which is a green badge over an empty comparison" >&2
  echo "       (#lzvacuousrun)." >&2
  exit 1
fi
if [ "$covered" -ne "$expected_opened" ]; then
  if [ "$covered" -lt "$expected_opened" ]; then
    echo "ERROR: only $covered distinct canonical fixtures were OPENED; the corpus at" >&2
    echo "       $SPEC_DIR minus KNOWN_UNCOVERED derives $expected_opened." >&2
    echo "       A replay was removed, renamed, or short-circuited, or the recorder" >&2
    echo "       detached mid-run. There is no number to lower here — the expectation" >&2
    echo "       is computed from the corpus, not typed." >&2
  else
    echo "ERROR: $covered distinct fixtures were OPENED but the corpus minus" >&2
    echo "       KNOWN_UNCOVERED derives only $expected_opened, so the manifest and the" >&2
    echo "       corpus this guard walked are not the same tree: a leftover manifest, a" >&2
    echo "       corpus that shrank underneath it, or LAZILY_SPEC_CONFORMANCE_DIR" >&2
    echo "       pointing the two halves at different trees." >&2
  fi
  exit 1
fi

echo "conformance coverage OK: $covered/$total canonical fixtures OPENED by the suite" \
     "($uniq_known listed as known-uncovered; $expected_opened DERIVED from the corpus" \
     "listing minus that ledger and asserted EQUAL; runtime manifest — these bytes were" \
     "really read)"

# The same treatment for the per-scenario rung. Its loop walks the scenarios of
# OPENED fixtures, so zero opened fixtures means zero scenarios, which means
# zero unreplayed scenarios — OK reported having compared nothing.
#
# `SCENARIO_TOTAL` is NOT the independent witness. It walks only fixtures the
# MANIFEST says were opened, so a detached recorder shrinks the manifest,
# SCENARIO_TOTAL and SCENARIO_REPLAYED together and an expectation derived from
# it follows them into the ditch. The walk below starts from the CORPUS LISTING
# minus KNOWN_UNCOVERED instead — the same composition whose cardinality the
# fixture rung just asserted — and resolves ids through the SAME `scenario_ids`
# the rung above uses.
#
# Unidentified ids are counted here exactly as the rung above counts them, so
# the two halves stay comparable. They cannot survive to this point anyway: the
# rung above books each one into `missing`, and `missing` exits before this.
DERIVED_OPENED=""
derived_scenario_total=0
while IFS= read -r fixture; do
  is_known=0
  for known in "${KNOWN_UNCOVERED[@]:-}"; do
    [ -n "$known" ] || continue
    if [ "$known" = "$fixture" ]; then is_known=1; break; fi
  done
  [ "$is_known" -eq 0 ] || continue
  DERIVED_OPENED+="$fixture"$'\n'
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    derived_scenario_total=$((derived_scenario_total + 1))
  done < <(scenario_ids "$fixture")
done < <(cd "$SPEC_DIR" && find . -name '*.json' | sed 's|^\./||' | sort)

# An excuse only subtracts when its fixture is one the corpus composition says
# is OPENED. An excuse naming an uncovered fixture contributes no scenario to
# `derived_scenario_total`, so counting it would take the expectation one below
# reality. The key is spelled the way the two directional loops above spell it,
# so there is one rule for what an entry names. Duplicates are refused first,
# for the same arithmetic reason KNOWN_UNCOVERED duplicates are.
excuse_keys=""
for item in "${KNOWN_UNREPLAYED_SCENARIOS[@]:-}"; do
  [ -n "$item" ] || continue
  entry="${item%|*}"
  excuse_keys+="${entry%%|*}|${entry#*|}"$'\n'
done
if [ -n "$excuse_keys" ]; then
  dupes="$(printf '%s' "$excuse_keys" | grep -v '^$' | sort | uniq -d || true)"
  if [ -n "$dupes" ]; then
    echo "ERROR: KNOWN_UNREPLAYED_SCENARIOS names the same fixture and scenario more" >&2
    echo "       than once:" >&2
    printf '         %s\n' $dupes >&2
    echo "       Both directions above still pass on a duplicate, while the derived" >&2
    echo "       replay count below silently drops by one per repeat. Delete the" >&2
    echo "       duplicates." >&2
    exit 1
  fi
fi
derived_excused=0
while IFS= read -r key; do
  [ -n "$key" ] || continue
  if grep -qxF "${key%%|*}" <<< "$DERIVED_OPENED"; then
    derived_excused=$((derived_excused + 1))
  fi
done <<< "$(printf '%s' "$excuse_keys" | grep -v '^$' | sort -u || true)"

if [ "$SCENARIO_TOTAL" -eq 0 ] || [ "$derived_scenario_total" -eq 0 ]; then
  echo "ERROR: ZERO scenarios were found across the OPENED fixtures." >&2
  echo "       The per-scenario rung above compared nothing and reported no gaps" >&2
  echo "       (#lzvacuousrun)." >&2
  exit 1
fi
expected_replayed=$((derived_scenario_total - derived_excused))
if [ "$expected_replayed" -le 0 ]; then
  echo "ERROR: the corpus at $SPEC_DIR minus KNOWN_UNCOVERED carries" >&2
  echo "       $derived_scenario_total scenario(s) and KNOWN_UNREPLAYED_SCENARIOS excuses" >&2
  echo "       $derived_excused of them, deriving an expectation of $expected_replayed." >&2
  echo "       An expectation of zero is a green badge over an empty comparison" >&2
  echo "       (#lzvacuousrun)." >&2
  exit 1
fi
if [ "$SCENARIO_REPLAYED" -ne "$expected_replayed" ]; then
  if [ "$SCENARIO_REPLAYED" -lt "$expected_replayed" ]; then
    echo "ERROR: only $SCENARIO_REPLAYED scenarios were REPLAYED; the corpus at" >&2
    echo "       $SPEC_DIR minus KNOWN_UNCOVERED carries $derived_scenario_total, less" >&2
    echo "       $derived_excused excused, deriving $expected_replayed." >&2
    echo "       A scenario dispatch stopped matching, or the ledger detached. There is" >&2
    echo "       no number to lower here — the expectation is computed from the corpus," >&2
    echo "       not typed." >&2
  else
    echo "ERROR: $SCENARIO_REPLAYED scenarios were REPLAYED but the corpus at" >&2
    echo "       $SPEC_DIR minus KNOWN_UNCOVERED derives only $expected_replayed" >&2
    echo "       ($derived_scenario_total carried, less $derived_excused excused)." >&2
    echo "       The ledger and the corpus this guard walked are not the same tree: a" >&2
    echo "       leftover ledger, a corpus that shrank underneath it, or" >&2
    echo "       LAZILY_SPEC_CONFORMANCE_DIR pointing the two halves apart." >&2
  fi
  exit 1
fi

echo "scenario replay OK: $SCENARIO_REPLAYED/$SCENARIO_TOTAL scenarios of the OPENED fixtures" \
     "were REPLAYED ($derived_excused excused; $expected_replayed DERIVED from the corpus" \
     "listing minus KNOWN_UNCOVERED and asserted EQUAL; runtime ledger)"
