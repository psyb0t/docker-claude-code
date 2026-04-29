#!/bin/bash

# ── table: image properties ─────────────────────────────────────────────────

BUILD_CHECKS=(
    "entrypoint|Config.Entrypoint|entrypoint.sh"
    "claude user env|Config.Env|DISABLE_AUTOUPDATER=1"
    "minimal variant|Config.Env|CLAUDEBOX_IMAGE_VARIANT=minimal"
)

test_build_image_config() {
    local entry label field expected
    for entry in "${BUILD_CHECKS[@]}"; do
        IFS='|' read -r label field expected <<< "$entry"
        local out
        out=$(docker inspect "$IMAGE" --format "{{json .${field}}}")
        assert_contains "$out" "$expected" "$label" || return 1
    done
    echo "OK: build_image_config (${#BUILD_CHECKS[@]} checks)"
}

# ── table: binaries that should exist ────────────────────────────────────────

BINARY_CHECKS=(
    "claude|claude --version"
    "python|python3 --version"
    "node|node --version"
    "docker|docker --version"
    "git|git --version"
    "jq|jq --version"
)

test_build_binaries() {
    local entry label cmd
    for entry in "${BINARY_CHECKS[@]}"; do
        IFS='|' read -r label cmd <<< "$entry"
        # shellcheck disable=SC2086
        docker run --rm --entrypoint bash "$IMAGE" -c "$cmd" >/dev/null 2>&1 || {
            echo "  FAIL: $label not found ($cmd)"
            return 1
        }
        echo "  OK: $label"
    done
    echo "OK: build_binaries (${#BINARY_CHECKS[@]} binaries)"
}

# ── table: user/permission checks ───────────────────────────────────────────

# format: label|command|expected_in_output
USER_CHECKS=(
    "claude user exists|id claude|claude"
    "passwordless sudo|sudo -u claude sudo -n whoami|root"
)

test_build_user_perms() {
    local entry label cmd expected
    for entry in "${USER_CHECKS[@]}"; do
        IFS='|' read -r label cmd expected <<< "$entry"
        local out
        out=$(docker run --rm --entrypoint bash "$IMAGE" -c "$cmd" 2>&1)
        assert_contains "$out" "$expected" "$label" || return 1
    done
    echo "OK: build_user_perms (${#USER_CHECKS[@]} checks)"
}

ALL_TESTS+=(
    test_build_image_config
    test_build_binaries
    test_build_user_perms
)
