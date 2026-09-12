#!/usr/bin/env python3
"""Fixture-flag hygiene rung (`#lzsiblingrunnermasking`).

`#lzflagcoercion` enumerated and fixed every coerced fixture-flag read in this
binding's conformance suite. Nothing stopped the next one. Every fix was a call
site, and a convention a reviewer has to remember is not a guard — worse, in
lazily-rs and lazily-kt the only thing that caught the coercion was a SECOND
runner over the same fixture happening to be strict, which is coverage by
accident of which runners exist. A mask disappears the moment a runner is
deleted, split, renamed or skipped.

lazily-cpp's `97790fd` is the shape to copy: it deleted
`lazily_test::Json::as_bool()` so the weak spelling became a COMPILE ERROR.
Dart cannot be made to do that — `==` is defined on `Object?`, `as bool?` is a
language construct, and this repo has no custom-lint plugin — so the local
equivalent of "unavailable" is a scan that runs inside `make check`, plus the
strict funnel (`flagOf` / `flagAt` in `test/conformance_assertions.dart`) that
every banned site was converted to. That is what this rung is.

WHAT IS BANNED, and why each spelling is decidable from the source alone:

  `== true` / `!= true`
      False for EVERY non-boolean. `{"downstream_consumer_reran": "true"}`
      against a run that observed `false` goes GREEN while the fixture reads as
      asserting the consumer DID re-run — a silently INVERTED assertion that
      passes. lazily-go shipped exactly this.

  `as bool?`
      Only ever appeared here as `(x as bool?) ?? false`, and the `??` is what
      makes it a flag read rather than a cast. The cast form REFUSED a
      non-boolean, so these sites were safe as spelled — but a spelling whose
      safety has to be re-derived per site is the one the next copy reaches
      for. `flagAt` is that contract by name: absent or null means false, a
      present non-boolean is a named refusal. After the conversions there are
      no remaining callers, so this rung needs no allowlist for it.

WHAT IS NOT BANNED, deliberately:

  `?? 0` / `?? []` / `?? const {}`
      The `#lzflagcoercion` sibling defect — an accessor answering a ZERO VALUE
      for something ABSENT, read as a measurement — is NOT a spelling. This
      binding has ~10 of these and they are INPUT SEEDS, where absence
      legitimately means "start empty"/"start at zero". The one live defect,
      `model.computes[id] ?? 0` satisfying `{"typo_id": 0}` by the node's
      non-existence, is STILL SPELLED THAT WAY in
      `reactive_graph_conformance_test.dart` and is closed structurally, by
      `subKeyOf`'s population bound. Banning the spelling would flag a site
      whose defect is already shut and would need an allowlist longer than the
      finding — the guard for that class is "bound the key population by the
      RUN" (`subKeyOf` / `assertKeysOf` / `assertKeySet`), not a grep.

  `as bool` (non-nullable)
      An INPUT cast standing beside `as int` / `as String` in the same
      expression. It refuses uniformly and by the same rule; singling out bool
      would be cosmetic. It is also the spelling the banned sites were
      converted TO where a boolean is required unconditionally.

SCOPE: `test/**/*.dart`. That is where fixture values arrive as `dynamic`.
`lib/` is excluded because it validates its own JSON at the parse boundary and
throws — `state_chart.dart` refuses a non-boolean `parallel` / `internal` with
a `FormatException` BEFORE the comparison, which is a stricter funnel than this
rung could impose. `bin/interop_peer.dart` is excluded because its one
`!= true` reads a response its OWN process just produced, not a fixture.

FLOORS, so an empty or broken scan cannot pass silently:
  * MIN_SCANNED_SOURCES — files actually read and stripped.
  * MIN_FUNNEL_CALL_SITES — `flagOf` / `flagAt` call sites found in the
    stripped code. A scanner whose stripper ate the whole file, or a suite that
    abandoned the funnel wholesale, fails here rather than reporting clean.

Comments and string literals are STRIPPED before matching, by a real Dart
lexer, not a regex: `computed_ripple_when_test.dart` carries a test NAME
reading `changed == true`, and six files carry the banned spellings inside the
comments that explain why they are banned. Interpolated expressions are kept as
code, so `'${flag == true}'` is still caught.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# Files actually read. A scan that reaches fewer sources than this is a broken
# scan reporting clean; raise it when the suite grows, never lower it to make a
# run green.
MIN_SCANNED_SOURCES = 60

# `flagOf` / `flagAt` call sites in the stripped code. Evidence that the strict
# funnel is still WIRED, not merely present: the ban below can be satisfied by
# deleting every flag read in the suite.
MIN_FUNNEL_CALL_SITES = 20

# Every entry is a file plus a reason. EMPTY, and that is the claim: every site
# the ban would have hit was converted, so there is nothing a reviewer has to
# remember. cpp needed one entry (a file carrying a second JSON parser); this
# binding needs none.
ALLOWLIST: dict[str, str] = {}

BANNED = [
    (
        re.compile(r"[!=]=\s*true\b"),
        "`== true` / `!= true` on a dynamic COERCES: it is false for every "
        "non-boolean, so a fixture spelling \"true\" or 1 against a run that "
        "observed false passes while reading as the opposite assertion. "
        "Use flagOf(value, where) — or `as bool` where the boolean is "
        "unconditionally required (`#lzflagcoercion`).",
    ),
    (
        re.compile(r"\bas\s+bool\s*\?"),
        "`as bool?` is only ever a flag read with a default hanging off it "
        "(`?? false`). Use flagAt(block, key, where): absent or null means "
        "false, a present non-boolean is a named refusal "
        "(`#lzsiblingrunnermasking`).",
    ),
]

FUNNEL = re.compile(r"\bflag(?:Of|At)\s*\(")


def strip_dart(src: str) -> str:
    """Blank out comments and string CONTENT, keeping interpolated code.

    Line and column positions are preserved: every consumed character is
    replaced by a space, and newlines are kept, so a match's line number is the
    line number in the real file.
    """
    out: list[str] = []
    i = 0
    n = len(src)

    def blank(ch: str) -> str:
        return "\n" if ch == "\n" else " "

    while i < n:
        ch = src[i]
        # Line comment.
        if src.startswith("//", i):
            while i < n and src[i] != "\n":
                out.append(" ")
                i += 1
            continue
        # Block comment. Dart nests these.
        if src.startswith("/*", i):
            depth = 0
            while i < n:
                if src.startswith("/*", i):
                    depth += 1
                    out.append("  ")
                    i += 2
                    continue
                if src.startswith("*/", i):
                    depth -= 1
                    out.append("  ")
                    i += 2
                    if depth == 0:
                        break
                    continue
                out.append(blank(src[i]))
                i += 1
            continue
        # String literal, with an optional `r` raw prefix.
        raw = False
        start = i
        if ch == "r" and i + 1 < n and src[i + 1] in "'\"":
            raw = True
            i += 1
            ch = src[i]
        if ch in "'\"":
            quote = ch
            triple = src.startswith(quote * 3, i)
            closer = quote * 3 if triple else quote
            if raw:
                out.append(" ")  # the consumed `r`
            out.append(" " * len(closer))
            i += len(closer)
            while i < n:
                if not raw and src[i] == "\\" and i + 1 < n:
                    out.append("  ")
                    i += 2
                    continue
                if src.startswith(closer, i):
                    out.append(" " * len(closer))
                    i += len(closer)
                    break
                # `${ ... }` is CODE and is kept verbatim, brace-balanced.
                if not raw and src.startswith("${", i):
                    out.append(src[i : i + 2])
                    i += 2
                    depth = 1
                    while i < n and depth > 0:
                        if src[i] == "{":
                            depth += 1
                        elif src[i] == "}":
                            depth -= 1
                        out.append(src[i])
                        i += 1
                    continue
                out.append(blank(src[i]))
                i += 1
            else:
                # Unterminated literal: refuse rather than guess.
                raise SystemExit(
                    f"check-flag-hygiene: unterminated string literal starting "
                    f"at offset {start}; the stripper cannot be trusted on this "
                    f"file, so the rung refuses rather than reporting clean."
                )
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    sources = sorted(p for p in (root / "test").rglob("*.dart"))
    violations: list[str] = []
    scanned = 0
    funnel_sites = 0

    for path in sources:
        rel = str(path.relative_to(root)) if path.is_absolute() else str(path)
        code = strip_dart(path.read_text())
        scanned += 1
        funnel_sites += len(FUNNEL.findall(code))
        excuse = ALLOWLIST.get(rel)
        for lineno, line in enumerate(code.splitlines(), start=1):
            for pattern, why in BANNED:
                match = pattern.search(line)
                if match is None:
                    continue
                if excuse is not None:
                    continue
                violations.append(
                    f"  {rel}:{lineno}: `{match.group(0).strip()}`\n"
                    f"      {why}"
                )

    failed = 0
    if violations:
        failed = 1
        print(
            "FAIL: banned fixture-flag spelling in the conformance suite "
            f"({len(violations)} site(s)):",
            file=sys.stderr,
        )
        for v in violations:
            print(v, file=sys.stderr)

    if scanned < MIN_SCANNED_SOURCES:
        failed = 1
        print(
            f"FAIL: flag-hygiene scan read {scanned} source(s) under "
            f"{root / 'test'}, below the floor of {MIN_SCANNED_SOURCES}. A scan "
            "that reaches nothing reports clean, which is the vacuous green "
            "this floor exists to prevent.",
            file=sys.stderr,
        )

    if funnel_sites < MIN_FUNNEL_CALL_SITES:
        failed = 1
        print(
            f"FAIL: only {funnel_sites} flagOf/flagAt call site(s) survive the "
            f"strip, below the floor of {MIN_FUNNEL_CALL_SITES}. The ban above "
            "is also satisfied by deleting every flag read in the suite, so the "
            "strict funnel has to be shown still WIRED, not merely present.",
            file=sys.stderr,
        )

    if failed:
        return 1

    excused = (
        "0 excused"
        if not ALLOWLIST
        else f"{len(ALLOWLIST)} excused: " + ", ".join(sorted(ALLOWLIST))
    )
    print(
        f"flag hygiene OK: no `== true` / `!= true` / `as bool?` in "
        f"{scanned} conformance source(s) ({excused}; comments and string "
        f"literals stripped by a Dart lexer, interpolated expressions kept as "
        f"code), and {funnel_sites} flagOf/flagAt call site(s) prove the "
        f"strict funnel is still wired"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
