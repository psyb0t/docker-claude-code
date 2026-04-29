#!/usr/bin/env bash
# end-to-end test for cron+telegram combined mode + reply context injection.
#
# what it does:
#   - cron fires every 30s, runs a claude job that writes a weird-text file
#   - on finish, claude's result is sent to the configured telegram chat
#   - YOU then reply (in telegram) to that message asking what file was written
#     and what's in it
#   - the bot picks up the reply, prepends the cron job context, runs claude
#     (fresh session, no --continue), claude tells you exactly what was in the file
#
# success = bot's response mentions "peen goes in vageen" — proves the cron
# context (job name, instruction, result) was injected into the reply prompt.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$SCRIPT_DIR/.e2e-cron-tg"
CRON_YAML="$WORKSPACE/cron.yaml"
TELEGRAM_YAML="$WORKSPACE/telegram.yml"
CNAME="claudebox-cron-tg-e2e_cron"

if [ -f "$SCRIPT_DIR/tests/.env" ]; then
    set -a; . "$SCRIPT_DIR/tests/.env"; set +a
fi
: "${CLAUDE_CODE_OAUTH_TOKEN:?CLAUDE_CODE_OAUTH_TOKEN not set (put it in tests/.env)}"
: "${CLAUDEBOX_TELEGRAM_BOT_TOKEN:?CLAUDEBOX_TELEGRAM_BOT_TOKEN not set (put it in tests/.env)}"
: "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID not set (put it in tests/.env)}"

OAUTH="$CLAUDE_CODE_OAUTH_TOKEN"
BOT_TOKEN="$CLAUDEBOX_TELEGRAM_BOT_TOKEN"
CHAT_ID="$TELEGRAM_CHAT_ID"

mkdir -p "$WORKSPACE"

cat > "$CRON_YAML" <<EOF
model: haiku
telegram_chat_id: $CHAT_ID

jobs:
  - name: weird_writer
    schedule: "*/30 * * * * *"
    instruction: |
      Write a file at ./weird.txt containing exactly the line:
      peen goes in vageen
      Then briefly tell me you wrote it and what's in it.
EOF

cat > "$TELEGRAM_YAML" <<EOF
allowed_chats:
  - $CHAT_ID
default:
  model: haiku
  continue: true
  workspace: e2e
chats: {}
EOF

mkdir -p "$WORKSPACE/.claude"
cp "$TELEGRAM_YAML" "$WORKSPACE/.claude/telegram.yml"

mkdir -p "$WORKSPACE/workspaces/e2e"

docker rm -f "$CNAME" >/dev/null 2>&1 || true

docker run -d \
    --name "$CNAME" \
    --network host \
    -e "CLAUDEBOX_MODE_CRON=1" \
    -e "CLAUDEBOX_MODE_TELEGRAM=1" \
    -e "CLAUDEBOX_MODE_CRON_FILE=/workspace/cron.yaml" \
    -e "CLAUDEBOX_WORKSPACE=/workspace" \
    -e "CLAUDE_CODE_OAUTH_TOKEN=$OAUTH" \
    -e "CLAUDEBOX_TELEGRAM_BOT_TOKEN=$BOT_TOKEN" \
    -v "$WORKSPACE:/workspace" \
    -v "$WORKSPACE/.claude:/home/claude/.claude" \
    -v "$WORKSPACE/workspaces:/workspaces" \
    psyb0t/claudebox:test

cat <<'INSTRUCTIONS'

🟢 container started.

  watch logs:    docker logs -f claudebox-cron-tg-e2e_cron
  stop:          docker stop claudebox-cron-tg-e2e_cron && docker rm claudebox-cron-tg-e2e_cron

what to do:
  1. wait up to 30s — the cron job fires and posts its result into the telegram chat.
  2. in telegram, REPLY to that message with:
        what was the file you wrote, again? and what u wrote in it?
  3. the bot should answer with something like:
        ./weird.txt — contents: peen goes in vageen
     even though that knowledge came from a DIFFERENT claude session (the cron one).
     proof that the cron job context was injected into the reply prompt.

  to inspect the saved tracking:  cat $HOME/claudebox-cron-tg-e2e/.claude/cron/telegram_messages.json
INSTRUCTIONS
