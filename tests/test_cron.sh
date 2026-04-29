#!/bin/bash

# Tests cron mode end-to-end.
# Spawns the claudebox image with CLAUDEBOX_MODE_CRON=1 + a yaml,
# waits for the schedule to fire, verifies the history dir and files.

_cron_setup_dirs() {
    mkdir -p "$WORKDIR/tests/.fixtures"
    CRON_TMP=$(mktemp -d "$WORKDIR/tests/.fixtures/cron-XXXXX")
    chmod 777 "$CRON_TMP"
    mkdir -p "$CRON_TMP/home/.claude" "$CRON_TMP/workspace"
    chown -R 1000:1000 "$CRON_TMP" 2>/dev/null || sudo chown -R 1000:1000 "$CRON_TMP"
}

_cron_cleanup_dirs() {
    [ -n "${CRON_TMP:-}" ] && { rm -rf "$CRON_TMP" 2>/dev/null || sudo rm -rf "$CRON_TMP"; }
    CRON_TMP=""
}

# ── invalid yaml exits non-zero ───────────────────────────────────────────────

test_cron_invalid_yaml_fails() {
    _cron_setup_dirs
    local cron_file="$CRON_TMP/cron.yaml"
    cat > "$cron_file" <<'EOF'
# missing 'jobs' key
foo: bar
EOF
    chown 1000:1000 "$cron_file" 2>/dev/null || sudo chown 1000:1000 "$cron_file"

    local cname="claudebox-cron-test-$$-$RANDOM"
    local out rc
    out=$(docker run --rm --name "$cname" \
        --network host \
        -e "CLAUDEBOX_MODE_CRON=1" \
        -e "CLAUDEBOX_MODE_CRON_FILE=/cron.yaml" \
        -e "CLAUDE_WORKSPACE=$CRON_TMP/workspace" \
        -e "CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN" \
        -v "$cron_file:/cron.yaml:ro" \
        -v "$CRON_TMP/home/.claude:/home/claude/.claude" \
        -v "$CRON_TMP/workspace:$CRON_TMP/workspace" \
        "$IMAGE" 2>&1)
    rc=$?

    docker rm -f "$cname" >/dev/null 2>&1 || true
    _cron_cleanup_dirs

    if [ "$rc" -eq 0 ]; then
        echo "  FAIL: invalid yaml should have failed, got rc=0"
        echo "  output: ${out:0:500}"
        return 1
    fi
    assert_contains "$out" "invalid cron file" "error message printed" || return 1
}

# ── missing cron file env var fails ──────────────────────────────────────────

test_cron_missing_file_env_fails() {
    _cron_setup_dirs
    local cname="claudebox-cron-test-$$-$RANDOM"
    local out rc
    out=$(docker run --rm --name "$cname" \
        --network host \
        -e "CLAUDEBOX_MODE_CRON=1" \
        -e "CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN" \
        "$IMAGE" 2>&1)
    rc=$?
    docker rm -f "$cname" >/dev/null 2>&1 || true
    _cron_cleanup_dirs

    if [ "$rc" -eq 0 ]; then
        echo "  FAIL: missing cron file env should have failed"
        return 1
    fi
    assert_contains "$out" "CLAUDEBOX_MODE_CRON_FILE" "error mentions missing env var" || return 1
}

# ── valid yaml loads, jobs listed, debug logs ────────────────────────────────

test_cron_loads_and_lists_jobs() {
    _cron_setup_dirs
    local cron_file="$CRON_TMP/cron.yaml"
    cat > "$cron_file" <<'EOF'
jobs:
  - name: never_fires
    schedule: "0 0 1 1 *"
    instruction: |
      This job will essentially never fire during the test.
EOF
    chown 1000:1000 "$cron_file" 2>/dev/null || sudo chown 1000:1000 "$cron_file"

    local cname="claudebox-cron-test-$$-$RANDOM"

    # run for a few seconds, then kill it
    docker run -d --name "$cname" \
        --network host \
        -e "CLAUDEBOX_MODE_CRON=1" \
        -e "CLAUDEBOX_MODE_CRON_FILE=/cron.yaml" \
        -e "CLAUDE_WORKSPACE=$CRON_TMP/workspace" \
        -e "CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN" \
        -e "DEBUG=true" \
        -v "$cron_file:/cron.yaml:ro" \
        -v "$CRON_TMP/home/.claude:/home/claude/.claude" \
        -v "$CRON_TMP/workspace:$CRON_TMP/workspace" \
        "$IMAGE" >/dev/null 2>&1

    sleep 4
    local out
    out=$(docker logs "$cname" 2>&1)
    docker rm -f "$cname" >/dev/null 2>&1 || true
    _cron_cleanup_dirs

    assert_contains "$out" "loaded 1 job" "log shows job count" || return 1
    assert_contains "$out" "never_fires" "log lists job name" || return 1
    assert_contains "$out" "history root" "log shows history root path" || return 1
}

# ── duplicate job names fail validation ──────────────────────────────────────

test_cron_duplicate_job_names_fail() {
    _cron_setup_dirs
    local cron_file="$CRON_TMP/cron.yaml"
    cat > "$cron_file" <<'EOF'
jobs:
  - name: dup
    schedule: "* * * * *"
    instruction: hi
  - name: dup
    schedule: "* * * * *"
    instruction: hi
EOF
    chown 1000:1000 "$cron_file" 2>/dev/null || sudo chown 1000:1000 "$cron_file"

    local cname="claudebox-cron-test-$$-$RANDOM"
    local out rc
    out=$(docker run --rm --name "$cname" \
        -e "CLAUDEBOX_MODE_CRON=1" \
        -e "CLAUDEBOX_MODE_CRON_FILE=/cron.yaml" \
        -e "CLAUDE_WORKSPACE=$CRON_TMP/workspace" \
        -v "$cron_file:/cron.yaml:ro" \
        -v "$CRON_TMP/home/.claude:/home/claude/.claude" \
        -v "$CRON_TMP/workspace:$CRON_TMP/workspace" \
        "$IMAGE" 2>&1)
    rc=$?
    docker rm -f "$cname" >/dev/null 2>&1 || true
    _cron_cleanup_dirs

    [ "$rc" -ne 0 ] || { echo "  FAIL: duplicate names should have failed"; return 1; }
    assert_contains "$out" "duplicate job name" "log mentions duplicate" || return 1
}

# ── invalid cron expression fails ────────────────────────────────────────────

test_cron_invalid_schedule_fails() {
    _cron_setup_dirs
    local cron_file="$CRON_TMP/cron.yaml"
    cat > "$cron_file" <<'EOF'
jobs:
  - name: bad
    schedule: "not a cron"
    instruction: hi
EOF
    chown 1000:1000 "$cron_file" 2>/dev/null || sudo chown 1000:1000 "$cron_file"

    local cname="claudebox-cron-test-$$-$RANDOM"
    local out rc
    out=$(docker run --rm --name "$cname" \
        -e "CLAUDEBOX_MODE_CRON=1" \
        -e "CLAUDEBOX_MODE_CRON_FILE=/cron.yaml" \
        -e "CLAUDE_WORKSPACE=$CRON_TMP/workspace" \
        -v "$cron_file:/cron.yaml:ro" \
        -v "$CRON_TMP/home/.claude:/home/claude/.claude" \
        -v "$CRON_TMP/workspace:$CRON_TMP/workspace" \
        "$IMAGE" 2>&1)
    rc=$?
    docker rm -f "$cname" >/dev/null 2>&1 || true
    _cron_cleanup_dirs

    [ "$rc" -ne 0 ] || { echo "  FAIL: invalid schedule should have failed"; return 1; }
    assert_contains "$out" "invalid cron schedule" "log mentions invalid schedule" || return 1
}

# ── legacy CLAUDE_MODE_CRON_FILE still works ─────────────────────────────────

test_cron_legacy_env_works() {
    _cron_setup_dirs
    local cron_file="$CRON_TMP/cron.yaml"
    cat > "$cron_file" <<'EOF'
jobs:
  - name: legacy_test
    schedule: "0 0 1 1 *"
    instruction: legacy never fires
EOF
    chown 1000:1000 "$cron_file" 2>/dev/null || sudo chown 1000:1000 "$cron_file"

    local cname="claudebox-cron-test-$$-$RANDOM"

    docker run -d --name "$cname" \
        -e "CLAUDE_MODE_CRON=1" \
        -e "CLAUDE_MODE_CRON_FILE=/cron.yaml" \
        -e "CLAUDE_WORKSPACE=$CRON_TMP/workspace" \
        -v "$cron_file:/cron.yaml:ro" \
        -v "$CRON_TMP/home/.claude:/home/claude/.claude" \
        -v "$CRON_TMP/workspace:$CRON_TMP/workspace" \
        "$IMAGE" >/dev/null 2>&1

    sleep 3
    local out
    out=$(docker logs "$cname" 2>&1)
    docker rm -f "$cname" >/dev/null 2>&1 || true
    _cron_cleanup_dirs

    assert_contains "$out" "legacy_test" "legacy env vars still work" || return 1
}

# ── end-to-end: 30-sec cron actually fires within ~35s, output is correct ────

test_cron_end_to_end_fires() {
    _cron_setup_dirs
    local cron_file="$CRON_TMP/cron.yaml"
    # 6-field cron: every 30 seconds (sec min hr dom mon dow). croniter supports this with
    # second_at_beginning=True, which cron.py enables.
    cat > "$cron_file" <<EOF
jobs:
  - name: ping
    schedule: "*/30 * * * * *"
    model: $TEST_MODEL
    instruction: |
      Respond with exactly the single word CRONPONG and nothing else.
EOF
    chown 1000:1000 "$cron_file" 2>/dev/null || sudo chown 1000:1000 "$cron_file"

    local cname="claudebox-cron-test-$$-$RANDOM"
    local started_at_epoch
    started_at_epoch=$(date +%s)

    docker run -d --name "$cname" \
        --network host \
        -e "CLAUDEBOX_MODE_CRON=1" \
        -e "CLAUDEBOX_MODE_CRON_FILE=/cron.yaml" \
        -e "CLAUDE_WORKSPACE=$CRON_TMP/workspace" \
        -e "CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN" \
        -e "DEBUG=true" \
        -v "$cron_file:/cron.yaml:ro" \
        -v "$CRON_TMP/home/.claude:/home/claude/.claude" \
        -v "$CRON_TMP/workspace:$CRON_TMP/workspace" \
        "$IMAGE" >/dev/null 2>&1

    # 30-sec cron fires at the next :00 or :30 boundary. Worst case ≤30s wait, plus
    # a few seconds for claude itself. We give it 60s max — anything past that means
    # the schedule didn't fire when it should have.
    local history_root="$CRON_TMP/home/.claude/cron/history"
    local activity="" first_seen_epoch=0
    for i in $(seq 1 60); do
        activity=$(find "$history_root" -name 'activity.jsonl' -size +0 2>/dev/null | head -1)
        if [ -n "$activity" ]; then
            first_seen_epoch=$(date +%s)
            # also wait briefly for the run to finish writing meta.json with finished_at
            for _ in $(seq 1 15); do
                if grep -q '"finished_at": "' "${activity%/activity.jsonl}/meta.json" 2>/dev/null; then
                    break
                fi
                sleep 1
            done
            break
        fi
        sleep 1
    done

    local logs
    logs=$(docker logs "$cname" 2>&1)
    docker rm -f "$cname" >/dev/null 2>&1 || true

    if [ -z "$activity" ]; then
        echo "  FAIL: no activity.jsonl appeared within 60s"
        echo "  logs (last 30 lines):"
        echo "$logs" | tail -30 | sed 's/^/    /'
        _cron_cleanup_dirs
        return 1
    fi

    # timing assertion: file should appear within ~40s of container start
    # (≤30s for next :00/:30 boundary + ≤10s for claude to produce its first stream-json line)
    local elapsed=$((first_seen_epoch - started_at_epoch))
    if [ "$elapsed" -gt 40 ]; then
        echo "  FAIL: cron took $elapsed seconds to fire — schedule didn't trigger on time (expected ≤40s)"
        _cron_cleanup_dirs
        return 1
    fi
    echo "  OK: cron fired within ${elapsed}s of container start (≤40s)"

    local job_dir meta stderr_log
    job_dir=$(dirname "$activity")
    meta="$job_dir/meta.json"
    stderr_log="$job_dir/stderr.log"

    [ -f "$meta" ] || { echo "  FAIL: meta.json missing"; _cron_cleanup_dirs; return 1; }
    [ -f "$stderr_log" ] || { echo "  FAIL: stderr.log missing"; _cron_cleanup_dirs; return 1; }
    echo "  OK: history files written (activity.jsonl, meta.json, stderr.log)"

    # job dir should be under correct workspace slug
    local slug
    slug=$(echo "$CRON_TMP/workspace" | sed -E 's/[^A-Za-z0-9]+/_/g' | sed 's/^_*//;s/_*$//')
    if [ ! -d "$history_root/$slug" ]; then
        echo "  FAIL: workspace slug dir not found: $history_root/$slug"
        ls -la "$history_root" 2>&1 | sed 's/^/    /'
        _cron_cleanup_dirs
        return 1
    fi
    echo "  OK: history nested under workspace slug ($slug)"

    # job dir name should match YYYYMMDD-HHMMSS-<job> and time component should be a :00 or :30 second
    local dir_name
    dir_name=$(basename "$job_dir")
    if ! echo "$dir_name" | grep -qE '^[0-9]{8}-[0-9]{6}-ping$'; then
        echo "  FAIL: job dir name does not match YYYYMMDD-HHMMSS-<name>: $dir_name"
        _cron_cleanup_dirs
        return 1
    fi
    local dir_seconds
    dir_seconds="${dir_name:13:2}"
    if [ "$dir_seconds" != "00" ] && [ "$dir_seconds" != "30" ]; then
        echo "  FAIL: dir timestamp seconds=$dir_seconds, expected 00 or 30 (cron schedule */30)"
        _cron_cleanup_dirs
        return 1
    fi
    echo "  OK: dir timestamp seconds=$dir_seconds (matches */30 schedule)"

    local activity_content meta_content
    activity_content=$(cat "$activity")
    meta_content=$(cat "$meta")

    assert_contains "$activity_content" "CRONPONG" "claude ran and produced expected output" || { _cron_cleanup_dirs; return 1; }
    assert_contains "$meta_content" "\"name\": \"ping\"" "meta has job name" || { _cron_cleanup_dirs; return 1; }
    assert_contains "$meta_content" "\"schedule\": \"*/30 * * * * *\"" "meta has schedule" || { _cron_cleanup_dirs; return 1; }
    assert_contains "$meta_content" "\"started_at\":" "meta has started_at" || { _cron_cleanup_dirs; return 1; }
    assert_contains "$meta_content" "\"finished_at\": \"" "meta has finished_at populated" || { _cron_cleanup_dirs; return 1; }

    local rc
    rc=$(python3 -c "import json; print(json.load(open('$meta'))['exit_code'])" 2>/dev/null)
    assert_eq "$rc" "0" "claude exit code 0" || { _cron_cleanup_dirs; return 1; }

    _cron_cleanup_dirs
}

ALL_TESTS+=(
    test_cron_invalid_yaml_fails
    test_cron_missing_file_env_fails
    test_cron_loads_and_lists_jobs
    test_cron_duplicate_job_names_fail
    test_cron_invalid_schedule_fails
    test_cron_legacy_env_works
    test_cron_end_to_end_fires
)
