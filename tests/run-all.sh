#!/bin/sh
# Run the headless Steel test suites. Must be run from the repo root:
#   sh tests/run-all.sh
#
# The bare steel CLI exits 0 even when a script raises, so success is
# detected by the SUITE-PASS sentinel the harness prints: a suite that
# crashes or has failing checks never prints it.

fail=0
for t in tests/test-*.scm; do
    out=$(steel < "$t" 2>&1)
    if printf '%s\n' "$out" | grep -q "^SUITE-PASS"; then
        printf '%s\n' "$out" | grep "^SUITE-PASS" | sed "s|^|$t: |"
    else
        echo "$t: FAIL"
        printf '%s\n' "$out" | grep -v "^=> " | sed 's/^/    /'
        fail=1
    fi
done
exit $fail
