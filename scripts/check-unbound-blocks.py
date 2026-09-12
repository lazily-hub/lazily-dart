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

Every check here reasons about a block the run INVENTORIED, so all of them are
vacuously satisfied by an empty population: zero inventoried blocks means zero
unbound blocks, reported OK having compared nothing (``#lzvacuousrun``). So the
SIZE of the population is asserted too, in two dimensions — SITES and distinct
CONTENT DIGESTS — both DERIVED from the canonical corpus minus this binding's
own ``KNOWN_UNCOVERED`` ledger, and both compared for EQUALITY rather than
floored (``#lzblocksitepin``). See ``derive_expected``.

The excused set carries a CEILING on top of its set equality
(``#lzledgerceiling``). An equality only says the ledger and the run AGREE, and
any consistent pair satisfies it — a commit that detaches binds and writes the
matching entries passes both directions, and the magnitude rung above cannot
see it either because a detached site is still declared. ``MAX_LEDGERED``
bounds how much may be excused at all, so the ledger can only shrink without a
deliberate edit.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TRACKER = os.path.join(REPO_ROOT, "test", "conformance_assertions.dart")

# The ledger of fixtures this binding does NOT open, and the CANONICAL corpus.
# Together they are the two on-disk inputs the block-population expectation is
# derived from (see `derive_expected`). Both move on their own; neither is typed
# here.
COVERAGE_GUARD = os.path.join(REPO_ROOT, "scripts", "check-conformance-coverage.sh")
COVERAGE_GUARD_NAME = "scripts/check-conformance-coverage.sh"


def canonical_corpus_dir() -> str:
    """The CANONICAL corpus — the ``lazily-spec`` sibling checkout.

    Deliberately NOT ``LAZILY_SPEC_CONFORMANCE_DIR``. The override says which
    bytes the run REPLAYED; this is the corpus the run is JUDGED AGAINST, and
    the comparison in `main` is only worth making while the two come from
    different places. An expectation that followed the override would shrink in
    step with a doctored copy and agree with itself — the vacuous green this
    rung exists to reject (#lzvacuousrun).
    That asymmetry is also what makes a perturbation probe possible: doctoring a
    scratch copy and pointing the override at it moves the INVENTORY alone.

    Computed from this file's location, not the process's cwd: the repo and its
    sibling sit side by side both locally and in CI
    (``$GITHUB_WORKSPACE/lazily-dart`` beside ``$GITHUB_WORKSPACE/lazily-spec``).
    """
    return os.path.join(os.path.dirname(REPO_ROOT), "lazily-spec", "conformance")

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

# A CEILING on the excused population (#lzledgerceiling).
#
# `KNOWN_UNBOUND_BLOCKS` is checked as a SET EQUALITY against the run, in both
# directions: an unbound block nobody excused fails, and an excuse the suite
# outlived fails as stale. That is the right shape, and it is still not enough,
# because set equality is satisfied by ANY CONSISTENT PAIR. A commit that
# detaches N binds AND writes the N matching entries passes both directions.
# Nothing else here catches it either — the magnitude rung compares DECLARED
# sites and digests against the canonical corpus, and a detached bind leaves the
# site declared, merely no longer bound, so both dimensions stay equal.
#
# A typed COUNT of the ledger would not fix it. A number that mirrors the
# current population is redundant with the equality above — equal sets have
# equal counts — so it carries no information and only adds a second edit site
# that drifts. That is the `MIN_BLOCKS` shape whose history is written out
# below.
#
# What closes the hole is a ceiling on how much MAY be excused. A ceiling is a
# POLICY, not a measurement: it does not move when the corpus moves, and it
# never needs re-pinning except deliberately and upward, in review. What it buys
# is that a regression and its excuse can no longer land in the same commit
# unnoticed — raising this line is the explicit act.
#
# Raise it ONLY for a block this binding genuinely cannot bind, carrying a reason
# that says what cannot be expressed, and expect to be asked why the capability
# cannot exist. Never raise it to park a block that is merely unbound today: that
# is the laundering this guard exists to refuse. The six entries above are here
# because the replay model has no `merge_cell` or `drain_exhausted` op;
# implementing those ops is what LOWERS this line, and it should only ever move
# in that direction.
MAX_LEDGERED = int(os.environ.get("MAX_LEDGERED_BLOCKS", "25"))

# Positive-evidence floors (#lzvacuousrun). Every check below reasons about
# blocks the run OPENED, so all of them are vacuously satisfied by an empty
# population: zero fixtures means zero unbound blocks and zero stale excuses,
# and "nothing is wrong" is indistinguishable from "nothing was measured".
#
# EXACT, with no margin, and pinned from a green local `make check`. Do NOT
# lower them to make a red run green: a drop means the corpus shrank or the
# ledger detached mid-run, and that is the finding.
#
# The BLOCK POPULATION is no longer one of these. `MIN_BLOCKS` used to be a
# typed constant compared with `>=`, and its own history is the ledger of why
# that shape does not work: 672 -> 674 -> 722, every step the same event — the
# corpus moved, a gate went red, and someone copied the gate's own output back
# into this file. The 722 pin was stale within 53 MINUTES of being written:
# lazily-spec 4010d99 ("replay: pin member framing with three rows, not one")
# landed three more blocks the same afternoon, and `>=` cannot notice the lag at
# all — a floor three below reality tolerates three blocks silently detaching,
# which is the failure the floor existed to catch. It is now DERIVED from the
# corpus and asserted EQUAL, in two dimensions; see `derive_expected`.
MIN_FIXTURES = int(os.environ.get("MIN_BLOCK_FIXTURES", "144"))
MIN_BOUND = int(os.environ.get("MIN_BOUND_BLOCKS", "697"))


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
    """Append every assertion block under [node] to [out] as (path, block).

    ONE walk, TWO callers (#lzblocksitepin): the loader-side inventory over the
    fixtures the run OPENED, and the expectation derived from the canonical
    corpus in `derive_expected`. Both go through here, so the two sides cannot
    disagree about what counts as a block or about how a SITE is spelled, and
    their counts are comparable by construction. A derivation that walked the
    corpus differently from the inventory it is compared against would be worse
    than the typed constant it replaces, because the disagreement would then
    read as a corpus problem.

    The rule is this binding's own, read out of the tracker by the caller: the
    `assertionBlockKeys` names, OBJECT values only (an array element is never a
    block here — `isAssertionBlockPath` in the tracker says the same), at any
    depth up to `attributionDepthLimit`.
    """
    if depth > limit:
        return
    if isinstance(node, dict):
        for key, value in node.items():
            child = key if not path else "{}.{}".format(path, key)
            if isinstance(value, dict) and key in keys:
                out.append((child, value))
            walk(value, child, depth + 1, limit, keys, out)
    elif isinstance(node, list):
        for index, value in enumerate(node):
            walk(value, "{}[{}]".format(path, index), depth + 1, limit, keys, out)


def block_digest(block) -> str:
    """A content key for one block: what it SAYS, independent of where it sits.

    Insertion order is preserved (json.load keeps it), so two blocks share a
    digest only when they are spelled the same way, which is what "the same
    claim" means here.
    """
    text = json.dumps(block, separators=(",", ":"), sort_keys=False)
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def site(fixture: str, path: str) -> str:
    """One assertion block OCCURRENCE. Unique per (fixture, path)."""
    return "{}|{}".format(fixture, path)


def known_uncovered_fixtures() -> set:
    """The fixtures this binding does not open, parsed out of the coverage guard.

    Restating them here would be a second copy to re-pin by hand — the defect
    being removed — and the array has to stay over there anyway: lazily-spec's
    check-corpus-floors.mjs classifies the ledger arrays declared in it and
    fails on an unclassified one.

    A missing or unparsable array is a HARD failure and never an empty set:
    deriving over corpus-minus-nothing would build a larger expectation out of
    fixtures this suite never opens, and report this guard's own blindness as a
    corpus problem.
    """
    if not os.path.isfile(COVERAGE_GUARD):
        die(
            "ERROR: cannot read {}, which holds the KNOWN_UNCOVERED ledger the".format(
                COVERAGE_GUARD_NAME
            ),
            "       assertion-block expectation is derived from.",
        )
    with open(COVERAGE_GUARD, encoding="utf-8") as handle:
        text = handle.read()
    marker = "\nKNOWN_UNCOVERED=(\n"
    start = text.find(marker)
    if start < 0:
        die(
            "ERROR: {} no longer declares a KNOWN_UNCOVERED=( array. The".format(
                COVERAGE_GUARD_NAME
            ),
            "       assertion-block expectation is derived from it, so a rename has to",
            "       be mirrored here rather than quietly deriving over a different set.",
        )
    body = text[start + len(marker) :]
    end = body.find("\n)\n")
    if end < 0:
        die(
            "ERROR: {}: the KNOWN_UNCOVERED=( array is never closed by a".format(
                COVERAGE_GUARD_NAME
            ),
            "       line holding only ')'.",
        )
    entries = set()
    for line in body[:end].split("\n"):
        trimmed = line.strip()
        if not trimmed or trimmed.startswith("#"):
            continue
        entries.update(re.findall(r'"([^"]+)"', trimmed))
    if not entries:
        die(
            "ERROR: {}: KNOWN_UNCOVERED parsed as EMPTY. Shrinking that".format(
                COVERAGE_GUARD_NAME
            ),
            "       list to nothing is the goal state, but so is a parser that has",
            "       stopped matching its entries, and the two are indistinguishable from",
            "       here. If the list is genuinely empty, relax this check deliberately.",
        )
    return entries


def corpus_fixtures(root: str) -> list:
    out = []
    for directory, _, files in os.walk(root):
        for name in files:
            if name.endswith(".json"):
                full = os.path.join(directory, name)
                out.append(os.path.relpath(full, root))
    return sorted(out)


def derive_expected(limit: int, keys: set) -> tuple:
    """``(fixtures, sites, digests)`` the fixtures this binding opens must carry.

    TWO dimensions, both derived, both asserted EQUAL, because each is blind to
    what the other sees (#lzblocksitepin):

      * a DIGEST count deduplicates by content, so deleting a block whose bytes
        recur at another site leaves it unmoved — the equality stays green over
        a run that LOST a block. 109 of this corpus's sites carry a shape that
        occurs somewhere else, and every one of them is individually invisible
        to this dimension.
      * a SITE count ('<fixture>|<where>', one per occurrence) cannot see a
        content edit that collapses two distinct claims onto one shape: the same
        blocks are still there, and they now say one thing where they said two.

    Neither number is typed. The two inputs are the canonical corpus DIRECTORY
    LISTING and this binding's own committed KNOWN_UNCOVERED ledger, and corpus
    MINUS ledger is exactly the set this suite opens —
    check-conformance-coverage.sh asserts that same identity from the other
    side, failing both when a corpus fixture outside the ledger is not opened
    and when one inside it is. So a fixture landing upstream moves these numbers
    with no edit here, and a fixture this binding stops opening moves them only
    through a committed ledger line.

    What this deliberately does NOT read: the runtime manifest, the bound-block
    ledger, or anything else the run produced. An expectation derived from what
    the run read follows the actual count into the ditch — let the recorder
    detach and both go to zero, green over nothing.

    Compared as SETS rather than magnitudes: two blocks that moved cancel in a
    count and cannot cancel in a set.
    """
    root = canonical_corpus_dir()
    if not os.path.isdir(root):
        die(
            "ERROR: cannot derive the assertion-block expectation: the canonical",
            "       corpus is not at {}.".format(root),
            "       Clone the lazily-spec sibling. Pointing",
            "       LAZILY_SPEC_CONFORMANCE_DIR somewhere else does not substitute for",
            "       it — these numbers are what the run is judged AGAINST, not what it",
            "       replayed.",
        )
    excused = known_uncovered_fixtures()
    sites = {}
    digests = {}
    fixtures = 0
    for fixture in corpus_fixtures(root):
        if fixture in excused:
            continue
        fixtures += 1
        try:
            with open(os.path.join(root, fixture), encoding="utf-8") as handle:
                decoded = json.load(handle)
        except (OSError, ValueError) as error:
            # NOT a `continue`, unlike the inventory walk in main(): there the
            # fixture is one the run already parsed, here an unparsable file
            # would silently subtract its blocks from the expectation and make
            # the comparison agree with a corpus nobody can read.
            die(
                "ERROR: cannot derive the assertion-block expectation: '{}'".format(
                    fixture
                ),
                "       under {} is unreadable or is not JSON ({}).".format(
                    root, error
                ),
                "       A fixture that cannot be parsed is missing evidence, not a",
                "       fixture carrying no blocks.",
            )
        blocks = []
        walk(decoded, "", 0, limit, keys, blocks)
        for path, block in blocks:
            key = block_digest(block)
            sites[site(fixture, path)] = key
            digests.setdefault(key, site(fixture, path))
    # Zero-guard on EVERY dimension. Zero compares equal to an inventory of
    # zero, which is this rung reporting OK over nothing at all — reached from
    # the expectation side instead of the inventory side.
    if fixtures == 0 or not sites or not digests:
        die(
            "ERROR: deriving the assertion-block expectation over {} found".format(
                root
            ),
            "       {} fixture(s), {} site(s) and {} distinct block(s).".format(
                fixtures, len(sites), len(digests)
            ),
            "       An expectation of zero in EITHER dimension is satisfied by an",
            "       inventory of zero, which is the vacuous green this rung exists to",
            "       reject (#lzvacuousrun). The corpus path is wrong, or the ledger",
            "       excused all of it.",
        )
    return fixtures, sites, digests


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

    # The ceiling, before anything else is read (#lzledgerceiling). It is the
    # one check here that needs no evidence from the run at all — it is a policy
    # about the committed ledger — so it reports first and on its own terms,
    # rather than behind a manifest or a corpus derivation that could fail for
    # unrelated reasons.
    if len(excuses) > MAX_LEDGERED:
        die(
            "ERROR: {} assertion-block site(s) are ledgered as unbound; the "
            "ceiling is {}.".format(len(excuses), MAX_LEDGERED),
            "       The ledger may only SHRINK. It is checked as a set EQUALITY",
            "       against the run, and an equality only says the ledger and the run",
            "       AGREE — any consistent pair satisfies it, including a commit that",
            "       detaches binds and writes the matching entries. The magnitude rung",
            "       misses that too, because a detached site is still DECLARED. This",
            "       ceiling is what makes enlarging the excused set an explicit act",
            "       instead of a side effect.",
            "       Bind the block. Raise MAX_LEDGERED_BLOCKS only for a block this",
            "       binding genuinely cannot bind, with a reason saying what cannot be",
            "       expressed.",
        )

    carried = {}
    # The inventory's two dimensions, held as maps rather than counts so a
    # failure can name the blocks that differ instead of only the magnitude of
    # the difference (#lzblocksitepin).
    declared_sites = {}
    declared_digests = {}
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
        carried[fixture] = [block_path for block_path, _ in blocks]
        for block_path, block in blocks:
            key = block_digest(block)
            declared_sites[site(fixture, block_path)] = key
            declared_digests.setdefault(key, site(fixture, block_path))

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
    # The MAGNITUDE of what was inventoried, in two derived dimensions, both
    # asserted EQUAL (#lzblocksitepin). Zero unbound blocks out of zero
    # inventoried blocks reports OK having compared nothing, so the SIZE of the
    # population is evidence in its own right — and it is derived from the
    # canonical corpus plus this binding's own ledger, never typed here. See
    # `derive_expected` for why both dimensions are needed and why neither is a
    # floor.
    #
    # Both dimensions are reported TOGETHER rather than short-circuiting on the
    # first, so a reader (and a perturbation probe) can see which one moved and
    # which stayed silent.
    expected_fixtures, expected_sites, expected_digests = derive_expected(limit, keys)
    magnitude = []
    missing_sites = sorted(set(expected_sites) - set(declared_sites))
    extra_sites = sorted(set(declared_sites) - set(expected_sites))
    if missing_sites or extra_sites:
        magnitude.append(
            "ERROR: the run inventoried {} assertion-block SITES, but the canonical "
            "corpus".format(len(declared_sites))
        )
        magnitude.append(
            "       plus this binding's own ledger say {}.".format(len(expected_sites))
        )
        magnitude.append(
            "       Expected: every assertion block carried by the {} fixture(s) under".format(
                expected_fixtures
            )
        )
        magnitude.append(
            "       {} that are not in KNOWN_UNCOVERED ({}),".format(
                canonical_corpus_dir(), COVERAGE_GUARD_NAME
            )
        )
        magnitude.append(
            "       counted by SITE — '<fixture>|<where>' — and NOT deduplicated by"
        )
        magnitude.append(
            "       content. A site the corpus carries and the run does not is a block"
        )
        magnitude.append(
            "       that detached; the digest dimension below cannot see it whenever"
        )
        magnitude.append("       that block's content recurs at another site.")
        for label, listing in (
            ("the corpus carries and the run does NOT", missing_sites),
            ("the run carries and the corpus derivation does NOT", extra_sites),
        ):
            if not listing:
                continue
            magnitude.append("       {} site(s) {}:".format(len(listing), label))
            for entry in listing[:20]:
                magnitude.append("         {}".format(entry))
            if len(listing) > 20:
                magnitude.append(
                    "         ... and {} more".format(len(listing) - 20)
                )
        magnitude.append(
            "       There is nothing to re-pin: these numbers are derived, not typed."
        )
    missing_digests = sorted(set(expected_digests) - set(declared_digests))
    extra_digests = sorted(set(declared_digests) - set(expected_digests))
    if missing_digests or extra_digests:
        magnitude.append(
            "ERROR: the run inventoried {} DISTINCT assertion blocks, but the "
            "canonical".format(len(declared_digests))
        )
        magnitude.append(
            "       corpus plus this binding's own ledger say {}.".format(
                len(expected_digests)
            )
        )
        magnitude.append(
            "       Blocks are counted by CONTENT DIGEST here, so this dimension sees a"
        )
        magnitude.append(
            "       content edit that collapsed two distinct claims onto one shape — a"
        )
        magnitude.append(
            "       change the site count above cannot see, because the sites are all"
        )
        magnitude.append("       still there.")
        for label, listing, where in (
            ("the corpus says and the run does NOT", missing_digests, expected_digests),
            (
                "the run says and the corpus derivation does NOT",
                extra_digests,
                declared_digests,
            ),
        ):
            if not listing:
                continue
            magnitude.append(
                "       {} distinct block(s) {} (one site each):".format(
                    len(listing), label
                )
            )
            for entry in listing[:20]:
                magnitude.append("         {}".format(where[entry]))
            if len(listing) > 20:
                magnitude.append(
                    "         ... and {} more".format(len(listing) - 20)
                )
        magnitude.append(
            "       There is nothing to re-pin: these numbers are derived, not typed."
        )
    if magnitude:
        magnitude.append(
            "       Either the CORPUS MOVED under this checkout — re-pull the"
        )
        magnitude.append(
            "       lazily-spec sibling, and say so in KNOWN_UNCOVERED if this binding"
        )
        magnitude.append(
            "       now opens a different set — or the run's INVENTORY DETACHED and"
        )
        magnitude.append(
            "       fixtures stopped being opened, or stopped being walked. Running"
        )
        magnitude.append(
            "       against a doctored or older copy via LAZILY_SPEC_CONFORMANCE_DIR"
        )
        magnitude.append("       shows up here too, which is the point.")
        die(*magnitude)

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
        "were BOUND by the suite ({} excused of at most {}; runtime ledger — these "
        "blocks were really passed to a tracker; the ledger is an EQUALITY against "
        "the run under a CEILING that makes enlarging it an explicit act). "
        "Population {} site(s) and {} distinct content "
        "digest(s), BOTH DERIVED from the {} fixture(s) the canonical corpus carries "
        "minus KNOWN_UNCOVERED by the same walk the inventory uses, and BOTH asserted "
        "EQUAL, not floored — the site dimension sees a block detach while its "
        "content survives at a twin site, which digest dedup hides, and the digest "
        "dimension sees two claims collapse onto one shape, which the site count "
        "hides".format(
            bound_count,
            total,
            examined,
            len(excuses),
            MAX_LEDGERED,
            len(expected_sites),
            len(expected_digests),
            expected_fixtures,
        )
    )


if __name__ == "__main__":
    main()
