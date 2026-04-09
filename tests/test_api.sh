#!/bin/bash

API_PORT=18943
API_CONTAINER="${CONTAINER_PREFIX}-api"
API_BASE="http://localhost:${API_PORT}"

_api_image=""

_api_start() {
    local name="${1:-$API_CONTAINER}"
    shift || true
    start_container "$name" \
        --rm --network host \
        -e "CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN" \
        -e "CLAUDE_MODE_API=1" \
        -e "CLAUDE_MODE_API_PORT=$API_PORT" \
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

# format: label|method|path|data|expected_status_or_body|check_type(contains|eq|code)
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

AUTH_CASES=(
    "no token|/status||401"
    "wrong token|/status|Bearer wrong|401"
    "correct token|/status|Bearer secret|200"
    "health no auth|/health||200"
)

test_api_auth() {
    _api_start "${API_CONTAINER}-auth" -e "CLAUDE_MODE_API_TOKEN=secret" || return 1

    local entry label endpoint auth_header expected_code
    for entry in "${AUTH_CASES[@]}"; do
        IFS='|' read -r label endpoint auth_header expected_code <<< "$entry"
        local code
        if [ -n "$auth_header" ]; then
            code=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: $auth_header" "$API_BASE$endpoint")
        else
            code=$(curl -s -o /dev/null -w "%{http_code}" "$API_BASE$endpoint")
        fi
        assert_eq "$code" "$expected_code" "auth: $label" || { _api_stop "${API_CONTAINER}-auth"; return 1; }
    done

    echo "OK: api_auth (${#AUTH_CASES[@]} cases)"
    _api_stop "${API_CONTAINER}-auth"
}

# ── path traversal ───────────────────────────────────────────────────────────

test_api_path_traversal() {
    _api_start "${API_CONTAINER}-trav" || return 1

    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API_BASE/run" \
        -H "Content-Type: application/json" \
        -d '{"prompt":"test","workspace":"../../etc"}')
    assert_eq "$code" "400" "traversal via workspace param" || { _api_stop "${API_CONTAINER}-trav"; return 1; }

    echo "OK: api_path_traversal"
    _api_stop "${API_CONTAINER}-trav"
}

# ── workspace busy ───────────────────────────────────────────────────────────

test_api_workspace_busy() {
    _api_start || return 1

    curl -sf -X POST "$API_BASE/run" \
        -H "Content-Type: application/json" \
        -d "{\"prompt\": \"count from 1 to 100 slowly\", \"model\": \"$TEST_MODEL\", \"noContinue\": true, \"fireAndForget\": true}" >/dev/null 2>&1 &
    sleep 3

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

    # start a long-running prompt
    curl -sf -X POST "$API_BASE/run" \
        -H "Content-Type: application/json" \
        -d "{\"prompt\": \"write a 10000 word essay about clouds\", \"model\": \"$TEST_MODEL\", \"noContinue\": true, \"fireAndForget\": true}" >/dev/null 2>&1 &
    sleep 3

    # cancel it
    local out
    out=$(curl -sf -X POST "$API_BASE/run/cancel")
    assert_contains "$out" '"ok"' "cancel returns ok" || { wait; _api_stop "${API_CONTAINER}-cancel"; return 1; }

    wait
    _api_stop "${API_CONTAINER}-cancel"
}

# ── noContinue field ─────────────────────────────────────────────────────────

test_api_no_continue() {
    _api_start "${API_CONTAINER}-nocont" || return 1

    local out
    out=$(post "$API_BASE/run" \
        "{\"prompt\": \"respond with exactly NOCONT\", \"model\": \"$TEST_MODEL\", \"noContinue\": true}")
    assert_contains "$out" "NOCONT" "noContinue works"

    _api_stop "${API_CONTAINER}-nocont"
}

# ── appendSystemPrompt field ─────────────────────────────────────────────────

test_api_append_system_prompt() {
    _api_start "${API_CONTAINER}-asp" || return 1

    local out
    out=$(post "$API_BASE/run" \
        "{\"prompt\": \"what is 1+1?\", \"model\": \"$TEST_MODEL\", \"noContinue\": true, \"appendSystemPrompt\": \"Always end your response with the word MANGO.\"}")
    assert_contains "$out" "MANGO" "appendSystemPrompt applied"

    _api_stop "${API_CONTAINER}-asp"
}

# ── table: continue fallback (try --continue, fall back without) ─────────────

test_api_continue_fallback() {
    _api_start "${API_CONTAINER}-cont" || return 1

    # first run without noContinue — should work (--continue may fail on fresh container, falls back)
    local out
    out=$(post "$API_BASE/run" \
        "{\"prompt\": \"respond with exactly FALLBACK\", \"model\": \"$TEST_MODEL\"}")
    assert_contains "$out" "FALLBACK" "continue fallback works"

    _api_stop "${API_CONTAINER}-cont"
}

# ── json-verbose output format ──────────────────────────────────────────────

test_api_json_verbose() {
    _api_start "${API_CONTAINER}-jv" || return 1

    local out
    out=$(post "$API_BASE/run" \
        "{\"prompt\": \"read the file /etc/hostname and tell me what it says\", \"model\": \"$TEST_MODEL\", \"noContinue\": true, \"outputFormat\": \"json-verbose\"}")
    assert_contains "$out" '"turns"' "json-verbose has turns array" || { _api_stop "${API_CONTAINER}-jv"; return 1; }
    assert_contains "$out" '"tool_use"' "json-verbose has tool_use in turns" || { _api_stop "${API_CONTAINER}-jv"; return 1; }
    assert_contains "$out" '"system"' "json-verbose has system init" || { _api_stop "${API_CONTAINER}-jv"; return 1; }
    assert_no_snake_keys "$out" "api json-verbose no snake_case keys" || { _api_stop "${API_CONTAINER}-jv"; return 1; }

    echo "OK: api_json_verbose"
    _api_stop "${API_CONTAINER}-jv"
}

# ── large output (>64KB line) doesn't crash ─────────────────────────────────

test_api_large_output() {
    _api_start "${API_CONTAINER}-large" || return 1

    # generate a file >64KB and ask claude to read it — tool result will be one big JSON line
    local big_file="/tmp/bigfile_$$.txt"
    python3 -c "print('X' * 70000)" > "$big_file"
    curl -sf -X PUT "$API_BASE/files/bigtest.txt" --data-binary @"$big_file" >/dev/null
    rm -f "$big_file"

    local out code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API_BASE/run" \
        -H "Content-Type: application/json" \
        -d "{\"prompt\": \"read the file /workspaces/bigtest.txt and tell me how many characters it has\", \"model\": \"$TEST_MODEL\", \"noContinue\": true}")
    assert_eq "$code" "200" "large output does not crash (no 500)" || { _api_stop "${API_CONTAINER}-large"; return 1; }

    echo "OK: api_large_output"
    _api_stop "${API_CONTAINER}-large"
}

# ── OpenAI-compatible adapter ─────────────────────────────────────────────────

test_api_openai_models() {
    _api_start "${API_CONTAINER}-oai-m" || return 1

    local out
    out=$(curl -sf "$API_BASE/openai/v1/models")
    assert_contains "$out" '"object":"list"' "openai models returns list" || { _api_stop "${API_CONTAINER}-oai-m"; return 1; }
    assert_contains "$out" '"haiku"' "openai models contains haiku" || { _api_stop "${API_CONTAINER}-oai-m"; return 1; }

    echo "OK: api_openai_models"
    _api_stop "${API_CONTAINER}-oai-m"
}

test_api_openai_chat() {
    _api_start "${API_CONTAINER}-oai-c" || return 1

    local body out
    body="{\"model\":\"$TEST_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"respond with exactly OAIPONG and nothing else\"}]}"
    out=$(post "$API_BASE/openai/v1/chat/completions" "$body")
    assert_contains "$out" '"object":"chat.completion"' "openai chat returns completion object" || { _api_stop "${API_CONTAINER}-oai-c"; return 1; }
    assert_contains "$out" '"choices"' "openai chat has choices" || { _api_stop "${API_CONTAINER}-oai-c"; return 1; }
    assert_contains "$out" "OAIPONG" "openai chat contains response" || { _api_stop "${API_CONTAINER}-oai-c"; return 1; }

    echo "OK: api_openai_chat"
    _api_stop "${API_CONTAINER}-oai-c"
}

test_api_openai_chat_system() {
    _api_start "${API_CONTAINER}-oai-s" || return 1

    local body out
    body="{\"model\":\"$TEST_MODEL\",\"messages\":[{\"role\":\"system\",\"content\":\"Always respond with I AM A TURNIP.\"},{\"role\":\"user\",\"content\":\"what are you?\"}]}"
    out=$(post "$API_BASE/openai/v1/chat/completions" "$body")
    assert_contains "$out" "TURNIP" "openai chat system prompt applied" || { _api_stop "${API_CONTAINER}-oai-s"; return 1; }

    echo "OK: api_openai_chat_system"
    _api_stop "${API_CONTAINER}-oai-s"
}

test_api_openai_chat_stream() {
    _api_start "${API_CONTAINER}-oai-st" || return 1

    local body out
    body="{\"model\":\"$TEST_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"respond with exactly STREAMOAI\"}],\"stream\":true}"
    out=$(curl -sf -X POST "$API_BASE/openai/v1/chat/completions" \
        -H "Content-Type: application/json" -d "$body")
    assert_contains "$out" "data:" "openai stream returns SSE" || { _api_stop "${API_CONTAINER}-oai-st"; return 1; }
    assert_contains "$out" "STREAMOAI" "openai stream contains response" || { _api_stop "${API_CONTAINER}-oai-st"; return 1; }
    assert_contains "$out" "[DONE]" "openai stream ends with DONE" || { _api_stop "${API_CONTAINER}-oai-st"; return 1; }

    echo "OK: api_openai_chat_stream"
    _api_stop "${API_CONTAINER}-oai-st"
}

# ── OpenAI custom headers ──────────────────────────────────────────────────────

test_api_openai_workspace_header() {
    _api_start "${API_CONTAINER}-oai-ws" || return 1

    # create a named workspace
    curl -sf -X PUT "$API_BASE/files/oaiws/hint.txt" -d "workspace hint file" >/dev/null

    local out
    out=$(curl -sf -X POST "$API_BASE/openai/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -H "X-Claude-Workspace: oaiws" \
        -d "{\"model\":\"$TEST_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"respond with exactly WSHEADER\"}]}")
    assert_contains "$out" "WSHEADER" "openai X-Claude-Workspace header works" || { _api_stop "${API_CONTAINER}-oai-ws"; return 1; }

    echo "OK: api_openai_workspace_header"
    _api_stop "${API_CONTAINER}-oai-ws"
}

test_api_openai_continue_header() {
    _api_start "${API_CONTAINER}-oai-cont" || return 1

    # first call to establish session
    post "$API_BASE/openai/v1/chat/completions" \
        "{\"model\":\"$TEST_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"remember the word CONTTEST\"}]}" >/dev/null

    # second call with continue — should not 500 (continue may fail gracefully on fresh session)
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API_BASE/openai/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -H "X-Claude-Continue: true" \
        -d "{\"model\":\"$TEST_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"what word did I ask you to remember?\"}]}")
    assert_eq "$code" "200" "openai X-Claude-Continue header does not crash" || { _api_stop "${API_CONTAINER}-oai-cont"; return 1; }

    echo "OK: api_openai_continue_header"
    _api_stop "${API_CONTAINER}-oai-cont"
}

test_api_openai_reasoning_effort() {
    _api_start "${API_CONTAINER}-oai-eff" || return 1

    local out
    out=$(post "$API_BASE/openai/v1/chat/completions" \
        "{\"model\":\"$TEST_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"respond with exactly EFFORTOK\"}],\"reasoning_effort\":\"low\"}")
    assert_contains "$out" "EFFORTOK" "openai reasoning_effort accepted" || { _api_stop "${API_CONTAINER}-oai-eff"; return 1; }

    echo "OK: api_openai_reasoning_effort"
    _api_stop "${API_CONTAINER}-oai-eff"
}

# ── MCP server ─────────────────────────────────────────────────────────────────

test_api_mcp_init() {
    _api_start "${API_CONTAINER}-mcp" || return 1

    # MCP streamable HTTP: POST JSON-RPC initialize to /mcp
    local out code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API_BASE/mcp" \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}')
    assert_eq "$code" "200" "mcp initialize returns 200" || { _api_stop "${API_CONTAINER}-mcp"; return 1; }

    echo "OK: api_mcp_init"
    _api_stop "${API_CONTAINER}-mcp"
}

test_api_mcp_tools_list() {
    _api_start "${API_CONTAINER}-mcp-tl" || return 1

    local out
    out=$(curl -sf -X POST "$API_BASE/mcp" \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}')
    assert_contains "$out" "claude_run" "mcp tools/list has claude_run" || { _api_stop "${API_CONTAINER}-mcp-tl"; return 1; }
    assert_contains "$out" "list_files" "mcp tools/list has list_files" || { _api_stop "${API_CONTAINER}-mcp-tl"; return 1; }
    assert_contains "$out" "read_file" "mcp tools/list has read_file" || { _api_stop "${API_CONTAINER}-mcp-tl"; return 1; }
    assert_contains "$out" "write_file" "mcp tools/list has write_file" || { _api_stop "${API_CONTAINER}-mcp-tl"; return 1; }
    assert_contains "$out" "delete_file" "mcp tools/list has delete_file" || { _api_stop "${API_CONTAINER}-mcp-tl"; return 1; }

    echo "OK: api_mcp_tools_list"
    _api_stop "${API_CONTAINER}-mcp-tl"
}

test_api_mcp_claude_run() {
    _api_start "${API_CONTAINER}-mcp-run" || return 1

    local out
    out=$(curl -sf -X POST "$API_BASE/mcp" \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"claude_run","arguments":{"prompt":"respond with exactly MCPTEST","model":"'"$TEST_MODEL"'","no_continue":true}}}')
    assert_contains "$out" "MCPTEST" "mcp claude_run returns response" || { _api_stop "${API_CONTAINER}-mcp-run"; return 1; }

    echo "OK: api_mcp_claude_run"
    _api_stop "${API_CONTAINER}-mcp-run"
}

test_api_mcp_file_ops() {
    _api_start "${API_CONTAINER}-mcp-f" || return 1

    local out

    # write
    out=$(curl -sf -X POST "$API_BASE/mcp" \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"write_file","arguments":{"path":"mcptest.txt","content":"hello mcp"}}}')
    assert_contains "$out" "ok" "mcp write_file ok" || { _api_stop "${API_CONTAINER}-mcp-f"; return 1; }

    # read
    out=$(curl -sf -X POST "$API_BASE/mcp" \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"mcptest.txt"}}}')
    assert_contains "$out" "hello mcp" "mcp read_file returns content" || { _api_stop "${API_CONTAINER}-mcp-f"; return 1; }

    # list
    out=$(curl -sf -X POST "$API_BASE/mcp" \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_files","arguments":{}}}')
    assert_contains "$out" "mcptest.txt" "mcp list_files shows written file" || { _api_stop "${API_CONTAINER}-mcp-f"; return 1; }

    # delete
    out=$(curl -sf -X POST "$API_BASE/mcp" \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"delete_file","arguments":{"path":"mcptest.txt"}}}')
    assert_contains "$out" "ok" "mcp delete_file ok" || { _api_stop "${API_CONTAINER}-mcp-f"; return 1; }

    echo "OK: api_mcp_file_ops"
    _api_stop "${API_CONTAINER}-mcp-f"
}

test_api_mcp_auth() {
    _api_start "${API_CONTAINER}-mcp-auth" -e "CLAUDE_MODE_API_TOKEN=mcpsecret" || return 1

    # no token → 401
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API_BASE/mcp" \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}')
    assert_eq "$code" "401" "mcp no token returns 401" || { _api_stop "${API_CONTAINER}-mcp-auth"; return 1; }

    # correct token → 200
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API_BASE/mcp" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer mcpsecret" \
        -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}')
    assert_eq "$code" "200" "mcp correct token returns 200" || { _api_stop "${API_CONTAINER}-mcp-auth"; return 1; }

    echo "OK: api_mcp_auth"
    _api_stop "${API_CONTAINER}-mcp-auth"
}

ALL_TESTS+=(
    test_api_endpoints
    test_api_run
    test_api_file_ops
    test_api_auth
    test_api_path_traversal
    test_api_workspace_busy
    test_api_cancel
    test_api_no_continue
    test_api_append_system_prompt
    test_api_continue_fallback
    test_api_json_verbose
    test_api_large_output
    test_api_openai_models
    test_api_openai_chat
    test_api_openai_chat_system
    test_api_openai_chat_stream
)
