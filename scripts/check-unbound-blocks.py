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

The excused set carries a SIZE PIN on top of its set equality
(``#lzledgerratchet``). An equality only says the ledger and the run AGREE, and
any consistent pair satisfies it — a commit that detaches binds and writes the
matching entries passes both directions, and the magnitude rung above cannot
see it either because a detached site is still declared.
``EXPECTED_LEDGERED`` is compared for EQUALITY, in both directions, against a
committed constant that the corpus cannot move; see its comment for why a
one-sided bound on the same number self-disables after the first migration.
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

# ---------------------------------------------------------------------------
# The evidence belongs to THIS invocation (#lzstalemanifest)
# ---------------------------------------------------------------------------
#
# This guard reads two files — the fixture manifest and the bound-block ledger —
# written by the 69 ``dart test`` child processes of an EARLIER make step, and
# until now it had no way to tell this run's bytes from last week's. Measured
# before the stamp existed: ``make unbound-block-check`` with no test run in the
# invocation printed the full "712/737 assertion blocks ... these blocks were
# really passed to a tracker" off the previous run's ledger, and a five-test
# ``dart test test/topic_test.dart`` appending to those files printed the same.
#
# ``dart test`` caches nothing, so this is not Gradle's ``UP-TO-DATE``; it is the
# leftover file. ``#lzsiblingrunnermasking`` ran each of 69 test files alone
# against its own manifest, which is precisely how one gets left behind.
#
# The recorder in test/conformance_manifest.dart writes the stamp as the FIRST
# line of each evidence file, under the same lock the records take, keyed off an
# empty file so it lands once per truncation. Same prefix in every binding.
RUN_ID_ENV = "LAZILY_CONFORMANCE_RUN_ID"
RUN_ID_PREFIX = "# lazily-run-id "


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

# The SIZE of the excused population, pinned and compared for EQUALITY
# (#lzledgerratchet).
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
# So the hole is closed by a number the corpus CANNOT MOVE. The set equality
# compares the ledger against the RUN, and both sides move together under that
# attack; this compares it against a COMMITTED CONSTANT, which does not move at
# all. That independence is the whole value, and it is why the number is not
# redundant with the equality above even though equal sets have equal counts.
#
# It is compared EXACTLY, both directions, and that is the correction
# #lzledgerratchet made to the one-sided `<=` bound this line used to be. A
# one-sided bound SELF-DISABLES. It refuses the detach-and-excuse commit only
# while slack is zero; the first genuine migration shrinks the ledger, leaves the
# constant where it is, and hands the next such commit a free slot. Repeat per
# migration and the bound converges on exactly the `MIN_BLOCKS` defect written
# out below: a number so far above reality that it never fires and so is never
# updated. An equality has no slack by construction and cannot drift silently,
# because a stale value FAILS — a number that fails when stale is a ratchet, not
# a floor.
#
# Both directions are things a person must see. GROWTH means an excuse was
# added: legitimate only for a block this binding genuinely cannot bind, with a
# reason saying what cannot be expressed (a corpus that gains a genuinely
# unreachable fixture is the real case), and expect to be asked why the
# capability cannot exist. Never raise it to park a block that is merely unbound
# today — that is the laundering this guard exists to refuse. SHRINK means sites
# were migrated and this line was not lowered in the same commit; lower it, in
# that commit, so the ratchet stays tight. Either way the edit is deliberate and
# visible in the diff, which is the point.
#
# The 25 sites above are here because the replay model has no `merge_cell` or
# `drain_exhausted` op; implementing those ops is what LOWERS this number, and
# it should only ever move in that direction.
EXPECTED_LEDGERED_RAW = os.environ.get("EXPECTED_LEDGERED_BLOCKS", "25")
# ONE parse for the whole family (#lzpinparsestrict): a NON-EMPTY run of bare
# ASCII digits `0`-`9`, and nothing else. Validated BEFORE any parse runs, and
# deliberately stricter than `int()`, `str.isdigit()` AND `re.fullmatch(r"\d+")`,
# because every one of those silently accepts a number nobody wrote:
# `int("1_0")` is 10 (PEP 515 separators), `int(" 7 ")` is 7, and both
# `"\u0663".isdigit()` and `re.fullmatch(r"\d+", "\u0663")` match the Arabic-Indic
# three — Python's `\d` is UNICODE against a `str`, not ASCII, which is exactly
# what this reader used to rely on. Refused now: whitespace around or inside
# (this reader used to `.strip()` first, so `" 7 "` became 7), a leading `+` or
# `-`, separators, a radix prefix, a float or an exponent, and any non-ASCII
# digit. A negative falls out of the same check — no ledger size can equal it, so
# it would make this rung unsatisfiable rather than exact. Leading zeros are fine
# and `0` stays valid; this number goes to 0 when the `merge_cell` and
# `drain_exhausted` ops land.
#
# An UNSET variable takes the committed literal above. An EXPLICITLY EMPTY one is
# a REJECTION, not a fall-through to it: `os.environ.get(NAME, DEFAULT)`
# distinguishes the two, and whoever exported the wrong thing is the one person
# who cannot see that it was ignored.
if not EXPECTED_LEDGERED_RAW or EXPECTED_LEDGERED_RAW.strip("0123456789"):
    # FAIL CLOSED, never fall back to the default. A pin that cannot be read is
    # an unknown policy, and silently substituting the committed default would
    # let an override typo report this rung as enforced while enforcing a number
    # nobody asked for.
    print(
        "ERROR: EXPECTED_LEDGERED_BLOCKS is {!r}, which is not a non-negative "
        "integer in bare ASCII digits (#lzpinparsestrict).".format(
            EXPECTED_LEDGERED_RAW
        ),
        file=sys.stderr,
    )
    print(
        "       This pin is the excused-ledger size, compared for EQUALITY. An",
        file=sys.stderr,
    )
    print(
        "       unreadable pin fails closed rather than falling back to the",
        file=sys.stderr,
    )
    print(
        "       committed default, which would report a policy that is not the one",
        file=sys.stderr,
    )
    print("       in force.", file=sys.stderr)
    sys.exit(1)
EXPECTED_LEDGERED = int(EXPECTED_LEDGERED_RAW)

# There are NO positive-evidence floors here any more (#lzdartboundfloor).
#
# There used to be three. `MIN_BLOCKS` went first: a typed site count compared
# with `>=`, whose own history is the ledger of why the shape does not work.
# 672 -> 674 -> 722, every step the same event — the corpus moved, the gate went
# red, and someone copied the gate's own output back into this file. The 722 pin
# was stale within 53 MINUTES of being written (lazily-spec 4010d99, "replay: pin
# member framing with three rows, not one", landed three more blocks the same
# afternoon), and `>=` cannot notice the lag at all: a floor three below reality
# tolerates three blocks silently detaching, which is the failure the floor
# existed to catch. It is DERIVED from the corpus and asserted EQUAL in two
# dimensions now; see `derive_expected`.
#
# `MIN_BOUND_BLOCKS` and `MIN_BLOCK_FIXTURES` have now gone the same way, and for
# a sharper reason than redundancy: both were IMPLIED by rungs that already run,
# so neither could ever do anything but agree, while drifting by hand in between.
#
#   * bound = declared - ledgered. `derive_expected` asserts the declared SITE
#     SET equal to the canonical corpus minus KNOWN_UNCOVERED, and
#     `EXPECTED_LEDGERED` pins the ledger size as an exact equality in both
#     directions. Once the `problems` gate below has passed, every declared site
#     is either bound or excused and the two sets are disjoint, so `bound_count`
#     is DETERMINED at 725 - 25 = 700. A floor could only restate it.
#   * `MIN_BLOCK_FIXTURES` was subsumed one rung up rather than here. 8 of the
#     144 opened fixtures (all of `statechart/`) carry no assertion block at all,
#     so the site set spans only 136 of them and the fixture set is NOT implied
#     by the site-set equality — but check-conformance-coverage.sh asserts the
#     opened set equal to corpus-minus-KNOWN_UNCOVERED from the other side, and
#     it names the fixture that went missing instead of reporting a magnitude.
#
# And a floor is not merely redundant here, it is WEAKER than what remains.
# `MIN_BOUND_BLOCKS` sat at 697 against a real 700, and a detach-plus-excuse
# commit that took bound to 699 reached the floor and passed it — verified, not
# argued. Slack is the whole defect: an exact pin fails when it goes stale, a
# floor with slack passes.
#
# What stays is the VACUITY GUARDS (#lzvacuousrun), which are not floors and are
# not implied by anything: every check here reasons about a population that can
# be empty, and zero declared means zero ledgered means zero bound, so an empty
# run satisfies every equality above by comparing nothing. Those live in `main`
# as `examined == 0` and `total == 0`, and `derive_expected` carries the matching
# zero-guard on the expectation side.


def die(*lines: str) -> None:
    for line in lines:
        print(line, file=sys.stderr)
    sys.exit(1)


def current_run_id() -> str:
    """This invocation's run id, or a hard failure (`#lzstalemanifest`).

    REFUSES when unset rather than skipping the stamp comparison. A guard that
    accepts unstamped evidence whenever the variable happens to be absent is the
    same stale-evidence hole with one extra step, and the absent variable is the
    state a hand-run script is in.

    There is no opt-out flag. The only callers are the Makefile and
    .github/workflows/ci.yml and both supply the id; a hand-run
    ``python3 scripts/check-unbound-blocks.py`` cannot know which run wrote
    build/, so refusing is the correct answer for it too.
    """
    raw = (os.environ.get(RUN_ID_ENV) or "").strip()
    if not raw:
        die(
            "FAIL: {} is not set (#lzstalemanifest).".format(RUN_ID_ENV),
            "      This guard reads a manifest and a block ledger written by a",
            "      SEPARATE process — the `dart test` children of an earlier make",
            "      step — so the id both sides carry is the only thing separating",
            "      this run's evidence from a leftover file. Refusing rather than",
            "      skipping: accepting unstamped evidence when the variable is unset",
            "      is the same hole with one extra step.",
            "      Run `make check` (or `make unbound-block-check`), which generates",
            "      one id per invocation and exports it.",
        )
    return raw


def read_stamped_evidence(path: str, label: str, run_id: str, hint: str) -> list:
    """Lines of ``path`` with the run-id stamp verified and removed.

    Fails by NAME — the file, the id found, the id wanted. A MISSING stamp fails
    too: an evidence file predating this change carries none, and so does one
    written by a suite run with no run id in its environment.

    The stamp is stripped rather than skipped over because both consumers parse
    every remaining line as evidence — a corpus-relative fixture id here, a
    ``fixture<TAB>path`` site in the ledger — and a stray comment line would be
    read as a corrupt record.

    RECORDS, not bytes (``#lzstampsatisfiesnonempty``). The two callers in `main`
    used to ask ``os.path.getsize(...) == 0``, and the stamp this function
    verifies makes any written file non-empty — so a byte test can no longer tell
    a suite that replayed the corpus from a recorder that attached, stamped, and
    attributed nothing. The emptiness half of those gates therefore lives HERE,
    below the stamp prefix it has to skip, and their existence half stays in
    `main` where it was.

    The records rung comes first but is not the LAST word: when the file carries
    a stamp at all, the stamp is adjudicated before emptiness is blamed, so a
    stamp-only LEFTOVER is reported as STALE rather than as a recorder that
    attributed nothing "in this run".

    This binding's recorder cannot currently produce a stamp-only file — the
    stamp and the first record are written in one call under one lock, keyed off
    a zero-length file, and ``make test`` truncates to GENUINELY empty — but the
    gate judges bytes written by a separate process, so it refuses what is on
    disk rather than what today's recorder happens to write. Unchecked, a
    stamp-only ledger died 712 blocks later as "no runner ever bound", once per
    block: detected, and reported as a binding collapse rather than as absent
    evidence.
    """
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().splitlines()
    first = lines[0] if lines else ""
    if not any(
        line.strip() and not line.startswith(RUN_ID_PREFIX) for line in lines
    ):
        # Records-before-stamp is right for a GENUINELY empty file, which carries
        # no stamp either — blaming the stamp would send a contributor who forgot
        # `LAZILY_CONFORMANCE_BLOCKS` to the wrong rung. It is wrong for a file
        # that DOES carry one: a stamp is positive evidence that some run wrote
        # here, and an id that is not this run's makes the file a LEFTOVER, which
        # is the rung below. Measured before this split, with a matching manifest
        # so this file was the one under test: a 0-byte ledger and a stamp-only
        # ledger carrying `make-STALE-0000-deadbeef` produced the SAME message,
        # "the recorder attributed nothing in this run" — a claim about a run the
        # stale file is not about, with the stale rung never reached. Mirrors the
        # same split in check-conformance-coverage.sh's `require_evidence`.
        if first.startswith(RUN_ID_PREFIX):
            _refuse_foreign_stamp(first, path, label, run_id)
        die(
            "FAIL: {} at {} carries ZERO records "
            "(#lzstampsatisfiesnonempty).".format(label, path),
            "      The file is empty, or it holds nothing but the run-id stamp —",
            "      which is itself non-empty, so a byte test would have accepted",
            "      it. Either way the recorder attributed nothing in this run.",
            "      {}".format(hint),
            "      Zero records is missing evidence, not evidence of absence.",
        )
    if not first.startswith(RUN_ID_PREFIX):
        die(
            "FAIL: {} at {} carries no run-id stamp (#lzstalemanifest).".format(
                label, path
            ),
            "      wanted first line: {}{}".format(RUN_ID_PREFIX, run_id),
            "      found first line:  {}".format(first),
            "      It was written by a suite run with no {} in its".format(RUN_ID_ENV),
            "      environment, or it predates the stamp. Either way it is not",
            "      evidence about this run.",
        )
    _refuse_foreign_stamp(first, path, label, run_id)
    return [line for line in lines[1:] if not line.startswith(RUN_ID_PREFIX)]


def _refuse_foreign_stamp(first: str, path: str, label: str, run_id: str) -> None:
    """Die unless ``first`` is a run-id stamp naming THIS run.

    Called from two places in `read_stamped_evidence` — once for a file with
    records and once for a stamp-only one — so a leftover file is reported as
    STALE either way instead of as an absence of records.
    """
    found = first[len(RUN_ID_PREFIX) :]
    if found != run_id:
        die(
            "FAIL: {} at {} is STALE (#lzstalemanifest).".format(label, path),
            "      run id in the file:  {}".format(found),
            "      run id of this gate: {}".format(run_id),
            "      It was written by an earlier invocation — a previous `make check`,",
            "      an aborted run, or a single-file `dart test`. Re-run the suite in",
            "      this invocation (`make check`); do NOT read it as block coverage.",
        )


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
    `assertionBlockKeys` names, at any depth up to `attributionDepthLimit`, and
    a site for

      * the OBJECT value of a tracked key, and
      * each plain-OBJECT ELEMENT of an ARRAY value of a tracked key
        (`#lzdartarrayblocks`).

    The second is the widening, and `isAssertionBlockPath` in the tracker now
    says exactly the same — a path with ONE trailing index stripped down to a
    bare tracked key name. Before it, an array-valued tracked key contributed no
    site at all: the array is not an object, and its elements are list items
    rather than tracked keys, so they were descended into and dropped.
    `signaling/anti_spoof_session.json` holds its expected outbound frames that
    way, and all 12 of its elements were invisible to this guard while the
    runner read and asserted every one.

    The site is the ELEMENT, `steps[3].expect[1]`, never the array. A label per
    array would collapse a step's frames into one site, and two frames that are
    individually falsifiable would stop being individually nameable — the
    set-identity failure the site dimension exists to catch.

    A NESTED array element is not directly under a tracked key and gets no site
    of its own; the element walk below is only entered from the tracked-key
    branch. The canonical corpus carries no such shape.
    """
    if depth > limit:
        return
    if isinstance(node, dict):
        for key, value in node.items():
            child = key if not path else "{}.{}".format(path, key)
            if key in keys:
                if isinstance(value, dict):
                    out.append((child, value))
                elif isinstance(value, list):
                    for index, element in enumerate(value):
                        if isinstance(element, dict):
                            out.append(("{}[{}]".format(child, index), element))
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

    # EXISTENCE only. The emptiness half of both gates moved into
    # `read_stamped_evidence`, which counts records BELOW the stamp
    # (#lzstampsatisfiesnonempty); `getsize(...) == 0` was a byte test, and the
    # stamp makes every written evidence file non-empty. These two stay here, at
    # the order they always reported in, because an absent file and a
    # record-free one want different answers.
    if not os.path.isfile(manifest):
        die(
            "FAIL: no conformance manifest at {}.".format(manifest),
            "      Run the suite with LAZILY_CONFORMANCE_MANIFEST set (`make test`).",
            "      An absent manifest is missing evidence, not evidence of absence.",
        )
    if not os.path.isfile(ledger_path):
        die(
            "FAIL: no bound-block ledger at {}.".format(ledger_path),
            "      Run the suite with LAZILY_CONFORMANCE_BLOCKS set (`make test`) so",
            "      the recorder in test/conformance_assertions.dart attaches. An",
            "      absent ledger is missing evidence, not evidence of absence.",
        )

    # The stamp rung (#lzstalemanifest), at the point each file is first read
    # and BELOW the corpus skip above for the same reason the coverage guard's
    # is: with no corpus the recorder attributes no read, the manifest comes out
    # empty, and a contributor's honest local skip must not become a failure.
    run_id = current_run_id()
    opened = sorted(
        {
            line.strip()
            for line in read_stamped_evidence(
                manifest,
                "conformance manifest",
                run_id,
                "Run the suite with LAZILY_CONFORMANCE_MANIFEST set (`make test`).",
            )
            if line.strip()
        }
    )
    bound = {
        line
        for line in read_stamped_evidence(
            ledger_path,
            "bound-block ledger",
            run_id,
            "Run the suite with LAZILY_CONFORMANCE_BLOCKS set (`make test`) so the "
            "recorder in test/conformance_assertions.dart attaches. An empty ledger "
            "would report EVERY block unbound.",
        )
        if line.strip()
    }

    source = tracker_source()
    keys = tracker_block_keys(source)
    limit = tracker_depth_limit(source)
    excuses = expand_excuses()
    excused = {(fixture, path) for fixture, path, _ in excuses}

    # The size pin, before anything else is read (#lzledgerratchet). It is the
    # one check here that needs no evidence from the run at all — it is a policy
    # about the committed ledger — so it reports first and on its own terms,
    # rather than behind a manifest or a corpus derivation that could fail for
    # unrelated reasons.
    #
    # EXACT, both directions. A one-sided bound would refuse growth only while
    # slack is zero and would hand itself a free slot at every migration; see
    # `EXPECTED_LEDGERED`.
    if len(excuses) != EXPECTED_LEDGERED:
        report = []
        if len(excuses) > EXPECTED_LEDGERED:
            report.append(
                "ERROR: the excused assertion-block ledger GREW to {} site(s); the "
                "pin is {}.".format(len(excuses), EXPECTED_LEDGERED)
            )
            report.append(
                "       Set equality alone cannot see this. It compares the ledger"
            )
            report.append(
                "       against the RUN, and a commit that detaches binds and writes the"
            )
            report.append(
                "       matching entries moves both sides together and passes both"
            )
            report.append(
                "       directions. The magnitude rung misses it too, because a detached"
            )
            report.append("       bind's site is still DECLARED, merely no longer bound.")
            report.append(
                "       Bind the block. Raise EXPECTED_LEDGERED_BLOCKS only for a block"
            )
            report.append(
                "       this binding genuinely cannot bind, with a reason saying what"
            )
            report.append("       cannot be expressed.")
        else:
            report.append(
                "ERROR: the excused assertion-block ledger SHRANK to {} site(s); the "
                "pin is still {}.".format(len(excuses), EXPECTED_LEDGERED)
            )
            report.append(
                "       LOWER THE PIN IN THIS COMMIT. This number is compared for"
            )
            report.append(
                "       EQUALITY on purpose: leaving it high is how a one-sided bound"
            )
            report.append(
                "       accumulates slack and stops refusing the detach-and-excuse commit"
            )
            report.append(
                "       it exists to refuse. Migrating sites is the goal state; the pin"
            )
            report.append("       has to follow them down in the same diff.")
        report.append(
            "       The {} site(s) the ledger currently names:".format(len(excuses))
        )
        for fixture, path, _ in excuses[:20]:
            report.append("         {}|{}".format(fixture, path))
        if len(excuses) > 20:
            report.append(
                "         ... and {} more — read `git diff` on KNOWN_UNBOUND_BLOCKS "
                "for the rest".format(len(excuses) - 20)
            )
        die(*report)

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

    # The vacuity guards come FIRST (#lzvacuousrun). Every check below reasons
    # about blocks the run OPENED, so all of them are vacuously satisfied by an
    # empty population — and a run that measured nothing must say so, rather
    # than report whatever the excuse list happens to disagree with.
    #
    # These two are not floors and do not become ones. A floor asks whether the
    # population is BIG ENOUGH, which is a question the derived equality below
    # already answers exactly; these ask whether there is a population at all,
    # which no equality can answer, because zero compares equal to zero.
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

    # `bound_count` is NOT checked against a floor (#lzdartboundfloor). Reaching
    # here means the loop above found every declared site either bound or
    # excused, and the stale-excuse direction means no site is both, so
    # `bound_count == len(declared_sites) - len(excuses)` identically. Both of
    # those are already pinned: the site set by the derived equality above, the
    # ledger size by `EXPECTED_LEDGERED`. There is no way to move this number
    # that does not move one of them first, and each of the three ways to try
    # reports above — an unexcused detach in the loop just above, an excused one
    # at the size pin, a shrunken corpus at the magnitude rung.
    print(
        "unbound-block guard OK: {}/{} assertion blocks across {} opened fixtures "
        "were BOUND by the suite ({} excused against a pin of exactly {}; runtime "
        "ledger — these blocks were really passed to a tracker; the ledger is an "
        "EQUALITY against the run, and its SIZE is a second EQUALITY against a "
        "committed constant the corpus cannot move, so neither growing it nor "
        "migrating out of it can happen without a visible edit). "
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
            EXPECTED_LEDGERED,
            len(expected_sites),
            len(expected_digests),
            expected_fixtures,
        )
    )


if __name__ == "__main__":
    main()
