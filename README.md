# 🧠 docker-claude-code

[Claude Code](https://claude.com/product/claude-code) in a Docker container. No host installs. No permission nightmares. Just vibes and `--dangerously-skip-permissions`.

Four ways to unleash it:

- **Interactive** — drop-in `claude` CLI replacement, persistent container, picks up where you left off
- **Programmatic** — pass a prompt, get a response, pipe it into your cursed pipeline
- **API server** — HTTP endpoints for prompts, file management, monitoring. Slap it in your infra
- **Telegram bot** — talk to Claude from your phone when you're takin' a shit. Per-chat workspaces, models, effort levels, file sharing, shell access

## Table of Contents

- [Why?](#-why)
- [Image Variants](#-image-variants)
- [What's Inside?](#-whats-inside-full-image)
- [Requirements](#-requirements)
- [Quick Start](#%EF%B8%8F-quick-start)
- [ENV Vars](#-env-vars)
- [Usage](#-usage)
  - [Interactive mode](#interactive-mode)
  - [Programmatic mode](#programmatic-mode)
  - [API mode](#api-mode)
  - [Telegram mode](#telegram-mode)
- [Customization](#-customization)
- [Gotchas](#-gotchas)
- [License](#-license)

## 💀 Why?

Because installing things natively is for people who enjoy suffering.

This image exists so you can run Claude Code in a fully isolated container with every tool known to humankind pre-installed, passwordless sudo, docker-in-docker, and zero concern for your host system's wellbeing. It's like giving an AI a padded room with power tools.

## 🎞️ Image Variants

Pick your poison:

### `latest` (full) — the kitchen sink

Everything pre-installed. Go, Python, Node, C/C++, Terraform, kubectl, database clients, linters, formatters, the works. Big image, zero wait time. Claude wakes up and gets to work immediately.

```bash
curl -fsSL https://raw.githubusercontent.com/psyb0t/docker-claude-code/master/install.sh | bash
```

### `latest-minimal` — diet mode

Just enough to run Claude: Ubuntu, git, curl, Node.js, Docker. Claude has passwordless sudo so it'll install whatever it needs on the fly. Smaller pull, but first run takes longer while Claude figures out its life choices.

```bash
CLAUDE_MINIMAL=1 curl -fsSL https://raw.githubusercontent.com/psyb0t/docker-claude-code/master/install.sh | bash
```

Pro tip: use `~/.claude/init.d/*.sh` hooks to pre-install your tools on first container create instead of waiting for Claude to `apt-get` its way through life.

### Side by side

|                                       | `latest` (full) | `latest-minimal` |
| ------------------------------------- | :-------------: | :--------------: |
| Ubuntu 22.04                          |       yes       |       yes        |
| git, curl, wget, jq                   |       yes       |       yes        |
| Node.js LTS + npm                     |       yes       |       yes        |
| Docker CE + Compose                   |       yes       |       yes        |
| Claude Code CLI                       |       yes       |       yes        |
| Go 1.25.5 + tools                     |       yes       |        -         |
| Python 3.12.11 + tools                |       yes       |        -         |
| Node.js dev tools                     |       yes       |        -         |
| C/C++ tools                           |       yes       |        -         |
| DevOps (terraform, kubectl, helm, gh) |       yes       |        -         |
| Database clients                      |       yes       |        -         |
| Shell utilities (ripgrep, bat, etc.)  |       yes       |        -         |

## 🎞️ What's Inside? (full image)

The full image is a buffet of dev tools. Here's what Claude gets to play with:

**Languages & runtimes:**

- Go 1.25.5 with the whole toolchain (golangci-lint, gopls, delve, staticcheck, gofumpt, gotests, impl, gomodifytags)
- Python 3.12.11 via pyenv with linters, formatters, testing (flake8, black, isort, autoflake, pyright, mypy, vulture, pytest, poetry, pipenv) plus common libs (requests, beautifulsoup4, lxml, pyyaml, toml)
- Node.js LTS with the npm ecosystem loaded (eslint, prettier, typescript, ts-node, yarn, pnpm, nodemon, pm2, framework CLIs, newman, http-server, serve, lighthouse, storybook)
- C/C++ (gcc, g++, make, cmake, clang-format, valgrind, gdb, strace, ltrace)

**DevOps & infra:**

- Docker CE with Docker Compose (docker-in-docker chaos)
- Terraform, kubectl, helm, gh CLI

**Databases:**

- sqlite3, postgresql-client, mysql-client, redis-tools

**Shell & system:**

- jq, tree, ripgrep, bat, exa, fd-find, ag, htop, tmux, shellcheck, shfmt, httpie, vim, nano
- Archive tools (zip, unzip, tar), networking (net-tools, iputils-ping, dnsutils)

**Magic under the hood:**

- Auto-generated `CLAUDE.md` in workspace listing all available tools (so Claude knows what it has)
- Auto-Git config from env vars
- Auto-updates on interactive startup (skip with `--no-update`), background auto-updater disabled
- Workspace trust dialog pre-accepted (no annoying prompts)
- Custom scripts via `~/.claude/bin` (in PATH automatically)
- Init hooks via `~/.claude/init.d/*.sh` (run once on first container create)
- Session continuity with `--continue` / `--no-continue` / `--resume <session_id>`
- Debug logging (`DEBUG=true`) with timestamps everywhere

## 📋 Requirements

- Docker installed and running. That's it.

## ⚙️ Quick Start

### One-liner install

```bash
# full image (recommended)
curl -fsSL https://raw.githubusercontent.com/psyb0t/docker-claude-code/master/install.sh | bash

# minimal image
CLAUDE_MINIMAL=1 curl -fsSL https://raw.githubusercontent.com/psyb0t/docker-claude-code/master/install.sh | bash

# custom binary name (if you already have a native `claude` install)
curl -fsSL https://raw.githubusercontent.com/psyb0t/docker-claude-code/master/install.sh | bash -s -- dclaude
# or: CLAUDE_BIN_NAME=dclaude curl -fsSL .../install.sh | bash
```

### Manual setup

If you don't trust piping scripts to bash (understandable):

```bash
# 1. create dirs
mkdir -p ~/.claude
mkdir -p "$HOME/.ssh/claude-code"

# 2. generate SSH keys (for git push/pull inside the container)
ssh-keygen -t ed25519 -C "claude@claude.ai" -f "$HOME/.ssh/claude-code/id_ed25519" -N ""
# then add the pubkey to GitHub/GitLab/wherever

# 3. pull
docker pull psyb0t/claude-code:latest
# or: docker pull psyb0t/claude-code:latest-minimal

# 4. check install.sh for how the wrapper script works and wire it up yourself
```

## 🔐 ENV Vars

### Wrapper script vars

Set these on your host (e.g. `~/.bashrc`). The wrapper forwards them to the container.

| Variable                  | What it does                                                                   | Default              |
| ------------------------- | ------------------------------------------------------------------------------ | -------------------- |
| `CLAUDE_GIT_NAME`         | Git commit name inside the container                                           | _(none)_             |
| `CLAUDE_GIT_EMAIL`        | Git commit email inside the container                                          | _(none)_             |
| `ANTHROPIC_API_KEY`       | API key for authentication                                                     | _(none)_             |
| `CLAUDE_CODE_OAUTH_TOKEN` | OAuth token for authentication                                                 | _(none)_             |
| `CLAUDE_DATA_DIR`         | Custom `.claude` data directory                                                | `~/.claude`          |
| `CLAUDE_SSH_DIR`          | Custom SSH key directory                                                       | `~/.ssh/claude-code` |
| `CLAUDE_INSTALL_DIR`      | Custom install path for the wrapper (install-time only)                        | `/usr/local/bin`     |
| `CLAUDE_BIN_NAME`         | Custom binary name (install-time only)                                         | `claude`             |
| `CLAUDE_ENV_*`            | Forward custom env vars (prefix is stripped: `CLAUDE_ENV_FOO=bar` → `FOO=bar`) | _(none)_             |
| `CLAUDE_MOUNT_*`          | Mount extra volumes (path = same in container, or `src:dest`)                  | _(none)_             |
| `DEBUG`                   | Enable debug logging with timestamps                                           | _(none)_             |

### API mode vars

Set directly on the container (e.g. docker-compose).

| Variable                | What it does                                                             | Default  |
| ----------------------- | ------------------------------------------------------------------------ | -------- |
| `CLAUDE_MODE_API`       | Set to `1` to run as HTTP API server instead of interactive/programmatic | _(none)_ |
| `CLAUDE_MODE_API_PORT`  | Port for the API server                                                  | `8080`   |
| `CLAUDE_MODE_API_TOKEN` | Bearer token for API auth (optional)                                     | _(none)_ |

### Telegram mode vars

Set directly on the container (e.g. docker-compose).

| Variable                    | What it does                                        | Default                             |
| --------------------------- | --------------------------------------------------- | ----------------------------------- |
| `CLAUDE_MODE_TELEGRAM`      | Set to `1` to run as Telegram bot                   | _(none)_                            |
| `CLAUDE_TELEGRAM_BOT_TOKEN` | Bot token from [@BotFather](https://t.me/BotFather) | _(none)_                            |
| `CLAUDE_TELEGRAM_CONFIG`    | Path to the YAML config file inside the container   | `/home/claude/.claude/telegram.yml` |

### Authentication

Either log in interactively or set up a token:

```bash
# one-time interactive OAuth setup
claude setup-token

# then use the token for programmatic/headless runs
CLAUDE_CODE_OAUTH_TOKEN=xxx claude "do stuff"

# or just use an API key
ANTHROPIC_API_KEY=sk-ant-xxx claude "do stuff"
```

### Forwarding env vars

The `CLAUDE_ENV_` prefix lets you inject arbitrary env vars into the container. The prefix gets stripped:

```bash
# inside the container: GITHUB_TOKEN=xxx, MY_VAR=hello
CLAUDE_ENV_GITHUB_TOKEN=xxx CLAUDE_ENV_MY_VAR=hello claude "do stuff"
```

### Extra volume mounts

The `CLAUDE_MOUNT_` prefix mounts additional directories:

```bash
CLAUDE_MOUNT_DATA=/data claude "process the data"                    # same path inside container
CLAUDE_MOUNT_1=/opt/configs CLAUDE_MOUNT_2=/var/logs claude "go"     # mount multiple
CLAUDE_MOUNT_STUFF=/host/path:/container/path claude "do stuff"      # explicit mapping
CLAUDE_MOUNT_RO=/data:/data:ro claude "read the data"                # read-only
```

If the value contains `:`, it's used as-is (docker `-v` syntax). Otherwise, same path on both sides.

## 🧙 Usage

### Interactive mode

```bash
claude
```

Just like the native CLI but in a container. The container persists between runs — `--continue` resumes your last conversation automatically. Claude auto-updates on each interactive start.

```bash
claude --no-update    # skip auto-update
```

### Programmatic mode

Pass a prompt and get a response. `-p` is added automatically. No TTY, works from scripts, cron, CI, whatever.

```bash
claude "explain this codebase"                                      # plain text (default)
claude "explain this codebase" --output-format json                 # JSON response
claude "list all TODOs" --output-format stream-json | jq .          # streaming NDJSON
claude "explain this codebase" --model opus                         # pick your model
claude "review this" --system-prompt "You are a security auditor"   # custom system prompt
claude "review this" --append-system-prompt "Focus on SQL injection" # append to default
claude "debug this" --effort max                                    # go hard
claude "quick question" --effort low                                # go fast
claude "start over" --no-continue                                   # fresh session
claude "keep going" --resume abc123-def456                          # resume specific session

# structured output with JSON schema
claude "extract the author and title" --output-format json \
  --json-schema '{"type":"object","properties":{"author":{"type":"string"},"title":{"type":"string"}},"required":["author","title"]}'
```

`--continue` is passed automatically so successive programmatic runs share conversation context. Use `--no-continue` to start fresh or `--resume <session_id>` to continue a specific conversation.

#### Model selection

| Alias        | Model                                | Best for                                        |
| ------------ | ------------------------------------ | ----------------------------------------------- |
| `opus`       | Claude Opus 4.6                      | Complex reasoning, architecture, hard debugging |
| `sonnet`     | Claude Sonnet 4.6                    | Daily coding, balanced speed/intelligence       |
| `haiku`      | Claude Haiku 4.5                     | Quick lookups, simple tasks, high volume        |
| `opusplan`   | Opus (planning) + Sonnet (execution) | Best of both worlds                             |
| `sonnet[1m]` | Sonnet with 1M context               | Long sessions, huge codebases                   |

You can also pin specific versions with full model names (`claude-opus-4-6`, `claude-sonnet-4-6`, `claude-haiku-4-5-20251001`, etc.). If not specified, defaults based on your account type.

#### Output formats

**`text`** (default) — plain text response.

**`json`** — single JSON object:

```json
{
  "type": "result",
  "subtype": "success",
  "is_error": false,
  "result": "the response text",
  "num_turns": 1,
  "duration_ms": 3100,
  "total_cost_usd": 0.156,
  "session_id": "...",
  "usage": { "input_tokens": 3, "output_tokens": 4 }
}
```

**`stream-json`** — NDJSON stream, one event per line. Event types: `system` (init), `assistant` (text/tool_use), `user` (tool results), `rate_limit_event`, `result` (final summary with cost). A typical multi-step run: `system` → (`assistant` → `user`) × N → `result`.

<details>
<summary>Full stream-json event examples</summary>

**`system`** — session init:

```json
{
  "type": "system",
  "subtype": "init",
  "cwd": "/your/project",
  "session_id": "...",
  "tools": ["Bash", "Read", "Write", "Glob", "Grep"],
  "model": "claude-opus-4-6",
  "permissionMode": "bypassPermissions"
}
```

**`assistant`** — Claude's response (text or tool_use):

```json
{
  "type": "assistant",
  "message": {
    "model": "claude-opus-4-6",
    "role": "assistant",
    "content": [{ "type": "text", "text": "I'll install cowsay first." }],
    "usage": { "input_tokens": 3, "output_tokens": 2 }
  }
}
```

```json
{
  "type": "assistant",
  "message": {
    "content": [
      {
        "type": "tool_use",
        "id": "toolu_abc123",
        "name": "Bash",
        "input": { "command": "sudo apt-get install -y cowsay" }
      }
    ]
  }
}
```

**`user`** — tool execution result:

```json
{
  "type": "user",
  "message": {
    "content": [
      {
        "tool_use_id": "toolu_abc123",
        "type": "tool_result",
        "content": "Setting up cowsay (3.03+dfsg2-8) ...",
        "is_error": false
      }
    ]
  }
}
```

**`result`** — final summary:

```json
{
  "type": "result",
  "subtype": "success",
  "is_error": false,
  "num_turns": 10,
  "duration_ms": 60360,
  "total_cost_usd": 0.203,
  "result": "Here's what I did:\n1. Installed cowsay..."
}
```

</details>

### API mode

Turn the container into an HTTP API server. Useful for integrating Claude into your services.

```yaml
# docker-compose.yml
services:
  claude:
    image: psyb0t/claude-code:latest
    ports:
      - "8080:8080"
    environment:
      - CLAUDE_MODE_API=1
      - CLAUDE_MODE_API_TOKEN=your-secret-token
      - CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-xxx
    volumes:
      - ~/.claude:/home/claude/.claude
      - /your/projects:/workspaces
      - /var/run/docker.sock:/var/run/docker.sock
```

#### Endpoints

**`POST /run`** — send a prompt, get JSON back:

```bash
curl -X POST http://localhost:8080/run \
  -H "Authorization: Bearer your-secret-token" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "what does this repo do", "workspace": "myproject"}'
```

| Field                  | Type   | Description                                                              | Default         |
| ---------------------- | ------ | ------------------------------------------------------------------------ | --------------- |
| `prompt`               | string | The prompt to send                                                       | required        |
| `workspace`            | string | Subpath under `/workspaces` (e.g. `myproject` → `/workspaces/myproject`) | `/workspaces`   |
| `model`                | string | Model to use (same aliases as CLI)                                       | account default |
| `system_prompt`        | string | Replace the default system prompt                                        | _(none)_        |
| `append_system_prompt` | string | Append to the default system prompt                                      | _(none)_        |
| `json_schema`          | string | JSON Schema for structured output                                        | _(none)_        |
| `effort`               | string | Reasoning effort (`low`, `medium`, `high`, `max`)                        | _(none)_        |
| `no_continue`          | bool   | Start fresh (don't continue previous conversation)                       | `false`         |
| `resume`               | string | Resume a specific session by ID                                          | _(none)_        |
| `fire_and_forget`      | bool   | Don't kill the process if the client disconnects                         | `false`         |

Returns `application/json` (same format as `--output-format json`). Returns **409** if the workspace is already busy.

**`GET /files/{path}`** — list directory or download file:

```bash
curl "http://localhost:8080/files" -H "Authorization: Bearer token"                    # list root
curl "http://localhost:8080/files/myproject/src" -H "Authorization: Bearer token"      # list subdir
curl "http://localhost:8080/files/myproject/src/main.py" -H "Authorization: Bearer token"  # download
```

**`PUT /files/{path}`** — upload a file (auto-creates parent dirs):

```bash
curl -X PUT "http://localhost:8080/files/myproject/src/main.py" \
  -H "Authorization: Bearer token" --data-binary @main.py
```

**`DELETE /files/{path}`** — delete a file:

```bash
curl -X DELETE "http://localhost:8080/files/myproject/src/old.py" -H "Authorization: Bearer token"
```

**`GET /health`** — health check (no auth).
**`GET /status`** — which workspaces are busy.
**`POST /run/cancel?workspace=X`** — kill a running claude process.

All file paths are relative to `/workspaces`. Path traversal outside root is blocked.

### Telegram mode

Talk to Claude from Telegram. Each chat gets its own workspace and settings. Send text, files, photos, videos, voice messages. Run shell commands. Get files back.

#### Setup

1. **Create a bot** — talk to [@BotFather](https://t.me/BotFather), run `/newbot`, save the token
2. **Get your chat ID** — message [@userinfobot](https://t.me/userinfobot), it replies with your user ID (which is also your DM chat ID). Group chat IDs are negative.
3. **Create `~/.claude/telegram.yml`:**

```yaml
# which chats the bot responds in
# DM user IDs (positive) and/or group chat IDs (negative)
# empty = no restriction (dangerous!)
allowed_chats:
  - 123456789 # your DM
  - -987654321 # a group

# defaults for chats not explicitly configured
default:
  model: sonnet
  effort: high
  continue: true

# per-chat overrides
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
    # only these users can talk in this group
    allowed_users:
      - 123456789
      - 111222333
```

Per-chat options: `workspace`, `model`, `effort`, `continue`, `system_prompt`, `append_system_prompt`, `max_budget_usd`, `allowed_users`.

4. **Run it:**

```yaml
# docker-compose.yml
services:
  claude-telegram:
    image: psyb0t/claude-code:latest
    environment:
      - CLAUDE_MODE_TELEGRAM=1
      - CLAUDE_TELEGRAM_BOT_TOKEN=123456:ABC-DEF
      - CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-xxx
    volumes:
      - ~/.claude:/home/claude/.claude
      - ~/telegram-workspaces:/workspaces
      - /var/run/docker.sock:/var/run/docker.sock
```

#### Bot commands

| Command                       | What it does                                              |
| ----------------------------- | --------------------------------------------------------- |
| any text message              | Sent to Claude as a prompt                                |
| send a file/photo/video/voice | Saved to workspace; caption becomes the prompt if present |
| `/bash <command>`             | Run a shell command in the chat's workspace               |
| `/fetch <path>`               | Get a file from the workspace as a Telegram attachment    |
| `/cancel`                     | Kill the running Claude process for this chat             |
| `/status`                     | Show which chats are busy                                 |
| `/config`                     | Show this chat's config                                   |
| `/reload`                     | Hot-reload the YAML config without restarting             |

Claude can send files back by putting `[SEND_FILE: relative/path]` in its response — images get sent as photos, videos as videos, everything else as documents. Long responses are automatically split across multiple messages (4096 char Telegram limit).

## 🔧 Customization

### Custom scripts (`~/.claude/bin`)

Drop executables into `~/.claude/bin/` and they're in PATH inside every container session:

```bash
mkdir -p ~/.claude/bin
echo '#!/bin/bash
echo "hello from custom script"' > ~/.claude/bin/my-tool
chmod +x ~/.claude/bin/my-tool
# now available inside the container as `my-tool`
```

### Init hooks (`~/.claude/init.d`)

Scripts in `~/.claude/init.d/*.sh` run once on first container create (as root, before dropping to the claude user). They don't re-run on subsequent `docker start` — only on fresh containers.

```bash
mkdir -p ~/.claude/init.d
cat > ~/.claude/init.d/setup.sh << 'EOF'
#!/bin/bash
apt-get update && apt-get install -y some-package
pip install some-library
EOF
chmod +x ~/.claude/init.d/setup.sh
```

Great for pre-installing tools on the minimal image so Claude doesn't waste your tokens figuring out `apt-get`.

## 🦴 Gotchas

- **`--dangerously-skip-permissions`** is always on. Claude has full access. That's the point.
- **SSH keys** are mounted for git operations. Don't share your container with strangers.
- **Host paths are preserved** — your project at `/home/you/project` stays at `/home/you/project` inside the container. This means docker volume mounts from inside Claude work correctly against host paths.
- **UID/GID matching** — the container user's UID/GID auto-matches the host directory owner. File permissions just work.
- **Docker-in-Docker** — the Docker socket is mounted. Claude can spawn containers within containers. It's fine. Probably.
- **Two containers per workspace** — `claude-_path` (interactive, TTY) and `claude-_path_prog` (programmatic, no TTY). They share the same mounted data.
- **`~/.claude/bin`** is in PATH. Custom scripts are available everywhere.
- **Telegram config is required** — the bot won't start without `telegram.yml`. No config = no bot. This is intentional so you don't accidentally expose Claude to the world.

## 📜 License

[WTFPL](http://www.wtfpl.net/) — do what the fuck you want to.
