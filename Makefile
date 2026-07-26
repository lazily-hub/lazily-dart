.PHONY: check conformance-coverage

# lazily-dart had no Makefile; verification was ad-hoc `dart analyze` + `dart test`.
# The conformance-coverage guard needs somewhere to hang, and a named `check` makes
# the binding's gate discoverable the way every sibling's is.
check: conformance-coverage
	dart analyze
	dart test
	dart tool/formal_check.dart

# Static guard (#portconformancecoverage): fails when the canonical corpus grows a
# fixture no test here even names. Naming is not replaying — see the script header.
conformance-coverage:
	./scripts/check-conformance-coverage.sh
