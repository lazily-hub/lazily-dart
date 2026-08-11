.PHONY: check fmt fmt-fix analyze test test-interop-peer stdlib-browser-check ipc-browser-check conformance-coverage unbound-block-check assertion-ordering-check formal-check ci-reach

# lazily-dart had no Makefile; verification was ad-hoc `dart analyze` + `dart test`.
# The conformance-coverage guard needs somewhere to hang, and a named `check` makes
# the binding's gate discoverable the way every sibling's is.
#
# `conformance-coverage` runs AFTER `test`, not before: the guard now reads the
# runtime manifest the suite writes, so ordering it first would only ever see the
# previous run's evidence, or none at all.
check: fmt analyze test test-interop-peer stdlib-browser-check ipc-browser-check conformance-coverage unbound-block-check assertion-ordering-check formal-check ci-reach
	@echo "lazily-dart: check OK"

assertion-ordering-check:
	python3 ../lazily-spec/scripts/check-assertion-ordering.py --binding dart --root .

# CI-reachability guard (#lzcheckcireachguard). Fails when a target above runs a
# gate no CI workflow step reaches — the drift that hid #lzinteroppeerci in every
# binding for months. It guards itself: `ci-reach` is in `check`, so CI has to run
# it too or this target reports itself missing.
ci-reach:
	./scripts/check-ci-reach.sh

# The formatting GATE (#lazilydartzig). This binding had no formatting floor at
# all — nothing in `check`, nothing in CI — so drift stayed invisible until
# someone read a diff. `dart analyze` is a linter, not a formatter, and does not
# cover this.
#
# `dart format` is canonical and ships with the SDK, so the floor costs no new
# dependency; the SDK version CI installs is what pins the style. `--output=none
# --set-exit-if-changed` is the GATE spelling: a bare `dart format` REWRITES the
# tree it is judging and exits 0 whatever it found, which is a gate that cannot
# fail (#lzruffautofixvacuity). The rewriting form is `fmt-fix`, and it is not in
# `check`.
fmt:
	dart format --output=none --set-exit-if-changed .

fmt-fix:
	dart format .

analyze:
	dart analyze --fatal-infos

# A third channel rides alongside (`#lzunboundblockguard`): the manifest says a
# FIXTURE was opened, the scenario ledger says which of its SCENARIOS ran, and
# the block ledger says which of its assertion BLOCKS were bound to the tracker
# at all. Same truncate-once, same absolute path, same reason.
#
# The manifest is truncated ONCE here, and the path handed to the suite is
# ABSOLUTE: `dart test` runs each test file in its own process, and a relative path
# would scatter partial manifests across whatever working directory each process
# uses. The recorder appends, so every process contributes to one union.
#
# The scenario ledger (`#lzscenariocoverage`) is the same shape one level down:
# the manifest says a FIXTURE was opened, the ledger says which of its
# SCENARIOS were replayed. Same truncate-once, same absolute path, same reason.
test:
	@mkdir -p build && : > build/conformance-fixtures-loaded.txt \
		&& rm -f build/conformance-fixtures-loaded.txt.lock \
		&& : > build/conformance-scenarios-replayed.txt \
		&& rm -f build/conformance-scenarios-replayed.txt.lock \
		&& : > build/conformance-blocks-bound.txt \
		&& rm -f build/conformance-blocks-bound.txt.lock
	LAZILY_CONFORMANCE_MANIFEST=$(CURDIR)/build/conformance-fixtures-loaded.txt \
		LAZILY_CONFORMANCE_SCENARIOS=$(CURDIR)/build/conformance-scenarios-replayed.txt \
		LAZILY_CONFORMANCE_BLOCKS=$(CURDIR)/build/conformance-blocks-bound.txt \
		dart test

test-interop-peer:
	dart run bin/interop_peer.dart --self-check

# The public stdlib core and Future adapters are portable; compiling this
# entrypoint catches accidental dart:io or VM-only dependencies.
stdlib-browser-check:
	@mkdir -p build
	dart compile js -O1 -o build/stdlib_browser_check.js tool/stdlib_browser_check.dart
	node build/stdlib_browser_check.js

# The IPC WIRE's browser gate (#lzdartwebcompile). `stdlib-browser-check` above
# imports `package:lazily/stdlib.dart` and nothing else, so it passed for months
# while the wire surface did not compile to JavaScript AT ALL — dart2js refuses
# an integer literal above 2^53 - 1, and the FNV-1a and SplitMix64 constants were
# spelled as literals. A browser gate over the portable half is not a browser
# gate over the half that carries the protocol.
#
# This target is also where the platform half of the #lzdartintwidth guard is
# proven: that guard's refuse-on-web branch is compiled out on the VM, so the
# test suite can execute the POLICY and never the binding. Here it runs on the
# platform.
ipc-browser-check:
	@mkdir -p build
	dart compile js -O1 -o build/ipc_browser_check.js tool/ipc_browser_check.dart
	node build/ipc_browser_check.js

# Conformance-coverage guard (#lazilyupgradeconformance). Runtime: fails when a
# canonical fixture was never OPENED by the suite. Naming is not replaying — see
# the script header.
conformance-coverage:
	./scripts/check-conformance-coverage.sh

# Unbound-assertion-block guard (#lzunboundblockguard). Runtime: fails when a
# fixture the suite OPENED carries an assertion block no runner ever bound to
# the tracker. Everything the key guards prove is about a block a runner
# REACHED; a block nothing binds is invisible to all of them. Runs AFTER `test`
# for the same reason `conformance-coverage` does — it reads the ledger the run
# just wrote.
unbound-block-check:
	python3 scripts/check-unbound-blocks.py

formal-check:
	dart tool/formal_check.dart
