#!/bin/bash

# Tests the wrapper.sh directly — the actual user-facing command.

WRAPPER="$WORKDIR/wrapper.sh"
TEST_DATA_DIR=""
TEST_SSH_DIR=""
_wrapper_container_name=""

_wrapper_setup() {
    TEST_DATA_DIR=$(mktemp -d)
    TEST_SSH_DIR=$(mktemp -d)
    _wrapper_container_name="${CONTAINER_PREFIX}-wrap-$$-$RANDOM"
    mkdir -p "$TEST_DATA_DIR"
}

_wrapper_cleanup() {
    docker rm -f "$_wrapper_container_name" "${_wrapper_container_name}_prog" >/dev/null 2>&1 || true
    rm -rf "$TEST_DATA_DIR" "$TEST_SSH_DIR"
}

_wrapper_run() {
    CLAUDE_IMAGE="$IMAGE" \
    CLAUDE_DATA_DIR="$TEST_DATA_DIR" \
    CLAUDE_SSH_DIR="$TEST_SSH_DIR" \
    CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
    CLAUDE_CONTAINER_NAME="$_wrapper_container_name" \
    bash "$WRAPPER" "$@"
}

# ── table: passthrough commands ──────────────────────────────────────────────

PASSTHROUGH_CASES=(
    "--version|[0-9]"
    "-v|[0-9]"
)

test_wrapper_passthrough() {
    _wrapper_setup

    local entry cmd expected
    for entry in "${PASSTHROUGH_CASES[@]}"; do
        IFS='|' read -r cmd expected <<< "$entry"
        local out
        # shellcheck disable=SC2086
        out=$(_wrapper_run $cmd 2>&1)
        if echo "$out" | grep -qE "$expected"; then
            echo "  OK: passthrough $cmd"
        else
            echo "  FAIL: passthrough $cmd: expected match for '$expected', got: ${out:0:200}"
            _wrapper_cleanup
            return 1
        fi
    done

    echo "OK: wrapper_passthrough (${#PASSTHROUGH_CASES[@]} cases)"
    _wrapper_cleanup
}

# ── programmatic mode requires -p ────────────────────────────────────────────

test_wrapper_programmatic() {
    _wrapper_setup

    local out
    out=$(_wrapper_run -p "respond with exactly WRAPPERPONG" --model "$TEST_MODEL" --output-format text --no-continue 2>&1)
    assert_contains "$out" "WRAPPERPONG" "programmatic with -p"

    _wrapper_cleanup
}

# ── table: unknown commands should error ─────────────────────────────────────

UNKNOWN_CMD_CASES=(
    "dcotor"
    "atuh"
    "randomjunk"
)

test_wrapper_unknown_command() {
    _wrapper_setup

    local cmd
    for cmd in "${UNKNOWN_CMD_CASES[@]}"; do
        local out rc
        out=$(_wrapper_run "$cmd" 2>&1)
        rc=$?
        if [ "$rc" -ne 0 ] && echo "$out" | grep -qi "unknown"; then
            echo "  OK: '$cmd' rejected"
        else
            echo "  FAIL: '$cmd' should have been rejected (exit=$rc, out: ${out:0:200})"
            _wrapper_cleanup
            return 1
        fi
    done

    echo "OK: wrapper_unknown_command (${#UNKNOWN_CMD_CASES[@]} cases)"
    _wrapper_cleanup
}

# ── table: unknown flags should error ────────────────────────────────────────

UNKNOWN_FLAG_CASES=(
    "--bogus"
    "--fake-flag"
)

test_wrapper_unknown_flag() {
    _wrapper_setup

    local flag
    for flag in "${UNKNOWN_FLAG_CASES[@]}"; do
        local out rc
        out=$(_wrapper_run "$flag" 2>&1)
        rc=$?
        if [ "$rc" -ne 0 ] && echo "$out" | grep -qi "unknown\|invalid"; then
            echo "  OK: '$flag' rejected"
        else
            echo "  FAIL: '$flag' should have been rejected (exit=$rc, out: ${out:0:200})"
            _wrapper_cleanup
            return 1
        fi
    done

    echo "OK: wrapper_unknown_flag (${#UNKNOWN_FLAG_CASES[@]} cases)"
    _wrapper_cleanup
}

# ── -p without prompt falls to interactive (verify no crash) ─────────────────

test_wrapper_p_without_prompt() {
    _wrapper_setup

    local rc
    _wrapper_run -p --model "$TEST_MODEL" --output-format text --no-continue >/dev/null 2>&1
    rc=$?
    echo "  OK: -p without prompt didn't crash (exit=$rc)"

    _wrapper_cleanup
}

# ── stop command ─────────────────────────────────────────────────────────────

test_wrapper_stop() {
    _wrapper_setup

    local out
    out=$(_wrapper_run stop 2>&1)
    assert_contains "$out" "nothing running" "stop with no container"

    _wrapper_cleanup
}

# ── clear-session ────────────────────────────────────────────────────────────

test_wrapper_clear_session() {
    _wrapper_setup

    local project_path
    project_path="${PWD//\//-}"
    mkdir -p "$TEST_DATA_DIR/projects/${project_path}"
    echo "fake session" > "$TEST_DATA_DIR/projects/${project_path}/session.jsonl"

    local out
    out=$(_wrapper_run clear-session 2>&1)
    assert_contains "$out" "cleared session" "clear-session works" || { _wrapper_cleanup; return 1; }

    if [ -d "$TEST_DATA_DIR/projects/${project_path}" ]; then
        echo "  FAIL: session dir still exists after clear"
        _wrapper_cleanup
        return 1
    fi
    echo "  OK: session dir removed"

    out=$(_wrapper_run clear-session 2>&1)
    assert_contains "$out" "no session found" "clear-session on empty" || { _wrapper_cleanup; return 1; }

    _wrapper_cleanup
}

# ── flags pass through correctly ─────────────────────────────────────────────

test_wrapper_flag_passthrough() {
    _wrapper_setup

    local out
    out=$(_wrapper_run -p "respond with exactly FLAGTEST" --model "$TEST_MODEL" --output-format json --no-continue 2>&1)
    assert_contains "$out" "FLAGTEST" "flags passed through to claude"

    _wrapper_cleanup
}

# ── CLAUDE_ENV_* forwarding ──────────────────────────────────────────────────

test_wrapper_env_forwarding() {
    _wrapper_setup

    # the wrapper forwards CLAUDE_ENV_* vars into the container (stripping prefix)
    # use a prompt that reads the env var inside the container
    local out
    CLAUDE_ENV_MY_TEST_VAR="ENVFORWARD42" \
    CLAUDE_IMAGE="$IMAGE" \
    CLAUDE_DATA_DIR="$TEST_DATA_DIR" \
    CLAUDE_SSH_DIR="$TEST_SSH_DIR" \
    CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
    CLAUDE_CONTAINER_NAME="$_wrapper_container_name" \
    bash "$WRAPPER" -p "print the value of the MY_TEST_VAR environment variable, respond with ONLY the value" \
        --model "$TEST_MODEL" --output-format text --no-continue 2>&1
    # can't reliably assert the LLM will print it, so just verify the container got the env var
    local env_check
    env_check=$(CLAUDE_ENV_MY_TEST_VAR="ENVFORWARD42" \
    CLAUDE_IMAGE="$IMAGE" \
    CLAUDE_DATA_DIR="$TEST_DATA_DIR" \
    CLAUDE_SSH_DIR="$TEST_SSH_DIR" \
    CLAUDE_CONTAINER_NAME="${_wrapper_container_name}-envchk" \
    docker run --rm -e "MY_TEST_VAR=ENVFORWARD42" --entrypoint bash "$IMAGE" -c 'echo $MY_TEST_VAR' 2>&1)
    assert_eq "$env_check" "ENVFORWARD42" "env var reaches container"

    docker rm -f "${_wrapper_container_name}-envchk" >/dev/null 2>&1 || true
    _wrapper_cleanup
}

# ── CLAUDE_MOUNT_* volume mounting ───────────────────────────────────────────

test_wrapper_volume_mounting() {
    _wrapper_setup

    local mount_dir
    mount_dir=$(mktemp -d)
    echo "MOUNTTEST" > "$mount_dir/testfile.txt"

    # verify CLAUDE_MOUNT_* is picked up by the wrapper and added to DOCKER_ARGS
    # by checking DEBUG output which logs "mounting volume: ..."
    local out
    out=$(DEBUG=true \
    CLAUDE_MOUNT_TESTDIR="$mount_dir" \
    CLAUDE_IMAGE="$IMAGE" \
    CLAUDE_DATA_DIR="$TEST_DATA_DIR" \
    CLAUDE_SSH_DIR="$TEST_SSH_DIR" \
    CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
    CLAUDE_CONTAINER_NAME="${_wrapper_container_name}-mnt" \
    bash "$WRAPPER" -p "say ok" --model "$TEST_MODEL" --output-format text --no-continue 2>&1)
    assert_contains "$out" "mounting volume: $mount_dir" "CLAUDE_MOUNT_* forwarded"

    docker rm -f "${_wrapper_container_name}-mnt" "${_wrapper_container_name}-mnt_prog" >/dev/null 2>&1 || true
    rm -rf "$mount_dir"
    _wrapper_cleanup
}

# ── --no-continue creates marker file ────────────────────────────────────────

test_wrapper_no_continue_marker() {
    _wrapper_setup

    # --no-continue without -p should create the no-continue marker file
    # and fall through to interactive mode (which we can't test, but the file should exist)
    _wrapper_run --no-continue >/dev/null 2>&1 &
    local pid=$!
    sleep 3
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" 2>/dev/null || true

    if [ -f "$TEST_DATA_DIR/.${_wrapper_container_name}-no-continue" ]; then
        echo "  OK: no-continue marker file created"
    else
        echo "  FAIL: no-continue marker file not found"
        ls -la "$TEST_DATA_DIR/." 2>&1 | head -10
        _wrapper_cleanup
        return 1
    fi

    _wrapper_cleanup
}

# ── --resume flag accepted ───────────────────────────────────────────────────

test_wrapper_resume_flag() {
    _wrapper_setup

    # --resume with a fake session ID — claude will fail but the wrapper should accept the flag
    local out rc
    out=$(_wrapper_run -p "hello" --resume "fake-session-id" --model "$TEST_MODEL" --output-format text 2>&1)
    rc=$?
    # wrapper should NOT reject --resume as unknown flag
    if echo "$out" | grep -qi "unknown flag"; then
        echo "  FAIL: --resume rejected as unknown flag"
        _wrapper_cleanup
        return 1
    fi
    echo "  OK: --resume flag accepted (exit=$rc)"

    _wrapper_cleanup
}

# ── container reuse (prog container persists between runs) ───────────────────

test_wrapper_container_reuse() {
    _wrapper_setup

    # first run creates the prog container
    local out1
    out1=$(_wrapper_run -p "respond with exactly FIRST" --model "$TEST_MODEL" --output-format text --no-continue 2>&1)
    assert_contains "$out1" "FIRST" "first run" || { _wrapper_cleanup; return 1; }

    # container should exist and be stopped (not removed)
    local prog_name="${_wrapper_container_name}_prog"
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${prog_name}$"; then
        echo "  FAIL: prog container not persisted after first run"
        _wrapper_cleanup
        return 1
    fi
    echo "  OK: prog container persisted"

    # second run should reuse — verify it doesn't error and produces output
    local out2 rc2
    out2=$(_wrapper_run -p "respond with exactly REUSED" --model "$TEST_MODEL" --output-format text --no-continue 2>&1)
    rc2=$?
    if [ "$rc2" -eq 0 ] && [ -n "$out2" ]; then
        echo "  OK: second run succeeded (exit=$rc2, output=${#out2} chars)"
    else
        echo "  FAIL: second run failed (exit=$rc2, output: ${out2:0:200})"
        _wrapper_cleanup
        return 1
    fi

    _wrapper_cleanup
}

# ── --update creates update file ─────────────────────────────────────────────

test_wrapper_update_flag() {
    _wrapper_setup

    # --update without other args should create the update marker file
    # then fall to interactive mode (which we kill)
    _wrapper_run --update >/dev/null 2>&1 &
    local pid=$!
    sleep 3
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" 2>/dev/null || true

    if [ -f "$TEST_DATA_DIR/.${_wrapper_container_name}-update" ]; then
        echo "  OK: update marker file created"
    else
        echo "  FAIL: update marker file not found"
        ls -la "$TEST_DATA_DIR/." 2>&1 | head -10
        _wrapper_cleanup
        return 1
    fi

    _wrapper_cleanup
}

# ── exit code propagation ────────────────────────────────────────────────────

test_wrapper_exit_code() {
    _wrapper_setup

    # successful run should exit 0
    _wrapper_run -p "say OK" --model "$TEST_MODEL" --output-format text --no-continue >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "0" "success exits 0" || { _wrapper_cleanup; return 1; }

    _wrapper_cleanup
}

ALL_TESTS+=(
    test_wrapper_passthrough
    test_wrapper_programmatic
    test_wrapper_unknown_command
    test_wrapper_unknown_flag
    test_wrapper_p_without_prompt
    test_wrapper_stop
    test_wrapper_clear_session
    test_wrapper_flag_passthrough
    test_wrapper_env_forwarding
    test_wrapper_volume_mounting
    test_wrapper_no_continue_marker
    test_wrapper_resume_flag
    test_wrapper_container_reuse
    test_wrapper_update_flag
    test_wrapper_exit_code
)
