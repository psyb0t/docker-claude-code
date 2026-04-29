# API Mode

Run the container as an HTTP API server with workspace management, file operations, and optional authentication. This is the mode that powers the OpenAI-compatible adapter and MCP server as well.

```yaml
# docker-compose.yml
services:
  claudebox:
    image: psyb0t/claudebox:latest
    ports:
      - "8080:8080"
    environment:
      - CLAUDEBOX_MODE_API=1
      - CLAUDEBOX_MODE_API_TOKEN=your-secret-token
      - CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-xxx
    volumes:
      - ~/.claude:/home/claude/.claude
      - /your/projects:/workspaces
      - /var/run/docker.sock:/var/run/docker.sock
```

| Variable                   | Description                                                         | Default  |
| -------------------------- | ------------------------------------------------------------------- | -------- |
| `CLAUDEBOX_MODE_API`       | Set to `1` to start in API server mode                              | _(none)_ |
| `CLAUDEBOX_MODE_API_PORT`  | Port the API server listens on                                      | `8080`   |
| `CLAUDEBOX_MODE_API_TOKEN` | Bearer token for API authentication (if unset, no auth is required) | _(none)_ |
| `DEBUG`                    | Set to `1` or `true` for structured JSON debug logging              | _(none)_ |

> Legacy `CLAUDE_MODE_API`, `CLAUDE_MODE_API_PORT`, `CLAUDE_MODE_API_TOKEN` are still accepted as fallbacks.

The API server outputs structured JSON logs (timestamp, level, logger, function name, line number, and file) for every request, error, and lifecycle event.

## API Endpoints

**`POST /run`** — send a prompt to Claude Code and get a JSON response:

```bash
curl -X POST http://localhost:8080/run \
  -H "Authorization: Bearer your-secret-token" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "what does this repo do", "workspace": "myproject"}'
```

| Field                | Type   | Description                                                                               | Default         |
| -------------------- | ------ | ----------------------------------------------------------------------------------------- | --------------- |
| `prompt`             | string | The prompt to send to Claude Code                                                         | _(required)_    |
| `workspace`          | string | Subpath under `/workspaces` (e.g., `myproject` resolves to `/workspaces/myproject`)       | `/workspaces`   |
| `model`              | string | Model alias or full model name (see [Model Selection](programmatic.md#model-selection))                  | account default |
| `systemPrompt`       | string | Replace the default system prompt entirely                                                | _(none)_        |
| `appendSystemPrompt` | string | Append text to the default system prompt without replacing it                             | _(none)_        |
| `jsonSchema`         | string | A JSON Schema string for structured output — Claude will return JSON matching this schema | _(none)_        |
| `effort`             | string | Reasoning effort level: `low`, `medium`, `high`, or `max`                                 | _(none)_        |
| `outputFormat`       | string | Response format: `json` (default) or `json-verbose` (includes full tool call history)     | `json`          |
| `noContinue`         | bool   | If true, start a fresh session instead of continuing the previous one                     | `false`         |
| `resume`             | string | Resume a specific session by its session ID                                               | _(none)_        |
| `fireAndForget`      | bool   | If true, the Claude process keeps running even if the HTTP client disconnects             | `false`         |
| `async`              | bool   | If true, return immediately with a `runId` and run in the background                      | `false`         |

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

| Status      | Response                                                                                 |
| ----------- | ---------------------------------------------------------------------------------------- |
| `running`   | `{"runId": "...", "workspace": "...", "status": "running"}`                              |
| `completed` | Full result JSON with `runId` and `workspace` injected (then purged from cache)          |
| `failed`    | `{"runId": "...", "workspace": "...", "status": "failed", "error": "..."}` (then purged) |
| `cancelled` | `{"runId": "...", "workspace": "...", "status": "cancelled"}` (then purged)              |

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
    { "name": "main.py", "type": "file", "size": 1234 },
    { "name": "utils", "type": "dir" }
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
{ "status": "ok" }
```

**`GET /status`** — returns busy workspaces and all tracked runs (running, completed, failed, cancelled):

```json
{
  "busyWorkspaces": ["/workspaces/myproject"],
  "runs": [
    {
      "runId": "abc123",
      "workspace": "/workspaces/myproject",
      "status": "running"
    }
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

## OpenAI-Compatible Endpoints

claudebox exposes an OpenAI-compatible adapter so tools like [LiteLLM](https://github.com/BerriAI/litellm), OpenAI SDKs, and anything that speaks the `chat/completions` protocol can connect directly. This is not a simple model proxy — every request runs the full Claude Code agentic CLI behind the scenes, meaning Claude can read and write files, run shell commands, and use all of its tools.

**`GET /openai/v1/models`** — list available models:

```bash
curl http://localhost:8080/openai/v1/models
# {"object":"list","data":[{"id":"haiku",...},{"id":"sonnet",...},{"id":"opus",...},{"id":"opusplan",...}]}
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

**Model names:** use the same aliases as the CLI (`haiku`, `sonnet`, `opus`, `opusplan`). Provider prefixes are stripped automatically — `claudebox/haiku` becomes `haiku`, `openai/sonnet` becomes `sonnet`.

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

| Header                          | Description                                                   |
| ------------------------------- | ------------------------------------------------------------- |
| `X-Claude-Workspace`            | Workspace subpath under `/workspaces` to run in               |
| `X-Claude-Continue`             | Set to `1`, `true`, or `yes` to continue the previous session |
| `X-Claude-Append-System-Prompt` | Text to append to the system prompt for this request          |

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

## MCP Server

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

| Tool          | Description                                                                                                                                                             |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `claude_run`  | Run a prompt through Claude Code. Parameters: `prompt`, `model`, `system_prompt`, `append_system_prompt`, `json_schema`, `workspace`, `no_continue`, `resume`, `effort` |
| `list_files`  | List files and directories in the workspace                                                                                                                             |
| `read_file`   | Read the contents of a file from the workspace                                                                                                                          |
| `write_file`  | Write content to a file in the workspace (creates parent directories automatically)                                                                                     |
| `delete_file` | Delete a file from the workspace                                                                                                                                        |
