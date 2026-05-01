#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/tests/common.sh"

# shellcheck disable=SC1090
for f in "$SCRIPT_DIR"/tests/test_*.sh; do
    source "$f"
done

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 0
fi

TESTS_TO_RUN=("${@}")
if [ ${#TESTS_TO_RUN[@]} -eq 0 ]; then
    TESTS_TO_RUN=("${ALL_TESTS[@]}")
fi

for t in "${TESTS_TO_RUN[@]}"; do
    if ! declare -f "$t" >/dev/null 2>&1; then
        echo "unknown test: $t"
        echo ""
        usage
        exit 1
    fi
done

trap cleanup EXIT
setup

# Per-test logs: stdout+stderr of every test goes to tests/logs/<testname>.log
# (overwritten each run). The new e2e tests also dump container logs into this
# dir so a failure has all the evidence in one place.
export TEST_LOG_DIR="$SCRIPT_DIR/tests/logs"
mkdir -p "$TEST_LOG_DIR"

echo ""
echo "=== running ${#TESTS_TO_RUN[@]} test(s) ==="
echo "    per-test logs: $TEST_LOG_DIR/<testname>.log"
echo ""

FAILED=0
PASSED=0

for t in "${TESTS_TO_RUN[@]}"; do
    echo "--- $t ---"
    test_setup
    log_file="$TEST_LOG_DIR/$t.log"
    : > "$log_file"   # truncate for this run
    # Run the test, tee its output into the per-test log, recover the test's
    # own exit code (not tee's) via PIPESTATUS. The `if` form exempts the
    # pipeline from `set -e` so a failing test doesn't kill the runner.
    if $t 2>&1 | tee "$log_file"; then
        PASSED=$((PASSED + 1))
    else
        rc_first=${PIPESTATUS[0]}
        if [ "$rc_first" -eq 0 ]; then
            PASSED=$((PASSED + 1))
        else
            FAILED=$((FAILED + 1))
        fi
    fi
    test_teardown
done

echo ""
echo "=== results: $PASSED passed, $FAILED failed ==="

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
