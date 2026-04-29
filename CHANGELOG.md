# Changelog

All notable changes to **claudebox** (formerly `docker-claude-code`).

Format roughly follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions before `v1.0.0` are pre-release; the rename to `claudebox` at `v1.0.0` is the only breaking change in the project's history.

## [v1.11.0] — 2026-04-30

### Added
- **Telegram per-chat overrides** stored in `~/.claude/telegram_overrides.json`, persisting across bot restarts and trumping the YAML config:
  - `/model` — inline keyboard or `/model <name>`; choices: `haiku`, `sonnet`, `opus`, `opusplan`, `reset`.
  - `/effort` — same UX; choices: `low`, `medium`, `high`, `xhigh`, `max`, `reset` (verified against the official Claude CLI docs).
  - `/system_prompt [text|reset]` — show/set/clear system-prompt override per chat.
  - `/append_system_prompt [text|reset]` — same for the appended system prompt.
- `opusplan` model alias surfaced everywhere: telegram bot, OpenAI `/openai/v1/models`, MCP tool docstring, docs.
- `tests/test_cron_telegram.sh` — unit + integration tests for the cron/telegram bridge: round-trip message tracking, prune to 200 entries, no-`--continue` on cron replies, `CRON_SYSTEM_HINT` content, combined-entrypoint smoke test.
- `run-e2e-cron-telegram.sh` — end-to-end script (sources `tests/.env` for credentials) for the cron+telegram reply-context flow.

### Changed
- `get_chat_config()` merges in-memory + on-disk overrides on top of YAML defaults.
- `_apply_choice` / `_send_choice_keyboard` / `_BUTTON_HANDLERS` shared plumbing for keyboard-driven overrides.

### Security
- `run-e2e-cron-telegram.sh` now sources `tests/.env` instead of carrying hardcoded OAuth/bot tokens. (A previously-committed token in `v1.10.0`'s `run-test.sh` was auto-revoked by Anthropic's secret scanning; new token issued and stored only in gitignored `tests/.env`.)

## [v1.10.0] — 2026-04-29

### Added
- **Combined cron + telegram mode**: when both `CLAUDEBOX_MODE_CRON=1` and `CLAUDEBOX_MODE_TELEGRAM=1` are set, the entrypoint runs the cron scheduler in the background and the telegram bot in the foreground (trap kills cron when the bot exits).
- Cron yaml supports `telegram_chat_id` (root-level default + per-job override) — finished jobs post their result to Telegram.
- **Cron-reply context injection**: when a user replies to a cron notification in Telegram, the bot looks up the original job (name, fired_at, instruction, result) in `~/.claude/cron/telegram_messages.json` and prepends it to the prompt. Cron replies always run in a fresh session (no `--continue`); regular messages keep `--continue`.
- Chat-wide cron awareness: the most recent 10 cron runs are injected into every prompt's `--append-system-prompt` so Claude can answer questions about them without an explicit reply.
- `telegram_utils.py` shared module (`BOT_TOKEN`, `make_bot()`, `send_long()`); `send_long()` now returns the list of sent `Message` objects so the caller can capture `message_id`.
- `wrapper.sh` gained a named `_cron` container with start/stop/restart parity to `_prog`, plus an auth file.

## [v1.9.0] — 2026-04-29

### Added
- Cron jobs support `system_prompt` / `append_system_prompt` (root-level + per-job override).
- Template variables expanded at fire time: `{system_datetime}`, `{job_name}`.

## [v1.8.0] — 2026-04-29

### Added
- `claudebox mcp ...` wrapper passthrough (`list`, `add`, `remove`, …) so MCP server management works the same as bare `claude mcp`.
- Documentation covering MCP server scopes (project `.mcp.json`, user, local) with CLI examples.

## [v1.7.0] — 2026-04-29

### Added
- **Cron mode** (`CLAUDEBOX_MODE_CRON=1`): yaml-scheduled Claude jobs with sub-minute resolution, per-job history under `~/.claude/cron/history/<workspace-slug>/<ts>-<job>/`, overlap protection, and foreground logging.

### Changed
- Environment variable namespace renamed `CLAUDE_*` → `CLAUDEBOX_*`. Legacy `CLAUDE_*` names are still accepted as fallbacks for backwards compatibility.

## [v1.6.0] — 2026-04-29

### Added
- Proper standalone installer (`install.sh`) that drops in a working setup with one command.

## [v1.5.0] — 2026-04-29

### Fixed
- Misc release-blocking bugs.

## [v1.4.1] — 2026-04-29

### Fixed
- Installer script regressions; bumped pinned Claude CLI version.

## [v1.4.0] — 2026-04-16

### Changed
- Base image upgraded to **Ubuntu 24.04** (CVE reduction).
- Adopted DEB822 apt sources; dropped `apt-transport-https` (no longer needed).
- `pip3 --break-system-packages --ignore-installed` to work around PEP 668 + PyJWT conflict.
- `userdel ubuntu` before `useradd claude` to free UID 1000.
- `exa` → `eza` (exa is unmaintained); `mysql-client` → `default-mysql-client`.
- Dropped `python3-venv`.

## [v1.3.0] — 2026-04-16

### Added
- **Async run mode** in API: `POST /run` with `async: true`, `GET /run/result` for polling. Run IDs included on every response. Read-once result cache with 6-hour TTL. Cancel by `runId`. `/status` now lists active runs.

### Changed
- All API responses include `workspace`.
- Switched build apt mirror to Cloudflare for faster Docker builds.
- README updated with full response schemas.

### Fixed
- `asyncio.Lock` around run state to eliminate races.

## [v1.2.0] — 2026-04-11

### Security
- Telegram **path traversal** fix on file operations.
- Auth file mode hardened to `chmod 600`.
- Entrypoint **command-injection** fix via `printf %q` quoting.
- `jq` failure protection.
- Port number validation.
- Install script fail-safe.

### Changed
- `/status` response normalized to camelCase.
- Test isolation via `mktemp`.

## [v1.1.0] — 2026-04-11

### Added
- `make test` target.
- `.dockerignore` (faster, smaller build context).
- Test for entrypoint always-skills wiring.

### Changed
- Tests refactored to a table-driven layout with workspace-relative test dirs.
- README revamp.

## [v1.0.0] — 2026-04-11

### BREAKING
Project renamed from `docker-claude-code` → **`claudebox`**:
- Docker image: `psyb0t/docker-claude-code` → `psyb0t/claudebox`.
- Binary: `claude-code` → `claudebox`.
- SSH dir: `~/.ssh/claude-code` → `~/.ssh/claudebox`.
- GitHub repo: `psyb0t/docker-claudebox`.

## [v0.39.0] — 2026-04-11

### Added
- **Always-skills**: scan `~/.claude/.always-skills` for `SKILL.md` files and inject them (with file-path prefix) into every Claude invocation across interactive, programmatic, API, and OpenAI modes.

## [v0.38.0] — 2026-04-10

### Added
- Structured JSON logging (`ts`, `level`, `logger`, `func`, `line`, `file`, `msg`) across auth, `/run`, OpenAI, MCP, and image handling. `DEBUG=1` enables debug level.

## [v0.37.0] — 2026-04-10

### Added
- **OpenAI multimodal**: base64 + URL images saved to the workspace and forwarded to Claude.
- Real usage-token reporting on OpenAI responses.
- Multi-turn via conversation JSON file.
- `X-Claude-Append-System-Prompt` request header.

### Changed
- Extra/unknown OpenAI fields silently ignored.

## [v0.36.0] — 2026-04-10

### Changed
- All 24 tests in `ALL_TESTS`; every assertion now checks the response body, not just status codes.

## [v0.35.0] — 2026-04-10

### Fixed
- `streamable_http_app` for MCP.
- MCP lifespan registered via FastAPI.
- `stream-json` assistant-event parsing.
- `--continue` flag logic.
- MCP tests with proper session init.

## [v0.34.0] — 2026-04-10

### Changed
- OpenAI `/v1/models` returns bare aliases (`haiku`, `sonnet`, `opus`).
- Provider prefix (`openai/`, `claudebox/`) stripped from inbound model names.
- Tests use `$TEST_MODEL` instead of hardcoded values.

## [v0.33.0] — 2026-04-10

### Added
- **OpenAI-compatible adapter** at `/openai/v1` (streaming, custom headers, `reasoning_effort`).
- **MCP server** at `/mcp` exposing `claude_run`, file operations, and auth tools.
- Shared `_run_claude_text` helper.

## [v0.32.0] — 2026-04-07

### Changed
- camelCase response normalization across the board: `jsonpipe.py` normalizes `json` / `stream-json` / `json-verbose`, wrapper pipes all formats. Tests assert recursively against snake_case.

## [v0.31.0] — 2026-04-07

### Fixed
- `asyncio.StreamReader` 64KB-line crash in API.
- Truncate `json-verbose` tool results > 2K with sha256 hash.

## [v0.30.0 – v0.29.0] — 2026-04-07

### Added
- `outputFormat: json-verbose` — assembles `stream-json` into a single JSON document with a `turns` array showing all tool calls.

## [v0.28.0] — 2026-04-03

### Added
- `clear-session` wrapper command.

### Fixed
- `--no-continue` without prompt.

### Changed
- README env-var section restructured.

## [v0.27.0] — 2026-04-03

### Changed
- camelCase normalization rolled out further.

## [v0.26.0] — 2026-04-03

### Removed
- Claude Code Router (CCR) integration.

### Changed
- Bumped Claude CLI to 2.1.90.

## [v0.25.0] — 2026-04-03

### Changed
- API moved to camelCase.
- Auto-updates now opt-in.
- Bumped CLI to 2.1.89.

## [v0.24.0] — 2026-04-01

### Added
- `claudebox stop` wrapper command.

## [v0.23.1 – v0.23.0] — 2026-03-31

### Added
- Wrapper passthrough for utility commands: `--version`, `doctor`, `auth`.

### Changed
- Go bumped 1.25.5 → 1.26.1.

## [v0.22.0] — 2026-03-31

### Added
- System hint appended to all modes — informs Claude about container info, image variant, sudo access, bin path, and host-path mapping.

## [v0.21.x] — 2026-03-30/31

### Added
- `CLAUDE.md` template seeded into all workspaces (telegram, API, interactive).
- Makefile build targets.

### Fixed
- Telegram cancel-retry bug; better logging.
- API kills the Claude process on client disconnect (opt out via `fire_and_forget`).

## [v0.20.x] — 2026-03-30

### Added
- **Telegram bot mode** (`CLAUDE_MODE_TELEGRAM=1`): per-chat workspaces, file/photo/video/voice handling, command menu, HTML formatting with plain-text fallback.

### Fixed
- Empty-file crash; httpx polling-spam silenced; proper logging.
- Filters, media handlers, command menu wiring.

## [v0.19.0] — 2026-03-30

### Added
- `--no-continue` and `--resume` wrapper flags.

### Changed
- Bumped Claude CLI to 2.1.87.

## [v0.18.x] — 2026-03-28

### Changed
- Hardcoded `/workspaces` as the API root; removed `CLAUDE_MODE_API_ROOT_WORKSPACE` env var.

### Fixed
- Workspace permissions.

## [v0.17.0] — 2026-03-28

### Added
- `--effort` (reasoning effort) flag in wrapper and API.

### Removed
- `claude-code-router` support.

## [v0.16.x] — 2026-03-28

### Added
- API expansion: `/files` with path params (`GET`/`PUT`/`DELETE`), `/health`, `/status`, `/run/cancel`.
- `--system-prompt`, `--append-system-prompt`, `--json-schema` flags in wrapper + API.
- Graceful API shutdown.
- `--continue` automatic fallback when no prior session.

### Changed
- API output is now JSON-only.

## [v0.15.0] — 2026-03-28

### Added
- **API mode** (`CLAUDE_MODE_API=1`) — FastAPI server.
- Multi-stage Dockerfile: `minimal` and `full` variants; `CLAUDE_MINIMAL` runtime flag.
- `CLAUDE_MOUNT_*` extra volume mounts.
- Per-workspace `409` locking.

### Changed
- `wrapper.sh` extracted from `install.sh` for clarity.

## [v0.14.x] — 2026-03-09/19

### Added
- `CLAUDE_MOUNT_*` extra volume mounts (same-path default, or explicit `src:dest`).
- Container env notes + overwrite warning baked into `CLAUDE.md`.

### Fixed
- Permissions / `chown` cleanup.

## [v0.13.x] — 2026-03-01/03

### Added
- `~/.claude/bin` in `PATH` for custom user scripts.
- `~/.claude/init.d/` hooks fired on first container creation.
- `CLAUDE_ENV_*` passthrough.
- `CLAUDE_INSTALL_DIR`, `CLAUDE_SSH_DIR`, `DEBUG` env-var docs.

### Removed
- Ephemeral mode (programmatic uses its own container — ephemeral was redundant).

## [v0.12.0] — 2026-02-27

### Added
- `--model` flag for programmatic / ephemeral runs.
- All available models documented.

## [v0.11.x – v0.10.x] — 2026-02-27

### Added
- **Programmatic** and **ephemeral** modes.
- `--no-update` flag (file-signal based).
- Argument whitelist + container lock.
- `--continue` automatic fallback.

### Changed
- Background auto-updates disabled by default.
- Restart instead of attach to existing containers.
- Trust pre-accept on first run.
- Bumped Claude CLI to 2.1.62.

### Fixed
- Silenced output for programmatic / ephemeral runs.

## [v0.9.x] — 2026-01-08 → 2026-02-03

### Added
- Native Claude installer (no more npm).

### Fixed
- Runtime permission fixes.
- Misc bug fixes; README updates.

## [v0.8.0] — 2025-12-10

### Added
- pyenv with Python 3.12.
- Auto-generated `CLAUDE.md` so Claude knows what tools are available in the container.

## [v0.7.x – v0.6.0] — 2025-11-23 → 2025-12-08

### Added
- Pinned Claude CLI version for reproducible builds.

## [v0.5.x] — 2025-10-10/13

### Fixed
- DNS resolution issue.

### Changed
- Image rebuild.

## [v0.4.0 – v0.1.0] — 2025-06-14 → 2025-08-25

Initial development: base image, more bundled tooling, project bootstrap.

[v1.11.0]: https://github.com/psyb0t/docker-claudebox/releases/tag/v1.11.0
[v1.10.0]: https://github.com/psyb0t/docker-claudebox/releases/tag/v1.10.0
[v1.9.0]: https://github.com/psyb0t/docker-claudebox/releases/tag/v1.9.0
[v1.8.0]: https://github.com/psyb0t/docker-claudebox/releases/tag/v1.8.0
[v1.7.0]: https://github.com/psyb0t/docker-claudebox/releases/tag/v1.7.0
[v1.6.0]: https://github.com/psyb0t/docker-claudebox/releases/tag/v1.6.0
[v1.5.0]: https://github.com/psyb0t/docker-claudebox/releases/tag/v1.5.0
[v1.4.1]: https://github.com/psyb0t/docker-claudebox/releases/tag/v1.4.1
[v1.4.0]: https://github.com/psyb0t/docker-claudebox/releases/tag/v1.4.0
[v1.3.0]: https://github.com/psyb0t/docker-claudebox/releases/tag/v1.3.0
[v1.2.0]: https://github.com/psyb0t/docker-claudebox/releases/tag/v1.2.0
[v1.1.0]: https://github.com/psyb0t/docker-claudebox/releases/tag/v1.1.0
[v1.0.0]: https://github.com/psyb0t/docker-claudebox/releases/tag/v1.0.0
