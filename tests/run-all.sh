#!/bin/sh
# Run the headless Steel test suites in file mode. Run from the repo root:
#   sh tests/run-all.sh
#
# Each suite is a steel-test file: it ends in (run-tests!), which raises on
# any failure or error, so file mode exits nonzero. The exit code is the
# verdict; this script aggregates them.

fail=0
for t in tests/test-*.scm; do
    if steel "$t" >/dev/null 2>&1; then
        echo "PASS $t"
    else
        echo "FAIL $t"
        steel "$t" 2>&1 | sed 's/^/    /'
        fail=1
    fi
done
exit $fail
