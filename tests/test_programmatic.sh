#!/bin/bash

# All programmatic tests go through the wrapper — that's what users actually run.

_prog_data_dir=""
_prog_ssh_dir=""

_prog_container_name=""

_prog_setup() {
    _prog_data_dir=$(mktemp -d "$WORKDIR/tests/.tmp-prog-data-XXXXX")
    _prog_ssh_dir=$(mktemp -d "$WORKDIR/tests/.tmp-prog-ssh-XXXXX")
    _prog_container_name="${CONTAINER_PREFIX}-prog-$$-$RANDOM"
}

_prog_cleanup() {
    docker rm -f "$_prog_container_name" "${_prog_container_name}_prog" >/dev/null 2>&1 || true
    rm -rf "$_prog_data_dir" "$_prog_ssh_dir"
}

_prog_run() {
    [ -z "$_prog_data_dir" ] && { echo "BUG: _prog_setup not called"; return 1; }
    CLAUDE_IMAGE="$IMAGE" \
    CLAUDE_DATA_DIR="$_prog_data_dir" \
    CLAUDE_SSH_DIR="$_prog_ssh_dir" \
    CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
    CLAUDE_CONTAINER_NAME="$_prog_container_name" \
    bash "$WORKDIR/wrapper.sh" "$@"
}

_prog_run_with_token() {
    [ -z "$_prog_data_dir" ] && { echo "BUG: _prog_setup not called"; return 1; }
    local token="$1"
    shift
    CLAUDE_IMAGE="$IMAGE" \
    CLAUDE_DATA_DIR="$_prog_data_dir" \
    CLAUDE_SSH_DIR="$_prog_ssh_dir" \
    CLAUDE_CODE_OAUTH_TOKEN="$token" \
    CLAUDE_CONTAINER_NAME="$_prog_container_name" \
    bash "$WORKDIR/wrapper.sh" "$@"
}

# ── table: prompts with expected output ──────────────────────────────────────

# format: label|extra_args|prompt|expected_in_output
PROMPT_CASES=(
    "simple text|--output-format text|respond with exactly the word PONG and nothing else|PONG"
    "json output|--output-format json|respond with exactly the word HELLO|result"
    "json contains response|--output-format json|respond with exactly the word HELLO|HELLO"
    "effort low|--output-format text --effort low|respond with exactly OK|OK"
)

test_programmatic_prompts() {
    local entry label extra prompt expected
    for entry in "${PROMPT_CASES[@]}"; do
        IFS='|' read -r label extra prompt expected <<< "$entry"
        _prog_setup
        local out
        # shellcheck disable=SC2086
        out=$(_prog_run -p "$prompt" $extra --model "$TEST_MODEL" --no-continue 2>&1)
        assert_contains "$out" "$expected" "$label" || { _prog_cleanup; return 1; }
        _prog_cleanup
    done
    echo "OK: programmatic_prompts (${#PROMPT_CASES[@]} cases)"
}

# ── table: model aliases ─────────────────────────────────────────────────────

MODEL_CASES=(
    "haiku"
)

test_programmatic_models() {
    _prog_setup

    local alias
    for alias in "${MODEL_CASES[@]}"; do
        local out
        out=$(_prog_run -p "respond with exactly YES" \
            --output-format text --model "$alias" --no-continue 2>&1)
        assert_contains "$out" "YES" "model: $alias" || { _prog_cleanup; return 1; }
    done

    echo "OK: programmatic_models (${#MODEL_CASES[@]} models)"
    _prog_cleanup
}

# ── table: system prompt injection ───────────────────────────────────────────

# format: label|flag|flag_value|prompt|expected
SYSTEM_PROMPT_CASES=(
    "system prompt|--system-prompt|You are a potato. Always respond with I AM A POTATO.|what are you?|POTATO"
    "append system prompt|--append-system-prompt|Always end your response with the word BANANA.|what is 2+2?|BANANA"
)

test_programmatic_system_prompts() {
    local entry label flag flag_value prompt expected
    for entry in "${SYSTEM_PROMPT_CASES[@]}"; do
        IFS='|' read -r label flag flag_value prompt expected <<< "$entry"
        _prog_setup
        local out
        out=$(_prog_run -p "$prompt" "$flag" "$flag_value" \
            --output-format text --model "$TEST_MODEL" --no-continue 2>&1)
        assert_contains "$out" "$expected" "$label" || { _prog_cleanup; return 1; }
        _prog_cleanup
    done
    echo "OK: programmatic_system_prompts (${#SYSTEM_PROMPT_CASES[@]} cases)"
}

# ── bad auth ─────────────────────────────────────────────────────────────────

test_programmatic_bad_auth() {
    _prog_setup

    # use a completely separate container name to avoid reusing a container with valid auth
    local bad_name="${CONTAINER_PREFIX}-badauth-$$-$RANDOM"
    CLAUDE_IMAGE="$IMAGE" \
    CLAUDE_DATA_DIR="$_prog_data_dir" \
    CLAUDE_SSH_DIR="$_prog_ssh_dir" \
    CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-INVALID" \
    CLAUDE_CONTAINER_NAME="$bad_name" \
    bash "$WORKDIR/wrapper.sh" \
        -p "hello" --output-format text --model "$TEST_MODEL" --no-continue >/dev/null 2>&1
    local rc=$?
    docker rm -f "$bad_name" "${bad_name}_prog" >/dev/null 2>&1 || true

    if [ "$rc" -ne 0 ]; then
        echo "  OK: bad auth exits non-zero ($rc)"
    else
        echo "  FAIL: bad auth should exit non-zero"
        _prog_cleanup
        return 1
    fi

    _prog_cleanup
}

# ── camelCase normalization ──────────────────────────────────────────────────

test_programmatic_json_camelcase() {
    _prog_setup
    local out
    out=$(_prog_run -p "respond with exactly CAMELTEST" \
        --output-format json --model "$TEST_MODEL" --no-continue 2>&1)
    assert_contains "$out" "CAMELTEST" "json has response" || { _prog_cleanup; return 1; }
    assert_no_snake_keys "$out" "json no snake_case keys" || { _prog_cleanup; return 1; }
    echo "OK: programmatic_json_camelcase"
    _prog_cleanup
}

test_programmatic_json_verbose_camelcase() {
    _prog_setup
    local out
    out=$(_prog_run -p "read the file /etc/hostname" \
        --output-format json-verbose --model "$TEST_MODEL" --no-continue 2>&1)
    assert_contains "$out" '"turns"' "json-verbose has turns" || { _prog_cleanup; return 1; }
    assert_no_snake_keys "$out" "json-verbose no snake_case keys" || { _prog_cleanup; return 1; }
    echo "OK: programmatic_json_verbose_camelcase"
    _prog_cleanup
}

test_programmatic_stream_json_camelcase() {
    _prog_setup
    local out
    out=$(_prog_run -p "respond with exactly STREAMTEST" \
        --output-format stream-json --model "$TEST_MODEL" --no-continue 2>&1)
    assert_contains "$out" "STREAMTEST" "stream-json has response" || { _prog_cleanup; return 1; }
    # check each JSON line
    local line
    local failed=0
    while IFS= read -r line; do
        echo "$line" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null || continue
        assert_no_snake_keys "$line" "stream-json line" || { failed=1; break; }
    done <<< "$out"
    [ "$failed" = "1" ] && { _prog_cleanup; return 1; }
    echo "OK: programmatic_stream_json_camelcase"
    _prog_cleanup
}

# ── always-skills via entrypoint ────────────────────────────────────────────

test_programmatic_always_skills() {
    _prog_setup

    # create skills dir with trigger-based skill
    local skills_dir
    skills_dir=$(mktemp -d "$WORKDIR/tests/.tmp-prog-skills-XXXXX")
    mkdir -p "$skills_dir/testskill"
    printf 'When the user says PROGTRIG you MUST respond with only the word PROGSKILL and nothing else.' \
        > "$skills_dir/testskill/SKILL.md"

    # negative: no skills dir mounted
    local out_neg
    out_neg=$(_prog_run -p "PROGTRIG" --output-format text --model "$TEST_MODEL" --no-continue 2>&1)
    assert_not_contains "$out_neg" "PROGSKILL" "entrypoint skill trigger ignored without mount" || { _prog_cleanup; rm -rf "$skills_dir"; return 1; }
    _prog_cleanup

    # positive: mount skills dir into .claude/.always-skills
    _prog_setup
    mkdir -p "$_prog_data_dir/.always-skills"
    cp -r "$skills_dir/testskill" "$_prog_data_dir/.always-skills/"

    local out
    out=$(_prog_run -p "PROGTRIG" --output-format text --model "$TEST_MODEL" --no-continue 2>&1)
    assert_contains "$out" "PROGSKILL" "entrypoint skill trigger fires with always-skills dir" || { _prog_cleanup; rm -rf "$skills_dir"; return 1; }

    echo "OK: programmatic_always_skills"
    _prog_cleanup
    rm -rf "$skills_dir"
}

ALL_TESTS+=(
    test_programmatic_prompts
    test_programmatic_models
    test_programmatic_system_prompts
    test_programmatic_bad_auth
    test_programmatic_json_camelcase
    test_programmatic_json_verbose_camelcase
    test_programmatic_stream_json_camelcase
    test_programmatic_always_skills
)
