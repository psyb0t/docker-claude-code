# 🧠 docker-claude-code

**claude** but dockerized, goth-approved, and dangerously executable.
This container gives you the [Claude Code](https://claude.com/product/claude-code) in a fully isolated ritual circle – no cursed system installs required.

## 💀 Why?

Because installing things natively is for suckers.
This image is for devs who live dangerously, commit anonymously, and like their AI tools in containers.

## 🎞️ What's Inside?

- Ubuntu 22.04 (stable and unfeeling)
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
- Workspace trust dialog is automatically pre-accepted (no annoying prompts)
- Programmatic mode support — just pass a prompt and optional `--output-format` (`-p` is added automatically)
- `--ephemeral` flag for throwaway containers that auto-remove after exit

## 📋 Requirements

- Docker installed and running

## ⚙️ Quick Start

### 🚀 Quick Install

There's an install script that sets everything up automatically:

```bash
curl -fsSL https://raw.githubusercontent.com/psyb0t/docker-claude-code/master/install.sh | bash
```

Or if you prefer manual control:

### Create settings dir

```bash
mkdir -p ~/.claude
```

### 🥪 Generate SSH Keys

If you don't have an SSH key pair yet, conjure one with:

```bash
mkdir -p "$HOME/.ssh/claude-code"
ssh-keygen -t ed25519 -C "claude@claude.ai" -f "$HOME/.ssh/claude-code/id_ed25519" -N ""
```

Then add the public key (`$HOME/.ssh/claude-code/id_ed25519.pub`) to your GitHub account or wherever you push code.

## 🔐 ENV Vars

| Variable   | What it does                      |
| ---------- | --------------------------------- |
| `CLAUDE_GIT_NAME`  | Git commit name inside the image (optional) |
| `CLAUDE_GIT_EMAIL` | Git commit email inside the image (optional) |
| `CLAUDE_WORKSPACE` | Host path to mount and work in (set automatically by wrapper script) |
| `ANTHROPIC_API_KEY` | API key for authentication (forwarded to container if set) |
| `CLAUDE_CODE_OAUTH_TOKEN` | OAuth token for authentication (forwarded to container if set) |

To set these, export them on your host machine (e.g. in your `~/.bashrc` or `~/.zshrc`):

```bash
export CLAUDE_GIT_NAME="Your Name"
export CLAUDE_GIT_EMAIL="your@email.com"
```

If not set, git inside the container won't have a default identity configured.

For auth, either log in interactively or set up a long-lived OAuth token:

```bash
# generate an OAuth token (interactive, one-time setup)
claude setup-token

# then use it for programmatic runs
CLAUDE_CODE_OAUTH_TOKEN=xxx claude "do stuff"

# or use an API key
ANTHROPIC_API_KEY=sk-ant-xxx claude "do stuff"
```

## 🧙 Usage

### Interactive mode

```bash
claude
```

Starts an interactive session. The container is named by directory path and persists between runs — stop/restart instead of attach, with `--continue` to resume the last conversation.

### Programmatic mode

Just pass a prompt — `-p` is added automatically:

```bash
# one-shot prompt with JSON output
claude "explain this codebase" --output-format json

# streaming output piped to jq
claude "list all TODOs" --output-format stream-json | jq .

# plain text output (default)
claude "what does this repo do"
```

Uses the same container as interactive mode — custom installs persist and `--continue` is passed automatically so programmatic runs pick up your last interactive session.

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
  "usage": { "input_tokens": 3, "output_tokens": 4, "..." : "..." },
  "modelUsage": { "..." : "..." }
}
```

**`stream-json`** — newline-delimited JSON, one object per line:

```json
{"type":"system","subtype":"init","cwd":"/your/project","session_id":"...","tools":["Bash","Read","Write","..."],"model":"claude-opus-4-6","permissionMode":"bypassPermissions","claude_code_version":"2.1.62","...":"..."}
{"type":"assistant","message":{"model":"claude-opus-4-6","role":"assistant","content":[{"type":"text","text":"Hello!"}],"usage":{"input_tokens":3,"output_tokens":1,"cache_read_input_tokens":24960,"...":"..."}},"session_id":"..."}
{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1772204400,"rateLimitType":"five_hour","overageStatus":"allowed","isUsingOverage":false},"session_id":"..."}
{"type":"result","subtype":"success","is_error":false,"result":"Hello!","num_turns":1,"duration_ms":2797,"duration_api_ms":2767,"total_cost_usd":0.012,"session_id":"...","usage":{"input_tokens":3,"output_tokens":5,"cache_read_input_tokens":24960,"...":"..."},"modelUsage":{"...":"..."}}
```

### Ephemeral mode

Add `--ephemeral` for a throwaway container that auto-removes after exit with no session persistence:

```bash
claude --ephemeral "quick question" --output-format json
```

## 🦴 Gotchas

- This tool uses `--dangerously-skip-permissions`. Because Claude likes to live fast and break sandboxes.
- SSH keys are mounted to allow commit/push shenanigans. Keep 'em safe, goblin.
- The host directory is mounted at its exact path inside the container (e.g. `/home/you/project` stays `/home/you/project`). This means docker volume mounts from inside Claude will use correct host paths.
- The container user's UID/GID is automatically matched to the host directory owner, so file permissions just work.
- Docker socket is mounted so Claude can spawn containers within containers. Docker-in-Docker madness enabled.
- Workspace trust dialog is pre-accepted automatically — no confirmation prompts on startup.

## 📜 License

[WTFPL](http://www.wtfpl.net/) – do what the fuck you want to.
