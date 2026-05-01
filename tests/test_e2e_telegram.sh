#!/bin/bash

# End-to-end Telegram tests. Drives the user side of the chat with
# psyb0t/telethon-plus (HTTP wrapper around a real Telegram MTProto userbot)
# while a real claudebox container runs cron+telegram mode against the same
# chat. Verifies:
#
#   1. cron output → bot message → markdown rendered correctly (no PUA leak,
#      no bare CB\d sentinel leak — regression for v1.12.6/.7)
#   2. cron history dir gets telegram.json with chat_id + message_id
#   3. user reply to a cron bot-message → Claude responds with history_dir
#      context (not --continue)
#   4. user non-reply text → Claude responds (with --continue)
#   5. user reply to a non-cron bot message (text) → Claude acknowledges with
#      kind=text label in logs
#
# Required env (loaded from tests/.env):
#   CLAUDEBOX_TELEGRAM_BOT_TOKEN   bot the claudebox container connects as
#   TELEGRAM_CHAT_ID               chat id (positive = DM user id)
#   TELETHON_API_ID, TELETHON_API_HASH, TELETHON_SESSION  MTProto creds
#   TELETHON_AUTH_KEY              bearer key for the telethon-plus HTTP API
#
# Per-test container logs are dumped under tests/logs/<testname>-claudebox.log
# and tests/logs/<testname>-telethon.log. tests/logs/<testname>.log itself
# captures the test's own stdout (set up by test.sh).

TELETHON_IMAGE="psyb0t/telethon-plus"

_e2e_check_env() {
    local missing=()
    for v in CLAUDEBOX_TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID \
             TELETHON_API_ID TELETHON_API_HASH TELETHON_SESSION TELETHON_AUTH_KEY; do
        if [ -z "${!v:-}" ]; then
            missing+=("$v")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "  SKIP: missing env vars in tests/.env: ${missing[*]}"
        return 1
    fi
    return 0
}

_e2e_setup_dirs() {
    mkdir -p "$WORKDIR/tests/.fixtures"
    E2E_TMP=$(mktemp -d "$WORKDIR/tests/.fixtures/e2e-tg-XXXXX")
    chmod 777 "$E2E_TMP"
    mkdir -p "$E2E_TMP/home/.claude/cron" "$E2E_TMP/workspace"
    chown -R 1000:1000 "$E2E_TMP" 2>/dev/null || sudo chown -R 1000:1000 "$E2E_TMP"
}

_e2e_cleanup_dirs() {
    [ -n "${E2E_TMP:-}" ] && { rm -rf "$E2E_TMP" 2>/dev/null || sudo rm -rf "$E2E_TMP"; }
    E2E_TMP=""
}

# Write the telegram.yml config with our test chat allowed and haiku as model.
_e2e_write_telegram_yml() {
    local path="$1"
    cat > "$path" <<EOF
allowed_chats:
  - $TELEGRAM_CHAT_ID
default:
  model: $TEST_MODEL
  effort: low
  continue: true
EOF
    chown 1000:1000 "$path" 2>/dev/null || sudo chown 1000:1000 "$path"
}

# Pick a free localhost port for the telethon-plus HTTP API.
_e2e_pick_port() {
    python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

# Start telethon-plus. Sets E2E_TELETHON_NAME, E2E_TELETHON_PORT, E2E_TELETHON_URL.
_e2e_start_telethon() {
    E2E_TELETHON_PORT=$(_e2e_pick_port)
    E2E_TELETHON_NAME="claudebox-e2e-telethon-$$-$RANDOM"
    E2E_TELETHON_URL="http://127.0.0.1:$E2E_TELETHON_PORT"

    docker pull "$TELETHON_IMAGE" >/dev/null 2>&1 || true

    docker run -d --name "$E2E_TELETHON_NAME" \
        -p "127.0.0.1:$E2E_TELETHON_PORT:8080" \
        -e "TELETHON_API_ID=$TELETHON_API_ID" \
        -e "TELETHON_API_HASH=$TELETHON_API_HASH" \
        -e "TELETHON_SESSION=$TELETHON_SESSION" \
        -e "TELETHON_AUTH_KEY=$TELETHON_AUTH_KEY" \
        -e "TELETHON_LOG_LEVEL=DEBUG" \
        "$TELETHON_IMAGE" >/dev/null 2>&1

    for _ in $(seq 1 30); do
        if curl -sf "$E2E_TELETHON_URL/healthz" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "  FAIL: telethon-plus did not become healthy on $E2E_TELETHON_URL"
    docker logs "$E2E_TELETHON_NAME" 2>&1 | tail -30 | sed 's/^/    /'
    return 1
}

# Dump container logs to per-test log dir, then remove the container.
_e2e_dump_and_kill() {
    local cname="$1" suffix="$2" testname="$3"
    [ -z "$cname" ] && return 0
    local out_path="${TEST_LOG_DIR:-$WORKDIR/tests/logs}/${testname}-${suffix}.log"
    docker logs "$cname" >"$out_path" 2>&1 || true
    docker rm -f "$cname" >/dev/null 2>&1 || true
}

# Tear down both containers and capture their logs under per-test names.
# Args: <testname>
_e2e_teardown_containers() {
    local testname="$1"
    _e2e_dump_and_kill "${E2E_CLAUDEBOX_NAME:-}"  "claudebox" "$testname"
    _e2e_dump_and_kill "${E2E_TELETHON_NAME:-}"   "telethon"  "$testname"
    E2E_CLAUDEBOX_NAME=""
    E2E_TELETHON_NAME=""
    # Give Telegram a moment to release the bot polling slot before next test
    sleep 2
}

# ---- Telethon HTTP helpers ---------------------------------------------------
#
# A DM between user U and bot B is the same chat addressed differently:
#   - via Bot API as B   → chat_id = U's user_id (what cron uses)
#   - via MTProto as U   → chat by @username or B's user_id (what telethon uses)
# Telethon refuses bare numeric IDs it hasn't cached, so we resolve the bot's
# @username once from the Bot API getMe call and reuse it.
TG_BOT_USER_ID() { echo "${CLAUDEBOX_TELEGRAM_BOT_TOKEN%%:*}"; }

# Cached bot identifier in the form telethon accepts (@username).
# Set lazily by _e2e_resolve_bot.
TG_BOT_REF=""

_e2e_resolve_bot() {
    [ -n "$TG_BOT_REF" ] && return 0
    local resp username
    resp=$(curl -sf "https://api.telegram.org/bot${CLAUDEBOX_TELEGRAM_BOT_TOKEN}/getMe")
    username=$(echo "$resp" | python3 -c 'import json,sys
print((json.load(sys.stdin).get("result") or {}).get("username", ""))')
    if [ -z "$username" ]; then
        echo "  FAIL: could not resolve bot username via getMe — response: $resp"
        return 1
    fi
    TG_BOT_REF="@$username"
    echo "  OK: bot resolved as $TG_BOT_REF"
}

# Telegram bots can only DM users that have first talked to them. Ensure the
# user→bot chat exists by sending /start (idempotent — Telegram is fine with
# repeats). Must be called after telethon-plus is up.
_e2e_ensure_chat_initialized() {
    local payload status
    payload=$(CHAT="$TG_BOT_REF" TEXT="/start" REPLY_TO="" _tg_send_json)
    status=$(_tg_curl -o /dev/null -w '%{http_code}' \
        -X POST "$E2E_TELETHON_URL/api/messages" \
        -H "Content-Type: application/json" -d "$payload")
    if [ "$status" != "200" ]; then
        echo "  FAIL: could not send /start to $TG_BOT_REF (HTTP $status)"
        return 1
    fi
    echo "  OK: chat initialized with /start to $TG_BOT_REF"
}

_tg_curl() {
    curl -sS -H "Authorization: Bearer $TELETHON_AUTH_KEY" "$@"
}

# JSON-encode env-passed values via python (safe vs. shell quoting).
_tg_send_json() {
    # stdin: nothing; reads CHAT, TEXT, REPLY_TO from env.
    python3 - <<'PY'
import json, os
payload = {"chat": os.environ["CHAT"], "text": os.environ["TEXT"]}
if os.environ.get("REPLY_TO"):
    payload["reply_to"] = int(os.environ["REPLY_TO"])
print(json.dumps(payload))
PY
}

# Send text from the user side TO the bot. Args: <text>. Echoes message id.
tg_send_text() {
    local payload
    payload=$(CHAT="$TG_BOT_REF" TEXT="$1" REPLY_TO="" _tg_send_json)
    _tg_curl -X POST "$E2E_TELETHON_URL/api/messages" \
        -H "Content-Type: application/json" -d "$payload" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["id"])'
}

# Reply to a specific bot message id. Args: <text> <reply_to_id>.
tg_reply() {
    local payload
    payload=$(CHAT="$TG_BOT_REF" TEXT="$1" REPLY_TO="$2" _tg_send_json)
    _tg_curl -X POST "$E2E_TELETHON_URL/api/messages" \
        -H "Content-Type: application/json" -d "$payload" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["id"])'
}

# Latest message id in the user-bot DM, or 0 if chat empty.
tg_latest_msg_id() {
    _tg_curl "$E2E_TELETHON_URL/api/messages?chat=$TG_BOT_REF&limit=1" \
        | python3 -c 'import json,sys
d = json.load(sys.stdin).get("result", [])
print(d[0]["id"] if d else 0)'
}

# Wait for a bot-sent message AFTER baseline_id whose text contains $SUBSTR.
# Args: <baseline_id> <substr> [timeout_seconds].
# On success prints "<id>\n<text>" to stdout and returns 0.
tg_wait_for_bot_message() {
    local baseline="$1" substr="$2" timeout="${3:-90}"
    local bot_numeric i resp
    bot_numeric=$(TG_BOT_USER_ID)
    for i in $(seq 1 "$timeout"); do
        resp=$(_tg_curl "$E2E_TELETHON_URL/api/messages?chat=$TG_BOT_REF&limit=30" 2>/dev/null) \
            || { sleep 1; continue; }
        local hit
        hit=$(BASELINE="$baseline" BOT_ID="$bot_numeric" SUBSTR="$substr" RESP="$resp" python3 - <<'PY'
import json, os, sys
data = json.loads(os.environ["RESP"]).get("result", [])
baseline = int(os.environ["BASELINE"])
bot_id = int(os.environ["BOT_ID"])
substr = os.environ["SUBSTR"]
# results are newest-first per the README; iterate in reverse so we pick the
# OLDEST new match first — that's the actual response we asked about.
for m in reversed(data):
    mid = int(m.get("id") or 0)
    if mid <= baseline:
        continue
    if int(m.get("sender_id") or 0) != bot_id:
        continue
    text = m.get("text") or ""
    if substr and substr not in text:
        continue
    print(mid)
    print(text)
    sys.exit(0)
sys.exit(1)
PY
)
        if [ -n "$hit" ]; then
            echo "$hit"
            return 0
        fi
        sleep 1
    done
    return 1
}

# ---- Common docker run for claudebox in cron+telegram ----------------------
# Sets E2E_CLAUDEBOX_NAME. Args: <cron_yaml_path>
_e2e_run_claudebox_cron_tg() {
    local cron_file="$1"
    local tg_yml="$E2E_TMP/home/.claude/telegram.yml"
    _e2e_write_telegram_yml "$tg_yml"

    E2E_CLAUDEBOX_NAME="claudebox-e2e-$$-$RANDOM"
    docker run -d --name "$E2E_CLAUDEBOX_NAME" \
        --network host \
        -e "CLAUDEBOX_MODE_CRON=1" \
        -e "CLAUDEBOX_MODE_TELEGRAM=1" \
        -e "CLAUDEBOX_MODE_CRON_FILE=/cron.yaml" \
        -e "CLAUDEBOX_WORKSPACE=$E2E_TMP/workspace" \
        -e "CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN" \
        -e "CLAUDEBOX_TELEGRAM_BOT_TOKEN=$CLAUDEBOX_TELEGRAM_BOT_TOKEN" \
        -e "DEBUG=true" \
        -v "$cron_file:/cron.yaml:ro" \
        -v "$E2E_TMP/home/.claude:/home/claude/.claude" \
        -v "$E2E_TMP/workspace:$E2E_TMP/workspace" \
        "$IMAGE" >/dev/null 2>&1
}

# ============================================================================
# test 1: cron fires → bot message renders cleanly + telegram.json written
# ============================================================================

test_e2e_cron_message_renders_without_placeholder_leak() {
    _e2e_check_env || return 0
    _e2e_resolve_bot || return 1
    _e2e_setup_dirs
    _e2e_start_telethon || { _e2e_cleanup_dirs; return 1; }
    _e2e_ensure_chat_initialized || { _e2e_teardown_containers init; _e2e_cleanup_dirs; return 1; }
    local TNAME=test_e2e_cron_message_renders_without_placeholder_leak

    local cron_file="$E2E_TMP/cron.yaml"
    cat > "$cron_file" <<EOF
telegram_chat_id: $TELEGRAM_CHAT_ID
jobs:
  - name: leakcheck
    schedule: "*/30 * * * * *"
    model: $TEST_MODEL
    instruction: |
      Respond with exactly this markdown text and nothing else, no preamble:

      ## **Logs**
      Mostly boring-ass cron jobs.

      ## **Docker Health**
      \`mt5-httpapi-mt5-1\` is **unhealthy**.
EOF
    chown 1000:1000 "$cron_file" 2>/dev/null || sudo chown 1000:1000 "$cron_file"

    local baseline
    baseline=$(tg_latest_msg_id)
    _e2e_run_claudebox_cron_tg "$cron_file"

    local result bot_msg_id bot_msg_text
    if ! result=$(tg_wait_for_bot_message "$baseline" "Logs" 90); then
        echo "  FAIL: no bot message containing 'Logs' arrived within 90s"
        _e2e_teardown_containers "$TNAME"; _e2e_cleanup_dirs; return 1
    fi
    bot_msg_id=$(echo "$result" | head -1)
    bot_msg_text=$(echo "$result" | tail -n +2)
    echo "  OK: bot delivered cron message id=$bot_msg_id"

    local leak
    leak=$(TEXT="$bot_msg_text" python3 - <<'PY'
import os, re
text = os.environ["TEXT"]
for ch in ("", "", "\x00"):
    if ch in text:
        print(f"PUA/NUL leak: {ch!r}"); break
else:
    m = re.search(r"\bCB\d+\b", text)
    if m:
        print(f"sentinel leak: {m.group()!r}")
PY
)
    if [ -n "$leak" ]; then
        echo "  FAIL: $leak"
        echo "  raw bot message:"
        echo "$bot_msg_text" | sed 's/^/    /'
        _e2e_teardown_containers "$TNAME"; _e2e_cleanup_dirs; return 1
    fi
    echo "  OK: rendered text has no PUA/NUL/CB-sentinel leak"

    assert_contains "$bot_msg_text" "Logs"          "heading 'Logs' present"          || { _e2e_teardown_containers "$TNAME"; _e2e_cleanup_dirs; return 1; }
    assert_contains "$bot_msg_text" "Docker Health" "heading 'Docker Health' present" || { _e2e_teardown_containers "$TNAME"; _e2e_cleanup_dirs; return 1; }

    local history_root="$E2E_TMP/home/.claude/cron/history"
    local tg_json
    tg_json=$(find "$history_root" -name 'telegram.json' 2>/dev/null | head -1)
    if [ -z "$tg_json" ]; then
        echo "  FAIL: telegram.json was not written into history dir"
        find "$history_root" -type f 2>&1 | sed 's/^/    /'
        _e2e_teardown_containers "$TNAME"; _e2e_cleanup_dirs; return 1
    fi
    echo "  OK: telegram.json written at $tg_json"

    local saved_chat_id saved_msg_id
    saved_chat_id=$(python3 -c "import json; print(json.load(open('$tg_json'))['chat_id'])")
    saved_msg_id=$(python3 -c  "import json; print(json.load(open('$tg_json'))['message_id'])")
    assert_eq "$saved_chat_id" "$TELEGRAM_CHAT_ID" "telegram.json chat_id matches" \
        || { _e2e_teardown_containers "$TNAME"; _e2e_cleanup_dirs; return 1; }
    # Bot API (what cron writes here) and telethon's MTProto report different
    # ids for the same logical message, so we just assert sanity (positive int).
    if ! [[ "$saved_msg_id" =~ ^[0-9]+$ ]] || [ "$saved_msg_id" -le 0 ]; then
        echo "  FAIL: telegram.json message_id is not a positive int: $saved_msg_id"
        _e2e_teardown_containers "$TNAME"; _e2e_cleanup_dirs; return 1
    fi
    echo "  OK: telegram.json message_id is a positive int ($saved_msg_id, Bot API view)"

    _e2e_teardown_containers "$TNAME"
    _e2e_cleanup_dirs
}

# ============================================================================
# test 2: replying to cron message → claude responds with history_dir context
# ============================================================================

test_e2e_reply_to_cron_message_triggers_claude_with_history() {
    _e2e_check_env || return 0
    _e2e_resolve_bot || return 1
    _e2e_setup_dirs
    _e2e_start_telethon || { _e2e_cleanup_dirs; return 1; }
    _e2e_ensure_chat_initialized || { _e2e_teardown_containers init; _e2e_cleanup_dirs; return 1; }
    local TNAME=test_e2e_reply_to_cron_message_triggers_claude_with_history

    local cron_file="$E2E_TMP/cron.yaml"
    cat > "$cron_file" <<EOF
telegram_chat_id: $TELEGRAM_CHAT_ID
jobs:
  - name: replytarget
    schedule: "*/30 * * * * *"
    model: $TEST_MODEL
    instruction: |
      Respond with exactly the single token CRONREPLYTARGET and nothing else.
EOF
    chown 1000:1000 "$cron_file" 2>/dev/null || sudo chown 1000:1000 "$cron_file"

    local baseline
    baseline=$(tg_latest_msg_id)
    _e2e_run_claudebox_cron_tg "$cron_file"

    local result cron_msg_id
    if ! result=$(tg_wait_for_bot_message "$baseline" "CRONREPLYTARGET" 90); then
        echo "  FAIL: cron didn't deliver CRONREPLYTARGET message within 90s"
        _e2e_teardown_containers "$TNAME"; _e2e_cleanup_dirs; return 1
    fi
    cron_msg_id=$(echo "$result" | head -1)
    echo "  OK: cron message landed id=$cron_msg_id"

    local marker="REPLYECHO$RANDOM$$"
    local reply_baseline
    reply_baseline=$(tg_latest_msg_id)
    tg_reply "Reply with exactly the token $marker and nothing else." "$cron_msg_id" >/dev/null
    echo "  OK: user replied to cron message $cron_msg_id"

    local resp resp_text
    if ! resp=$(tg_wait_for_bot_message "$reply_baseline" "$marker" 120); then
        echo "  FAIL: Claude did not respond with marker $marker within 120s"
        _e2e_teardown_containers "$TNAME"; _e2e_cleanup_dirs; return 1
    fi
    resp_text=$(echo "$resp" | tail -n +2)
    assert_contains "$resp_text" "$marker" "claude reply contains the marker" \
        || { _e2e_teardown_containers "$TNAME"; _e2e_cleanup_dirs; return 1; }

    local logs
    logs=$(docker logs "$E2E_CLAUDEBOX_NAME" 2>&1)
    assert_contains "$logs" "reply to cron job replytarget" "bot logged cron reply" \
        || { _e2e_teardown_containers "$TNAME"; _e2e_cleanup_dirs; return 1; }
    assert_contains "$logs" "history_dir=" "bot logged history_dir on cron reply" \
        || { _e2e_teardown_containers "$TNAME"; _e2e_cleanup_dirs; return 1; }

    _e2e_teardown_containers "$TNAME"
    _e2e_cleanup_dirs
}

# ============================================================================
# test 3: plain (non-reply) text → claude responds (telegram-only path)
# ============================================================================

test_e2e_non_cron_text_message_triggers_claude() {
    _e2e_check_env || return 0
    _e2e_resolve_bot || return 1
    _e2e_setup_dirs
    _e2e_start_telethon || { _e2e_cleanup_dirs; return 1; }
    _e2e_ensure_chat_initialized || { _e2e_teardown_containers init; _e2e_cleanup_dirs; return 1; }
    local TNAME=test_e2e_non_cron_text_message_triggers_claude

    local cron_file="$E2E_TMP/cron.yaml"
    cat > "$cron_file" <<'EOF'
jobs:
  - name: never_fires
    schedule: "0 0 1 1 *"
    instruction: never fires
EOF
    chown 1000:1000 "$cron_file" 2>/dev/null || sudo chown 1000:1000 "$cron_file"

    _e2e_run_claudebox_cron_tg "$cron_file"
    sleep 6   # let the bot register its long-poll

    local marker="TEXTECHO$RANDOM$$"
    local baseline
    baseline=$(tg_latest_msg_id)
    tg_send_text "Reply with exactly the token $marker and nothing else." >/dev/null
    echo "  OK: user sent text with marker $marker"

    local resp resp_text
    if ! resp=$(tg_wait_for_bot_message "$baseline" "$marker" 120); then
        echo "  FAIL: Claude did not respond with marker $marker within 120s"
        _e2e_teardown_containers "$TNAME"; _e2e_cleanup_dirs; return 1
    fi
    resp_text=$(echo "$resp" | tail -n +2)
    assert_contains "$resp_text" "$marker" "claude reply contains marker" \
        || { _e2e_teardown_containers "$TNAME"; _e2e_cleanup_dirs; return 1; }

    _e2e_teardown_containers "$TNAME"
    _e2e_cleanup_dirs
}

# ============================================================================
# test 4: reply to a non-cron bot text → claude responds, kind=text logged
# ============================================================================

test_e2e_reply_to_non_cron_bot_message_acknowledged() {
    _e2e_check_env || return 0
    _e2e_resolve_bot || return 1
    _e2e_setup_dirs
    _e2e_start_telethon || { _e2e_cleanup_dirs; return 1; }
    _e2e_ensure_chat_initialized || { _e2e_teardown_containers init; _e2e_cleanup_dirs; return 1; }
    local TNAME=test_e2e_reply_to_non_cron_bot_message_acknowledged

    local cron_file="$E2E_TMP/cron.yaml"
    cat > "$cron_file" <<'EOF'
jobs:
  - name: never_fires
    schedule: "0 0 1 1 *"
    instruction: never fires
EOF
    chown 1000:1000 "$cron_file" 2>/dev/null || sudo chown 1000:1000 "$cron_file"

    _e2e_run_claudebox_cron_tg "$cron_file"
    sleep 6

    local seed_marker="SEED$RANDOM$$"
    local b1 seed_resp seed_resp_id
    b1=$(tg_latest_msg_id)
    tg_send_text "Reply with exactly the token $seed_marker and nothing else." >/dev/null
    if ! seed_resp=$(tg_wait_for_bot_message "$b1" "$seed_marker" 120); then
        echo "  FAIL: bot did not produce seed response with $seed_marker"
        _e2e_teardown_containers "$TNAME"; _e2e_cleanup_dirs; return 1
    fi
    seed_resp_id=$(echo "$seed_resp" | head -1)
    echo "  OK: seed bot message id=$seed_resp_id ready to be replied to"

    local reply_marker="REPL$RANDOM$$"
    local b2
    b2=$(tg_latest_msg_id)
    tg_reply "Reply with exactly the token $reply_marker and nothing else." "$seed_resp_id" >/dev/null

    local resp2 resp2_text
    if ! resp2=$(tg_wait_for_bot_message "$b2" "$reply_marker" 120); then
        echo "  FAIL: Claude did not respond to plain-reply with $reply_marker"
        _e2e_teardown_containers "$TNAME"; _e2e_cleanup_dirs; return 1
    fi
    resp2_text=$(echo "$resp2" | tail -n +2)
    assert_contains "$resp2_text" "$reply_marker" "claude responded to non-cron reply" \
        || { _e2e_teardown_containers "$TNAME"; _e2e_cleanup_dirs; return 1; }

    local logs
    logs=$(docker logs "$E2E_CLAUDEBOX_NAME" 2>&1)
    # The bot logs the Bot API message id; telethon's seed_resp_id is the MTProto
    # view of the same logical message. We can't trivially translate, so just
    # assert that *some* "reply to message <int> kind=text" line was logged.
    if ! echo "$logs" | grep -Eq "reply to message [0-9]+ kind=text"; then
        echo "  FAIL: bot did not log a 'reply to message <id> kind=text' line"
        _e2e_teardown_containers "$TNAME"; _e2e_cleanup_dirs; return 1
    fi
    echo "  OK: bot logged non-cron reply with kind=text"

    _e2e_teardown_containers "$TNAME"
    _e2e_cleanup_dirs
}

ALL_TESTS+=(
    test_e2e_cron_message_renders_without_placeholder_leak
    test_e2e_reply_to_cron_message_triggers_claude_with_history
    test_e2e_non_cron_text_message_triggers_claude
    test_e2e_reply_to_non_cron_bot_message_acknowledged
)
