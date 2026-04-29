# Interactive Mode

```bash
claudebox
```

Works just like the native `claude` CLI but runs inside a container. The container persists between runs, and `--continue` is applied automatically so each session picks up where you left off.

```bash
claudebox --update        # opt in to a Claude Code CLI update on this run
claudebox --no-continue   # start a fresh session instead of resuming the last one
```

## Utility commands

Some commands are passed through directly without entering interactive mode:

```bash
claudebox --version      # show the Claude Code CLI version
claudebox -v             # same thing
claudebox doctor         # run health checks
claudebox auth           # manage authentication
claudebox mcp <args...>  # manage MCP servers (e.g. `claudebox mcp list`, `claudebox mcp add ...`)
claudebox setup-token    # interactive OAuth token setup
claudebox stop           # stop the running interactive container for this workspace
claudebox clear-session  # delete session history for this workspace
```
