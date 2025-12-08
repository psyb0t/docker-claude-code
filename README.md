# 🧠 docker-claude-code

**claude** but dockerized, goth-approved, and dangerously executable.
This container gives you the [Claude Code CLI](https://www.npmjs.com/package/@anthropic-ai/claude-code) in a fully isolated ritual circle – no cursed system installs required.

## 💀 Why?

Because installing things natively is for suckers.
This image is for devs who live dangerously, commit anonymously, and like their AI tools in containers.

## 🎞️ What's Inside?

- Ubuntu 22.04 (stable and unfeeling)
- Go 1.24.5 with full toolchain (golangci-lint, gopls, delve, staticcheck, gofumpt, gotests, impl, gomodifytags)
- Latest Node.js with comprehensive dev tools (eslint, prettier, typescript, yarn, pnpm, framework CLIs)
- Python 3 with linters, formatters, testing (flake8, black, isort, pytest, poetry, pipenv)
- Docker CE with Docker Compose (full containerization chaos)
- DevOps tools (terraform, kubectl, helm, gh CLI)
- System utilities (jq, tree, ripgrep, bat, exa, fd-find, silversearcher-ag)
- Development tools (shellcheck, clang-format, valgrind, gdb, strace, ltrace)
- Database clients (sqlite3, postgresql-client, mysql-client, redis-tools)
- `git` + `curl` + Claude CLI + httpie
- Auto-Git config based on env vars
- Startup script that configures git, updates claude, and runs with `--dangerously-skip-permissions`

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
| `CLAUDE_GITHUB_NAME`  | Git commit name inside the image (optional) |
| `CLAUDE_GITHUB_EMAIL` | Git commit email inside the image (optional) |

To set these, export them on your host machine (e.g. in your `~/.bashrc` or `~/.zshrc`):

```bash
export CLAUDE_GITHUB_NAME="Your Name"
export CLAUDE_GITHUB_EMAIL="your@email.com"
```

If not set, git inside the container won't have a default identity configured.

### Create a Wrapper Script

Put this in your `/usr/local/bin/claude` (or wherever your chaos reigns):

```bash
#!/usr/bin/env bash

# Git identity - use env var if set, otherwise empty
CLAUDE_GITHUB_NAME="${CLAUDE_GITHUB_NAME:-}"
CLAUDE_GITHUB_EMAIL="${CLAUDE_GITHUB_EMAIL:-}"

# Convert PWD to a valid container name (slashes to underscores)
sanitized_pwd=$(echo "$PWD" | sed 's/\//_/g')
container_name="claude-${sanitized_pwd}"

# Check if the container is running
if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
    echo "🟢 Container '$container_name' is running. Attaching..."
    docker attach "$container_name"
    exit 0
fi

# Check if container exists but stopped
if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
    echo "🔄 Container '$container_name' exists. Starting and attaching..."
    docker start "$container_name" > /dev/null
    docker attach "$container_name"
    exit 0
fi

echo "🔧 Creating and running new container: '$container_name'"
docker run -it \
    --network host \
    -e CLAUDE_GITHUB_NAME="$CLAUDE_GITHUB_NAME" \
    -e CLAUDE_GITHUB_EMAIL="$CLAUDE_GITHUB_EMAIL" \
    -v $HOME/.ssh/claude-code:/home/claude/.ssh \
    -v $HOME/.claude:/home/claude/.claude \
    -v "$(pwd)":/workspace \
    -v /var/run/docker.sock:/var/run/docker.sock \
    --name "$container_name" \
    psyb0t/claude-code:latest
```

Make it executable:

```bash
sudo chmod +x /usr/local/bin/claude
```

Now you can summon Claude like so:

```bash
claude
```

## 🦴 Gotchas

- This tool uses `--dangerously-skip-permissions`. Because Claude likes to live fast and break sandboxes.
- SSH keys are mounted to allow commit/push shenanigans. Keep 'em safe, goblin.
- Volumes mount the current directory into the container workspace. That's your playground.
- Docker socket is mounted so Claude can spawn containers within containers. Docker-in-Docker madness enabled.

## 📜 License

[WTFPL](http://www.wtfpl.net/) – do what the fuck you want to.
