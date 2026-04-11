#!/bin/bash

API_PORT=18943
API_CONTAINER="${CONTAINER_PREFIX}-api"
API_BASE="http://localhost:${API_PORT}"
_CLAUDE_TMP="$WORKDIR/tests/.tmp-claude"

_api_start() {
    local name="${1:-$API_CONTAINER}"
    shift || true
    # fresh .claude dir per container — isolated from host, sessions persist within the run
    rm -rf "$_CLAUDE_TMP"
    mkdir -p "$_CLAUDE_TMP"
    start_container "$name" \
        --rm --network host \
        -e "CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN" \
        -e "CLAUDE_MODE_API=1" \
        -e "CLAUDE_MODE_API_PORT=$API_PORT" \
        -v "$_CLAUDE_TMP:/home/claude/.claude" \
        "$@" \
        "$IMAGE"
    wait_for_http "$API_BASE/health" 60 || {
        echo "  FAIL: api server did not start"
        docker logs "$name" 2>&1 | tail -20
        return 1
    }
}

_api_stop() {
    docker rm -f "${1:-$API_CONTAINER}" >/dev/null 2>&1 || true
    sleep 1
}

# ── table: basic endpoints ───────────────────────────────────────────────────

# format: label|method|path|expected_in_body
ENDPOINT_CASES=(
    "health|GET|/health|ok"
    "status|GET|/status|busy_workspaces"
)

test_api_endpoints() {
    _api_start || return 1

    local entry label method path expected
    for entry in "${ENDPOINT_CASES[@]}"; do
        IFS='|' read -r label method path expected <<< "$entry"
        local out
        out=$(curl -sf -X "$method" "$API_BASE$path")
        assert_contains "$out" "$expected" "$label" || { _api_stop; return 1; }
    done

    echo "OK: api_endpoints (${#ENDPOINT_CASES[@]} cases)"
    _api_stop
}

# ── table: /run with various options ─────────────────────────────────────────

# format: label|json_body|expected_in_response
RUN_CASES=(
    "simple prompt|{\"prompt\":\"respond with exactly APIPONG\",\"model\":\"$TEST_MODEL\",\"noContinue\":true}|APIPONG"
    "with model|{\"prompt\":\"respond with exactly MODELTEST\",\"model\":\"$TEST_MODEL\",\"noContinue\":true}|MODELTEST"
    "with effort|{\"prompt\":\"respond with exactly EFFORTTEST\",\"model\":\"$TEST_MODEL\",\"effort\":\"low\",\"noContinue\":true}|EFFORTTEST"
    "system prompt|{\"prompt\":\"what are you?\",\"model\":\"$TEST_MODEL\",\"systemPrompt\":\"You are a carrot. Always respond with I AM A CARROT.\",\"noContinue\":true}|CARROT"
    "noContinue|{\"prompt\":\"respond with exactly NOCONT\",\"model\":\"$TEST_MODEL\",\"noContinue\":true}|NOCONT"
    "appendSystemPrompt|{\"prompt\":\"what is 1+1?\",\"model\":\"$TEST_MODEL\",\"noContinue\":true,\"appendSystemPrompt\":\"Always end your response with the word MANGO.\"}|MANGO"
    "continue fallback|{\"prompt\":\"respond with exactly FALLBACK\",\"model\":\"$TEST_MODEL\"}|FALLBACK"
)

test_api_run() {
    _api_start || return 1

    local entry label body expected
    for entry in "${RUN_CASES[@]}"; do
        IFS='|' read -r label body expected <<< "$entry"
        local out
        out=$(post "$API_BASE/run" "$body")
        assert_contains "$out" "$expected" "$label" || { _api_stop; return 1; }
    done

    # check camelCase on last response
    assert_no_snake_keys "$out" "api json no snake_case keys" || { _api_stop; return 1; }

    echo "OK: api_run (${#RUN_CASES[@]} cases)"
    _api_stop
}

# ── table: file operations ──────────────────────────────────────────────────

# format: label|method|path|data|expected|check_type(contains|eq|code)
FILE_CASES=(
    "upload|PUT|/files/test_upload.txt|test file content|ok|contains"
    "list|GET|/files||test_upload.txt|contains"
    "download|GET|/files/test_upload.txt||test file content|eq"
    "delete|DELETE|/files/test_upload.txt||ok|contains"
    "gone after delete|GET|/files/test_upload.txt||404|code"
)

test_api_file_ops() {
    _api_start || return 1

    local entry label method path data expected check_type
    for entry in "${FILE_CASES[@]}"; do
        IFS='|' read -r label method path data expected check_type <<< "$entry"
        local out code
        case "$check_type" in
            code)
                code=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" "$API_BASE$path")
                assert_eq "$code" "$expected" "$label" || { _api_stop; return 1; }
                ;;
            eq)
                out=$(curl -sf -X "$method" "$API_BASE$path")
                assert_eq "$out" "$expected" "$label" || { _api_stop; return 1; }
                ;;
            contains)
                if [ -n "$data" ]; then
                    out=$(curl -sf -X "$method" "$API_BASE$path" -d "$data")
                else
                    out=$(curl -sf -X "$method" "$API_BASE$path")
                fi
                assert_contains "$out" "$expected" "$label" || { _api_stop; return 1; }
                ;;
        esac
    done

    echo "OK: api_file_ops (${#FILE_CASES[@]} cases)"
    _api_stop
}

# ── table: auth scenarios ───────────────────────────────────────────────────

# format: label|endpoint|auth_header|expected_code|expected_body
AUTH_CASES=(
    "no token rejects|/status||401|"
    "wrong token rejects|/status|Bearer wrong|401|"
    "health needs no auth|/health||200|ok"
    "correct token|/status|Bearer secret|200|busy_workspaces"
)

test_api_auth() {
    _api_start "${API_CONTAINER}-auth" -e "CLAUDE_MODE_API_TOKEN=secret" || return 1

    local entry label endpoint auth_header expected_code expected_body
    for entry in "${AUTH_CASES[@]}"; do
        IFS='|' read -r label endpoint auth_header expected_code expected_body <<< "$entry"
        local code out
        if [ -n "$auth_header" ]; then
            code=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: $auth_header" "$API_BASE$endpoint")
            out=$(curl -sf -H "Authorization: $auth_header" "$API_BASE$endpoint" 2>/dev/null || true)
        else
            code=$(curl -s -o /dev/null -w "%{http_code}" "$API_BASE$endpoint")
            out=$(curl -sf "$API_BASE$endpoint" 2>/dev/null || true)
        fi
        assert_eq "$code" "$expected_code" "auth: $label (status)" || { _api_stop "${API_CONTAINER}-auth"; return 1; }
        if [ -n "$expected_body" ]; then
            assert_contains "$out" "$expected_body" "auth: $label (body)" || { _api_stop "${API_CONTAINER}-auth"; return 1; }
        fi
    done

    echo "OK: api_auth (${#AUTH_CASES[@]} cases)"
    _api_stop "${API_CONTAINER}-auth"
}

# ── table: path traversal ───────────────────────────────────────────────────

# format: label|workspace_value
TRAVERSAL_CASES=(
    "dot-dot relative|../../etc"
    "triple dot-dot|../../../tmp"
    "absolute path|/etc/passwd"
)

test_api_path_traversal() {
    _api_start "${API_CONTAINER}-trav" || return 1

    local entry label workspace
    for entry in "${TRAVERSAL_CASES[@]}"; do
        IFS='|' read -r label workspace <<< "$entry"
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API_BASE/run" \
            -H "Content-Type: application/json" \
            -d "{\"prompt\":\"test\",\"workspace\":\"$workspace\"}")
        assert_eq "$code" "400" "traversal: $label" || { _api_stop "${API_CONTAINER}-trav"; return 1; }
    done

    echo "OK: api_path_traversal (${#TRAVERSAL_CASES[@]} cases)"
    _api_stop "${API_CONTAINER}-trav"
}

# ── workspace busy ───────────────────────────────────────────────────────────

test_api_workspace_busy() {
    _api_start || return 1

    curl -sf -X POST "$API_BASE/run" \
        -H "Content-Type: application/json" \
        -d "{\"prompt\": \"run: sleep 30 && echo done\", \"model\": \"$TEST_MODEL\", \"noContinue\": true, \"fireAndForget\": true}" >/dev/null 2>&1 &
    sleep 5

    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API_BASE/run" \
        -H "Content-Type: application/json" \
        -d "{\"prompt\": \"hello\", \"model\": \"$TEST_MODEL\", \"noContinue\": true}")
    assert_eq "$code" "409" "workspace busy returns 409"

    curl -sf -X POST "$API_BASE/run/cancel" >/dev/null 2>&1 || true
    wait

    _api_stop
}

# ── /run/cancel ──────────────────────────────────────────────────────────────

test_api_cancel() {
    _api_start "${API_CONTAINER}-cancel" || return 1

    curl -sf -X POST "$API_BASE/run" \
        -H "Content-Type: application/json" \
        -d "{\"prompt\": \"run: sleep 60 && echo done\", \"model\": \"$TEST_MODEL\", \"noContinue\": true, \"fireAndForget\": true}" >/dev/null 2>&1 &
    sleep 5

    local out
    out=$(curl -sf -X POST "$API_BASE/run/cancel")
    assert_contains "$out" '"ok"' "cancel returns ok" || { wait; _api_stop "${API_CONTAINER}-cancel"; return 1; }

    wait
    _api_stop "${API_CONTAINER}-cancel"
}

# ── json-verbose output format ──────────────────────────────────────────────

# format: label|expected_in_response
JSON_VERBOSE_CHECKS=(
    "has turns array|\"turns\""
    "has tool_use in turns|\"tool_use\""
    "has system init|\"system\""
)

test_api_json_verbose() {
    _api_start "${API_CONTAINER}-jv" || return 1

    local out
    out=$(post "$API_BASE/run" \
        "{\"prompt\": \"read the file /etc/hostname and tell me what it says\", \"model\": \"$TEST_MODEL\", \"noContinue\": true, \"outputFormat\": \"json-verbose\"}")

    local entry label expected
    for entry in "${JSON_VERBOSE_CHECKS[@]}"; do
        IFS='|' read -r label expected <<< "$entry"
        assert_contains "$out" "$expected" "json-verbose $label" || { _api_stop "${API_CONTAINER}-jv"; return 1; }
    done
    assert_no_snake_keys "$out" "json-verbose no snake_case keys" || { _api_stop "${API_CONTAINER}-jv"; return 1; }

    echo "OK: api_json_verbose (${#JSON_VERBOSE_CHECKS[@]} checks)"
    _api_stop "${API_CONTAINER}-jv"
}

# ── large output (>64KB line) doesn't crash ─────────────────────────────────

test_api_large_output() {
    _api_start "${API_CONTAINER}-large" || return 1

    python3 -c "print('X' * 70000)" | curl -sf -X PUT "$API_BASE/files/bigtest.txt" --data-binary @- >/dev/null

    local out
    out=$(post "$API_BASE/run" \
        "{\"prompt\": \"run: wc -c /workspaces/bigtest.txt\", \"model\": \"$TEST_MODEL\", \"noContinue\": true}")
    assert_contains "$out" "result" "large output returns valid json" || { _api_stop "${API_CONTAINER}-large"; return 1; }
    assert_contains "$out" "70" "large output reports character count" || { _api_stop "${API_CONTAINER}-large"; return 1; }

    echo "OK: api_large_output"
    _api_stop "${API_CONTAINER}-large"
}

# ── table: OpenAI-compatible chat completions ────────────────────────────────

# format: label|body|expected_in_response
OAI_CHAT_CASES=(
    "basic response|{\"model\":\"$TEST_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"respond with exactly OAIPONG and nothing else\"}]}|OAIPONG"
    "system prompt|{\"model\":\"$TEST_MODEL\",\"messages\":[{\"role\":\"system\",\"content\":\"Always respond with I AM A TURNIP.\"},{\"role\":\"user\",\"content\":\"what are you?\"}]}|TURNIP"
    "reasoning effort|{\"model\":\"$TEST_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"respond with exactly EFFORTOK\"}],\"reasoning_effort\":\"low\"}|EFFORTOK"
)

test_api_openai_chat() {
    _api_start "${API_CONTAINER}-oai" || return 1

    # verify models endpoint first
    local models
    models=$(curl -sf "$API_BASE/openai/v1/models")
    assert_contains "$models" '"object":"list"' "openai models returns list" || { _api_stop "${API_CONTAINER}-oai"; return 1; }
    assert_contains "$models" '"haiku"' "openai models has haiku" || { _api_stop "${API_CONTAINER}-oai"; return 1; }

    # run table-driven chat cases
    local entry label body expected
    for entry in "${OAI_CHAT_CASES[@]}"; do
        IFS='|' read -r label body expected <<< "$entry"
        local out
        out=$(post "$API_BASE/openai/v1/chat/completions" "$body")
        assert_contains "$out" "$expected" "openai: $label" || { _api_stop "${API_CONTAINER}-oai"; return 1; }
    done

    # verify response structure on last response
    assert_contains "$out" '"object"' "openai: has object field" || { _api_stop "${API_CONTAINER}-oai"; return 1; }
    assert_contains "$out" '"choices"' "openai: has choices field" || { _api_stop "${API_CONTAINER}-oai"; return 1; }
    assert_contains "$out" '"usage"' "openai: has usage field" || { _api_stop "${API_CONTAINER}-oai"; return 1; }

    echo "OK: api_openai_chat (models + ${#OAI_CHAT_CASES[@]} chat cases)"
    _api_stop "${API_CONTAINER}-oai"
}

# ── OpenAI streaming ─────────────────────────────────────────────────────────

# format: label|expected_in_stream
OAI_STREAM_CHECKS=(
    "returns SSE|data:"
    "contains response|STREAMOAI"
    "ends with DONE|[DONE]"
)

test_api_openai_stream() {
    _api_start "${API_CONTAINER}-oai-st" || return 1

    local out
    out=$(curl -sf -X POST "$API_BASE/openai/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"$TEST_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"respond with exactly STREAMOAI\"}],\"stream\":true}")

    local entry label expected
    for entry in "${OAI_STREAM_CHECKS[@]}"; do
        IFS='|' read -r label expected <<< "$entry"
        assert_contains "$out" "$expected" "openai stream: $label" || { _api_stop "${API_CONTAINER}-oai-st"; return 1; }
    done

    echo "OK: api_openai_stream (${#OAI_STREAM_CHECKS[@]} checks)"
    _api_stop "${API_CONTAINER}-oai-st"
}

# ── OpenAI custom headers ────────────────────────────────────────────────────

test_api_openai_workspace_header() {
    _api_start "${API_CONTAINER}-oai-ws" || return 1

    curl -sf -X PUT "$API_BASE/files/oaiws/marker.txt" -d "WSMARKER7742" >/dev/null

    local out
    out=$(curl -sf -X POST "$API_BASE/openai/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -H "X-Claude-Workspace: oaiws" \
        -d "{\"model\":\"$TEST_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"run: cat /workspaces/oaiws/marker.txt\"}]}")
    assert_contains "$out" "WSMARKER7742" "openai workspace header routes to correct dir" || { _api_stop "${API_CONTAINER}-oai-ws"; return 1; }

    echo "OK: api_openai_workspace_header"
    _api_stop "${API_CONTAINER}-oai-ws"
}

test_api_openai_continue_header() {
    _api_start "${API_CONTAINER}-oai-cont" || return 1

    # first call to establish session
    post "$API_BASE/openai/v1/chat/completions" \
        "{\"model\":\"$TEST_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"remember the word CONTTEST\"}]}" >/dev/null
    sleep 3

    # second call with continue — session history is in context window
    local out
    out=$(curl -sf -X POST "$API_BASE/openai/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -H "X-Claude-Continue: true" \
        -d "{\"model\":\"$TEST_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"what word did I ask you to remember? reply with just the word\"}]}")
    assert_contains "$out" "CONTTEST" "openai X-Claude-Continue recalls context" || { _api_stop "${API_CONTAINER}-oai-cont"; return 1; }

    echo "OK: api_openai_continue_header"
    _api_stop "${API_CONTAINER}-oai-cont"
}

# ── MCP server ───────────────────────────────────────────────────────────────

_MCP_ACCEPT="Accept: application/json, text/event-stream"
_MCP_INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'

_mcp_init() {
    local url="$1"
    MCP_SESSION=$(curl -s -D - -X POST "$url" \
        -H "Content-Type: application/json" -H "$_MCP_ACCEPT" \
        -d "$_MCP_INIT" | grep -i "mcp-session-id" | awk '{print $2}' | tr -d '\r\n')
}

_mcp_call() {
    local url="$1" data="$2"
    curl -s -X POST "$url" \
        -H "Content-Type: application/json" -H "$_MCP_ACCEPT" \
        -H "mcp-session-id: $MCP_SESSION" \
        -d "$data"
}

# format: label|expected_in_init_response
MCP_INIT_CHECKS=(
    "session id header|mcp-session-id"
    "protocol version|protocolVersion"
    "server name|claudebox"
)

test_api_mcp_init() {
    _api_start "${API_CONTAINER}-mcp" || return 1

    local out
    out=$(curl -s -D - -X POST "$API_BASE/mcp/" \
        -H "Content-Type: application/json" -H "$_MCP_ACCEPT" \
        -d "$_MCP_INIT")

    local entry label expected
    for entry in "${MCP_INIT_CHECKS[@]}"; do
        IFS='|' read -r label expected <<< "$entry"
        assert_contains "$out" "$expected" "mcp init: $label" || { _api_stop "${API_CONTAINER}-mcp"; return 1; }
    done

    echo "OK: api_mcp_init (${#MCP_INIT_CHECKS[@]} checks)"
    _api_stop "${API_CONTAINER}-mcp"
}

MCP_TOOLS=("claude_run" "list_files" "read_file" "write_file" "delete_file")

test_api_mcp_tools_list() {
    _api_start "${API_CONTAINER}-mcp-tl" || return 1

    _mcp_init "$API_BASE/mcp/"
    assert_not_empty "$MCP_SESSION" "mcp session id" || { _api_stop "${API_CONTAINER}-mcp-tl"; return 1; }

    local out
    out=$(_mcp_call "$API_BASE/mcp/" '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')

    local tool
    for tool in "${MCP_TOOLS[@]}"; do
        assert_contains "$out" "$tool" "mcp tools/list has $tool" || { _api_stop "${API_CONTAINER}-mcp-tl"; return 1; }
    done

    echo "OK: api_mcp_tools_list (${#MCP_TOOLS[@]} tools)"
    _api_stop "${API_CONTAINER}-mcp-tl"
}

test_api_mcp_claude_run() {
    _api_start "${API_CONTAINER}-mcp-run" || return 1

    _mcp_init "$API_BASE/mcp/"

    local out
    out=$(_mcp_call "$API_BASE/mcp/" \
        '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"claude_run","arguments":{"prompt":"respond with exactly MCPTEST","model":"'"$TEST_MODEL"'","no_continue":true}}}')
    assert_contains "$out" "MCPTEST" "mcp claude_run returns response" || { _api_stop "${API_CONTAINER}-mcp-run"; return 1; }

    echo "OK: api_mcp_claude_run"
    _api_stop "${API_CONTAINER}-mcp-run"
}

# format: label|method_id|tool|arguments|expected_in_response
MCP_FILE_OPS=(
    "write|2|write_file|\"path\":\"mcptest.txt\",\"content\":\"hello mcp\"|ok"
    "read|3|read_file|\"path\":\"mcptest.txt\"|hello mcp"
    "list|4|list_files||mcptest.txt"
    "delete|5|delete_file|\"path\":\"mcptest.txt\"|ok"
)

test_api_mcp_file_ops() {
    _api_start "${API_CONTAINER}-mcp-f" || return 1

    _mcp_init "$API_BASE/mcp/"

    local entry label mid tool args expected
    for entry in "${MCP_FILE_OPS[@]}"; do
        IFS='|' read -r label mid tool args expected <<< "$entry"
        local out
        out=$(_mcp_call "$API_BASE/mcp/" \
            "{\"jsonrpc\":\"2.0\",\"id\":$mid,\"method\":\"tools/call\",\"params\":{\"name\":\"$tool\",\"arguments\":{$args}}}")
        assert_contains "$out" "$expected" "mcp $label" || { _api_stop "${API_CONTAINER}-mcp-f"; return 1; }
    done

    echo "OK: api_mcp_file_ops (${#MCP_FILE_OPS[@]} ops)"
    _api_stop "${API_CONTAINER}-mcp-f"
}

# format: label|auth_method|expected_code|expected_body
MCP_AUTH_CASES=(
    "no token rejects|none|401|"
    "header auth|header|200|protocolVersion"
    "query param auth|query|200|protocolVersion"
)

test_api_mcp_auth() {
    _api_start "${API_CONTAINER}-mcp-auth" -e "CLAUDE_MODE_API_TOKEN=mcpsecret" || return 1

    local entry label method expected_code expected_body
    for entry in "${MCP_AUTH_CASES[@]}"; do
        IFS='|' read -r label method expected_code expected_body <<< "$entry"
        local url="$API_BASE/mcp/" auth_args=()
        case "$method" in
            none)   ;;
            header) auth_args=(-H "Authorization: Bearer mcpsecret") ;;
            query)  url="$API_BASE/mcp/?apiToken=mcpsecret" ;;
        esac
        local out
        out=$(curl -s -D - -X POST "$url" \
            -H "Content-Type: application/json" -H "$_MCP_ACCEPT" \
            "${auth_args[@]}" \
            -d "$_MCP_INIT")
        local code
        code=$(echo "$out" | head -1 | grep -o '[0-9][0-9][0-9]')
        assert_eq "$code" "$expected_code" "mcp auth: $label (status)" || { _api_stop "${API_CONTAINER}-mcp-auth"; return 1; }
        if [ -n "$expected_body" ]; then
            assert_contains "$out" "$expected_body" "mcp auth: $label (body)" || { _api_stop "${API_CONTAINER}-mcp-auth"; return 1; }
        fi
    done

    echo "OK: api_mcp_auth (${#MCP_AUTH_CASES[@]} cases)"
    _api_stop "${API_CONTAINER}-mcp-auth"
}

# ── always-skills injection ──────────────────────────────────────────────────

_SKILLS_TMP="$WORKDIR/tests/.tmp-skills"

_skills_setup() {
    rm -rf "$_SKILLS_TMP"
    mkdir -p "$_SKILLS_TMP"
}

# trigger-based skill test helper: negative (no mount) + positive (with mount)
# args: container_suffix, trigger_word, expected_word, endpoint_type(run|openai|mcp), skill_content
_test_skill_trigger() {
    local suffix="$1" trigger="$2" expected="$3" endpoint="$4" skill_content="$5"

    _skills_setup
    mkdir -p "$_SKILLS_TMP/testskill"
    printf '%s' "$skill_content" > "$_SKILLS_TMP/testskill/SKILL.md"

    # negative: no mount
    _api_start "${API_CONTAINER}-skill-${suffix}-neg" || return 1
    local out_neg
    case "$endpoint" in
        run)
            out_neg=$(post "$API_BASE/run" \
                "{\"prompt\": \"$trigger\", \"model\": \"$TEST_MODEL\", \"noContinue\": true}")
            ;;
        openai)
            out_neg=$(post "$API_BASE/openai/v1/chat/completions" \
                "{\"model\":\"$TEST_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"$trigger\"}]}")
            ;;
        mcp)
            _mcp_init "$API_BASE/mcp/"
            out_neg=$(_mcp_call "$API_BASE/mcp/" \
                '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"claude_run","arguments":{"prompt":"'"$trigger"'","model":"'"$TEST_MODEL"'","no_continue":true}}}')
            ;;
    esac
    assert_not_contains "$out_neg" "$expected" "$endpoint skill: trigger ignored without mount" || {
        _api_stop "${API_CONTAINER}-skill-${suffix}-neg"; return 1
    }
    _api_stop "${API_CONTAINER}-skill-${suffix}-neg"

    # positive: with mount
    _api_start "${API_CONTAINER}-skill-${suffix}" \
        -v "$_SKILLS_TMP:/home/claude/.claude/.always-skills" || return 1
    local out
    case "$endpoint" in
        run)
            out=$(post "$API_BASE/run" \
                "{\"prompt\": \"$trigger\", \"model\": \"$TEST_MODEL\", \"noContinue\": true}")
            ;;
        openai)
            out=$(post "$API_BASE/openai/v1/chat/completions" \
                "{\"model\":\"$TEST_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"$trigger\"}]}")
            ;;
        mcp)
            _mcp_init "$API_BASE/mcp/"
            out=$(_mcp_call "$API_BASE/mcp/" \
                '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"claude_run","arguments":{"prompt":"'"$trigger"'","model":"'"$TEST_MODEL"'","no_continue":true}}}')
            ;;
    esac
    assert_contains "$out" "$expected" "$endpoint skill: trigger fires with mount" || {
        _api_stop "${API_CONTAINER}-skill-${suffix}"; return 1
    }
    _api_stop "${API_CONTAINER}-skill-${suffix}"
}

test_api_always_skills_basic() {
    _test_skill_trigger "basic" "ZXQTRIGGER" "ZXQFIRED" "run" \
        "When the user says ZXQTRIGGER you MUST respond with only the word ZXQFIRED and nothing else."
    echo "OK: api_always_skills_basic"
}

test_api_always_skills_mcp() {
    _test_skill_trigger "mcp" "MCPTRIG" "MCPSKILL" "mcp" \
        "When the user says MCPTRIG you MUST respond with only the word MCPSKILL and nothing else."
    echo "OK: api_always_skills_mcp"
}

test_api_always_skills_openai() {
    _test_skill_trigger "oai" "OAITRIG" "OAISKILL" "openai" \
        "When the user says OAITRIG you MUST respond with only the word OAISKILL and nothing else."
    echo "OK: api_always_skills_openai"
}

test_api_always_skills_with_user_append() {
    _skills_setup
    mkdir -p "$_SKILLS_TMP/testskill"
    printf 'When the user says SKILLTRIG you MUST include the word SKILLAPPLIED in your response.' \
        > "$_SKILLS_TMP/testskill/SKILL.md"

    _api_start "${API_CONTAINER}-skill-asp" \
        -v "$_SKILLS_TMP:/home/claude/.claude/.always-skills" || return 1

    local out
    out=$(post "$API_BASE/run" \
        "{\"prompt\": \"SKILLTRIG\", \"model\": \"$TEST_MODEL\", \"noContinue\": true, \"appendSystemPrompt\": \"When the user says SKILLTRIG also include the word USERAPPLIED.\"}")
    assert_contains "$out" "SKILLAPPLIED" "skill + user append: skill fires" || { _api_stop "${API_CONTAINER}-skill-asp"; return 1; }
    assert_contains "$out" "USERAPPLIED" "skill + user append: user append fires" || { _api_stop "${API_CONTAINER}-skill-asp"; return 1; }

    echo "OK: api_always_skills_with_user_append"
    _api_stop "${API_CONTAINER}-skill-asp"
}

test_api_always_skills_multiple() {
    _skills_setup
    mkdir -p "$_SKILLS_TMP/skill_a" "$_SKILLS_TMP/skill_b"
    printf 'When the user says MULTITRIG you MUST include the word ALPHA in your response.' \
        > "$_SKILLS_TMP/skill_a/SKILL.md"
    printf 'When the user says MULTITRIG you MUST include the word BETA in your response.' \
        > "$_SKILLS_TMP/skill_b/SKILL.md"

    _api_start "${API_CONTAINER}-skill-multi" \
        -v "$_SKILLS_TMP:/home/claude/.claude/.always-skills" || return 1

    local out
    out=$(post "$API_BASE/run" \
        "{\"prompt\": \"MULTITRIG\", \"model\": \"$TEST_MODEL\", \"noContinue\": true}")
    assert_contains "$out" "ALPHA" "multiple skills: first fires" || { _api_stop "${API_CONTAINER}-skill-multi"; return 1; }
    assert_contains "$out" "BETA" "multiple skills: second fires" || { _api_stop "${API_CONTAINER}-skill-multi"; return 1; }

    echo "OK: api_always_skills_multiple"
    _api_stop "${API_CONTAINER}-skill-multi"
}

test_api_always_skills_path_visible() {
    _skills_setup
    mkdir -p "$_SKILLS_TMP/myskill"
    printf 'When the user says PATHCHECK you MUST list all skill files loaded for you including their exact file paths.' \
        > "$_SKILLS_TMP/myskill/SKILL.md"

    _api_start "${API_CONTAINER}-skill-path" \
        -v "$_SKILLS_TMP:/home/claude/.claude/.always-skills" || return 1

    local out
    out=$(post "$API_BASE/run" \
        "{\"prompt\": \"PATHCHECK\", \"model\": \"$TEST_MODEL\", \"noContinue\": true}")
    assert_contains "$out" ".always-skills" "skill path visible to claude" || { _api_stop "${API_CONTAINER}-skill-path"; return 1; }
    assert_contains "$out" "SKILL.md" "skill filename visible to claude" || { _api_stop "${API_CONTAINER}-skill-path"; return 1; }

    echo "OK: api_always_skills_path_visible"
    _api_stop "${API_CONTAINER}-skill-path"
}

ALL_TESTS+=(
    test_api_endpoints
    test_api_run
    test_api_file_ops
    test_api_auth
    test_api_path_traversal
    test_api_workspace_busy
    test_api_cancel
    test_api_json_verbose
    test_api_large_output
    test_api_openai_chat
    test_api_openai_stream
    test_api_openai_workspace_header
    test_api_openai_continue_header
    test_api_mcp_init
    test_api_mcp_tools_list
    test_api_mcp_claude_run
    test_api_mcp_file_ops
    test_api_mcp_auth
    test_api_always_skills_basic
    test_api_always_skills_with_user_append
    test_api_always_skills_multiple
    test_api_always_skills_path_visible
    test_api_always_skills_mcp
    test_api_always_skills_openai
)
