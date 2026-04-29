#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="$HOME/claudebox-log-checker"
CRON_YAML="$WORKSPACE/cron.yaml"
CRON_NAME="claudebox-log-checker_cron"

mkdir -p "$WORKSPACE"

cat > "$CRON_YAML" <<'EOF'
model: haiku
append_system_prompt: |
  Current time: {system_datetime}.

jobs:
  - name: log_checker
    schedule: "0 */10 * * * *"
    instruction: |
      Check /var/log for anything interesting from the past 10 minutes.
      Look at syslog, auth.log, kern.log, and any other non-empty log files present.
      Report errors, warnings, failed logins, or unusual activity.
      If everything looks clean, say so.
EOF

docker rm -f "$CRON_NAME" >/dev/null 2>&1 || true

docker run -d \
    --name "$CRON_NAME" \
    --network host \
    -e "CLAUDEBOX_MODE_CRON=1" \
    -e "CLAUDEBOX_MODE_CRON_FILE=/workspace/cron.yaml" \
    -e "CLAUDEBOX_WORKSPACE=/workspace" \
    -e "CLAUDE_CODE_OAUTH_TOKEN=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" \
    -v "$CRON_YAML:/workspace/cron.yaml:ro" \
    -v "$WORKSPACE:/workspace" \
    -v "$HOME/.claude:/home/claude/.claude" \
    -v "/var/log:/var/log:ro" \
    psyb0t/claudebox:latest

echo "running — next fire at next :00 or :10 or :20... boundary"
echo "logs:    docker logs -f $CRON_NAME"
echo "stop:    docker stop $CRON_NAME"
