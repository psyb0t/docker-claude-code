#!/bin/bash

# Tests for cron+telegram combined mode:
#   - _save_telegram_message / _load_cron_message round-trip
#   - _build_claude_args omits --continue when use_continue=False
#   - CRON_SYSTEM_HINT populated with yaml path + history root when IS_CRON_MODE
#   - combined entrypoint starts both cron scheduler and telegram bot processes

_ct_setup_dirs() {
    mkdir -p "$WORKDIR/tests/.fixtures"
    CT_TMP=$(mktemp -d "$WORKDIR/tests/.fixtures/cron-tg-XXXXX")
    chmod 777 "$CT_TMP"
    mkdir -p "$CT_TMP/home/.claude/cron" "$CT_TMP/workspace"
    chown -R 1000:1000 "$CT_TMP" 2>/dev/null || sudo chown -R 1000:1000 "$CT_TMP"
}

_ct_cleanup_dirs() {
    [ -n "${CT_TMP:-}" ] && { rm -rf "$CT_TMP" 2>/dev/null || sudo rm -rf "$CT_TMP"; }
    CT_TMP=""
}

# ── unit: _save_telegram_message writes and _load_cron_message reads back ─────

test_cron_telegram_message_tracking_roundtrip() {
    _ct_setup_dirs

    local out rc
    out=$(docker run --rm -i \
        --entrypoint python3 \
        -e "HOME=/tmp/ct_home" \
        -e "CLAUDEBOX_MODE_TELEGRAM=1" \
        -e "CLAUDEBOX_MODE_CRON=1" \
        -e "CLAUDEBOX_MODE_CRON_FILE=/tmp/cron.yaml" \
        -e "CLAUDEBOX_WORKSPACE=/workspace" \
        "$IMAGE" - <<'PYEOF'
import sys, os, json
from pathlib import Path
from datetime import datetime, timezone

os.makedirs("/tmp/ct_home/.claude/cron", exist_ok=True)
sys.path.insert(0, "/home/claude")

import cron
cron.TELEGRAM_MESSAGES_FILE = Path("/tmp/ct_home/.claude/cron/telegram_messages.json")
cron.TELEGRAM_MODE = True

job = {"name": "test_job", "instruction": "check logs", "schedule": "*/30 * * * * *"}
fired_at = datetime(2026, 4, 29, 14, 35, 0, tzinfo=timezone.utc)

cron._save_telegram_message(99001, job, fired_at, "All clear")
cron._save_telegram_message(99002, job, fired_at, "Some errors found")

data = json.loads(cron.TELEGRAM_MESSAGES_FILE.read_text())
assert "99001" in data, "message 99001 missing"
assert "99002" in data, "message 99002 missing"
assert data["99001"]["job_name"] == "test_job", "wrong job_name"
assert data["99001"]["result"] == "All clear", "wrong result"
assert data["99002"]["result"] == "Some errors found", "wrong result 2"
assert "fired_at" in data["99001"], "fired_at missing"
assert "instruction" in data["99001"], "instruction missing"

import telegram_bot
telegram_bot.CRON_MESSAGES_FILE = cron.TELEGRAM_MESSAGES_FILE

entry = telegram_bot._load_cron_message(99001)
assert entry is not None, "_load_cron_message returned None"
assert entry["job_name"] == "test_job", f"wrong job_name: {entry['job_name']}"
assert entry["result"] == "All clear", f"wrong result: {entry['result']}"

missing = telegram_bot._load_cron_message(0)
assert missing is None, "_load_cron_message should return None for unknown id"

print("OK")
PYEOF
    )
    rc=$?

    _ct_cleanup_dirs
    [ "$rc" -eq 0 ] || { echo "  FAIL: python exited $rc"; echo "$out" | sed 's/^/    /'; return 1; }
    assert_contains "$out" "OK" "round-trip save/load works" || return 1
}

# ── unit: pruning keeps at most 200 entries ───────────────────────────────────

test_cron_telegram_message_tracking_prune() {
    _ct_setup_dirs

    local out rc
    out=$(docker run --rm -i \
        --entrypoint python3 \
        -e "HOME=/tmp/ct_home" \
        -e "CLAUDEBOX_MODE_TELEGRAM=1" \
        -e "CLAUDEBOX_MODE_CRON=1" \
        -e "CLAUDEBOX_MODE_CRON_FILE=/tmp/cron.yaml" \
        -e "CLAUDEBOX_WORKSPACE=/workspace" \
        "$IMAGE" - <<'PYEOF'
import sys, os, json
from pathlib import Path
from datetime import datetime, timezone

os.makedirs("/tmp/ct_home/.claude/cron", exist_ok=True)
sys.path.insert(0, "/home/claude")

import cron
cron.TELEGRAM_MESSAGES_FILE = Path("/tmp/ct_home/.claude/cron/telegram_messages.json")
cron.TELEGRAM_MODE = True

job = {"name": "j", "instruction": "x", "schedule": "* * * * *"}
fired_at = datetime(2026, 1, 1, tzinfo=timezone.utc)

for i in range(250):
    cron._save_telegram_message(i, job, fired_at, f"result {i}")

data = json.loads(cron.TELEGRAM_MESSAGES_FILE.read_text())
count = len(data)
assert count == 200, f"expected 200 entries after prune, got {count}"

# oldest entries (0..49) should be gone, newest (50..249) remain
assert "0" not in data, "entry 0 should have been pruned"
assert "49" not in data, "entry 49 should have been pruned"
assert "50" in data, "entry 50 should remain"
assert "249" in data, "entry 249 should remain"

print("OK")
PYEOF
    )
    rc=$?

    _ct_cleanup_dirs
    [ "$rc" -eq 0 ] || { echo "  FAIL: python exited $rc"; echo "$out" | sed 's/^/    /'; return 1; }
    assert_contains "$out" "OK" "pruning keeps last 200 entries" || return 1
}

# ── unit: _build_claude_args respects use_continue=False ─────────────────────

test_cron_telegram_no_continue_on_cron_reply() {
    local out rc
    out=$(docker run --rm -i \
        --entrypoint python3 \
        -e "HOME=/tmp/ct_home" \
        -e "CLAUDEBOX_MODE_CRON=1" \
        -e "CLAUDEBOX_MODE_CRON_FILE=/tmp/cron.yaml" \
        -e "CLAUDEBOX_WORKSPACE=/workspace" \
        "$IMAGE" - <<'PYEOF'
import sys, os
sys.path.insert(0, "/home/claude")

import telegram_bot

chat_cfg = {"continue": True}

args_with = telegram_bot._build_claude_args("hello", chat_cfg, use_continue=True)
assert "--continue" in args_with, f"--continue missing when use_continue=True: {args_with}"

args_without = telegram_bot._build_claude_args("hello", chat_cfg, use_continue=False)
assert "--continue" not in args_without, f"--continue present when use_continue=False: {args_without}"

print("OK")
PYEOF
    )
    rc=$?

    [ "$rc" -eq 0 ] || { echo "  FAIL: python exited $rc"; echo "$out" | sed 's/^/    /'; return 1; }
    assert_contains "$out" "OK" "use_continue=False omits --continue" || return 1
}

# ── unit: CRON_SYSTEM_HINT populated with yaml path + history root ────────────

test_cron_telegram_system_hint_content() {
    local out rc
    out=$(docker run --rm -i \
        --entrypoint python3 \
        -e "HOME=/home/claude" \
        -e "CLAUDEBOX_MODE_CRON=1" \
        -e "CLAUDEBOX_MODE_CRON_FILE=/home/claude/.claude/cron.yaml" \
        -e "CLAUDEBOX_WORKSPACE=/my/workspace" \
        "$IMAGE" - <<'PYEOF'
import sys
sys.path.insert(0, "/home/claude")

import telegram_bot

assert telegram_bot.IS_CRON_MODE, "IS_CRON_MODE should be True"
assert telegram_bot.CRON_SYSTEM_HINT, "CRON_SYSTEM_HINT should be non-empty"
assert "/home/claude/.claude/cron.yaml" in telegram_bot.CRON_SYSTEM_HINT, \
    f"yaml path missing from hint: {telegram_bot.CRON_SYSTEM_HINT}"
assert "history" in telegram_bot.CRON_SYSTEM_HINT, \
    f"history path missing from hint: {telegram_bot.CRON_SYSTEM_HINT}"
assert "my_workspace" in telegram_bot.CRON_SYSTEM_HINT, \
    f"workspace slug missing from hint: {telegram_bot.CRON_SYSTEM_HINT}"
assert "activity.jsonl" in telegram_bot.CRON_SYSTEM_HINT, \
    f"activity.jsonl mention missing: {telegram_bot.CRON_SYSTEM_HINT}"

args = telegram_bot._build_claude_args("hi", {}, use_continue=False)
append_idx = args.index("--append-system-prompt")
append_val = args[append_idx + 1]
assert telegram_bot.CRON_SYSTEM_HINT in append_val, \
    "CRON_SYSTEM_HINT not included in --append-system-prompt"

print("OK")
PYEOF
    )
    rc=$?

    [ "$rc" -eq 0 ] || { echo "  FAIL: python exited $rc"; echo "$out" | sed 's/^/    /'; return 1; }
    assert_contains "$out" "OK" "CRON_SYSTEM_HINT has yaml path, history root, workspace slug" || return 1
}

# ── integration: combined mode entrypoint starts both processes ───────────────

test_cron_telegram_combined_entrypoint_starts_both() {
    _ct_setup_dirs
    local cron_file="$CT_TMP/cron.yaml"
    cat > "$cron_file" <<'EOF'
jobs:
  - name: never_fires
    schedule: "0 0 1 1 *"
    instruction: this never fires during the test
EOF
    chown 1000:1000 "$cron_file" 2>/dev/null || sudo chown 1000:1000 "$cron_file"

    # no BOT_TOKEN — telegram bot will exit immediately after startup attempt,
    # but we can verify both processes were launched by checking logs
    local cname="claudebox-cron-tg-test-$$-$RANDOM"
    docker run -d --name "$cname" \
        -e "CLAUDEBOX_MODE_CRON=1" \
        -e "CLAUDEBOX_MODE_TELEGRAM=1" \
        -e "CLAUDEBOX_MODE_CRON_FILE=/cron.yaml" \
        -e "CLAUDEBOX_WORKSPACE=$CT_TMP/workspace" \
        -v "$cron_file:/cron.yaml:ro" \
        -v "$CT_TMP/home/.claude:/home/claude/.claude" \
        -v "$CT_TMP/workspace:$CT_TMP/workspace" \
        "$IMAGE" >/dev/null 2>&1

    sleep 5
    local out
    out=$(docker logs "$cname" 2>&1)
    docker rm -f "$cname" >/dev/null 2>&1 || true
    _ct_cleanup_dirs

    # cron scheduler must have started (loads the yaml and logs job list)
    assert_contains "$out" "never_fires" "cron scheduler started and loaded jobs" || return 1
    # telegram bot must have attempted to start (fails without token but logs the attempt)
    assert_contains "$out" "CLAUDEBOX_TELEGRAM_BOT_TOKEN" "telegram bot started (failed on missing token)" || return 1
}

ALL_TESTS+=(
    test_cron_telegram_message_tracking_roundtrip
    test_cron_telegram_message_tracking_prune
    test_cron_telegram_no_continue_on_cron_reply
    test_cron_telegram_system_hint_content
    test_cron_telegram_combined_entrypoint_starts_both
)
