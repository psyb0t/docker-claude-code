# Programmatic Mode

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

## Model Selection

| Alias        | Model                                | Best for                                               |
| ------------ | ------------------------------------ | ------------------------------------------------------ |
| `opus`       | Claude Opus 4.6                      | Complex reasoning, architecture design, hard debugging |
| `sonnet`     | Claude Sonnet 4.6                    | Daily coding tasks, balanced speed and intelligence    |
| `haiku`      | Claude Haiku 4.5                     | Quick lookups, simple tasks, high-volume operations    |
| `opusplan`   | Opus (planning) + Sonnet (execution) | Best of both worlds for large tasks                    |
| `sonnet[1m]` | Sonnet with 1M context               | Long sessions, huge codebases                          |

You can also pin specific model versions using full model names like `claude-opus-4-6`, `claude-sonnet-4-6`, or `claude-haiku-4-5-20251001`. If no model is specified, the default depends on your account type.

## Output Formats

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
        {
          "type": "tool_use",
          "id": "toolu_abc",
          "name": "Bash",
          "input": { "command": "hostname" }
        }
      ]
    },
    {
      "role": "tool_result",
      "content": [
        {
          "type": "toolResult",
          "toolUseId": "toolu_abc",
          "isError": false,
          "content": "mothership"
        }
      ]
    },
    {
      "role": "assistant",
      "content": [{ "type": "text", "text": "The hostname is mothership." }]
    }
  ],
  "system": {
    "sessionId": "...",
    "model": "claude-opus-4-6",
    "cwd": "/workspace",
    "tools": ["Bash", "Read", "..."]
  },
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
