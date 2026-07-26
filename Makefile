.PHONY: check analyze test conformance-coverage formal-check

# lazily-dart had no Makefile; verification was ad-hoc `dart analyze` + `dart test`.
# The conformance-coverage guard needs somewhere to hang, and a named `check` makes
# the binding's gate discoverable the way every sibling's is.
#
# `conformance-coverage` runs AFTER `test`, not before: the guard now reads the
# runtime manifest the suite writes, so ordering it first would only ever see the
# previous run's evidence, or none at all.
check: analyze test conformance-coverage formal-check
	@echo "lazily-dart: check OK"

analyze:
	dart analyze --fatal-infos

# The manifest is truncated ONCE here, and the path handed to the suite is
# ABSOLUTE: `dart test` runs each test file in its own process, and a relative path
# would scatter partial manifests across whatever working directory each process
# uses. The recorder appends, so every process contributes to one union.
test:
	@mkdir -p build && : > build/conformance-fixtures-loaded.txt \
		&& rm -f build/conformance-fixtures-loaded.txt.lock
	LAZILY_CONFORMANCE_MANIFEST=$(CURDIR)/build/conformance-fixtures-loaded.txt dart test

# Conformance-coverage guard (#lazilyupgradeconformance). Runtime: fails when a
# canonical fixture was never OPENED by the suite. Naming is not replaying — see
# the script header.
conformance-coverage:
	./scripts/check-conformance-coverage.sh

formal-check:
	dart tool/formal_check.dart
