#!/bin/bash

# ── table: entrypoint behaviors ──────────────────────────────────────────────

# format: label|docker_extra_args|entrypoint_override|command|expected_in_output
ENTRYPOINT_CASES=(
    "version|--entrypoint claude||--version|[0-9]"
    "debug mode|-e DEBUG=true -e CLAUDE_WORKSPACE=/workspace -e CLAUDE_CONTAINER_NAME=${CONTAINER_PREFIX}-debug|||\\[DEBUG"
)

test_entrypoint_behaviors() {
    local entry label docker_extra ep_override cmd expected
    for entry in "${ENTRYPOINT_CASES[@]}"; do
        IFS='|' read -r label docker_extra ep_override cmd expected <<< "$entry"

        local args=(--rm)
        # shellcheck disable=SC2206
        [ -n "$docker_extra" ] && args+=($docker_extra)
        [ -n "$ep_override" ] && args+=($ep_override)
        args+=("$IMAGE")
        [ -n "$cmd" ] && args+=($cmd)

        local out
        out=$(docker run "${args[@]}" 2>&1)
        if echo "$out" | grep -qE "$expected"; then
            echo "  OK: $label"
        else
            echo "  FAIL: $label: expected match for '$expected'"
            echo "  output: ${out:0:300}"
            return 1
        fi
    done
    echo "OK: entrypoint_behaviors (${#ENTRYPOINT_CASES[@]} cases)"
}

# ── UID/GID matching ─────────────────────────────────────────────────────────

test_entrypoint_uid_matching() {
    local tmpdir host_uid
    tmpdir=$(mktemp -d)
    host_uid=$(id -u)

    if [ "$host_uid" = "0" ]; then
        echo "  SKIP: running as root, UID matching not applicable"
        rm -rf "$tmpdir"
        return 0
    fi

    local out
    out=$(docker run --rm \
        -e "CLAUDE_WORKSPACE=$tmpdir" \
        -e "CLAUDE_CONTAINER_NAME=${CONTAINER_PREFIX}-uid" \
        -v "$tmpdir:$tmpdir" \
        --entrypoint bash "$IMAGE" -c \
        "/home/claude/entrypoint.sh echo uid_test 2>/dev/null; id -u claude" 2>&1)

    assert_contains "$out" "$host_uid" "UID matches host ($host_uid)"
    rm -rf "$tmpdir"
}

test_entrypoint_claude_md() {
    local out
    out=$(docker run --rm --entrypoint bash "$IMAGE" -c \
        '/home/claude/entrypoint.sh ls /workspace/CLAUDE.md 2>/dev/null; head -1 /workspace/CLAUDE.md 2>/dev/null' 2>&1)
    assert_contains "$out" "Available Tools" "CLAUDE.md generated with tool listing"
}

# ── system hint generation ───────────────────────────────────────────────────

test_entrypoint_system_hint() {
    local out
    out=$(docker run --rm --entrypoint bash "$IMAGE" -c \
        '/home/claude/entrypoint.sh ls /dev/null 2>/dev/null; cat /home/claude/.claude/system-hint.txt 2>/dev/null' 2>&1)
    assert_contains "$out" "Docker container" "system hint generated"
}

# ── .claude.json config patching ─────────────────────────────────────────────

test_entrypoint_config_patching() {
    local out
    out=$(docker run --rm --entrypoint bash "$IMAGE" -c \
        '/home/claude/entrypoint.sh ls /dev/null 2>/dev/null; cat /home/claude/.claude/.claude.json 2>/dev/null' 2>&1)
    assert_contains "$out" '"installMethod"' "config patched with installMethod" || return 1
    assert_contains "$out" '"native"' "installMethod set to native"
}

# ── init.d scripts ───────────────────────────────────────────────────────────

test_entrypoint_initd() {
    local img
    img=$(docker build -q -f - "$WORKDIR" <<'DEOF'
FROM psyb0t/claudebox:test
RUN mkdir -p /home/claude/.claude/init.d && \
    printf '#!/bin/bash\necho INITRAN > /tmp/init-marker\n' > /home/claude/.claude/init.d/01-test.sh && \
    chmod +x /home/claude/.claude/init.d/01-test.sh
DEOF
    )

    # run entrypoint but check the marker file, not claude output
    local out
    out=$(docker run --rm --entrypoint bash "$img" -c \
        'bash /home/claude/entrypoint.sh echo done 2>/dev/null; cat /tmp/init-marker 2>/dev/null' 2>&1)
    assert_contains "$out" "INITRAN" "init.d script executed"

    docker rmi -f "$img" >/dev/null 2>&1 || true
}

# ── auto --continue (first run tries --continue, falls back) ────────────────

test_entrypoint_auto_continue() {
    # on a fresh container with no previous session, --continue should fail
    # then the entrypoint falls back to running without --continue
    local out
    out=$(docker run --rm \
        -e "CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN" \
        -e "CLAUDE_WORKSPACE=/workspace" \
        -e "CLAUDE_CONTAINER_NAME=${CONTAINER_PREFIX}-autocont" \
        "$IMAGE" \
        -p "respond with exactly AUTOCONT" --output-format text --model "$TEST_MODEL" 2>&1)
    assert_contains "$out" "AUTOCONT" "auto-continue fallback works"
}

ALL_TESTS+=(
    test_entrypoint_behaviors
    test_entrypoint_claude_md
    test_entrypoint_uid_matching
    test_entrypoint_system_hint
    test_entrypoint_config_patching
    test_entrypoint_initd
    test_entrypoint_auto_continue
)
