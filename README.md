# 🧠 docker-claude-code

**claude** but dockerized, goth-approved, and dangerously executable.
This container gives you the [Claude Code](https://claude.com/product/claude-code) in a fully isolated ritual circle – no cursed system installs required.

## 💀 Why?

Because installing things natively is for suckers.
This image is for devs who live dangerously, commit anonymously, and like their AI tools in containers.

## 🎞️ Image Variants

Two image variants are available:

### `latest` (full) — batteries included

Everything pre-installed. Big image, zero setup time.

```bash
# default — full image
curl -fsSL .../install.sh | bash
```

### `minimal` — lean and mean

Just the bare essentials to run claude (Ubuntu, git, curl, wget, jq, Node.js, Docker). Claude has passwordless sudo so it can install whatever it needs on the fly. Smaller image, faster pull, but first-run setup takes longer.

```bash
# install with minimal image
CLAUDE_MINIMAL=1 curl -fsSL .../install.sh | bash
```

Use `~/.claude/init.d/*.sh` to pre-install your tools on first container create so you don't have to wait for claude to figure it out.

### What's in each variant?

|                                       | `latest` (full) | `minimal` |
| ------------------------------------- | --------------- | --------- |
| Ubuntu 22.04                          | yes             | yes       |
| git, curl, wget, jq                   | yes             | yes       |
| Node.js LTS + npm                     | yes             | yes       |
| Docker CE + Compose                   | yes             | yes       |
| Claude Code CLI                       | yes             | yes       |
| Go 1.25.5 + tools                     | yes             | -         |
| Python 3.12.11 + tools                | yes             | -         |
| Node.js dev tools                     | yes             | -         |
| C/C++ tools                           | yes             | -         |
| DevOps (terraform, kubectl, helm, gh) | yes             | -         |
| Database clients                      | yes             | -         |
| Shell utilities (ripgrep, bat, etc.)  | yes             | -         |

## 🎞️ What's Inside? (full image)

- Go 1.25.5 with full toolchain (golangci-lint, gopls, delve, staticcheck, gofumpt, gotests, impl, gomodifytags)
- Latest Node.js with comprehensive dev tools (eslint, prettier, typescript, ts-node, yarn, pnpm, nodemon, pm2, framework CLIs, newman, http-server, serve, lighthouse, storybook)
- Python 3.12.11 via pyenv with linters, formatters, testing (flake8, black, isort, autoflake, pyright, mypy, vulture, pytest, poetry, pipenv)
- Python libraries pre-installed (requests, beautifulsoup4, lxml, pyyaml, toml)
- Docker CE with Docker Compose (full containerization chaos)
- DevOps tools (terraform, kubectl, helm, gh CLI)
- System utilities (jq, tree, ripgrep, bat, exa, fd-find, silversearcher-ag, htop, tmux)
- Shell tools (shellcheck, shfmt)
- C/C++ tools (gcc, g++, make, cmake, clang-format, valgrind, gdb, strace, ltrace)
- Database clients (sqlite3, postgresql-client, mysql-client, redis-tools)
- Editors (vim, nano)
- Archive tools (zip, unzip, tar)
- Networking tools (net-tools, iputils-ping, dnsutils)
- `git` + `curl` + `wget` + `httpie` + Claude Code
- Auto-Git config based on env vars
- Auto-generated `CLAUDE.md` in workspace (lists all available tools for Claude's awareness)
- Startup script that configures git, updates claude, and runs with `--dangerously-skip-permissions --continue` (falls back to fresh session if no conversation to continue)
- Auto-updates claude on interactive startup (skip with `--no-update`), background auto-updater disabled
- Workspace trust dialog is automatically pre-accepted (no annoying prompts)
- Programmatic mode support — just pass a prompt and optional `--output-format` (`-p` is added automatically)
- Custom scripts via `~/.claude/bin` — drop executables there and they're in PATH inside the container
- Init hooks via `~/.claude/init.d/*.sh` — run once on first container create (not on subsequent starts)
- Debug logging (`DEBUG=true`) with timestamps in both wrapper and entrypoint

## 📋 Requirements

- Docker installed and running

## ⚙️ Quick Start

### 🚀 Quick Install

There's an install script that sets everything up automatically:

```bash
curl -fsSL https://raw.githubusercontent.com/psyb0t/docker-claude-code/master/install.sh | bash
```

To install the minimal image instead of full:

```bash
CLAUDE_MINIMAL=1 curl -fsSL https://raw.githubusercontent.com/psyb0t/docker-claude-code/master/install.sh | bash
```

To install as a different binary name (e.g. to avoid collision with a native `claude` install):

```bash
# as argument
curl -fsSL .../install.sh | bash -s -- dclaude

# or via env var
CLAUDE_BIN_NAME=dclaude curl -fsSL .../install.sh | bash
```

Or if you prefer manual control:

### 1. Create dirs

```bash
mkdir -p ~/.claude
mkdir -p "$HOME/.ssh/claude-code"
```

### 2. Generate SSH Keys

```bash
ssh-keygen -t ed25519 -C "claude@claude.ai" -f "$HOME/.ssh/claude-code/id_ed25519" -N ""
```

Then add the public key (`$HOME/.ssh/claude-code/id_ed25519.pub`) to your GitHub account or wherever you push code.

### 3. Pull the image

```bash
docker pull psyb0t/claude-code:latest
# or for minimal:
docker pull psyb0t/claude-code:latest-minimal
```

From here, check `install.sh` to see how the wrapper script works if you want to wire it up yourself.

## 🔐 ENV Vars

### Wrapper script vars

Set these on your host machine (e.g. in `~/.bashrc` or `~/.zshrc`). The wrapper script forwards them to the container.

| Variable                  | What it does                                                             | Default              |
| ------------------------- | ------------------------------------------------------------------------ | -------------------- |
| `CLAUDE_GIT_NAME`         | Git commit name inside the container                                     | _(none)_             |
| `CLAUDE_GIT_EMAIL`        | Git commit email inside the container                                    | _(none)_             |
| `ANTHROPIC_API_KEY`       | API key for authentication                                               | _(none)_             |
| `CLAUDE_CODE_OAUTH_TOKEN` | OAuth token for authentication                                           | _(none)_             |
| `CLAUDE_DATA_DIR`         | Custom `.claude` data directory (config, sessions, auth, plugins)        | `~/.claude`          |
| `CLAUDE_SSH_DIR`          | Custom SSH key directory                                                 | `~/.ssh/claude-code` |
| `CLAUDE_INSTALL_DIR`      | Custom install path for the wrapper script (install-time only)           | `/usr/local/bin`     |
| `CLAUDE_BIN_NAME`         | Custom binary name (install-time only)                                   | `claude`             |
| `CLAUDE_ENV_*`            | Forward custom env vars to the container (prefix is stripped)            | _(none)_             |
| `CLAUDE_MOUNT_*`          | Mount extra volumes (path alone = same path in container, or `src:dest`) | _(none)_             |
| `DEBUG`                   | Enable debug logging with timestamps in wrapper and entrypoint           | _(none)_             |

### API mode vars

Set these directly on the container (e.g. in docker-compose). Not used by the wrapper script.

| Variable                | What it does                                                             | Default  |
| ----------------------- | ------------------------------------------------------------------------ | -------- |
| `CLAUDE_MODE_API`       | Set to `1` to run as HTTP API server instead of interactive/programmatic | _(none)_ |
| `CLAUDE_MODE_API_PORT`  | Port for the API server                                                  | `8080`   |
| `CLAUDE_MODE_API_TOKEN` | Bearer token to require for API requests (optional)                      | _(none)_ |

To set wrapper vars, export them on your host:

```bash
export CLAUDE_GIT_NAME="Your Name"
export CLAUDE_GIT_EMAIL="your@email.com"
```

If not set, git inside the container won't have a default identity configured.

### Authentication

Either log in interactively or set up a long-lived OAuth token:

```bash
# generate an OAuth token (interactive, one-time setup)
claude setup-token

# then use it for programmatic runs
CLAUDE_CODE_OAUTH_TOKEN=xxx claude "do stuff"

# or use an API key
ANTHROPIC_API_KEY=sk-ant-xxx claude "do stuff"
```

### Custom env vars

Use the `CLAUDE_ENV_` prefix to forward arbitrary env vars into the container. The prefix is stripped:

```bash
# GITHUB_TOKEN=xxx and MY_VAR=hello will be set inside the container
CLAUDE_ENV_GITHUB_TOKEN=xxx CLAUDE_ENV_MY_VAR=hello claude "do stuff"
```

### Extra volume mounts

Use the `CLAUDE_MOUNT_` prefix to mount additional directories into the container:

```bash
# mount at the same path inside the container (just specify the host path)
CLAUDE_MOUNT_DATA=/data claude "process the data"

# mount multiple directories
CLAUDE_MOUNT_1=/opt/configs CLAUDE_MOUNT_2=/var/logs claude "check logs"

# explicit source:dest mapping
CLAUDE_MOUNT_STUFF=/host/path:/container/path claude "do stuff"

# read-only mount
CLAUDE_MOUNT_RO=/data:/data:ro claude "read the data"
```

If the value contains `:`, it's used as-is (docker `-v` syntax). Otherwise, the path is mounted at the same location inside the container.

### Custom paths

```bash
# custom .claude data directory
CLAUDE_DATA_DIR=/path/to/.claude claude "do stuff"

# custom SSH key directory
CLAUDE_SSH_DIR=/path/to/.ssh claude "do stuff"

# install to a different directory
CLAUDE_INSTALL_DIR=/usr/bin curl -fsSL .../install.sh | bash
```

## 🧙 Usage

### Interactive mode

```bash
claude
```

Starts an interactive session. The container is named by directory path and persists between runs — stop/restart instead of attach, with `--continue` to resume the last conversation. Claude auto-updates on each interactive start. To skip:

```bash
claude --no-update
```

Programmatic runs never auto-update.

### Programmatic mode

Just pass a prompt — `-p` is added automatically:

```bash
# one-shot prompt with JSON output
claude "explain this codebase" --output-format json

# use a specific model
claude "explain this codebase" --model sonnet
claude "explain this codebase" --model claude-sonnet-4-6

# streaming output piped to jq
claude "list all TODOs" --output-format stream-json | jq .

# plain text output (default)
claude "what does this repo do"

# custom system prompt (replaces default)
claude "review this" --system-prompt "You are a security auditor"

# append to default system prompt
claude "review this" --append-system-prompt "Focus on SQL injection"

# structured output with JSON schema
claude "extract the author and title" --output-format json \
  --json-schema '{"type":"object","properties":{"author":{"type":"string"},"title":{"type":"string"}},"required":["author","title"]}'

# set reasoning effort level
claude "debug this complex issue" --effort high
claude "quick question" --effort low
```

Uses its own `_prog` container (no TTY — works from scripts, cron, other tools). `--continue` is passed automatically so programmatic runs share session context via the mounted `.claude` data dir.

#### Model selection

Use `--model` to pick which Claude model to use:

| Alias        | Model                                | Best for                                        |
| ------------ | ------------------------------------ | ----------------------------------------------- |
| `opus`       | Claude Opus 4.6                      | Complex reasoning, architecture, hard debugging |
| `sonnet`     | Claude Sonnet 4.6                    | Daily coding, balanced speed/intelligence       |
| `haiku`      | Claude Haiku 4.5                     | Quick lookups, simple tasks, high volume        |
| `opusplan`   | Opus (planning) + Sonnet (execution) | Best of both worlds                             |
| `sonnet[1m]` | Sonnet with 1M context               | Long sessions, huge codebases                   |

You can also use full model names to pin specific versions:

| Full model name              | Notes                               |
| ---------------------------- | ----------------------------------- |
| `claude-opus-4-6`            | Current Opus                        |
| `claude-sonnet-4-6`          | Current Sonnet                      |
| `claude-haiku-4-5-20251001`  | Current Haiku                       |
| `claude-opus-4-5-20251101`   | Legacy                              |
| `claude-sonnet-4-5-20250929` | Legacy                              |
| `claude-opus-4-1-20250805`   | Legacy                              |
| `claude-opus-4-20250514`     | Legacy (alias: `claude-opus-4-0`)   |
| `claude-sonnet-4-20250514`   | Legacy (alias: `claude-sonnet-4-0`) |
| `claude-3-haiku-20240307`    | Deprecated, retiring April 2026     |

```bash
claude "do stuff" --model opus                        # latest opus
claude "do stuff" --model haiku                       # fast and cheap
claude "do stuff" --model claude-sonnet-4-5-20250929  # pin to specific version
```

If not specified, the model defaults based on your account type (Max/Team Premium → Opus, Pro/Team Standard → Sonnet).

#### Output formats

**`text`** (default) — plain text response.

**`json`** — single JSON object with the result:

```json
{
  "type": "result",
  "subtype": "success",
  "is_error": false,
  "result": "the response text",
  "num_turns": 1,
  "duration_ms": 3100,
  "duration_api_ms": 3069,
  "total_cost_usd": 0.156,
  "session_id": "...",
  "usage": { "input_tokens": 3, "output_tokens": 4, "...": "..." },
  "modelUsage": { "...": "..." }
}
```

**`stream-json`** — newline-delimited JSON (NDJSON), one event per line. Each event has a `type` field. Here's what a multi-step run looks like (e.g. `claude "install cowsay, run it, fetch a URL" --output-format stream-json`):

**`system`** — first event, session init with tools, model, version, permissions:

```json
{"type":"system","subtype":"init","cwd":"/your/project","session_id":"...","tools":["Bash","Read","Write","Glob","Grep","..."],"model":"claude-opus-4-6","permissionMode":"bypassPermissions","claude_code_version":"2.1.62","agents":["general-purpose","Explore","Plan","..."],"skills":["keybindings-help","debug"],"plugins":[...],"fast_mode_state":"off"}
```

**`assistant`** — Claude's responses. Content is an array of text and/or tool_use blocks:

```json
{
  "type": "assistant",
  "message": {
    "model": "claude-opus-4-6",
    "role": "assistant",
    "content": [{ "type": "text", "text": "I'll install cowsay first." }],
    "usage": {
      "input_tokens": 3,
      "output_tokens": 2,
      "cache_read_input_tokens": 22077,
      "...": "..."
    }
  },
  "session_id": "..."
}
```

When Claude calls a tool, content contains a `tool_use` block:

```json
{
  "type": "assistant",
  "message": {
    "model": "claude-opus-4-6",
    "role": "assistant",
    "content": [
      {
        "type": "tool_use",
        "id": "toolu_abc123",
        "name": "Bash",
        "input": {
          "command": "sudo apt-get install -y cowsay",
          "description": "Install cowsay"
        }
      }
    ],
    "usage": { "input_tokens": 1, "output_tokens": 26, "...": "..." }
  },
  "session_id": "..."
}
```

**`user`** — tool execution results (stdout, stderr, error status):

```json
{
  "type": "user",
  "message": {
    "role": "user",
    "content": [
      {
        "tool_use_id": "toolu_abc123",
        "type": "tool_result",
        "content": "Setting up cowsay (3.03+dfsg2-8) ...",
        "is_error": false
      }
    ]
  },
  "session_id": "...",
  "tool_use_result": {
    "stdout": "Setting up cowsay (3.03+dfsg2-8) ...",
    "stderr": "",
    "interrupted": false
  }
}
```

**`rate_limit_event`** — rate limit status check between turns:

```json
{
  "type": "rate_limit_event",
  "rate_limit_info": {
    "status": "allowed",
    "resetsAt": 1772204400,
    "rateLimitType": "five_hour",
    "overageStatus": "allowed",
    "isUsingOverage": false
  },
  "session_id": "..."
}
```

**`result`** — final event with summary, cost, usage breakdown per model:

```json
{
  "type": "result",
  "subtype": "success",
  "is_error": false,
  "num_turns": 10,
  "duration_ms": 60360,
  "duration_api_ms": 46285,
  "total_cost_usd": 0.203,
  "result": "Here's what I did:\n1. Installed cowsay...\n2. ...",
  "session_id": "...",
  "usage": {
    "input_tokens": 12,
    "output_tokens": 1669,
    "cache_read_input_tokens": 255610,
    "cache_creation_input_tokens": 5037
  },
  "modelUsage": {
    "claude-opus-4-6": {
      "inputTokens": 12,
      "outputTokens": 1669,
      "cacheReadInputTokens": 255610,
      "costUSD": 0.201
    },
    "claude-haiku-4-5-20251001": {
      "inputTokens": 1656,
      "outputTokens": 128,
      "costUSD": 0.002
    }
  }
}
```

A typical multi-step run produces: `system` → (`assistant` → `user`)× repeated per tool call → `rate_limit_event` between turns → final `assistant` text → `result`.

### API mode

Set `CLAUDE_MODE_API=1` to run the container as an HTTP API server instead of interactive/programmatic mode. Useful for integrating Claude into other services via docker-compose.

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

**`POST /run`** — run a prompt and return JSON:

```bash
curl -X POST http://localhost:8080/run \
  -H "Authorization: Bearer your-secret-token" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "what does this repo do", "workspace": "myproject"}'
```

Request body:

| Field                  | Type   | Description                                                              | Default         |
| ---------------------- | ------ | ------------------------------------------------------------------------ | --------------- |
| `prompt`               | string | The prompt to send                                                       | required        |
| `workspace`            | string | Subpath under `/workspaces` (e.g. `myproject` → `/workspaces/myproject`) | `/workspaces`   |
| `model`                | string | Model to use (same aliases as CLI)                                       | account default |
| `system_prompt`        | string | Replace the default system prompt entirely                               | _(none)_        |
| `append_system_prompt` | string | Append to the default system prompt                                      | _(none)_        |
| `json_schema`          | string | JSON Schema for structured output (result in `structured_output` field)  | _(none)_        |
| `effort`               | string | Reasoning effort level (`low`, `medium`, `high`, `max`)                  | _(none)_        |

Response is always `application/json` — same format as `--output-format json`.

If the workspace is already processing a request, returns **`409 Conflict`** — the client should retry.

**`GET /files/{path}`** — list a directory or download a file:

```bash
# list root workspace
curl "http://localhost:8080/files" -H "Authorization: Bearer your-secret-token"

# list a subdirectory
curl "http://localhost:8080/files/myproject/src" \
  -H "Authorization: Bearer your-secret-token"

# download a file
curl "http://localhost:8080/files/myproject/src/main.py" \
  -H "Authorization: Bearer your-secret-token"
```

Directory listing returns `{"path": "myproject/src", "entries": [{"name": "foo.py", "type": "file", "size": 1234}, {"name": "lib", "type": "dir"}]}`.

**`PUT /files/{path}`** — upload a file (creates parent dirs automatically):

```bash
curl -X PUT "http://localhost:8080/files/myproject/src/main.py" \
  -H "Authorization: Bearer your-secret-token" \
  --data-binary @main.py
```

**`DELETE /files/{path}`** — delete a file:

```bash
curl -X DELETE "http://localhost:8080/files/myproject/src/old.py" \
  -H "Authorization: Bearer your-secret-token"
```

All paths are relative to `/workspaces`. Path traversal outside root is blocked.

**`GET /health`** — health check (no auth required):

```bash
curl http://localhost:8080/health
```

**`GET /status`** — show which workspaces are busy:

```bash
curl http://localhost:8080/status -H "Authorization: Bearer your-secret-token"
```

**`POST /run/cancel`** — kill a running claude process:

```bash
curl -X POST "http://localhost:8080/run/cancel?workspace=myproject" \
  -H "Authorization: Bearer your-secret-token"
```

## 🔧 Customization

### Custom scripts (`~/.claude/bin`)

Drop executables into `~/.claude/bin/` on the host and they're in PATH inside every container session:

```bash
mkdir -p ~/.claude/bin
echo '#!/bin/bash
echo "hello from custom script"' > ~/.claude/bin/my-tool
chmod +x ~/.claude/bin/my-tool

# now available inside the container
claude  # my-tool is in PATH
```

### Init hooks (`~/.claude/init.d`)

Scripts in `~/.claude/init.d/*.sh` run once on first container create (as root, before dropping to claude user). They don't run again on subsequent `docker start` — only on fresh `docker run` after a container is removed.

```bash
mkdir -p ~/.claude/init.d
cat > ~/.claude/init.d/setup-my-tools.sh << 'EOF'
#!/bin/bash
apt-get update && apt-get install -y some-package
pip install some-library
EOF
chmod +x ~/.claude/init.d/setup-my-tools.sh
```

Useful for installing extra packages, configuring services, or any one-time setup that should survive container restarts but re-run on fresh containers.

## 🦴 Gotchas

- This tool uses `--dangerously-skip-permissions`. Because Claude likes to live fast and break sandboxes.
- SSH keys are mounted to allow commit/push shenanigans. Keep 'em safe, goblin.
- The host directory is mounted at its exact path inside the container (e.g. `/home/you/project` stays `/home/you/project`). This means docker volume mounts from inside Claude will use correct host paths.
- The container user's UID/GID is automatically matched to the host directory owner, so file permissions just work.
- Docker socket is mounted so Claude can spawn containers within containers. Docker-in-Docker madness enabled.
- Workspace trust dialog is pre-accepted automatically — no confirmation prompts on startup.
- Two container types per workspace: `claude-_path` (interactive, with TTY), `claude-_path_prog` (programmatic, no TTY). Programmatic runs without TTY so they work from scripts, cron jobs, and other tools.
- `~/.claude/bin` is in PATH inside the container. Drop custom scripts there and they're available in every session.

## 📜 License

[WTFPL](http://www.wtfpl.net/) – do what the fuck you want to.
