#!/bin/bash

IMAGE_NAME="psyb0t/claudebox"
TEST_TAG="test"
IMAGE="${IMAGE_NAME}:${TEST_TAG}"
CONTAINER_PREFIX="claudebox-test"
WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXTRA_CONTAINERS=()
ALL_TESTS=()

# load .env
ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "tests/.env not found — create it with CLAUDE_CODE_OAUTH_TOKEN=..." >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    echo "CLAUDE_CODE_OAUTH_TOKEN not set in .env" >&2
    exit 1
fi

# model to use for tests — haiku is fast and cheap
TEST_MODEL="haiku"

# common docker args for running claude
DOCKER_RUN_ARGS=(
    --rm
    --network host
    -e "CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN"
    -e "CLAUDE_WORKSPACE=/workspace"
    -e "CLAUDE_CONTAINER_NAME=${CONTAINER_PREFIX}"
)

# ── assertions ───────────────────────────────────────────────────────────────

assert_eq() {
    local actual="$1" expected="$2" name="$3"
    if [ "$actual" = "$expected" ]; then
        echo "  OK: $name"
        return 0
    fi
    echo "  FAIL: $name: expected '$expected', got '$actual'"
    return 1
}

assert_contains() {
    local actual="$1" expected="$2" name="$3"
    if [[ "$actual" == *"$expected"* ]]; then
        echo "  OK: $name"
        return 0
    fi
    echo "  FAIL: $name: expected to contain '$expected'"
    echo "  actual: ${actual:0:500}"
    return 1
}

assert_not_contains() {
    local actual="$1" unexpected="$2" name="$3"
    if [[ "$actual" != *"$unexpected"* ]]; then
        echo "  OK: $name"
        return 0
    fi
    echo "  FAIL: $name: should NOT contain '$unexpected'"
    echo "  actual: ${actual:0:500}"
    return 1
}

assert_not_empty() {
    local actual="$1" name="$2"
    if [ -n "$actual" ]; then
        echo "  OK: $name"
        return 0
    fi
    echo "  FAIL: $name: expected non-empty output"
    return 1
}

assert_exit_code() {
    local actual="$1" expected="$2" name="$3"
    assert_eq "$actual" "$expected" "$name (exit code)"
}

assert_no_snake_keys() {
    local json_str="$1" name="$2"
    local snake_keys
    snake_keys=$(echo "$json_str" | python3 -c "
import json, sys

ALLOW = set()

def check(obj, path=''):
    if isinstance(obj, dict):
        for k, v in obj.items():
            full = f'{path}.{k}' if path else k
            if '_' in k and k not in ALLOW:
                print(full)
            check(v, full)
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            check(v, f'{path}[{i}]')

try:
    check(json.load(sys.stdin))
except:
    pass
" 2>/dev/null)
    if [ -z "$snake_keys" ]; then
        echo "  OK: $name"
        return 0
    fi
    echo "  FAIL: $name: found snake_case keys:"
    echo "$snake_keys" | head -20 | sed 's/^/    /'
    return 1
}

# ── helpers ──────────────────────────────────────────────────────────────────

json_get() {
    python3 -c "import sys,json; print(json.load(sys.stdin)$1)"
}

post() {
    local url="$1" data="$2"
    curl -sf -X POST "$url" -H "Content-Type: application/json" -d "$data"
}

post_auth() {
    local url="$1" data="$2" token="$3"
    curl -sf -X POST "$url" -H "Content-Type: application/json" -H "Authorization: Bearer $token" -d "$data"
}

wait_for_http() {
    local url="$1" max="${2:-60}"
    for _ in $(seq 1 "$max"); do
        if curl -sf "$url" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "  timeout waiting for $url"
    return 1
}

start_container() {
    local name="$1"
    shift
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" "$@" >/dev/null
    EXTRA_CONTAINERS+=("$name")
}

# ── setup / cleanup ─────────────────────────────────────────────────────────

setup() {
    echo "building claudebox image (--target minimal)..."
    docker build --target minimal -t "$IMAGE" "$WORKDIR" >/dev/null 2>&1
    mkdir -p "$WORKDIR/tests/.fixtures/mounts"
}

cleanup() {
    for c in "${EXTRA_CONTAINERS[@]+"${EXTRA_CONTAINERS[@]}"}"; do
        docker rm -f "$c" >/dev/null 2>&1 || true
    done
    docker rmi -f "$IMAGE" >/dev/null 2>&1 || true
}

test_setup() { :; }
test_teardown() {
    for c in "${EXTRA_CONTAINERS[@]+"${EXTRA_CONTAINERS[@]}"}"; do
        docker rm -f "$c" >/dev/null 2>&1 || true
    done
    EXTRA_CONTAINERS=()
}

usage() {
    echo "usage: $0 [test_name ...]"
    echo ""
    echo "available tests:"
    for t in "${ALL_TESTS[@]}"; do
        echo "  $t"
    done
}
