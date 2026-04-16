# claudebox

A runtime harness for [Claude Code](https://claude.com/product/claude-code) — the agentic coding CLI from Anthropic — running in a fully isolated Docker container with every dev tool pre-installed, passwordless sudo, docker-in-docker support, and `--dangerously-skip-permissions` enabled by default.

claudebox wraps Claude Code with five distinct interfaces:

- **Interactive CLI** — a drop-in replacement for the native `claude` command, with persistent containers and automatic session resumption across runs
- **Programmatic CLI** — non-interactive mode for scripts, CI/CD pipelines, and automation; pass a prompt, get structured output, pipe it wherever you need
- **HTTP API server** — a full REST API with workspace management, file operations, structured output formats, and workspace isolation for multi-tenant deployments
- **OpenAI-compatible endpoint** — a `chat/completions` adapter that lets LiteLLM, OpenAI SDKs, and any OpenAI-compatible client talk to Claude Code, complete with streaming SSE, multi-turn conversations, and multimodal image handling
- **MCP server** — a [Model Context Protocol](https://modelcontextprotocol.io/) endpoint over streamable HTTP so other AI agents and tools (Claude Desktop, other Claude Code instances, etc.) can use Claude Code as a tool
- **Telegram bot** — a conversational interface with per-chat workspaces, configurable models and effort levels, file sharing, shell access, and group chat support

Beyond just running Claude Code in Docker, claudebox adds skill injection (auto-load `SKILL.md` files into every session), init hooks, custom script directories, structured JSON logging, and a workspace management layer that handles multi-tenant isolation with automatic busy/idle tracking.

> **Renamed from `docker-claude-code`:** This project was previously called `docker-claude-code` with the Docker image at `psyb0t/claude-code`. Starting with v1.0.0, it is `claudebox` — the Docker image is now `psyb0t/claudebox`, the default binary name is `claudebox`, the GitHub repository is `psyb0t/docker-claudebox`, and the SSH key directory defaults to `~/.ssh/claudebox`. If you were using the old names, update your image references, wrapper scripts, and SSH paths accordingly.

## Table of Contents

- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Image Variants](#image-variants)
- [What's Inside (Full Image)](#whats-inside-full-image)
- [Usage](#usage)
  - [Environment Variables](#environment-variables)
  - [Authentication](#authentication)
  - [Interactive Mode](#interactive-mode)
  - [Programmatic Mode](#programmatic-mode)
    - [Model Selection](#model-selection)
    - [Output Formats](#output-formats)
  - [API Mode](#api-mode)
    - [API Endpoints](#api-endpoints)
    - [OpenAI-Compatible Endpoints](#openai-compatible-endpoints)
    - [MCP Server](#mcp-server)
  - [Telegram Mode](#telegram-mode)
- [Customization](#customization)
  - [Custom Scripts](#custom-scripts-claudebin)
  - [Init Hooks](#init-hooks-claudeinitd)
  - [Always-Active Skills](#always-active-skills-claudealways-skills)
- [Gotchas](#gotchas)
- [License](#license)

## Requirements

Docker installed and running. That's it.

## Quick Start

### One-liner install

The install script pulls the Docker image, generates SSH keys for git operations inside the container, downloads the wrapper script, and installs it as a command on your system.

```bash
# full image (recommended — all dev tools pre-installed)
curl -fsSL https://raw.githubusercontent.com/psyb0t/docker-claudebox/master/install.sh | bash

# minimal image (just the essentials — Claude installs what it needs on the fly)
CLAUDE_MINIMAL=1 curl -fsSL https://raw.githubusercontent.com/psyb0t/docker-claudebox/master/install.sh | bash

# custom binary name (e.g. if you want to call it 'claude' instead of 'claudebox')
curl -fsSL https://raw.githubusercontent.com/psyb0t/docker-claudebox/master/install.sh | bash -s -- claude
# or: CLAUDE_BIN_NAME=claude curl -fsSL .../install.sh | bash
```

### Manual setup

If you prefer not to pipe scripts to bash:

```bash
# 1. create the data directory
mkdir -p ~/.claude

# 2. create SSH keys for git operations inside the container
mkdir -p "$HOME/.ssh/claudebox"
ssh-keygen -t ed25519 -C "claude@claude.ai" -f "$HOME/.ssh/claudebox/id_ed25519" -N ""
# then add the public key to GitHub/GitLab/wherever you push code

# 3. pull the image
docker pull psyb0t/claudebox:latest
# or: docker pull psyb0t/claudebox:latest-minimal

# 4. grab the wrapper script and install it
# see install.sh for exactly how the wrapper is set up
```

## Image Variants

### `psyb0t/claudebox:latest` (full)

Everything pre-installed. Go, Python, Node.js, C/C++ toolchains, Terraform, kubectl, database clients, linters, formatters — the works. Large image, but Claude wakes up and gets to work immediately with zero wait time. This is the recommended variant for most users.

```bash
curl -fsSL https://raw.githubusercontent.com/psyb0t/docker-claudebox/master/install.sh | bash
```

### `psyb0t/claudebox:latest-minimal`

Just enough to run Claude: Ubuntu, git, curl, Node.js, and Docker. Claude has passwordless sudo, so it will install whatever else it needs on the fly via `apt-get`, `pip`, `npm`, etc. Smaller image to pull, but the first run takes longer as Claude sorts out its dependencies.

```bash
CLAUDE_MINIMAL=1 curl -fsSL https://raw.githubusercontent.com/psyb0t/docker-claudebox/master/install.sh | bash
```

Use `~/.claude/init.d/*.sh` hooks (see [Init Hooks](#init-hooks-claudeinitd)) to pre-install your tools on first container create so Claude doesn't burn tokens figuring out package management.

### Comparison

|                                       | `latest` (full) | `latest-minimal` |
| ------------------------------------- | :-------------: | :--------------: |
| Ubuntu 22.04                          |       yes       |       yes        |
| git, curl, wget, jq                   |       yes       |       yes        |
| Node.js LTS + npm                     |       yes       |       yes        |
| Docker CE + Compose                   |       yes       |       yes        |
| Claude Code CLI                       |       yes       |       yes        |
| Go 1.26.1 + tools                     |       yes       |        -         |
| Python 3.12.11 + tools                |       yes       |        -         |
| Node.js dev tools                     |       yes       |        -         |
| C/C++ tools                           |       yes       |        -         |
| DevOps (terraform, kubectl, helm, gh) |       yes       |        -         |
| Database clients                      |       yes       |        -         |
| Shell utilities (ripgrep, bat, etc.)  |       yes       |        -         |

## What's Inside (Full Image)

**Languages and runtimes:**

- **Go 1.26.1** with the full toolchain — golangci-lint, gopls, delve, staticcheck, gofumpt, gotests, impl, gomodifytags
- **Python 3.12.11** via pyenv — flake8, black, isort, autoflake, pyright, mypy, vulture, pytest, poetry, pipenv, plus common libraries (requests, beautifulsoup4, lxml, pyyaml, toml)
- **Node.js LTS** — eslint, prettier, typescript, ts-node, yarn, pnpm, nodemon, pm2, framework CLIs (React, Vue, Angular), newman, http-server, serve, lighthouse, storybook
- **C/C++** — gcc, g++, make, cmake, clang-format, valgrind, gdb, strace, ltrace

**DevOps and infrastructure:**

- Docker CE with Docker Compose (docker-in-docker support)
- Terraform, kubectl, helm, GitHub CLI (`gh`)

**Database clients:**

- sqlite3, postgresql-client (`psql`), mysql-client, redis-tools (`redis-cli`)

**Shell and system utilities:**

- jq, tree, ripgrep, bat, exa, fd-find, ag (silversearcher), htop, tmux, shellcheck, shfmt, httpie, vim, nano
- Archive tools (zip, unzip, tar), networking (net-tools, iputils-ping, dnsutils)

**Container automation:**

- Auto-generated `CLAUDE.md` in each workspace listing all available tools, so Claude knows what it has access to
- Git identity auto-configured from environment variables
- Claude Code CLI with auto-updates disabled by default (opt in with `--update`)
- Workspace trust dialog pre-accepted — no interactive prompts
- Custom scripts via `~/.claude/bin` (added to PATH automatically)
- Init hooks via `~/.claude/init.d/*.sh` (run once on first container create)
- Always-active skills via `~/.claude/.always-skills/` (injected into every invocation)
- Session continuity via `--continue` / `--no-continue` / `--resume <session_id>`
- Structured JSON debug logging with `DEBUG=true`

## Usage

### Environment Variables

Set these on your host (e.g., in `~/.bashrc` or `~/.zshrc`). The wrapper script forwards them into the container automatically. These apply across all modes.

| Variable                  | Description                                                                     | Default              |
| ------------------------- | ------------------------------------------------------------------------------- | -------------------- |
| `ANTHROPIC_API_KEY`       | Anthropic API key for authentication                                            | _(none)_             |
| `CLAUDE_CODE_OAUTH_TOKEN` | OAuth token for authentication                                                  | _(none)_             |
| `CLAUDE_GIT_NAME`         | Git `user.name` inside the container                                            | _(none)_             |
| `CLAUDE_GIT_EMAIL`        | Git `user.email` inside the container                                           | _(none)_             |
| `CLAUDE_DATA_DIR`         | Override the `.claude` data directory on the host                               | `~/.claude`          |
| `CLAUDE_SSH_DIR`          | Override the SSH key directory mounted into the container                        | `~/.ssh/claudebox`   |
| `CLAUDE_INSTALL_DIR`      | Where to install the wrapper binary (install-time only)                         | `/usr/local/bin`     |
| `CLAUDE_BIN_NAME`         | Name of the wrapper binary (install-time only)                                  | `claudebox`          |
| `CLAUDE_IMAGE`            | Override the Docker image used by the wrapper                                   | `psyb0t/claudebox:latest` |
| `CLAUDE_ENV_*`            | Forward custom env vars into the container (prefix stripped: `CLAUDE_ENV_FOO=bar` becomes `FOO=bar`) | _(none)_ |
| `CLAUDE_MOUNT_*`          | Mount extra host directories into the container                                 | _(none)_             |
| `DEBUG`                   | Enable debug logging with timestamps throughout the entrypoint and API server   | _(none)_             |

#### Forwarding environment variables

The `CLAUDE_ENV_` prefix lets you inject arbitrary environment variables into the container. The prefix is stripped before forwarding:

```bash
# inside the container these become: GITHUB_TOKEN=xxx, MY_VAR=hello
CLAUDE_ENV_GITHUB_TOKEN=xxx CLAUDE_ENV_MY_VAR=hello claudebox "do stuff"
```

#### Extra volume mounts

The `CLAUDE_MOUNT_` prefix mounts additional host directories into the container:

```bash
CLAUDE_MOUNT_DATA=/data claudebox "process the data"                    # same path inside container
CLAUDE_MOUNT_1=/opt/configs CLAUDE_MOUNT_2=/var/logs claudebox "go"     # mount multiple directories
CLAUDE_MOUNT_STUFF=/host/path:/container/path claudebox "do stuff"      # explicit source:dest mapping
CLAUDE_MOUNT_RO=/data:/data:ro claudebox "read the data"                # read-only mount
```

If the value contains `:`, it is passed directly as Docker `-v` syntax. Otherwise, the same path is used on both host and container sides.

### Authentication

You need either an Anthropic API key or an OAuth token. Set up once, use everywhere:

```bash
# interactive OAuth token setup (one-time)
claudebox setup-token

# then use the token for programmatic and headless runs
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-xxx claudebox "do stuff"

# or use an API key directly
ANTHROPIC_API_KEY=sk-ant-api03-xxx claudebox "do stuff"
```

### Interactive Mode

```bash
claudebox
```

Works just like the native `claude` CLI but runs inside a container. The container persists between runs, and `--continue` is applied automatically so each session picks up where you left off.

```bash
claudebox --update        # opt in to a Claude Code CLI update on this run
claudebox --no-continue   # start a fresh session instead of resuming the last one
```

#### Utility commands

Some commands are passed through directly without entering interactive mode:

```bash
claudebox --version      # show the Claude Code CLI version
claudebox -v             # same thing
claudebox doctor         # run health checks
claudebox auth           # manage authentication
claudebox setup-token    # interactive OAuth token setup
claudebox stop           # stop the running interactive container for this workspace
claudebox clear-session  # delete session history for this workspace
```

### Programmatic Mode

Pass a prompt and get a response. The `-p` flag is added automatically. No TTY required — works from scripts, cron jobs, CI pipelines, and anywhere else you need non-interactive output.

```bash
claudebox "explain this codebase"                                       # plain text output (default)
claudebox "explain this codebase" --output-format json                  # structured JSON response
claudebox "list all TODOs" --output-format json-verbose | jq .          # JSON with full tool call history
claudebox "list all TODOs" --output-format stream-json | jq .           # streaming NDJSON
claudebox "explain this codebase" --model opus                          # choose a specific model
claudebox "review this" --system-prompt "You are a security auditor"    # override the system prompt
claudebox "review this" --append-system-prompt "Focus on SQL injection" # append to the default system prompt
claudebox "debug this" --effort max                                     # maximum reasoning effort
claudebox "quick question" --effort low                                 # fast, lightweight response
claudebox "start over" --no-continue                                    # fresh session, no history
claudebox "keep going" --resume abc123-def456                           # resume a specific session by ID

# structured output with a JSON schema
claudebox "extract the author and title" --output-format json \
  --json-schema '{"type":"object","properties":{"author":{"type":"string"},"title":{"type":"string"}},"required":["author","title"]}'
```

`--continue` is applied automatically so successive programmatic runs in the same workspace share conversation context. Use `--no-continue` to start fresh or `--resume <session_id>` to continue a specific conversation.

#### Model Selection

| Alias        | Model                                | Best for                                              |
| ------------ | ------------------------------------ | ----------------------------------------------------- |
| `opus`       | Claude Opus 4.6                      | Complex reasoning, architecture design, hard debugging |
| `sonnet`     | Claude Sonnet 4.6                    | Daily coding tasks, balanced speed and intelligence    |
| `haiku`      | Claude Haiku 4.5                     | Quick lookups, simple tasks, high-volume operations    |
| `opusplan`   | Opus (planning) + Sonnet (execution) | Best of both worlds for large tasks                    |
| `sonnet[1m]` | Sonnet with 1M context               | Long sessions, huge codebases                          |

You can also pin specific model versions using full model names like `claude-opus-4-6`, `claude-sonnet-4-6`, or `claude-haiku-4-5-20251001`. If no model is specified, the default depends on your account type.

#### Output Formats

**`text`** (default) — plain text response, suitable for reading or piping.

**`json`** — a single JSON object with all keys normalized to camelCase:

```json
{
  "type": "result",
  "subtype": "success",
  "isError": false,
  "result": "the response text",
  "runId": "abc123def456",
  "workspace": "/workspaces/myproject",
  "numTurns": 1,
  "durationMs": 3100,
  "totalCostUsd": 0.156,
  "sessionId": "...",
  "usage": { "inputTokens": 3, "outputTokens": 4, "cacheReadInputTokens": 512 }
}
```

**`json-verbose`** — like `json`, but includes a `turns` array showing every tool call, tool result, and assistant message. Under the hood it runs `stream-json` and assembles the full event stream into a single JSON object. You get one object to parse with full visibility into what Claude did:

```json
{
  "type": "result",
  "subtype": "success",
  "result": "The hostname is mothership.",
  "turns": [
    {
      "role": "assistant",
      "content": [
        { "type": "tool_use", "id": "toolu_abc", "name": "Bash", "input": { "command": "hostname" } }
      ]
    },
    {
      "role": "tool_result",
      "content": [
        { "type": "toolResult", "toolUseId": "toolu_abc", "isError": false, "content": "mothership" }
      ]
    },
    {
      "role": "assistant",
      "content": [
        { "type": "text", "text": "The hostname is mothership." }
      ]
    }
  ],
  "system": { "sessionId": "...", "model": "claude-opus-4-6", "cwd": "/workspace", "tools": ["Bash", "Read", "..."] },
  "numTurns": 2,
  "durationMs": 10600,
  "totalCostUsd": 0.049,
  "sessionId": "..."
}
```

**`stream-json`** — NDJSON (newline-delimited JSON), one event per line. All keys are normalized to camelCase. Event types include `system` (session init), `assistant` (text or tool_use), `user` (tool results), `rateLimitEvent`, and `result` (final summary with cost). A typical multi-step run looks like: `system` → (`assistant` → `user`) × N → `result`.

<details>
<summary>Full stream-json event examples</summary>

**`system`** — session initialization:

```json
{
  "type": "system",
  "subtype": "init",
  "cwd": "/your/project",
  "sessionId": "...",
  "tools": ["Bash", "Read", "Write", "Glob", "Grep"],
  "model": "claude-opus-4-6",
  "permissionMode": "bypassPermissions"
}
```

**`assistant`** — Claude's response (text or tool use):

```json
{
  "type": "assistant",
  "message": {
    "model": "claude-opus-4-6",
    "role": "assistant",
    "content": [{ "type": "text", "text": "I'll install cowsay first." }],
    "usage": { "inputTokens": 3, "outputTokens": 2 }
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
        "toolUseId": "toolu_abc123",
        "type": "toolResult",
        "content": "Setting up cowsay (3.03+dfsg2-8) ...",
        "isError": false
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
  "isError": false,
  "numTurns": 10,
  "durationMs": 60360,
  "totalCostUsd": 0.203,
  "result": "Here's what I did:\n1. Installed cowsay..."
}
```

</details>

### API Mode

Run the container as an HTTP API server with workspace management, file operations, and optional authentication. This is the mode that powers the OpenAI-compatible adapter and MCP server as well.

```yaml
# docker-compose.yml
services:
  claudebox:
    image: psyb0t/claudebox:latest
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

| Variable                | Description                                                              | Default  |
| ----------------------- | ------------------------------------------------------------------------ | -------- |
| `CLAUDE_MODE_API`       | Set to `1` to start in API server mode                                   | _(none)_ |
| `CLAUDE_MODE_API_PORT`  | Port the API server listens on                                           | `8080`   |
| `CLAUDE_MODE_API_TOKEN` | Bearer token for API authentication (if unset, no auth is required)      | _(none)_ |
| `DEBUG`                 | Set to `1` or `true` for structured JSON debug logging                   | _(none)_ |

The API server outputs structured JSON logs (timestamp, level, logger, function name, line number, and file) for every request, error, and lifecycle event.

#### API Endpoints

**`POST /run`** — send a prompt to Claude Code and get a JSON response:

```bash
curl -X POST http://localhost:8080/run \
  -H "Authorization: Bearer your-secret-token" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "what does this repo do", "workspace": "myproject"}'
```

| Field                | Type   | Description                                                              | Default         |
| -------------------- | ------ | ------------------------------------------------------------------------ | --------------- |
| `prompt`             | string | The prompt to send to Claude Code                                        | _(required)_    |
| `workspace`          | string | Subpath under `/workspaces` (e.g., `myproject` resolves to `/workspaces/myproject`) | `/workspaces` |
| `model`              | string | Model alias or full model name (see [Model Selection](#model-selection)) | account default |
| `systemPrompt`       | string | Replace the default system prompt entirely                               | _(none)_        |
| `appendSystemPrompt` | string | Append text to the default system prompt without replacing it            | _(none)_        |
| `jsonSchema`         | string | A JSON Schema string for structured output — Claude will return JSON matching this schema | _(none)_ |
| `effort`             | string | Reasoning effort level: `low`, `medium`, `high`, or `max`               | _(none)_        |
| `outputFormat`       | string | Response format: `json` (default) or `json-verbose` (includes full tool call history) | `json` |
| `noContinue`         | bool   | If true, start a fresh session instead of continuing the previous one    | `false`         |
| `resume`             | string | Resume a specific session by its session ID                              | _(none)_        |
| `fireAndForget`      | bool   | If true, the Claude process keeps running even if the HTTP client disconnects | `false`    |
| `async`              | bool   | If true, return immediately with a `runId` and run in the background     | `false`         |

Every response includes a `runId` field that uniquely identifies the run.

Returns `application/json`. Returns **409** if the workspace is already busy with another request.

**Async runs** — when `"async": true` is set, the request returns immediately with a run ID:

```bash
# fire off an async run
curl -X POST http://localhost:8080/run \
  -H "Authorization: Bearer token" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "refactor this entire codebase", "workspace": "myproject", "async": true}'
# → {"runId": "abc123", "workspace": "/workspaces/myproject", "status": "running"}

# poll for the result
curl "http://localhost:8080/run/result?runId=abc123" -H "Authorization: Bearer token"
# while running → {"runId": "abc123", "workspace": "/workspaces/myproject", "status": "running"}
# when done    → full result JSON with runId + workspace injected (see below)
```

Completed results are cached until first read — once you fetch a completed result, it is purged from the cache. Results that are never read are automatically purged after 6 hours. Failed and cancelled results are also returned once and purged.

**`GET /run/result?runId=X`** — poll for the result of an async (or any) run:

| Status        | Response                                            |
| ------------- | --------------------------------------------------- |
| `running`     | `{"runId": "...", "workspace": "...", "status": "running"}` |
| `completed`   | Full result JSON with `runId` and `workspace` injected (then purged from cache) |
| `failed`      | `{"runId": "...", "workspace": "...", "status": "failed", "error": "..."}` (then purged) |
| `cancelled`   | `{"runId": "...", "workspace": "...", "status": "cancelled"}` (then purged) |

Returns **404** if the run ID is not found (never existed, already read, or expired).

Completed result example:

```json
{
  "type": "result",
  "subtype": "success",
  "result": "the response text",
  "runId": "abc123",
  "workspace": "/workspaces/myproject",
  "usage": { "inputTokens": 100, "outputTokens": 50 },
  "costUsd": 0.003,
  "sessionId": "..."
}
```

**`GET /files/{path}`** — list a directory or download a file:

```bash
curl "http://localhost:8080/files" -H "Authorization: Bearer token"                         # list workspace root
curl "http://localhost:8080/files/myproject/src" -H "Authorization: Bearer token"           # list a subdirectory
curl "http://localhost:8080/files/myproject/src/main.py" -H "Authorization: Bearer token"   # download a file
```

Directory listing response:

```json
{
  "path": "myproject/src",
  "entries": [
    {"name": "main.py", "type": "file", "size": 1234},
    {"name": "utils", "type": "dir"}
  ]
}
```

File download returns raw file content with appropriate content type.

**`PUT /files/{path}`** — upload a file (parent directories are created automatically):

```bash
curl -X PUT "http://localhost:8080/files/myproject/src/main.py" \
  -H "Authorization: Bearer token" --data-binary @main.py
# → {"status": "ok", "path": "/workspaces/myproject/src/main.py", "size": 1234}
```

**`DELETE /files/{path}`** — delete a file:

```bash
curl -X DELETE "http://localhost:8080/files/myproject/src/old.py" -H "Authorization: Bearer token"
# → {"status": "ok", "path": "/workspaces/myproject/src/old.py"}
```

**`GET /health`** — health check endpoint (no authentication required):

```json
{"status": "ok"}
```

**`GET /status`** — returns busy workspaces and all tracked runs (running, completed, failed, cancelled):

```json
{
  "busyWorkspaces": ["/workspaces/myproject"],
  "runs": [
    {"runId": "abc123", "workspace": "/workspaces/myproject", "status": "running"}
  ]
}
```

**`POST /run/cancel`** — kill a running Claude process by run ID or workspace:

```bash
# cancel by run ID (preferred)
curl -X POST "http://localhost:8080/run/cancel?runId=abc123" -H "Authorization: Bearer token"
# → {"status": "ok", "runId": "abc123", "workspace": "/workspaces/myproject"}

# cancel by workspace (legacy)
curl -X POST "http://localhost:8080/run/cancel?workspace=myproject" -H "Authorization: Bearer token"
# → {"status": "ok", "workspace": "/workspaces/myproject"}
```

All file paths are relative to `/workspaces`. Path traversal attempts outside the workspace root are blocked and return a 400 error.

#### OpenAI-Compatible Endpoints

claudebox exposes an OpenAI-compatible adapter so tools like [LiteLLM](https://github.com/BerriAI/litellm), OpenAI SDKs, and anything that speaks the `chat/completions` protocol can connect directly. This is not a simple model proxy — every request runs the full Claude Code agentic CLI behind the scenes, meaning Claude can read and write files, run shell commands, and use all of its tools.

**`GET /openai/v1/models`** — list available models:

```bash
curl http://localhost:8080/openai/v1/models
# {"object":"list","data":[{"id":"haiku",...},{"id":"sonnet",...},{"id":"opus",...}]}
```

**`POST /openai/v1/chat/completions`** — chat completions (streaming and non-streaming):

```bash
# non-streaming
curl -X POST http://localhost:8080/openai/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"haiku","messages":[{"role":"user","content":"hello"}]}'

# streaming (SSE)
curl -X POST http://localhost:8080/openai/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"haiku","messages":[{"role":"user","content":"hello"}],"stream":true}'
```

**Model names:** use the same aliases as the CLI (`haiku`, `sonnet`, `opus`). Provider prefixes are stripped automatically — `claudebox/haiku` becomes `haiku`, `openai/sonnet` becomes `sonnet`.

**System messages:** messages with `role: "system"` are extracted and passed to Claude Code as `--system-prompt`.

**Reasoning effort:** pass `reasoning_effort` (`low`, `medium`, `high`) in the request body — this maps to Claude Code's `--effort` flag.

**Ignored fields:** `temperature`, `max_tokens`, `tools`, and other OpenAI-specific fields are accepted without error but silently ignored, since Claude Code manages these internally.

**Message handling:**

- **Single user message** — sent directly as the prompt to Claude Code. This is the fast path with no overhead.
- **Multi-turn conversations** — the full messages array is serialized to a JSON file in the workspace (`_oai_uploads/conv_<id>.json`). Claude Code reads the file and responds to the last user message, preserving the full conversation context.
- **Multimodal content** — base64-encoded images and image URLs in message content are automatically downloaded or decoded and saved to the workspace. The content blocks are replaced with local file paths so Claude Code can access the images directly.

**Streaming:** when `"stream": true` is set, the response is returned as standard SSE (Server-Sent Events). Content arrives in message-level chunks rather than character-by-character deltas, since Claude Code assembles complete messages internally.

**File workflow tip:** for best performance with large inputs or outputs, upload files via `PUT /files/...`, reference them by path in your prompt, and then download output files via `GET /files/...`. This is significantly faster than embedding large content directly in message bodies.

**Custom headers** for claudebox-specific behavior:

| Header                          | Description                                                       |
| ------------------------------- | ----------------------------------------------------------------- |
| `X-Claude-Workspace`            | Workspace subpath under `/workspaces` to run in                   |
| `X-Claude-Continue`             | Set to `1`, `true`, or `yes` to continue the previous session     |
| `X-Claude-Append-System-Prompt` | Text to append to the system prompt for this request              |

**LiteLLM integration example:**

```python
import litellm

response = litellm.completion(
    model="claudebox/haiku",
    messages=[{"role": "user", "content": "hello"}],
    api_base="http://localhost:8080/openai/v1",
    api_key="your-secret-token",  # or any string if no API token is configured
)
print(response.choices[0].message.content)
```

#### MCP Server

claudebox exposes an [MCP (Model Context Protocol)](https://modelcontextprotocol.io/) server at `/mcp/` using streamable HTTP transport. Any MCP-compatible client — Claude Desktop, other Claude Code instances, AI agent frameworks — can connect to it and use Claude Code as a tool. The `claude_run` tool executes the full agentic CLI, meaning it can read/write files, run commands, and use tools in the workspace, not just generate text.

**Configuration for MCP clients:**

```json
{
  "mcpServers": {
    "claudebox": {
      "url": "http://localhost:8080/mcp/",
      "headers": { "Authorization": "Bearer your-secret-token" }
    }
  }
}
```

If your MCP client does not support custom headers, you can pass the API token as a query parameter instead: `http://localhost:8080/mcp/?apiToken=your-secret-token`

**Available tools:**

| Tool          | Description                                                                                                     |
| ------------- | --------------------------------------------------------------------------------------------------------------- |
| `claude_run`  | Run a prompt through Claude Code. Parameters: `prompt`, `model`, `system_prompt`, `append_system_prompt`, `json_schema`, `workspace`, `no_continue`, `resume`, `effort` |
| `list_files`  | List files and directories in the workspace                                                                     |
| `read_file`   | Read the contents of a file from the workspace                                                                  |
| `write_file`  | Write content to a file in the workspace (creates parent directories automatically)                             |
| `delete_file` | Delete a file from the workspace                                                                                |

### Telegram Mode

Talk to Claude Code from Telegram. Each chat gets its own isolated workspace and individually configurable settings. Send text messages, files, photos, videos, and voice messages. Run shell commands. Retrieve files. All from your phone.

#### Setup

1. **Create a bot** — talk to [@BotFather](https://t.me/BotFather), run `/newbot`, and save the token.
2. **Get your chat ID** — message [@userinfobot](https://t.me/userinfobot) and it will reply with your user ID (which is also your DM chat ID). Group chat IDs are negative numbers.
3. **Create the config file at `~/.claude/telegram.yml`:**

```yaml
# which chats the bot responds in
# DM user IDs (positive) and/or group chat IDs (negative)
# empty list = no restriction (dangerous — anyone can talk to your bot!)
allowed_chats:
  - 123456789       # your DM
  - -987654321      # a group chat

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
      - CLAUDE_MODE_TELEGRAM=1
      - CLAUDE_TELEGRAM_BOT_TOKEN=123456:ABC-DEF
      - CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-xxx
    volumes:
      - ~/.claude:/home/claude/.claude
      - ~/telegram-workspaces:/workspaces
      - /var/run/docker.sock:/var/run/docker.sock
```

#### Telegram environment variables

| Variable                    | Description                                                  | Default                             |
| --------------------------- | ------------------------------------------------------------ | ----------------------------------- |
| `CLAUDE_MODE_TELEGRAM`      | Set to `1` to start in Telegram bot mode                     | _(none)_                            |
| `CLAUDE_TELEGRAM_BOT_TOKEN` | Bot token from [@BotFather](https://t.me/BotFather)          | _(none)_                            |
| `CLAUDE_TELEGRAM_CONFIG`    | Path to the YAML config file inside the container            | `/home/claude/.claude/telegram.yml` |

#### Bot commands

| Command                       | Description                                                        |
| ----------------------------- | ------------------------------------------------------------------ |
| any text message              | Sent to Claude as a prompt in the chat's workspace                 |
| send a file/photo/video/voice | Saved to workspace; the caption becomes the prompt (if present)    |
| `/bash <command>`             | Run a shell command directly in the chat's workspace               |
| `/fetch <path>`               | Get a file from the workspace sent as a Telegram attachment        |
| `/cancel`                     | Kill the running Claude process for this chat                      |
| `/status`                     | Show which chats currently have running processes                   |
| `/config`                     | Display this chat's current configuration                          |
| `/reload`                     | Hot-reload the YAML config file without restarting the container   |

Claude can send files back by including `[SEND_FILE: relative/path]` in its response text. Images are sent as photos, videos as video messages, and everything else as document attachments. Long responses are automatically split across multiple messages to stay within Telegram's 4096-character limit.

## Customization

### Custom scripts (`~/.claude/bin`)

Any executable files placed in `~/.claude/bin/` are available on PATH inside every container session — interactive, programmatic, API, all modes.

```bash
mkdir -p ~/.claude/bin
echo '#!/bin/bash
echo "hello from custom script"' > ~/.claude/bin/my-tool
chmod +x ~/.claude/bin/my-tool
# my-tool is now available inside every claudebox session
```

### Init hooks (`~/.claude/init.d`)

Scripts placed in `~/.claude/init.d/*.sh` run once when a container is first created. They execute as root before the entrypoint drops to the `claude` user. They do not re-run on subsequent `docker start` — only on fresh containers.

```bash
mkdir -p ~/.claude/init.d
cat > ~/.claude/init.d/setup.sh << 'EOF'
#!/bin/bash
apt-get update && apt-get install -y some-package
pip install some-library
EOF
chmod +x ~/.claude/init.d/setup.sh
```

This is particularly useful with the minimal image — pre-install your tools once on first run so Claude doesn't burn tokens and time running `apt-get` on every session.

### Always-active skills (`~/.claude/.always-skills`)

Skill files placed in `~/.claude/.always-skills/` are automatically injected into the system prompt of every Claude invocation — interactive, programmatic, API, OpenAI adapter, MCP, Telegram, all of them. No slash commands, no per-request headers, no configuration needed.

Each subdirectory should contain a `SKILL.md` file with instructions for Claude. The directory is scanned recursively in alphabetical order, and every `SKILL.md` found is appended to the system prompt with a prefix showing its full file path:

```
[Skill file: /home/claude/.claude/.always-skills/caveman/SKILL.md]

<contents of the skill file>
```

The path prefix is included so Claude knows exactly where the skill lives on disk and can read any adjacent files referenced by the skill.

**Example: install the caveman skill to auto-activate every session:**

```bash
mkdir -p ~/.claude/.always-skills/caveman
cp ~/.claude/plugins/cache/caveman/caveman/*/skills/caveman/SKILL.md \
   ~/.claude/.always-skills/caveman/SKILL.md
```

**Example: write a custom skill:**

```bash
mkdir -p ~/.claude/.always-skills/my-rules
cat > ~/.claude/.always-skills/my-rules/SKILL.md << 'EOF'
When writing Go code, always use slog for structured logging, never fmt.Println.
When writing Python, always use pathlib for file paths, never os.path.
EOF
```

Multiple skills stack — every `SKILL.md` found is injected. Any user-supplied `appendSystemPrompt` (via API request body, `--append-system-prompt` CLI flag, `X-Claude-Append-System-Prompt` header, etc.) is appended after the always-skills content, so per-request instructions take precedence.

## Gotchas

- **`--dangerously-skip-permissions`** is always enabled. Claude has full, unrestricted access to the container. That's the entire point.
- **SSH keys** are mounted from the host for git push/pull inside the container. Do not share your container or image with untrusted parties.
- **Host paths are preserved** — your project at `/home/you/project` is mounted at the same path inside the container. This means Docker volume mounts that Claude creates from within the container resolve correctly against host paths.
- **UID/GID matching** — the container's `claude` user UID/GID is automatically adjusted to match the host directory owner on startup. File permissions should just work without manual `chown`.
- **Docker-in-Docker** — the Docker socket is mounted into the container. Claude can build images and run containers from within its container. This is by design.
- **Two containers per workspace** — the wrapper creates `claude-<path>` for interactive (TTY) sessions and `claude-<path>_prog` for programmatic (no TTY) sessions. Both share the same mounted volumes and data.
- **Workspace busy tracking** — in API mode, each workspace can only have one active Claude process at a time. Concurrent requests to the same workspace return a 409 Conflict response. Use different workspace subpaths for parallel work.
- **Telegram config is required** — the Telegram bot will not start without a `telegram.yml` config file. This is intentional to prevent accidentally exposing Claude to the public.
- **Auto-updates disabled** — Claude Code CLI auto-updates are disabled by default inside the container to ensure reproducible behavior. Opt in with `claudebox --update` when you want to update.

## License

[WTFPL](http://www.wtfpl.net/) — do what the fuck you want to.
