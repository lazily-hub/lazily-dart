.PHONY: check analyze test test-interop-peer stdlib-browser-check conformance-coverage formal-check ci-reach

# lazily-dart had no Makefile; verification was ad-hoc `dart analyze` + `dart test`.
# The conformance-coverage guard needs somewhere to hang, and a named `check` makes
# the binding's gate discoverable the way every sibling's is.
#
# `conformance-coverage` runs AFTER `test`, not before: the guard now reads the
# runtime manifest the suite writes, so ordering it first would only ever see the
# previous run's evidence, or none at all.
check: analyze test test-interop-peer stdlib-browser-check conformance-coverage formal-check ci-reach
	@echo "lazily-dart: check OK"

# CI-reachability guard (#lzcheckcireachguard). Fails when a target above runs a
# gate no CI workflow step reaches — the drift that hid #lzinteroppeerci in every
# binding for months. It guards itself: `ci-reach` is in `check`, so CI has to run
# it too or this target reports itself missing.
ci-reach:
	./scripts/check-ci-reach.sh

analyze:
	dart analyze --fatal-infos

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
		&& rm -f build/conformance-scenarios-replayed.txt.lock
	LAZILY_CONFORMANCE_MANIFEST=$(CURDIR)/build/conformance-fixtures-loaded.txt \
		LAZILY_CONFORMANCE_SCENARIOS=$(CURDIR)/build/conformance-scenarios-replayed.txt \
		dart test

test-interop-peer:
	dart run bin/interop_peer.dart --self-check

# The public stdlib core and Future adapters are portable; compiling this
# entrypoint catches accidental dart:io or VM-only dependencies.
stdlib-browser-check:
	@mkdir -p build
	dart compile js -O1 -o build/stdlib_browser_check.js tool/stdlib_browser_check.dart
	node build/stdlib_browser_check.js

# Conformance-coverage guard (#lazilyupgradeconformance). Runtime: fails when a
# canonical fixture was never OPENED by the suite. Naming is not replaying — see
# the script header.
conformance-coverage:
	./scripts/check-conformance-coverage.sh

formal-check:
	dart tool/formal_check.dart
