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

echo ""
echo "=== running ${#TESTS_TO_RUN[@]} test(s) ==="
echo ""

FAILED=0
PASSED=0

for t in "${TESTS_TO_RUN[@]}"; do
    echo "--- $t ---"
    test_setup
    if $t; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
    fi
    test_teardown
done

echo ""
echo "=== results: $PASSED passed, $FAILED failed ==="

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
