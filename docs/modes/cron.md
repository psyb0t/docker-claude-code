# Cron Mode

Run scheduled Claude jobs from a YAML cron file. Each job has a cron expression and a multiline instruction. Output streams to `~/.claude/cron/history/<workspace-slug>/<YYYYMMDD-HHMMSS>-<job-name>/` as `activity.jsonl` (Claude's stream-json output) alongside `stderr.log` and `meta.json`.

1. **Write a cron yaml** (see `cron.yml.example`):

```yaml
model: haiku                    # default model for all jobs; per-job "model" overrides this
append_system_prompt: |
  The current date and time is {system_datetime}.
telegram_chat_id: -1001234567890  # optional: send results to this chat (requires CLAUDEBOX_TELEGRAM_BOT_TOKEN)

jobs:
  - name: every_30_seconds
    schedule: "*/30 * * * * *"  # 6-field = sec min hr dom mon dow
    instruction: |
      Write the current UTC timestamp to ./status.txt.

  - name: hourly_repo_check
    schedule: "0 * * * *"       # 5-field = standard cron, every hour at :00
    model: sonnet                # override the default for this job
    instruction: |
      Look at the git log for the last hour. Summarize commits.
      Job name: {job_name}.

  - name: nightly_cleanup
    schedule: "0 3 * * *"
    model: opus
    system_prompt: |             # replaces system prompt entirely for this job
      You are a cleanup agent. Current time: {system_datetime}.
    instruction: |
      Find files older than 7 days under ./tmp and delete them.
      Report what you removed.
```

## Root-level fields (defaults for all jobs)

| Field                  | Description                                                                          |
| ---------------------- | ------------------------------------------------------------------------------------ |
| `model`                | Default model — per-job `model` overrides it                                         |
| `system_prompt`        | Default system prompt — replaces Claude's built-in system prompt                     |
| `append_system_prompt` | Default text appended to the system prompt                                           |
| `telegram_chat_id`     | Chat/channel ID to send results to — requires `CLAUDEBOX_TELEGRAM_BOT_TOKEN` env var |

## Per-job fields

Same fields as root-level, plus:

| Field             | Description                                    |
| ----------------- | ---------------------------------------------- |
| `name`            | Unique job identifier (alphanumeric, `-`, `_`) |
| `schedule`        | Cron expression (5-field or 6-field)           |
| `instruction`     | The prompt sent to Claude                      |

Per-job values override the root-level defaults. `telegram_chat_id` can be set at root level for all jobs and overridden per job.

## Telegram notifications

Set `telegram_chat_id` (root or per-job) and `CLAUDEBOX_TELEGRAM_BOT_TOKEN` to get Claude's result posted to a Telegram chat after each job finishes. The bot must already be set up — see [Telegram mode](telegram.md) for setup.

```yaml
telegram_chat_id: -1001234567890   # root default — all jobs notify here

jobs:
  - name: hourly_check
    schedule: "0 * * * *"
    instruction: Check for issues and report.

  - name: silent_job
    schedule: "*/5 * * * *"
    telegram_chat_id: 0            # override: disable notifications for this job
    instruction: Write timestamp to status.txt.
```

After each job finishes, the last `result` block from Claude's output is sent. If Claude produced no output, a "finished (no output)" notice is sent. On non-zero exit, a failure notice is sent.

## Template variables

Use these in `instruction`, `system_prompt`, or `append_system_prompt` — expanded at fire time:

| Variable            | Expands to                                   | Example                      |
| ------------------- | -------------------------------------------- | ---------------------------- |
| `{system_datetime}` | Current UTC datetime                         | `2026-04-29 14:35:00 UTC`    |
| `{job_name}`        | The job's `name` field                       | `hourly_repo_check`          |

## Cron syntax

Standard 5-field (`min hr dom mon dow`) for minute resolution, or 6-field (`sec min hr dom mon dow`) for sub-minute — `*/30 * * * * *` fires every 30 seconds, `*/5 * * * * *` every 5 seconds.

2. **Run it:**

```yaml
# docker-compose.yml
services:
  claudebox-cron:
    image: psyb0t/claudebox:latest
    environment:
      - CLAUDEBOX_MODE_CRON=1
      - CLAUDEBOX_MODE_CRON_FILE=/home/claude/.claude/cron.yaml
      - CLAUDEBOX_WORKSPACE=/workspace
      - CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-xxx
      - DEBUG=true # optional, verbose per-tick logs
    volumes:
      - ./cron.yaml:/home/claude/.claude/cron.yaml:ro
      - ./workspace:/workspace
      - ~/.claude:/home/claude/.claude
      - /var/run/docker.sock:/var/run/docker.sock
```

The scheduler is a single foreground process — `docker logs` shows every tick (job fired, finished, errors). All jobs share the workspace at `CLAUDEBOX_WORKSPACE`. If a previous run is still in progress when the next tick fires, that tick is skipped (logged as a warning).

To target external systems (Telegram, Discord, Slack, email, web hooks, ...), tell Claude in the instruction to use an MCP server you've configured under `~/.claude` — it has full tool access during cron runs just like in interactive mode. See [Customization → MCP servers](../customization.md#mcp-servers) for setup.

## Environment variables

| Variable                   | Description                                                  | Default      |
| -------------------------- | ------------------------------------------------------------ | ------------ |
| `CLAUDEBOX_MODE_CRON`      | Set to `1` to start in cron mode                             | _(none)_     |
| `CLAUDEBOX_MODE_CRON_FILE` | Path inside the container to the cron yaml                   | _(none)_     |
| `CLAUDEBOX_WORKSPACE`      | Absolute path to the workspace directory (cwd for every job) | `/workspace` |
| `DEBUG`                    | Set to `true` for per-tick + per-line debug logs             | _(none)_     |

> Legacy `CLAUDE_MODE_CRON`, `CLAUDE_MODE_CRON_FILE`, `CLAUDE_WORKSPACE` are still accepted as fallbacks.
