# 🧠 docker-claude-code

**claude** but dockerized, goth-approved, and dangerously executable.
This container gives you the [Claude Code CLI](https://www.npmjs.com/package/@anthropic-ai/claude-code) in a fully isolated ritual circle – no cursed system installs required.

## 💀 Why?

Because installing things natively is for suckers.
This image is for devs who live dangerously, commit anonymously, and like their AI tools in containers.

## 🎞️ What’s Inside?

- Ubuntu 22.04 (stable and unfeeling)
- Node.js 20.x (blessed by the Node gods)
- `git` + `curl` + Claude CLI
- Auto-Git config based on env vars
- A dark little bash startup spell

## ⚙️ Quick Start

### Create settings dir

```bash
mkdir -p ~/.claude
```

### 🥪 Generate SSH Keys

If you don’t have an SSH key pair yet, conjure one with:

```bash
ssh-keygen -t ed25519 -C "claude@claude.ai"
```

Save it somewhere like:

```
/home/user/.ssh/claude-code
```

Then add the public key (`id_ed25519.pub`) to your GitHub account or wherever you push code.

## 🔐 ENV Vars

| Variable   | What it does                      |
| ---------- | --------------------------------- |
| `GH_NAME`  | Git commit name inside the image  |
| `GH_EMAIL` | Git commit email inside the image |

### Create a Wrapper Script

Put this in your `/usr/local/bin/claude` (or wherever your chaos reigns):

```bash
#!/usr/bin/env bash

# Convert PWD to a valid container name (slashes to underscores)
sanitized_pwd=$(echo "$PWD" | sed 's/\//_/g')
container_name="claude-${sanitized_pwd}"

# Check if the container exists
if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
    echo "🟢 Container '$container_name' exists."
    docker stop "$container_name"
    docker start "$container_name"
    docker attach "$container_name"
else
    echo "🔧 Creating and running new container: '$container_name'"
    docker run -it \
        -e GH_NAME="claude" \
        -e GH_EMAIL="claude@example.com" \
        -v /home/user/.ssh/claude-code:/home/claude/.ssh \
        -v /home/user/.claude:/home/claude/.claude \
        -v "$(pwd)":/workspace \
        --name "$container_name" \
        psyb0t/claude-code:latest "$@"
fi
```

Make it executable:

```bash
chmod +x /usr/local/bin/claude
```

Now you can summon Claude like so:

```bash
claude
```

## 🦴 Gotchas

- This tool uses `--dangerously-skip-permissions`. Because Claude likes to live fast and break sandboxes.
- SSH keys are mounted to allow commit/push shenanigans. Keep ‘em safe, goblin.
- Volumes mount the current directory into the container workspace. That’s your playground.

## 📜 License

[WTFPL](http://www.wtfpl.net/) – do what the fuck you want to.

## 🔮 Bonus Points

Use it with aliases, wrap it in `fzf`, call it from `neovim`, or trigger it via voice command while summoning eldritch horrors. Your machine, your madness.
