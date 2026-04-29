# Telegram Mode

Talk to Claude Code from Telegram. Each chat gets its own isolated workspace and individually configurable settings. Send text messages, files, photos, videos, and voice messages. Run shell commands. Retrieve files. All from your phone.

## Setup

1. **Create a bot** — talk to [@BotFather](https://t.me/BotFather), run `/newbot`, and save the token.
2. **Get your chat ID** — message [@userinfobot](https://t.me/userinfobot) and it will reply with your user ID (which is also your DM chat ID). Group chat IDs are negative numbers.
3. **Create the config file at `~/.claude/telegram.yml`:**

```yaml
# which chats the bot responds in
# DM user IDs (positive) and/or group chat IDs (negative)
# empty list = no restriction (dangerous — anyone can talk to your bot!)
allowed_chats:
  - 123456789 # your DM
  - -987654321 # a group chat

# defaults applied to chats without explicit overrides
default:
  model: sonnet
  effort: high
  continue: true

# per-chat configuration overrides
chats:
  123456789:
    workspace: my-project
    model: opus
    effort: max
    system_prompt: "You are a senior engineer"

  -987654321:
    workspace: team-stuff
    model: sonnet
    effort: medium
    continue: false
    append_system_prompt: "Keep responses short"
    # restrict which users can interact in this group
    allowed_users:
      - 123456789
      - 111222333
```

Per-chat configuration options: `workspace`, `model`, `effort`, `continue`, `system_prompt`, `append_system_prompt`, `max_budget_usd`, `allowed_users`.

4. **Run it:**

```yaml
# docker-compose.yml
services:
  claudebox-telegram:
    image: psyb0t/claudebox:latest
    environment:
      - CLAUDEBOX_MODE_TELEGRAM=1
      - CLAUDEBOX_TELEGRAM_BOT_TOKEN=123456:ABC-DEF
      - CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-xxx
    volumes:
      - ~/.claude:/home/claude/.claude
      - ~/telegram-workspaces:/workspaces
      - /var/run/docker.sock:/var/run/docker.sock
```

## Telegram environment variables

| Variable                       | Description                                         | Default                             |
| ------------------------------ | --------------------------------------------------- | ----------------------------------- |
| `CLAUDEBOX_MODE_TELEGRAM`      | Set to `1` to start in Telegram bot mode            | _(none)_                            |
| `CLAUDEBOX_TELEGRAM_BOT_TOKEN` | Bot token from [@BotFather](https://t.me/BotFather) | _(none)_                            |
| `CLAUDEBOX_TELEGRAM_CONFIG`    | Path to the YAML config file inside the container   | `/home/claude/.claude/telegram.yml` |

> Legacy `CLAUDE_MODE_TELEGRAM`, `CLAUDE_TELEGRAM_BOT_TOKEN`, `CLAUDE_TELEGRAM_CONFIG` are still accepted as fallbacks.

## Bot commands

| Command                       | Description                                                      |
| ----------------------------- | ---------------------------------------------------------------- |
| any text message              | Sent to Claude as a prompt in the chat's workspace               |
| send a file/photo/video/voice | Saved to workspace; the caption becomes the prompt (if present)  |
| `/model [name]`               | Show current model with selectable buttons, or set directly: `/model haiku\|sonnet\|opus\|opusplan\|reset`. |
| `/effort [level]`             | Show/select effort level: `/effort low\|medium\|high\|xhigh\|max\|reset`. |
| `/system_prompt [text]`       | Show, set, or reset (`reset`/`clear`) the system prompt override for this chat. With no args shows the current value. |
| `/append_system_prompt [text]` | Same as above for the appended system prompt. |
| `/bash <command>`             | Run a shell command directly in the chat's workspace             |
| `/fetch <path>`               | Get a file from the workspace sent as a Telegram attachment      |
| `/cancel`                     | Kill the running Claude process for this chat                    |
| `/status`                     | Show which chats currently have running processes                |
| `/config`                     | Display this chat's current configuration                        |
| `/reload`                     | Hot-reload the YAML config file without restarting the container |

Claude can send files back by including `[SEND_FILE: relative/path]` in its response text. Images are sent as photos, videos as video messages, and everything else as document attachments. Long responses are automatically split across multiple messages to stay within Telegram's 4096-character limit.
