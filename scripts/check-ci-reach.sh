#!/usr/bin/env bash
# CI-reachability guard (#lzcheckcireachguard).
#
# Fails the build when `make check` runs a gate that CI never reaches. That is the
# drift this guard exists for: someone adds a target to `check`, it passes locally
# forever, and no CI job ever executes it — which is exactly how #lzinteroppeerci
# happened. The interop peer, the single cross-binding wire-compatibility gate, was
# in every binding's `check` and in no binding's workflow, for months.
#
# It also exists because the obvious hand-audit is WRONG. Grepping the workflows
# for "make check" reported all nine bindings as covered; every one of those hits
# was a COMMENT. Comments are the reason this is a script and not a convention:
# only `run:` bodies count here, and comment lines inside them are stripped before
# anything is matched.
#
# WHAT IT PROVES
#
#   For every target in `check`'s prerequisite closure, at least one CI `run:`
#   step invokes the same program with the same distinguishing flags.
#
# WHAT IT DOES NOT PROVE
#
#   That CI runs it against the same inputs, in the same environment, or that the
#   command means the same thing there. Reach is a floor, not equivalence. The
#   sibling guards (conformance-coverage, assertion-keys, scenario-coverage) are
#   what prove a run examined anything.
#
# WHAT IT PINS (#pinreachclosure)
#
#   Reach was the only thing audited, and the verdict was a COUNT, so the
#   POPULATION was unpinned: a target that left the closure left no trace, and
#   deleting one printed `OK — 10 target(s) reached` in place of 11 without ever
#   naming it. Three rungs now pin the population, each measured necessary on
#   this repo's real Makefile because the other two pass its attack with output
#   byte-identical to healthy:
#
#     A. the make-derived ORACLE — `make -n <root>` really runs each member's
#        commands. Load-bearing: the closure itself is awk-scanned from Makefile
#        source and cannot see make conditionals.
#     B. EXPECTED_CLOSURE_TARGETS — set equality on WHICH targets are members,
#        plus EXPECTED_ROOT_TARGET so the root cannot be swapped underneath it.
#     C. EXPECTED_NOGATE_TARGETS — set equality on which members legitimately
#        carry no checkable command, so a name cannot be kept while its recipe
#        is neutered.
#
#   Still not caught, and deliberately so: swapping a member's recipe for a
#   DIFFERENT gate CI already runs. See the note on EXPECTED_ROOT_TARGET below
#   for why closing it would cost more than it buys.
#
# HOW A TARGET IS MATCHED
#
#   Recipes are read through `make -n`, so make variables are already expanded and
#   we compare real command lines rather than source text. `make -p` is
#   deliberately NOT used: it dumps the entire environment to stdout, which would
#   print every secret in the job's env into the CI log.
#
#   Each command is split on the shell's sequencing operators, redirections are
#   dropped, and the remainder is reduced to an ANCHOR: the program basename plus
#   its subcommands and flag NAMES (values dropped), with path arguments reduced to
#   basenames and bare path globs discarded. A target is reached when EVERY one of
#   its anchors is a subsequence of some CI command's token list, or when CI runs
#   `make <target>` directly. Every, not any: a target that runs two gates and is
#   half-covered by CI is a gap, and "any" would report it green.
#
#   Keeping flag names in the anchor is what makes the guard falsifiable rather
#   than decorative: `go test -race` does not match a CI step that only runs
#   `go test -count=1`, so dropping the race job reddens this guard instead of
#   being absorbed by the plain test job.
#
#   An argument that is still a VARIABLE reference at this point — `$MANIFEST` in
#   a CI step, or a `$$VAR` a recipe leaves for the shell — names a value the
#   guard cannot resolve, so it becomes a WILDCARD matching exactly one token on
#   the other side (#lzcireachvaranchor). Make and CI routinely spell the same
#   path differently, one through an expanded `$(VAR)` and the other through the
#   environment, and they are the same command. Dropping the token instead, which
#   is what this used to do, lost the argument as well as its value and reported
#   a step that genuinely ran the gate as unreachable — a false RED that cost one
#   binding a hardcoded second spelling of the path plus a hand-written equality
#   assertion, which is a new drift surface invented to satisfy a guard whose job
#   is detecting drift. Arity still counts: `script.sh $A` does not match a CI
#   step that passes no argument at all.
#
#   Commands whose program is a shell builtin or a plain file/text utility carry no
#   gate, so they contribute no anchor. A target with no non-trivial command at all
#   (a mkdir-only reset step, say) is reported as carrying no gate and is not
#   required to appear in CI. It cannot fail a build, so it cannot hide one.
#
# THE EXCUSE LIST IS THE OTHER HALF OF THE DELIVERABLE
#
#   scripts/ci-reach.conf names the workflows that count and the targets that are
#   deliberately local-only, each with a reason. It is the one place a reader can
#   see what this binding does not enforce in CI, in the same spirit as
#   KNOWN_UNCOVERED. Excuses are checked in THREE directions, so the list cannot
#   rot into a list of things that used to be true:
#
#     * an excused target CI turns out to REACH fails — the excuse is obsolete.
#     * an excused target that is NOT IN THE CLOSURE fails — it excuses no gate,
#       and this guard never consults it. That direction was missing: such an
#       excuse was silently ignored (`0 excused`, no complaint, exit 0) while
#       KNOWN_UNCOVERED has always refused its equivalent (`lists 'X', which is
#       not in the canonical corpus`). The asymmetry is closed below.
#     * an excuse with no reason fails, because it is not an excuse.
set -euo pipefail

MAKE_BIN="${MAKE:-make}"
ROOT_TARGET="${CI_REACH_ROOT_TARGET:-check}"
CONF="${CI_REACH_CONF:-scripts/ci-reach.conf}"

# ------------------------------------------------------------- the closure PIN
#
# WHICH targets `check` must reach (#pinreachclosure).
#
# Everything below this line audits the closure the Makefile happens to have.
# Nothing audited its MEMBERSHIP, and the verdict is a COUNT, so a target that
# LEAVES the closure left no trace. Measured on this repo's real Makefile, on a
# byte-verified scratch copy, with `analyze` deleted from `check:`'s prerequisite
# list: `OK — 10 target(s) reached by CI, 0 excused, 1 carrying no gate`,
# exit 0, down from 11 — never naming the gate that left, with
# `dart analyze --fatal-infos` sitting in its recipe untouched. A gate stopped
# being required and the guard approved.
#
# The mirror image was the same hole from the other side. An `excuse:` naming a
# target that is not in the closure AT ALL was silently ignored. Also measured,
# both with a name no rule defines (`excuse: typecheck ...`) and with a real
# target that `check` does not reach (`excuse: fmt-fix ...`): `0 excused`, no
# complaint, exit 0 — while the conformance guard has always checked that
# direction (`KNOWN_UNCOVERED lists 'X', which is not in the canonical corpus`).
# The conf header claims excuses "cannot rot into a list of things that used to
# be true"; only one of its two directions was actually proven. Membership is now
# pinned both ways, and an out-of-closure excuse is a hard failure below.
#
# This is NOT the `dry_run` false green (#lzgrepcpipefail) one rung up. That one
# hid an UNREADABLE target; this one hides a REMOVED one, and removing one leaves
# the `check:` line visibly changed in a diff — which is exactly why a pin
# works here: it turns an invisible count change into a required, reviewable
# edit.
#
# SET EQUALITY, not a count floor or ceiling. A floor passes a SWAP — drop one
# gate, add another — and a ceiling self-disables: it starts at zero slack and
# gains slack with every legitimate migration until the same deletion passes
# again. The property that matters is fails-when-stale, never
# passes-when-stale, which is the same reasoning that replaced
# MAX_LEDGERED_BLOCKS with EXPECTED_LEDGERED_BLOCKS in this family.
# `EXPECTED_` already means exact equality in these scripts, so the name carries
# the semantics; MIN_, MAX_ and KNOWN_ would all read as slack.
#
# The ROOT is pinned too. ROOT_TARGET is env-overridable, so without this line
# `CI_REACH_ROOT_TARGET=fmt-fix` — or renaming `check:` and pointing the
# override at the new name — swaps in a closure of one, and a pin over a root
# nobody fixed is a pin over nothing.
#
# The root target is itself a member: a closure includes the target it is rooted
# at, and `check` is reported as `no gate` because its recipe only echoes.
#
# This pin is EDITABLE, and that is the whole point — but editing it
# reflexively to quieten the guard is the one way to defeat it. So the
# diagnostics distinguish "you broke a gate" from "you meant to change the
# closure", and say which one is almost always true.
#
# A NAMES-ONLY PIN IS NOT SUFFICIENT ON ITS OWN, and it is not offered as one.
# It is one of three rungs, and the weakest:
#
#   A. the make-derived ORACLE, below the closure walk. `prereqs_of` reads
#      Makefile SOURCE TEXT and cannot see make conditionals, so the awk closure
#      and the closure make executes are two different sets; a pin over the
#      first is set-equal to a set that may describe nothing. Load-bearing.
#   B. this membership pin.
#   C. EXPECTED_NOGATE_TARGETS, at the foot of this file. Membership says a name
#      is still a prerequisite; it says nothing about whether the name still
#      carries a gate.
#
# Each rung was measured to be necessary on this repo's real Makefile: A and C
# each have an attack that B alone passes with output BYTE-IDENTICAL to healthy.
# The verdicts are in the comments on those two rungs.
#
# WHAT THE THREE TOGETHER STILL DO NOT CATCH, stated rather than implied. All
# three reason about a SET of names, so three things are structurally outside
# them:
#
#   RECIPE IDENTITY, partly. Swapping a member's recipe for a DIFFERENT gate CI
#   already runs keeps the name, the membership, the classification and every
#   count. Half of it is now caught, by accident of the collision check on the
#   oracle: if the borrowed gate belongs to ANOTHER closure member, the two
#   members reduce to one anchor and that is refused. Measured — point
#   `formal-check:` at `dart analyze --fatal-infos` and the guard names both
#   targets and the shared anchor, exit 1.
#
#   The other half stands. Borrow a command CI runs that NO member runs and
#   nothing sees it: measured, `formal-check:` running `dart pub get` (a real step
#   in this workflow) leaves `make -n check` running `tool/formal_check.dart` ZERO
#   times with the guard's whole output BYTE-IDENTICAL to healthy, exit 0.
#   Closing that needs a per-target recipe anchor — a second spelling of every
#   recipe inside this guard — which the header above records as a mistake that
#   already cost lazily-cpp a hand-written equality assertion. It also bounds the
#   honest case for this work: the argument for a pin is that it turns an
#   invisible drop into a REVIEWABLE edit, and that swap is an equally reviewable
#   edit that stays equally undetected.
#
#   ORDER. A set has none, and order is LOAD-BEARING here: `conformance-coverage`
#   and `unbound-block-check` read evidence that `test` truncates and the suite
#   appends to, so running either before `test` reads the previous run's file.
#   Under `make -j` the prerequisite list does not even fix the order. What
#   actually enforces it is the run-id rung one layer down (#lzstalemanifest):
#   the Makefile mints one `LAZILY_CONFORMANCE_RUN_ID` per invocation, the suite
#   stamps every record with it, and a guard refuses a file stamped by any other
#   run. Measured, which is the only reason to claim it — `make conformance-coverage`
#   and `make unbound-block-check` each invoked on their own against evidence a
#   previous `make check` left: both exit 2 with `conformance manifest ... is
#   STALE`, printing the run id in the file and the run id of the gate. That is
#   the same state a reordered `check:` produces, and it is refused there too.
#   This pin deliberately does not restate that; two mechanisms for one property
#   is how they drift apart.
#
#   EDGES. Dropping the dependency BETWEEN two members can leave the node set
#   unchanged and still pass the oracle, when some other member already pulls the
#   dependency into the root's run. Measured here: this closure is a STAR — all
#   11 members are direct prerequisites of `check` and not one of them has a
#   prerequisite of its own — so the class has no instance in this binding today.
#   It would gain one the moment a member acquires a member prerequisite, and
#   nothing in these three rungs would notice.
EXPECTED_ROOT_TARGET="check"
EXPECTED_CLOSURE_TARGETS=(
	"analyze"
	"assertion-ordering-check"
	"check"
	"ci-reach"
	"conformance-coverage"
	"fmt"
	"formal-check"
	"ipc-browser-check"
	"stdlib-browser-check"
	"test"
	"test-interop-peer"
	"unbound-block-check"
)

# Which closure members legitimately carry NO gate (#pinreachclosure, part C).
#
# `no gate` is the audit's escape hatch: a member whose recipe runs no checkable
# command is dropped from the reach population and cannot fail the build. It is
# therefore also the quietest place to park a gate. Membership pins the NAME; it
# says nothing about whether the name still carries anything.
#
# Measured on this repo's real Makefile, keeping the name and neutering the
# recipe to `analyze:` / `true`: pre-fix AND with the membership pin in place,
# `OK — 10 target(s) reached by CI, 0 excused, 2 carrying no gate`, exit 0, with
# `no gate analyze` sitting in the listing as though it had always been
# decorative. The make-derived oracle does not catch it either — `make -n check`
# genuinely does run `true` — so this is a third, independent rung, not a
# restatement of the other two.
#
# Set equality, both directions, same as the closure pin. Today the only
# legitimate member is the root itself, whose recipe only echoes, so the pin is
# one line and every other `no gate` line is a regression.
EXPECTED_NOGATE_TARGETS=(
	"check"
)

if [ ! -f Makefile ]; then
	echo "check-ci-reach: no Makefile in $(pwd)" >&2
	exit 1
fi

# ---------------------------------------------------------------- configuration

workflows=()
workflow_count=0
excused_targets=()
excused_reasons=()
excuse_count=0

if [ -f "$CONF" ]; then
	while IFS= read -r line || [ -n "$line" ]; do
		line="${line%%$'\r'}"
		case "$line" in
		'#'* | '') continue ;;
		esac
		key="${line%%:*}"
		val="${line#*:}"
		val="$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
		case "$key" in
		workflow)
			workflows+=("$val")
			workflow_count=$((workflow_count + 1))
			;;
		excuse)
			tgt="${val%%[[:space:]]*}"
			reason="${val#"$tgt"}"
			reason="$(printf '%s' "$reason" | sed -e 's/^[[:space:]]*//')"
			if [ -z "$reason" ]; then
				echo "check-ci-reach: excuse for '$tgt' has no reason — an excuse without a reason is not an excuse" >&2
				exit 1
			fi
			excused_targets+=("$tgt")
			excused_reasons+=("$reason")
			excuse_count=$((excuse_count + 1))
			;;
		*)
			echo "check-ci-reach: unknown key '$key' in $CONF" >&2
			exit 1
			;;
		esac
	done <"$CONF"
fi

if [ "$workflow_count" -eq 0 ]; then
	workflows=(".github/workflows/ci.yml")
	workflow_count=1
fi

for wf in "${workflows[@]}"; do
	if [ ! -f "$wf" ]; then
		echo "check-ci-reach: workflow '$wf' listed in $CONF does not exist" >&2
		exit 1
	fi
done

# Can make read the closure at all? (#lzgrepcpipefail) Every recipe this guard
# audits arrives through `make -n`, and a make that FAILS produces the same empty
# stdout as a recipe with no commands — which the walk below reads as "carrying
# no gate", drops from the population, and still reports OK on. `dry_run` refuses
# per target and both of its call sites read that status back, but its `exit 1`
# fires inside a command substitution, so this says the same refusal ONCE, up
# front, in the MAIN shell where nothing can swallow it (lazily-py's shape).
#
# Fully redirected, never piped: a pipe into a head/grep would SIGPIPE make
# mid-recipe.
# `2>&1 >/dev/null`, in that order: stderr is duplicated onto the substitution
# and stdout is then thrown away, so make's own complaint — which NAMES the
# offending target and prerequisite — goes into the diagnostic instead of being
# swallowed by the `2>/dev/null` that `dry_run` needs on its success path.
if ! root_probe="$("$MAKE_BIN" -n "$ROOT_TARGET" 2>&1 >/dev/null)"; then
	echo "check-ci-reach: '$MAKE_BIN -n $ROOT_TARGET' FAILED, so the recipes this guard audits cannot be read." >&2
	echo "                Every recipe reaches this guard through \`make -n\`, and an unreadable one" >&2
	echo "                is indistinguishable from a recipe with no commands — which would be" >&2
	echo "                reported as 'carrying no gate' and pass. Refusing instead." >&2
	printf '%s\n' "$root_probe" | sed 's/^/                > /' >&2
	exit 1
fi

# ------------------------------------------------------- make target extraction

# A Makefile may set .RECIPEPREFIX to something other than tab (lazily-rs uses
# `>`), which puts recipe lines at column 0 where a rule line lives. Without this
# a recipe such as `>cargo test --features a:b` reads as a rule named `>cargo`.
RECIPE_PREFIX="$(awk -F= '/^[[:space:]]*\.RECIPEPREFIX[[:space:]]*[:+]?=/ {
	v = $2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); if (v != "") print substr(v, 1, 1); exit
}' Makefile)"

# Prerequisites of a target, straight from the Makefile source, with `\`
# continuations joined and trailing comments removed. Order-only prerequisites are
# dropped: they constrain ordering, not what runs.
prereqs_of() {
	awk -v target="$1" -v rp="$RECIPE_PREFIX" '
		BEGIN { pat = "^" target ":([^=]|$)"; if (rp == "") rp = "\t" }
		{
			line = $0
			# Only the ACTUAL recipe prefix marks a recipe line. Treating any
			# leading whitespace as one loses a rule that is merely indented,
			# which under a non-tab .RECIPEPREFIX is perfectly legal make and
			# collapses the whole closure to a single target. A continuation is
			# exempt: under the default tab prefix a wrapped prerequisite list is
			# normally tab-indented.
			if (!cont && substr(line, 1, 1) == rp) next
			sub(/^[[:space:]]+/, "", line)
			if (cont) {
				buf = buf " " line
				if (line ~ /\\[[:space:]]*$/) next
				cont = 0
				emit(buf)
				exit
			}
			if (line !~ pat) next
			buf = line
			if (line ~ /\\[[:space:]]*$/) { cont = 1; next }
			emit(buf)
			exit
		}
		function emit(s,   rest, n, i, parts) {
			gsub(/\\/, " ", s)
			sub(/#.*$/, "", s)
			rest = substr(s, index(s, ":") + 1)
			sub(/\|.*$/, "", rest)
			n = split(rest, parts, /[[:space:]]+/)
			for (i = 1; i <= n; i++) if (parts[i] != "") print parts[i]
		}
	' Makefile
}

# Is this name an explicit rule in the Makefile?
is_makefile_target() {
	awk -v target="$1" -v rp="$RECIPE_PREFIX" '
		BEGIN { pat = "^" target ":([^=]|$)"; if (rp == "") rp = "\t"; found = 0 }
		substr($0, 1, 1) == rp { next }
		{ line = $0; sub(/^[[:space:]]+/, "", line) }
		line ~ pat { found = 1; exit }
		END { exit found ? 0 : 1 }
	' Makefile
}

# Breadth-first closure of ROOT_TARGET's prerequisites, parents before children.
closure=""
queue="$ROOT_TARGET"
seen=" "
while [ -n "$queue" ]; do
	current="${queue%%$'\n'*}"
	if [ "$current" = "$queue" ]; then queue=""; else queue="${queue#*$'\n'}"; fi
	[ -n "$current" ] || continue
	case "$seen" in
	*" $current "*) continue ;;
	esac
	seen="$seen$current "
	closure="$closure$current"$'\n'
	while IFS= read -r dep; do
		[ -n "$dep" ] || continue
		if is_makefile_target "$dep"; then
			queue="$queue$dep"$'\n'
		fi
	done < <(prereqs_of "$current")
done

# `make -n` for a target emits its prerequisites' commands first, then its own.
# Asking make for the prerequisite list alone yields exactly that prefix — make
# applies the same de-duplication to both invocations — so removing it leaves the
# target's own recipe. Diagnostics make writes about targets it has nothing to do
# for are not commands and are dropped.
# A recipe line broken across physical lines with `\` reaches the shell as ONE
# command, and make -n prints it the way the Makefile spells it. Joining here is
# what keeps `VAR=x \` + `go test ./...` from being read as two commands, the
# second of which is where the whole gate lives.
join_continuations() {
	awk '
		{
			line = $0
			if (line ~ /\\[[:space:]]*$/) {
				sub(/\\[[:space:]]*$/, "", line)
				buf = buf line " "
				next
			}
			print buf line
			buf = ""
		}
		END { if (buf != "") print buf }
	'
}

# A `|| true` used to hang off this whole pipeline, and it could not tell make's
# own FAILURE from "this recipe prints no commands" (#lzgrepcpipefail). Both
# arrive here as an empty stdout, and the caller reads empty as `no gate`: the
# target leaves the audited population with a benign line and the guard still
# prints OK. Measured, by giving `analyze` a prerequisite with no rule — the
# shape of a generated file absent on a fresh clone: `make -n analyze` exits 2
# with "No rule to make target", and the guard reported
# `no gate  analyze  recipe runs no checkable command` and exited 0 with
# "OK — 10 target(s) reached by CI, 0 excused, 2 carrying no gate", down from 11
# reached, while `dart analyze --fatal-infos` sat in the recipe untouched. A
# FALSE GREEN, and the exact case the brief warns a blanket `|| true` creates:
# here the nonzero exit was the real signal, not a measurement of zero.
#
# So make's status is checked and a failure is fatal, while the FILTER is `awk`
# rather than `grep -v` — a `grep -v` that matches nothing exits 1, and under
# `set -o pipefail` that would poison the pipeline the moment a recipe printed
# nothing BUT make noise, which is a legitimate zero. awk exits 0 either way, so
# the line count stays a measurement.
#
# Only the per-target collapse needed this: a Makefile broken for EVERY target
# was already caught by the vacuity rung at the bottom of this file, because
# reached + excused + unreached would come out zero.
dry_run() {
	local out
	# make's own status is deliberately NOT judged in here, for two reasons.
	#
	# It is answered EARLIER and better: the walk below takes a per-target
	# UNREADABLE verdict before it reads any recipe, so by the time a
	# single-target `dry_run` runs the question is already settled, and a verdict
	# reached from inside a `$(...)` could only `exit` its own subshell anyway.
	#
	# And the multi-goal call below MUST NOT be judged. When `make -n <deps...>`
	# fails, `prefix` stays 0 and the target is credited with its prerequisites'
	# commands as well as its own — OVER-reporting, which demands more CI anchors
	# and fails closed. Only SILENCE launders, and only the single-target call can
	# produce it. Judging the multi-goal call would also invent a false red of its
	# own: `make -n` with several goals sets `MAKECMDGOALS` to the whole list, so a
	# perfectly healthy goal-conditional prerequisite can behave differently there
	# than in any real invocation.
	#
	# `awk`, not `grep -v`, for the filter: a `grep -v` that matches nothing exits
	# 1, and under `set -o pipefail` that would poison the pipeline the moment a
	# recipe printed nothing BUT make noise — a legitimate zero. awk exits 0
	# either way, so the line count stays a measurement (#lzgrepcpipefail).
	out="$("$MAKE_BIN" -n "$@" 2>/dev/null)" || out=""
	[ -n "$out" ] || return 0
	printf '%s\n' "$out" | awk '!/^make\[/ && !/^make:/' | join_continuations
}

own_commands() {
	local target="$1"
	local deps=()
	local dep_count=0
	while IFS= read -r dep; do
		[ -n "$dep" ] || continue
		if is_makefile_target "$dep"; then
			deps+=("$dep")
			dep_count=$((dep_count + 1))
		fi
	done < <(prereqs_of "$target")

	if [ "$dep_count" -eq 0 ]; then
		dry_run "$target"
		return
	fi
	# Unprobed on purpose — see `dry_run`. A failure here over-reports the
	# target's anchors, which fails closed; it cannot produce the silence that
	# launders a gate out of the audit.
	local prefix
	prefix="$(dry_run "${deps[@]}" | wc -l)"
	dry_run "$target" | tail -n +"$((prefix + 1))"
}

# ------------------------------------------------------------- workflow scraping

# Command lines from every `run:` step. Comment lines inside a run body are
# stripped here — the whole reason this guard is a script.
ci_commands() {
	awk '
		function flush() { if (buf != "") { print buf; buf = "" } }
		{
			line = $0
			indent = match(line, /[^ ]/) - 1
			if (indent < 0) indent = 9999

			if (inblock) {
				if (line ~ /^[[:space:]]*$/) next
				if (indent <= block_indent) { flush(); inblock = 0 }
				else {
					sub(/^[[:space:]]+/, "", line)
					if (substr(line, 1, 1) == "#") next
					if (line ~ /\\[[:space:]]*$/) {
						sub(/\\[[:space:]]*$/, "", line)
						buf = buf " " line
						next
					}
					if (buf != "") { print buf " " line; buf = "" } else print line
					next
				}
			}

			if (line ~ /^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*[|>][-+]?[[:space:]]*$/) {
				inblock = 1
				block_indent = indent
				buf = ""
				next
			}
			if (line ~ /^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*[^|>[:space:]]/) {
				sub(/^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*/, "", line)
				print line
			}
		}
		END { flush() }
	' "$@"
}

# ------------------------------------------------------------------- normalizing

# Reduce command text to anchors, one per line, each a space-separated token list.
anchors() {
	awk '
		BEGIN {
			# Sentinel for an unresolvable variable reference. Deliberately not a
			# string any real argument can be.
			ANY = "\001any"
			split(": true false echo printf cd pushd popd mkdir rmdir rm cp mv ln touch " \
			      "export unset set local read eval exec trap wait sleep exit return " \
			      "if then else elif fi for while until do done case esac function " \
			      "test [ [[ pwd ls cat head tail sed awk grep egrep fgrep sort uniq " \
			      "wc tr cut paste tee xargs env dirname basename date git", t, / /)
			for (i in t) if (t[i] != "") trivial[t[i]] = 1
		}
		{
			n = split(split_unquoted($0), cmds, /\n/)
			for (i = 1; i <= n; i++) emit(cmds[i])
		}
		# Split on the shell'"'"'s sequencing operators, but ONLY outside quotes. Doing
		# this before quotes are stripped is what stops a `;` inside a message —
		# `echo "missing $(DIR); clone the sibling"` — from being read as a second
		# command and inventing an anchor for a gate that does not exist. That is a
		# false RED, so it costs a real target its verdict.
		function split_unquoted(s,   i, c, nxt, len, inq, q, out) {
			out = ""; inq = 0; q = ""; len = length(s)
			for (i = 1; i <= len; i++) {
				c = substr(s, i, 1)
				if (inq) {
					if (c == q) { inq = 0; q = "" }
					out = out c
					continue
				}
				if (c == "\"" || c == "'"'"'" || c == "`") { inq = 1; q = c; out = out c; continue }
				nxt = substr(s, i + 1, 1)
				if (c == ";") { out = out "\n"; continue }
				if ((c == "&" && nxt == "&") || (c == "|" && nxt == "|")) { out = out "\n"; i++; continue }
				if (c == "|") { out = out "\n"; continue }
				out = out c
			}
			return out
		}
		function emit(cmd,   m, j, tok, out, prog, started, parts) {
			gsub(/[`"'"'"']/, " ", cmd)
			gsub(/\$\(/, " ", cmd)
			gsub(/\$\{/, " ", cmd)
			gsub(/[(){}]/, " ", cmd)
			m = split(cmd, parts, /[[:space:]]+/)
			prog = ""
			out = ""
			started = 0
			for (j = 1; j <= m; j++) {
				tok = parts[j]
				if (tok == "" || tok == "\\") continue
				if (tok ~ /^[0-9]*>>?$/ || tok == "<" || tok ~ /^[0-9]+>&[0-9]+$/) break
				if (!started) {
					if (tok ~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue
					started = 1
					prog = tok
					sub(/.*\//, "", prog)
					if (prog == "" || (prog in trivial)) return
					out = prog
					continue
				}
				if (tok ~ /^-/) {
					sub(/=.*$/, "", tok)
					out = out " " tok
					continue
				}
				if (tok ~ /^\.{1,3}$/ || tok ~ /^\.{1,2}\/\.{0,3}$/) continue
				if (tok ~ /\//) {
					sub(/\/+$/, "", tok)
					sub(/.*\//, "", tok)
					if (tok == "" || tok ~ /^\.{1,3}$/) continue
				}
					# A token that is still a shell/make VARIABLE reference names a
					# value this guard cannot resolve — a CI step spelling a path as
					# "$LAZILY_CONFORMANCE_MANIFEST" and a Makefile recipe spelling the
					# same path through an expanded $(VAR) are the same command. Dropping
					# it (what this used to do) loses the ARGUMENT as well as its value,
					# so `script.sh <path>` no longer matched a CI step that really ran
					# `script.sh "$PATH"` and the target was reported unreachable. That is
					# a false RED, and it cost lazily-cpp a hardcoded second spelling of
					# the path plus a hand-written equality assertion to keep the two in
					# sync — a new drift surface invented to satisfy a guard that exists
					# to detect drift.
					#
					# Emit a WILDCARD instead: one token that matches one token, so arity
					# is preserved. `script.sh $A` still fails against a CI step that
					# passes no argument at all. This is the same looseness the normalizer
					# already applies to paths, which it reduces to basenames — reach is a
					# floor, not equivalence, exactly as the header says.
					if (substr(tok, 1, 1) == "$") { out = out " " ANY; continue }
				out = out " " tok
			}
			if (started && out != "") print out
		}
	'
}

# ------------------------------------------------ closure MEMBERSHIP (the pin)
#
# Set equality against EXPECTED_CLOSURE_TARGETS, reported in BOTH directions and
# by NAME (#pinreachclosure). Ahead of the per-target reach audit, because a
# reach verdict computed over the WRONG population is the laundering this pin
# removes: with `analyze` gone the audit printed a wall of `reached` lines and an
# OK verdict, and every one of those lines was true. Refused up front in the MAIN
# shell, the way the root probe above is, so nothing downstream can swallow it.

if [ "$ROOT_TARGET" != "$EXPECTED_ROOT_TARGET" ]; then
	echo "check-ci-reach: root target is '$ROOT_TARGET', but EXPECTED_ROOT_TARGET pins '$EXPECTED_ROOT_TARGET'." >&2
	echo "                The closure this guard audits is the one rooted at that name, so auditing some" >&2
	echo "                other root pins nothing. Drop the CI_REACH_ROOT_TARGET override; or if" >&2
	echo "                '$ROOT_TARGET' really is the new root, update EXPECTED_ROOT_TARGET and" >&2
	echo "                EXPECTED_CLOSURE_TARGETS together in the same commit." >&2
	exit 1
fi

# A pin that names nothing pins nothing, and it is set-equal to an empty closure
# — which is the one closure this guard must never approve (#lzvacuousrun). This
# also keeps `"${ARRAY[@]}"` off the `:-` form, whose expansion of an EMPTY array
# is ONE EMPTY ELEMENT and has already been read as a ledger entry once in this
# repo.
pin_count=${#EXPECTED_CLOSURE_TARGETS[@]}
if [ "$pin_count" -eq 0 ]; then
	echo "check-ci-reach: EXPECTED_CLOSURE_TARGETS is empty — a pin that names no target pins nothing" >&2
	exit 1
fi

# A blank or duplicated entry would make `pin_count` disagree with the SET the
# comparison below actually uses, and the accounting rung at the foot of this
# file reads that count. Refused rather than silently normalized: a count that
# lies is how this whole class of defect starts.
for pin_entry in "${EXPECTED_CLOSURE_TARGETS[@]}"; do
	if [ -z "$pin_entry" ]; then
		echo "check-ci-reach: EXPECTED_CLOSURE_TARGETS carries a BLANK entry — it names no target, and it" >&2
		echo "                makes the pinned count disagree with the pinned set. Delete it." >&2
		exit 1
	fi
done
pin_dupes="$(printf '%s\n' "${EXPECTED_CLOSURE_TARGETS[@]}" | LC_ALL=C sort | uniq -d)"
if [ -n "$pin_dupes" ]; then
	echo "check-ci-reach: EXPECTED_CLOSURE_TARGETS names the same target more than once:" >&2
	while IFS= read -r d; do
		[ -n "$d" ] || continue
		echo "  - $d" >&2
	done <<<"$pin_dupes"
	exit 1
fi

# `LC_ALL=C` on both sorts AND on `comm`: comm compares byte-wise against the
# collation its inputs were sorted in, and a locale mismatch makes it report
# differences that are not there. Both strings are non-empty by the refusals
# above (the closure always contains its root), so `printf '%s\n'` cannot
# contribute a phantom empty line here.
pin_sorted="$(printf '%s\n' "${EXPECTED_CLOSURE_TARGETS[@]}" | LC_ALL=C sort)"
closure_sorted="$(printf '%s\n' "$closure" | awk 'NF' | LC_ALL=C sort)"
pin_orphans="$(LC_ALL=C comm -23 <(printf '%s\n' "$pin_sorted") <(printf '%s\n' "$closure_sorted"))"
closure_unpinned="$(LC_ALL=C comm -13 <(printf '%s\n' "$pin_sorted") <(printf '%s\n' "$closure_sorted"))"

membership_status=0

# Direction 1: pinned, absent from the closure. A gate was dropped from the
# root's prerequisites, or renamed. This is the attack in the header.
if [ -n "$pin_orphans" ]; then
	echo >&2
	while IFS= read -r t; do
		[ -n "$t" ] || continue
		echo "check-ci-reach: '$t' is pinned in EXPECTED_CLOSURE_TARGETS but is NOT in '$ROOT_TARGET''s" >&2
		echo "                prerequisite closure — a gate LEFT the set CI is required to reach." >&2
	done <<<"$pin_orphans"
	echo >&2
	echo "Almost always the fix is in the Makefile: restore the prerequisite to '$ROOT_TARGET'." >&2
	echo "If the target was genuinely renamed or retired, update EXPECTED_CLOSURE_TARGETS in" >&2
	echo "$0 in the SAME commit and say why in the message — that edit is the review this pin" >&2
	echo "exists to force, and it is not a way to make this message go away." >&2
	membership_status=1
fi

# Direction 2: in the closure, absent from the pin. Nothing is wrong with the
# Makefile — the pin is behind. Reported separately from direction 1 because the
# remedies are in different files and confusing them is how a pin gets edited
# reflexively.
if [ -n "$closure_unpinned" ]; then
	echo >&2
	while IFS= read -r t; do
		[ -n "$t" ] || continue
		echo "check-ci-reach: '$t' is in '$ROOT_TARGET''s prerequisite closure but is NOT pinned in" >&2
		echo "                EXPECTED_CLOSURE_TARGETS — a gate was added without being pinned." >&2
	done <<<"$closure_unpinned"
	echo >&2
	echo "Add it to EXPECTED_CLOSURE_TARGETS in $0 (the list is sorted) so that DELETING it later" >&2
	echo "cannot pass as a smaller count. The Makefile is fine; the pin is behind it." >&2
	membership_status=1
fi

# --------------------------------- the make-derived ORACLE (part A, load-bearing)
#
# Everything above compares the awk-derived closure against a list of names.
# This asks MAKE whether it actually runs each of those targets' commands for
# the root.
#
# `prereqs_of` scans Makefile SOURCE TEXT for the FIRST line matching
# `^<root>:`. It never asks make and it cannot see make conditionals, so the awk
# closure and the closure make executes are two different sets, and a pin over
# the first is set-equal to a set that may describe nothing. lazily-js measured
# it first; re-measured here on this repo's real Makefile with a DEAD branch,
# which needs no variable and no CI cooperation at all:
#
#   ifeq (0,1)
#   check: fmt analyze test ...      <- the only ^check: line awk ever reads
#   else
#   check: fmt test ...              <- what make actually parses
#   endif
#
# `make -n check` then runs `dart analyze --fatal-infos` ZERO times, and the
# guard WITH the membership pin above printed output BYTE-IDENTICAL (compared as
# bytes, not through a filter) to healthy, exit 0. The awk closure is constant
# across both branches, so the pin is constant too and passes by construction.
# This rung is what makes the pin above mean anything.
#
# `make -n` only, NEVER `make -p`: `make -p` builds the default goal and dumps
# the entire environment to stdout, which would print every secret in the job's
# env into the CI log.
#
# ANCHORS, NOT RAW COMMAND LINES (lazily-gd's correction). The obvious shape of
# this rung compares `make -n <target>`'s literal lines against `make -n <root>`'s.
# gd measured that it permanently false-REDs the one target carrying its suite: a
# `:=` run id built from `date +%N` and `$$` lands IN the printed recipe, so the
# line differs between the two invocations on every single run. This binding mints
# a `LAZILY_CONFORMANCE_RUN_ID` exactly that way, so it is one recipe edit away
# from the same permanent red — measured here as not exposed TODAY (the id is
# `export`ed, never interpolated into a command, so `make -n check` prints it zero
# times and two `make -n test` runs are byte-identical), which is precisely the
# kind of fact that stops being true quietly.
#
# The trap is not the red. It is that the cheapest way to clear it is to loosen
# the oracle until it proves nothing. So this compares through `anchors` — the
# SAME normalizer the reach audit uses, applied to the SAME Makefile on both
# sides, which makes an EXACT match the right test here (unlike CI matching,
# where spellings legitimately differ and subsequence matching is required).
#
# And because normalizing can only ever merge, the merge is checked: if two
# members reduce to a SHARED anchor, this rung can no longer tell them apart —
# drop one and the other still supplies the anchor — so a collision is a hard
# failure that says so, rather than a silent loss of discriminating power.
# Measured today: all 11 gate-carrying members have distinct anchor sets, down to
# `stdlib_browser_check.js` vs `ipc_browser_check.js`, which survive because the
# normalizer keeps basenames.
#
# The root is skipped: its own commands are trivially in its own output. A member
# with no commands at all is skipped too and is answered by
# EXPECTED_NOGATE_TARGETS instead — an oracle over an empty command list is
# vacuously true, which is exactly the laundering that pin exists to stop.
root_anchors="$(dry_run "$ROOT_TARGET" | anchors | LC_ALL=C sort -u)"
oracle_missing=""
oracle_volatile=""
oracle_confirmed=0
oracle_seen=""
while IFS= read -r target; do
	[ -n "$target" ] || continue
	[ "$target" = "$ROOT_TARGET" ] && continue
	oracle_anchors="$(own_commands "$target" | anchors | LC_ALL=C sort -u)"
	# No anchors at all is not a pass and not a failure here — it is the
	# `no gate` classification, and EXPECTED_NOGATE_TARGETS is what pins it. An
	# oracle over an empty anchor set is vacuously true, which is exactly the
	# laundering that pin exists to stop.
	[ -n "$oracle_anchors" ] || continue
	oracle_hit=1
	while IFS= read -r a; do
		[ -n "$a" ] || continue
		oracle_seen="$oracle_seen$a"$'\t'"$target"$'\n'
		# A herestring, never a pipe into `grep -q`: a grep that exits on its
		# first match can SIGPIPE its producer, and under `pipefail` that inverts
		# the verdict ON A MATCH (#lzgrepcpipefail). `if !` also keeps grep's
		# status out of `set -e`. No `break`: every anchor is recorded, because
		# the collision check below needs the whole map.
		if ! grep -qxF -- "$a" <<<"$root_anchors"; then
			oracle_hit=0
		fi
	done <<<"$oracle_anchors"
	if [ "$oracle_hit" -eq 1 ]; then
		oracle_confirmed=$((oracle_confirmed + 1))
	else
		# Before blaming the closure, ask whether the recipe is COMPARABLE AT ALL.
		# Anchors survive a volatile value in a LEADING `VAR=` assignment, which is
		# the shape gd hit and the shape this binding's run id would take — measured:
		# `LAZILY_RUN_TAG=$(LAZILY_CONFORMANCE_RUN_ID) dart test` makes the raw lines
		# differ between invocations and this rung stays silent. They do NOT survive
		# one in an ARGUMENT: `dart test --tags run-$(LAZILY_CONFORMANCE_RUN_ID)`
		# keeps the expanded token verbatim, and since `make -n <target>` and
		# `make -n <root>` are two separate make processes with two separate `:=`
		# expansions, no comparison between them can ever succeed.
		#
		# That is a PERMANENT red with a wrong explanation attached, which is the
		# worse half: it sends the reader to the prerequisite list for a problem in
		# the recipe. So re-probe the same target and see whether it answers the same
		# way twice. Still exit 1 either way — this buys the right diagnosis, not a
		# pass — and it costs an extra `make -n` only on the failure path.
		oracle_reprobe="$(own_commands "$target" | anchors | LC_ALL=C sort -u)"
		if [ "$oracle_reprobe" != "$oracle_anchors" ]; then
			oracle_volatile="$oracle_volatile$target"$'\n'
		else
			oracle_missing="$oracle_missing$target"$'\n'
		fi
	fi
done <<<"$closure"

# Two members sharing an anchor means this rung cannot distinguish them: drop
# either from the root and the other still supplies the anchor, so the oracle
# passes a member it should have caught. Normalizing can only merge, so this is
# the price of the anchor comparison above, and it is charged out loud.
oracle_collisions="$(printf '%s' "$oracle_seen" | awk -F'\t' '
	NF == 2 {
		if ($1 in owner) { if (owner[$1] != $2) dup[$1] = dup[$1] == "" ? owner[$1] " and " $2 : dup[$1] " and " $2 }
		else owner[$1] = $2
	}
	END { for (a in dup) print dup[a] "\t" a }' | LC_ALL=C sort)"
if [ -n "$oracle_collisions" ]; then
	echo >&2
	while IFS=$'\t' read -r who a; do
		[ -n "$a" ] || continue
		echo "check-ci-reach: $who reduce to the SAME anchor \`$a\`, so this guard cannot tell" >&2
		echo "                them apart: drop either from '$ROOT_TARGET' and the other still supplies it." >&2
	done <<<"$oracle_collisions"
	echo >&2
	echo "Give one of them a distinguishable command — a distinct program, flag or basename — or" >&2
	echo "merge the two targets, which is what sharing a command already means. Do NOT answer this" >&2
	echo "by loosening the comparison: an oracle that cannot distinguish two members is the failure," >&2
	echo "not the message about it." >&2
	membership_status=1
fi

if [ -n "$oracle_volatile" ]; then
	echo >&2
	while IFS= read -r t; do
		[ -n "$t" ] || continue
		echo "check-ci-reach: '$t''s recipe does not answer the same way twice — its command line" >&2
		echo "                carries a value that CHANGES between two '$MAKE_BIN -n' runs, so it can never" >&2
		echo "                be compared against '$MAKE_BIN -n $ROOT_TARGET' (a separate make process, with a" >&2
		echo "                separate expansion of every ':=' variable)." >&2
	done <<<"$oracle_volatile"
	echo >&2
	echo "This is neither a closure problem nor a CI problem. Move the volatile value out of the" >&2
	echo "command line — export it, the way LAZILY_CONFORMANCE_RUN_ID already is, which is exactly" >&2
	echo "why this rung can read every other recipe in this Makefile." >&2
	membership_status=1
fi
if [ -n "$oracle_missing" ]; then
	echo >&2
	while IFS= read -r t; do
		[ -n "$t" ] || continue
		echo "check-ci-reach: '$t' is in the closure this guard derived from Makefile source, but" >&2
		echo "                '$MAKE_BIN -n $ROOT_TARGET' does NOT run its command — so it is not a gate" >&2
		echo "                '$ROOT_TARGET' actually runs, whatever the prerequisite list says." >&2
	done <<<"$oracle_missing"
	echo >&2
	echo "This is what a make CONDITIONAL around the '$ROOT_TARGET:' rule looks like: the closure is" >&2
	echo "read from the first matching line of source text, make parses a different one, and every" >&2
	echo "name-level check above still agrees. Remove the conditional, or move the target out of" >&2
	echo "'$ROOT_TARGET''s prerequisites AND out of EXPECTED_CLOSURE_TARGETS together so the drop is" >&2
	echo "visible. Do not satisfy this by editing the pin alone — the pin is not what failed." >&2
	membership_status=1
fi

# The other half of the asymmetry (#pinreachclosure): an `excuse:` naming a
# target OUTSIDE the discovered closure is an ERROR, not a silent no-op.
#
# The `is_excused` consultation in the audit loop only ever asks about targets IN
# the closure, so an excuse for anything else was never read by anything — it
# printed no `excused` line, did not raise `excused_ok`, and could not go stale,
# because the stale check also only runs inside the loop. That is precisely the
# residue a renamed or deleted target leaves behind, and it is the shape the conf
# file's own header promises cannot survive. KNOWN_UNCOVERED has checked its
# equivalent direction all along; this closes the asymmetry.
#
# An excuse is a claim about a gate `make $ROOT_TARGET` RUNS. Naming something it
# does not run is not an excuse; it is a note about nothing.
for i in "${!excused_targets[@]}"; do
	excused_name="${excused_targets[$i]}"
	# A herestring, never a pipe: a `grep -q` that exits on its first match can
	# SIGPIPE its producer, and under `pipefail` that inverts the verdict ON A
	# MATCH (#lzgrepcpipefail). `if !` also keeps grep's status out of `set -e`.
	if ! grep -qxF -- "$excused_name" <<<"$closure_sorted"; then
		echo >&2
		echo "check-ci-reach: $CONF excuses '$excused_name', which is NOT in '$ROOT_TARGET''s prerequisite" >&2
		echo "                closure — so the excuse covers no gate and this guard never consults it." >&2
		echo "                Either '$excused_name' left the closure and took its gate with it (restore the" >&2
		echo "                prerequisite in the Makefile), or the excuse is simply dead (delete the line" >&2
		echo "                from $CONF). An excuse is a claim about a gate 'make $ROOT_TARGET' RUNS." >&2
		membership_status=1
	fi
done

if [ "$membership_status" -ne 0 ]; then
	exit 1
fi

echo "check-ci-reach: closure pin OK — $pin_count target(s) set-equal to EXPECTED_CLOSURE_TARGETS, root '$EXPECTED_ROOT_TARGET'; '$MAKE_BIN -n $ROOT_TARGET' runs the recipe of all $oracle_confirmed member(s) carrying one"

# --------------------------------------------------------------------- matching

ci_raw="$(mktemp)"
ci_anchor="$(mktemp)"
trap 'rm -f "$ci_raw" "$ci_anchor"' EXIT
ci_commands "${workflows[@]}" >"$ci_raw"
anchors <"$ci_raw" | sort -u >"$ci_anchor"

if [ ! -s "$ci_anchor" ]; then
	echo "check-ci-reach: no run: steps found in ${workflows[*]} — a guard with an empty haystack passes everything" >&2
	exit 1
fi

# Does CI contain a command whose tokens contain this anchor as an in-order
# subsequence? Extra flags and arguments on the CI side are fine; missing ones are
# not.
anchor_reached() {
	awk -v want="$1" '
		BEGIN { ANY = "\001any"; wn = split(want, w, / /) }
		{
			hn = split($0, h, / /)
			wi = 1
			# A wildcard on EITHER side matches, because either side may be the
			# one that spelled the argument through a variable.
			for (hi = 1; hi <= hn && wi <= wn; hi++)
				if (h[hi] == w[wi] || h[hi] == ANY || w[wi] == ANY) wi++
			if (wi > wn) { found = 1; exit }
		}
		END { exit found ? 0 : 1 }
	' "$ci_anchor"
}

# CI invoking the target through make counts as reach without any anchor work.
make_invokes() {
	awk -v target="$1" '
		{
			n = split($0, t, / /)
			if (t[1] != "make") next
			for (i = 2; i <= n; i++) if (t[i] == target) { found = 1; exit }
		}
		END { exit found ? 0 : 1 }
	' "$ci_anchor"
}

is_excused() {
	local t="$1" i
	for i in "${!excused_targets[@]}"; do
		[ "${excused_targets[$i]}" = "$t" ] && return 0
	done
	return 1
}

excuse_reason() {
	local t="$1" i
	for i in "${!excused_targets[@]}"; do
		if [ "${excused_targets[$i]}" = "$t" ]; then
			printf '%s' "${excused_reasons[$i]}"
			return
		fi
	done
}

unreached=""
unreached_count=0
stale=""
stale_count=0
nogate=""
nogate_count=0
unreadable=""
unreadable_count=0
reached=0
excused_ok=0

while IFS= read -r target; do
	[ -n "$target" ] || continue

	# ---------------------------------------------------------------------
	# The UNREADABLE verdict, FIRST (#lzgrepcpipefail)
	# ---------------------------------------------------------------------
	#
	# Ahead of the recipe read, and ahead of the excuse consultation further
	# down, because both of those launder a Makefile make cannot read into a
	# pass. Every recipe reaches this guard through `make -n`, and a make that
	# FAILS yields the same empty output as a recipe with no commands — which
	# the `no gate` branch below then waves through at exit 0.
	#
	# Three attacks, all measured against this repo's real Makefile rather than
	# reasoned about:
	#
	#   1. a prerequisite with no rule (`analyze: build/generated-lints.txt`,
	#      the shape of a generated file absent on a fresh clone). Pre-fix:
	#      `no gate analyze` / `OK — 10 target(s) reached by CI, 0 excused, 2
	#      carrying no gate`, exit 0, down from 11 reached, with
	#      `dart analyze --fatal-infos` sitting in the recipe untouched.
	#   2. a goal-conditional prerequisite. `make -n check` exits 0 while
	#      `make -n typecheck` exits 2, so a ROOT-only probe never sees the
	#      member drop out. Pre-fix: `no gate typecheck` /
	#      `OK — 11 target(s) reached by CI, 0 excused, 2 carrying no gate`,
	#      exit 0.
	#   3. attack 2 plus `excuse: typecheck ...` in the config. An excuse is a
	#      claim about what CI RUNS, never a licence for a recipe make cannot
	#      read. (In this binding the `no gate` branch already preceded the
	#      excuse check, so the measured route was `no gate typecheck` rather
	#      than `excused typecheck` — same exit 0 either way.)
	#
	# `2>&1 >/dev/null`, in that order: stderr onto the substitution, stdout
	# thrown away, so make's own message — which NAMES the target and the
	# prerequisite — goes into the diagnostic. Single-goal, never the multi-goal
	# dep list: see `dry_run`. And `continue`, so a target can never be labelled
	# UNREADABLE and then also classified `no gate`.
	if ! target_probe="$("$MAKE_BIN" -n "$target" 2>&1 >/dev/null)"; then
		unreadable="$unreadable$target"$'\n'
		unreadable_count=$((unreadable_count + 1))
		printf 'UNREADABLE  %s\n' "$target"
		printf '%s\n' "$target_probe" | sed 's/^/              > /'
		continue
	fi

	# No `|| true`: nothing in this pipeline signals "nothing found" with a
	# nonzero exit — `anchors` and `join_continuations` are awk, `sort -u` is
	# empty-safe, and `dry_run` no longer refuses — so there is no status here
	# worth swallowing, and swallowing one would put the false green above
	# straight back (#lzgrepcpipefail).
	target_anchors="$(own_commands "$target" | anchors | sort -u)"

	if [ -z "$target_anchors" ]; then
		nogate="$nogate$target"$'\n'
		nogate_count=$((nogate_count + 1))
		continue
	fi

	hit=1
	missing_anchors=""
	if ! make_invokes "$target"; then
		while IFS= read -r a; do
			[ -n "$a" ] || continue
			if ! anchor_reached "$a"; then
				hit=0
				missing_anchors="$missing_anchors$a"$'\n'
			fi
		done <<<"$target_anchors"
	fi

	if is_excused "$target"; then
		if [ "$hit" -eq 1 ]; then
			stale="$stale$target"$'\n'
			stale_count=$((stale_count + 1))
		else
			excused_ok=$((excused_ok + 1))
			printf 'excused  %-32s %s\n' "$target" "$(excuse_reason "$target")"
		fi
		continue
	fi

	if [ "$hit" -eq 1 ]; then
		reached=$((reached + 1))
		printf 'reached  %s\n' "$target"
	else
		unreached="$unreached$target"$'\n'
		unreached_count=$((unreached_count + 1))
		printf 'MISSING  %s\n' "$target"
		while IFS= read -r a; do
			[ -n "$a" ] || continue
			printf '           no CI run: step matches `%s`\n' "$a"
		done <<<"$missing_anchors"
	fi
done <<<"$closure"

while IFS= read -r target; do
	[ -n "$target" ] || continue
	printf 'no gate  %-32s recipe runs no checkable command\n' "$target"
done <<<"$nogate"

# A guard that examined nothing must not report OK — the same vacuity rule the
# conformance guards apply (#lzvacuousrun). `unreadable_count` is in the sum so
# that a closure make cannot read anywhere is reported as unreadable by the rung
# below rather than as "no target carrying a gate", which would name the wrong
# problem.
if [ "$((reached + excused_ok + unreached_count + unreadable_count))" -eq 0 ]; then
	echo "check-ci-reach: '$ROOT_TARGET' has no prerequisite target carrying a gate — nothing was verified" >&2
	exit 1
fi

status=0
# Its OWN heading, not the `unreached` list. Appending these to `unreached`
# would print them under "no CI run: step reaches" and send the reader to the
# workflow file for a problem that is in the Makefile.
if [ "$unreadable_count" -gt 0 ]; then
	echo >&2
	echo "check-ci-reach: $unreadable_count target(s) run by 'make $ROOT_TARGET' whose recipe make could NOT READ:" >&2
	while IFS= read -r t; do
		[ -n "$t" ] || continue
		echo "  - $t" >&2
	done <<<"$unreadable"
	echo >&2
	echo "An unreadable recipe is not a recipe with no gate, and no excuse in $CONF covers" >&2
	echo "one: an excuse is a claim about what CI RUNS. This is a Makefile problem — fix it" >&2
	echo "there, not in the workflow." >&2
	status=1
fi
if [ "$stale_count" -gt 0 ]; then
	echo >&2
	while IFS= read -r t; do
		[ -n "$t" ] || continue
		echo "check-ci-reach: '$t' is excused in $CONF but CI DOES reach it — remove the excuse" >&2
	done <<<"$stale"
	status=1
fi

if [ "$unreached_count" -gt 0 ]; then
	echo >&2
	echo "check-ci-reach: $unreached_count target(s) run by 'make $ROOT_TARGET' that no CI run: step reaches:" >&2
	while IFS= read -r t; do
		[ -n "$t" ] || continue
		echo "  - $t" >&2
	done <<<"$unreached"
	echo >&2
	echo "Add a CI step that runs it, or add an excuse with a reason to $CONF." >&2
	status=1
fi

# The pin's cardinality and the audit's buckets describe the SAME population
# (#pinreachclosure). Every closure member leaves the loop above through
# exactly one of six branches, so their sum must EQUAL the pinned count. Today:
# 11 reached + 0 excused + 0 stale + 0 unreached + 0 unreadable + 1 no gate = 12,
# which is `pin_count`. Without this, a future branch that `continue`s without
# counting would shrink the audited population while both the pin and the verdict
# stayed green — the same species of unaccounted member this pin exists to catch,
# one level down. A mismatch is a bug in this script, not in the Makefile.
# ------------------------------- the no-gate CLASSIFICATION pin (part C)
#
# Set equality against EXPECTED_NOGATE_TARGETS, both directions. Membership above
# proves a NAME is still a prerequisite; this proves the name still carries
# something. `no gate` is the audit's escape hatch — a member with no checkable
# command is dropped from the reach population and cannot fail the build — so it
# is the quietest place to park a gate, and neither of the two rungs above sees
# it: membership is unchanged and `make -n $ROOT_TARGET` genuinely does run the
# neutered recipe.
#
# Measured on this repo's real Makefile with `analyze:` reduced to `true`,
# pre-fix and again with the membership pin and the oracle in place:
# `OK — 10 target(s) reached by CI, 0 excused, 2 carrying no gate`, exit 0, with
# `no gate analyze` in the listing as though it had always been decorative.
nogate_sorted="$(printf '%s\n' "$nogate" | awk 'NF' | LC_ALL=C sort)"
expected_nogate_count=${#EXPECTED_NOGATE_TARGETS[@]}
expected_nogate_sorted=""
if [ "$expected_nogate_count" -gt 0 ]; then
	expected_nogate_sorted="$(printf '%s\n' "${EXPECTED_NOGATE_TARGETS[@]}" | awk 'NF' | LC_ALL=C sort)"
fi
# `awk 'NF'` inside each process substitution: either side can legitimately be
# EMPTY, and `printf '%s\n' ""` contributes one BLANK line that comm would read
# as a member named "" (#lzgrepcpipefail's sibling trap, already measured in the
# conformance guard). LC_ALL=C on both sorts and on comm, so the collations agree.
nogate_unpinned="$(LC_ALL=C comm -13 <(printf '%s\n' "$expected_nogate_sorted" | awk 'NF') <(printf '%s\n' "$nogate_sorted" | awk 'NF'))"
nogate_regained="$(LC_ALL=C comm -23 <(printf '%s\n' "$expected_nogate_sorted" | awk 'NF') <(printf '%s\n' "$nogate_sorted" | awk 'NF'))"

if [ -n "$nogate_unpinned" ]; then
	echo >&2
	while IFS= read -r t; do
		[ -n "$t" ] || continue
		echo "check-ci-reach: '$t' now carries NO checkable command and is NOT in" >&2
		echo "                EXPECTED_NOGATE_TARGETS — it kept its place in '$ROOT_TARGET''s closure and" >&2
		echo "                stopped being a gate. A member classified 'no gate' is excluded from the" >&2
		echo "                reach audit entirely, so it can no longer fail this build." >&2
	done <<<"$nogate_unpinned"
	echo >&2
	echo "Almost always the fix is in the Makefile: restore the recipe. If the target really is" >&2
	echo "meant to run nothing checkable from now on, add it to EXPECTED_NOGATE_TARGETS in $0" >&2
	echo "in the SAME commit and say why." >&2
	status=1
fi
if [ -n "$nogate_regained" ]; then
	echo >&2
	while IFS= read -r t; do
		[ -n "$t" ] || continue
		echo "check-ci-reach: '$t' is pinned in EXPECTED_NOGATE_TARGETS but now carries a gate — the" >&2
		echo "                pin is behind the Makefile, which is good news." >&2
	done <<<"$nogate_regained"
	echo >&2
	echo "Delete it from EXPECTED_NOGATE_TARGETS in $0 so the list keeps naming only real" >&2
	echo "exemptions, the same way a stale excuse is deleted from $CONF." >&2
	status=1
fi
if [ "$status" -eq 0 ]; then
	echo "check-ci-reach: no-gate pin OK — $nogate_count target(s) set-equal to EXPECTED_NOGATE_TARGETS"
fi

accounted=$((reached + excused_ok + stale_count + unreached_count + unreadable_count + nogate_count))
if [ "$accounted" -ne "$pin_count" ]; then
	echo >&2
	echo "check-ci-reach: $accounted closure target(s) accounted for, but the closure pin holds $pin_count." >&2
	echo "                Every member of '$ROOT_TARGET''s closure must land in exactly one bucket" >&2
	echo "                (reached, excused, stale excuse, unreached, unreadable, no gate). One landed" >&2
	echo "                in none, so part of the closure was audited by nothing. This is a bug in" >&2
	echo "                $0 — not in the Makefile and not in the workflow." >&2
	status=1
fi

if [ "$status" -eq 0 ]; then
	echo "check-ci-reach: OK — $reached target(s) reached by CI, $excused_ok excused, $nogate_count carrying no gate"
fi
exit "$status"
