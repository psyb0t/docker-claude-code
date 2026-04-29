# Customization

- [Custom scripts (`~/.claude/bin`)](#custom-scripts-claudebin)
- [Init hooks (`~/.claude/init.d`)](#init-hooks-claudeinitd)
- [Always-active skills (`~/.claude/.always-skills`)](#always-active-skills-claudealways-skills)
- [MCP servers](#mcp-servers)

## Custom scripts (`~/.claude/bin`)

Any executable files placed in `~/.claude/bin/` are available on PATH inside every container session — interactive, programmatic, API, all modes.

```bash
mkdir -p ~/.claude/bin
echo '#!/bin/bash
echo "hello from custom script"' > ~/.claude/bin/my-tool
chmod +x ~/.claude/bin/my-tool
# my-tool is now available inside every claudebox session
```

## Init hooks (`~/.claude/init.d`)

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

## Always-active skills (`~/.claude/.always-skills`)

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

## MCP servers

Claude Code reads MCP server definitions from a few standard locations. Inside claudebox, all of these work because `~/.claude` is mounted from the host and the workspace is mounted from the host cwd:

| Scope     | Path                                                  | Description                                                                          |
| --------- | ----------------------------------------------------- | ------------------------------------------------------------------------------------ |
| Project   | `<workspace>/.mcp.json`                               | Per-repo, intended to be checked into git so the team shares the same servers        |
| User      | `~/.claude.json` (under the `mcpServers` key)         | Global, available across every project on the host                                   |
| Local     | `~/.claude.json` (per-project section)                | Default scope of `claude mcp add`, only affects the current project, not shared      |

**File format** (same for `.mcp.json` and the `mcpServers` block inside `~/.claude.json`):

```json
{
  "mcpServers": {
    "my-server": {
      "command": "npx",
      "args": ["-y", "@some/mcp-server"],
      "env": { "API_KEY": "..." }
    },
    "remote-http": {
      "type": "http",
      "url": "https://example.com/mcp/"
    }
  }
}
```

**Add via CLI inside the container:**

```bash
# project scope — writes to ./.mcp.json in the workspace (commit-friendly)
claudebox mcp add --scope project my-server -- npx -y @some/mcp-server

# user scope — writes to ~/.claude.json, available in every project
claudebox mcp add --scope user my-server -- npx -y @some/mcp-server

# local scope (default) — per-project entry inside ~/.claude.json
claudebox mcp add my-server -- npx -y @some/mcp-server
```

**Inspect what's loaded:** run `/mcp` inside an interactive session.

This is how cron and Telegram modes reach external systems — drop your server config in `.mcp.json` (project) or `~/.claude.json` (global) and reference it from the instruction.
