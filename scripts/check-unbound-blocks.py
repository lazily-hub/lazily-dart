#!/usr/bin/env python3
"""Unbound-assertion-block guard (#lzunboundblockguard).

Every guard in ``test/conformance_assertions.dart`` proves something about a
block a runner REACHED: an unconsumed key, a key read but never asserted, an
object value compared without its key set. All of them are blind to a block no
runner ever BINDS. ``assertionsOf`` is the only entry point that registers a
block with the tracker, so a block nothing passes in contributes no tracker, no
complaint, and no evidence — it simply is not there.

That is not hypothetical. Every per-frame ``assertions`` block of
``signaling/frames.json`` (17 frames, 9 keys) was dead for exactly this reason,
and it was found by FLIPPING FIXTURE VALUES and watching the suite stay green
(#lzperturbaudit), not by any guard. Commit d5ccebd bound them; nothing stopped
the next one.

So the suite writes a third evidence channel. ``conformance_assertions.dart``
appends ``fixture<TAB>path`` to ``LAZILY_CONFORMANCE_BLOCKS`` at BIND time, and
this script walks every fixture the runtime manifest says was OPENED,
enumerates the assertion-bearing blocks it carries, and fails on any the ledger
does not name.

Read it the way ``check-conformance-coverage.sh`` is read — the two are the
same idea one rung apart. That one asks whether a FILE was opened and which of
its SCENARIOS were replayed; this one asks whether the assertion BLOCKS inside
the fixtures that were opened were bound to anything at all.

Run it AFTER the suite. ``make check`` orders it that way, because it reads the
evidence the run just wrote.
"""

from __future__ import annotations

import json
import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TRACKER = os.path.join(REPO_ROOT, "test", "conformance_assertions.dart")

# Blocks deliberately not bound by this binding, as (fixture, path, reason).
#
# One rung below `KNOWN_UNREPLAYED_SCENARIOS` in check-conformance-coverage.sh,
# and read the same way: that list names scenarios inside files this binding
# opens, this one names assertion BLOCKS inside steps this binding cannot run.
#
# Checked in BOTH directions, exactly like every other ledger here. An entry
# naming a block the suite DID bind fails as stale — an excuse that hides
# nothing reads as a known gap and buries the real ones — and an entry naming a
# path the corpus does not carry fails as rot.
#
# A reason must say what this binding cannot express. "Not implemented yet" is
# not one: implement it.
KNOWN_UNBOUND_BLOCKS = [
    # reactive_graph_conformance_test.dart's runnability filter SKIPs these six
    # fixtures for BOTH execution models, and prints the reason per fixture:
    # five need the `merge_cell` op and one needs `drain_exhausted`, neither of
    # which the Dart replay model implements. The files are still OPENED — the
    # filter has to read the op stream to decide — so their per-step `expect`
    # blocks are visible here while no step ever runs. Implementing the ops is
    # what deletes these entries; there is nothing to bind them to until then.
    (
        "reactive-graph/exact_fold_paths_stay_exact.json",
        "steps[{}].expect",
        "the replay model has no `merge_cell` op, so the runnability filter "
        "skips this fixture for both execution models",
        (2, 3, 4),
    ),
    (
        "reactive-graph/feedback_drain_bound_reports_exhaustion.json",
        "steps[{}].expect",
        "the replay model has no `drain_exhausted` op, so the runnability "
        "filter skips this fixture for both execution models",
        (1, 2, 3),
    ),
    (
        "reactive-graph/merge_cell_acquires_no_dependency_edge.json",
        "steps[{}].expect",
        "the replay model has no `merge_cell` op, so the runnability filter "
        "skips this fixture for both execution models",
        (1, 2, 3, 4),
    ),
    (
        "reactive-graph/merge_feed_through_a_formula_coalesces.json",
        "steps[{}].expect",
        "the replay model has no `merge_cell` op, so the runnability filter "
        "skips this fixture for both execution models",
        (2, 3, 4, 5, 6, 7),
    ),
    (
        "reactive-graph/merge_folds_synchronously_in_batch.json",
        "steps[{}].expect",
        "the replay model has no `merge_cell` op, so the runnability filter "
        "skips this fixture for both execution models",
        (1, 2, 3),
    ),
    (
        "reactive-graph/merge_per_settled_cone_not_per_write.json",
        "steps[{}].expect",
        "the replay model has no `merge_cell` op, so the runnability filter "
        "skips this fixture for both execution models",
        (1, 2, 3, 4, 5, 6),
    ),
]

# Positive-evidence floors (#lzvacuousrun). Every check below reasons about
# blocks the run OPENED, so all of them are vacuously satisfied by an empty
# population: zero fixtures means zero unbound blocks and zero stale excuses,
# and "nothing is wrong" is indistinguishable from "nothing was measured".
#
# EXACT, with no margin, and pinned from a green local `make check`. Do NOT
# lower them to make a red run green: a drop means the corpus shrank or the
# ledger detached mid-run, and that is the finding.
MIN_FIXTURES = int(os.environ.get("MIN_BLOCK_FIXTURES", "138"))
MIN_BLOCKS = int(os.environ.get("MIN_BLOCKS", "672"))
MIN_BOUND = int(os.environ.get("MIN_BOUND_BLOCKS", "647"))


def die(*lines: str) -> None:
    for line in lines:
        print(line, file=sys.stderr)
    sys.exit(1)


def expand_excuses() -> list:
    out = []
    for fixture, template, reason, indexes in KNOWN_UNBOUND_BLOCKS:
        for index in indexes:
            out.append((fixture, template.format(index), reason))
    return out


def tracker_source() -> str:
    with open(TRACKER, encoding="utf-8") as handle:
        return handle.read()


def tracker_block_keys(source: str) -> set:
    """The block key names the TRACKER recognises, read out of its source.

    Spelling the set here instead would be a second definition of what an
    assertion block is, and the two would drift the first time the corpus grew
    a new block name. The Dart const is the one definition.
    """
    match = re.search(r"const assertionBlockKeys = <String>\{(.*?)\};", source, re.S)
    if match is None:
        die(
            "FAIL: could not find `assertionBlockKeys` in {}.".format(TRACKER),
            "      This script reads the block-name set out of the tracker so the",
            "      two cannot disagree; a rename there must not silently turn this",
            "      guard into a walk over nothing.",
        )
    keys = set(re.findall(r"'([^']+)'", match.group(1)))
    if not keys:
        die("FAIL: `assertionBlockKeys` in {} is EMPTY.".format(TRACKER))
    return keys


def tracker_depth_limit(source: str) -> int:
    """The attribution depth bound, read out of the tracker for the same reason.

    ``attributeFixture`` stops walking past it, so a block deeper than this can
    never be recorded as bound. Enumerating it here anyway would manufacture a
    failure nothing could clear.
    """
    match = re.search(r"const attributionDepthLimit = (\d+);", source)
    if match is None:
        die("FAIL: could not find `attributionDepthLimit` in {}.".format(TRACKER))
    return int(match.group(1))


def walk(node, path, depth, limit, keys, out):
    if depth > limit:
        return
    if isinstance(node, dict):
        for key, value in node.items():
            child = key if not path else "{}.{}".format(path, key)
            if isinstance(value, dict) and key in keys:
                out.append(child)
            walk(value, child, depth + 1, limit, keys, out)
    elif isinstance(node, list):
        for index, value in enumerate(node):
            walk(value, "{}[{}]".format(path, index), depth + 1, limit, keys, out)


def main() -> None:
    spec_dir = os.environ.get(
        "LAZILY_SPEC_CONFORMANCE_DIR", "../lazily-spec/conformance"
    )
    manifest = os.environ.get(
        "LAZILY_CONFORMANCE_MANIFEST", "build/conformance-fixtures-loaded.txt"
    )
    ledger_path = os.environ.get(
        "LAZILY_CONFORMANCE_BLOCKS", "build/conformance-blocks-bound.txt"
    )

    # A missing corpus is a legitimate LOCAL state and an illegitimate CI one,
    # exactly as in check-conformance-coverage.sh: without it every check here
    # is vacuously true and this script would report OK having examined zero
    # blocks.
    if not os.path.isdir(spec_dir):
        if os.environ.get("CI"):
            die(
                "ERROR: canonical corpus not found at {}, and CI is set.".format(
                    spec_dir
                ),
                "       Exiting 0 here would report block binding OK having examined",
                "       zero blocks (#lzvacuousrun).",
            )
        print(
            "SKIP: canonical corpus not found at {} (clone the lazily-spec "
            "sibling)".format(spec_dir),
            file=sys.stderr,
        )
        print(
            "      Local checkout only — this is a hard failure under CI.",
            file=sys.stderr,
        )
        return

    if not os.path.isfile(manifest) or os.path.getsize(manifest) == 0:
        die(
            "FAIL: no conformance manifest at {}.".format(manifest),
            "      Run the suite with LAZILY_CONFORMANCE_MANIFEST set (`make test`).",
            "      An absent manifest is missing evidence, not evidence of absence.",
        )
    if not os.path.isfile(ledger_path) or os.path.getsize(ledger_path) == 0:
        die(
            "FAIL: no bound-block ledger at {}.".format(ledger_path),
            "      Run the suite with LAZILY_CONFORMANCE_BLOCKS set (`make test`) so",
            "      the recorder in test/conformance_assertions.dart attaches. An",
            "      empty ledger would report EVERY block unbound, which is missing",
            "      evidence, not evidence of absence.",
        )

    with open(manifest, encoding="utf-8") as handle:
        opened = sorted({line.strip() for line in handle if line.strip()})
    with open(ledger_path, encoding="utf-8") as handle:
        bound = {line.rstrip("\n") for line in handle if line.strip()}

    source = tracker_source()
    keys = tracker_block_keys(source)
    limit = tracker_depth_limit(source)
    excuses = expand_excuses()
    excused = {(fixture, path) for fixture, path, _ in excuses}

    carried = {}
    examined = 0
    for fixture in opened:
        path = os.path.join(spec_dir, fixture)
        if not os.path.isfile(path):
            # The manifest's own integrity is check-conformance-coverage.sh's
            # job; not re-reporting it here keeps one voice per finding.
            continue
        examined += 1
        blocks = []
        with open(path, encoding="utf-8") as handle:
            walk(json.load(handle), "", 0, limit, keys, blocks)
        carried[fixture] = blocks

    # The vacuity floors come FIRST (#lzvacuousrun). Every check below reasons
    # about blocks the run OPENED, so all of them are vacuously satisfied by an
    # empty population — and a run that measured nothing must say so, rather
    # than report whatever the excuse list happens to disagree with.
    total = sum(len(blocks) for blocks in carried.values())
    if examined == 0:
        die(
            "ERROR: ZERO opened fixtures were examined.",
            "       Every check below is vacuously green over an empty population,",
            "       so this run proves nothing about block binding (#lzvacuousrun).",
        )
    if total == 0:
        die(
            "ERROR: the {} opened fixtures carried ZERO assertion blocks.".format(
                examined
            ),
            "       The walk found nothing to check — either the block-name set is",
            "       wrong or the corpus is not what this guard thinks it is.",
        )
    if examined < MIN_FIXTURES:
        die(
            "ERROR: only {} opened fixtures were examined, expected >= {}.".format(
                examined, MIN_FIXTURES
            ),
            "       A replay was removed or the recorder detached mid-run. Do not",
            "       lower MIN_BLOCK_FIXTURES to fix this.",
        )
    if total < MIN_BLOCKS:
        die(
            "ERROR: only {} assertion blocks were found across {} fixtures, "
            "expected >= {}.".format(total, examined, MIN_BLOCKS),
            "       Do not lower MIN_BLOCKS to fix this.",
        )

    problems = 0
    bound_count = 0
    for fixture in sorted(carried):
        for block in carried[fixture]:
            if "{}\t{}".format(fixture, block) in bound:
                bound_count += 1
                continue
            if (fixture, block) in excused:
                continue
            print(
                "ERROR: '{}' carries an assertion block at '{}' that NO runner "
                "bound.".format(fixture, block),
                file=sys.stderr,
            )
            print(
                "       Nothing passed it to assertionsOf(), so every key guard in",
                file=sys.stderr,
            )
            print(
                "       test/conformance_assertions.dart is blind to it and replaying",
                file=sys.stderr,
            )
            print(
                "       the fixture proves nothing about it. Bind it, or add it to",
                file=sys.stderr,
            )
            print("       KNOWN_UNBOUND_BLOCKS with a reason.", file=sys.stderr)
            problems += 1

    # The evidence channel guards itself, as the manifest's and the scenario
    # ledger's do: a recorded block the corpus does not carry means the ledger
    # was corrupted in transit or a runner recorded something it never bound,
    # and a verdict computed from it cannot be trusted.
    for entry in sorted(bound):
        fixture, _, block = entry.partition("\t")
        if fixture not in carried:
            # Blocks recorded for the vendored mirror, or for a fixture the
            # manifest deliberately ignores, are not evidence of corruption.
            continue
        if block not in carried[fixture]:
            print(
                "ERROR: the block ledger records '{}' for '{}', which carries no "
                "such assertion block.".format(block, fixture),
                file=sys.stderr,
            )
            print(
                "       Either the ledger is dropping or interleaving writes, or a",
                file=sys.stderr,
            )
            print("       runner recorded a block it invented.", file=sys.stderr)
            problems += 1

    # A stale excuse, in the same three directions the other ledgers use.
    for fixture, block, reason in excuses:
        if not reason.strip():
            print(
                "ERROR: KNOWN_UNBOUND_BLOCKS entry '{} {}' carries no reason.".format(
                    fixture, block
                ),
                file=sys.stderr,
            )
            problems += 1
        if block not in carried.get(fixture, []):
            print(
                "ERROR: KNOWN_UNBOUND_BLOCKS names '{}' in '{}', which is not a "
                "block that fixture carries".format(block, fixture),
                file=sys.stderr,
            )
            print(
                "       (or the fixture is not opened at all). The excuse is stale —",
                file=sys.stderr,
            )
            print("       delete or correct it.", file=sys.stderr)
            problems += 1
            continue
        if "{}\t{}".format(fixture, block) in bound:
            print(
                "ERROR: KNOWN_UNBOUND_BLOCKS names '{}' in '{}', but the suite DID "
                "bind it.".format(block, fixture),
                file=sys.stderr,
            )
            print(
                "       The excuse is stale — it now misreports a covered block as a",
                file=sys.stderr,
            )
            print("       known gap. Delete the entry.", file=sys.stderr)
            problems += 1

    if problems:
        die("unbound-block guard FAILED: {} problem(s)".format(problems))

    if bound_count < MIN_BOUND:
        die(
            "ERROR: only {} assertion blocks were BOUND, expected >= {}.".format(
                bound_count, MIN_BOUND
            ),
            "       A binding was removed or short-circuited. Do not lower",
            "       MIN_BOUND_BLOCKS to fix this.",
        )

    print(
        "unbound-block guard OK: {}/{} assertion blocks across {} opened fixtures "
        "were BOUND by the suite ({} excused; runtime ledger — these blocks were "
        "really passed to a tracker)".format(
            bound_count, total, examined, len(excuses)
        )
    )


if __name__ == "__main__":
    main()
