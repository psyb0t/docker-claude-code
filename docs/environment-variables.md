# Environment Variables

Set these on your host (e.g., in `~/.bashrc` or `~/.zshrc`). The wrapper script forwards them into the container automatically. These apply across all modes.

All wrapper/installer config uses the `CLAUDEBOX_*` prefix. Anything you want available **inside** the container goes through `CLAUDEBOX_ENV_*` (prefix stripped on the way in). Legacy `CLAUDE_*` / `CLAUDE_ENV_*` / `CLAUDE_MOUNT_*` and bare `ANTHROPIC_API_KEY` / `CLAUDE_CODE_OAUTH_TOKEN` / `DEBUG` still work for backwards compat.

| Variable                   | Description                                                                                | Default                   |
| -------------------------- | ------------------------------------------------------------------------------------------ | ------------------------- |
| `CLAUDEBOX_GIT_NAME`       | Git `user.name` inside the container                                                       | _(none)_                  |
| `CLAUDEBOX_GIT_EMAIL`      | Git `user.email` inside the container                                                      | _(none)_                  |
| `CLAUDEBOX_DATA_DIR`       | Override the `.claude` data directory on the host                                          | `~/.claude`               |
| `CLAUDEBOX_SSH_DIR`        | Override the SSH key directory mounted into the container                                  | `~/.ssh/claudebox`        |
| `CLAUDEBOX_INSTALL_DIR`    | Where to install the wrapper binary (install-time only)                                    | `/usr/local/bin`          |
| `CLAUDEBOX_BIN_NAME`       | Name of the wrapper binary (install-time only)                                             | `claudebox`               |
| `CLAUDEBOX_SKIP_PULL`      | Skip the `docker pull` during install (install-time only)                                  | _(none)_                  |
| `CLAUDEBOX_FORCE_PULL`     | Force `docker pull` even if image is already present (install-time only)                   | _(none)_                  |
| `CLAUDEBOX_IMAGE`          | Override the Docker image used by the wrapper                                              | `psyb0t/claudebox:latest` |
| `CLAUDEBOX_MINIMAL`        | When set, use the minimal image variant                                                    | _(none)_                  |
| `CLAUDEBOX_CONTAINER_NAME` | Override the per-workspace container name                                                  | derived from `$PWD`       |
| `CLAUDEBOX_ENV_*`          | Forward env vars into the container (prefix stripped: `CLAUDEBOX_ENV_FOO=bar` → `FOO=bar`) | _(none)_                  |
| `CLAUDEBOX_MOUNT_*`        | Mount extra host directories into the container                                            | _(none)_                  |

Auth and in-container settings go through `CLAUDEBOX_ENV_*`:

| Forwarded as                     | Set on host as                                 |
| -------------------------------- | ---------------------------------------------- |
| `ANTHROPIC_API_KEY`              | `CLAUDEBOX_ENV_ANTHROPIC_API_KEY`              |
| `CLAUDE_CODE_OAUTH_TOKEN`        | `CLAUDEBOX_ENV_CLAUDE_CODE_OAUTH_TOKEN`        |
| `DEBUG`                          | `CLAUDEBOX_ENV_DEBUG`                          |
| `CLAUDE_CODE_DISABLE_1M_CONTEXT` | `CLAUDEBOX_ENV_CLAUDE_CODE_DISABLE_1M_CONTEXT` |

## Forwarding environment variables

The `CLAUDEBOX_ENV_` prefix injects arbitrary env vars into the container. The prefix is stripped before forwarding:

```bash
# inside the container these become: GITHUB_TOKEN=xxx, MY_VAR=hello
CLAUDEBOX_ENV_GITHUB_TOKEN=xxx CLAUDEBOX_ENV_MY_VAR=hello claudebox "do stuff"
```

## Extra volume mounts

The `CLAUDEBOX_MOUNT_` prefix mounts additional host directories into the container:

```bash
CLAUDEBOX_MOUNT_DATA=/data claudebox "process the data"                    # same path inside container
CLAUDEBOX_MOUNT_1=/opt/configs CLAUDEBOX_MOUNT_2=/var/logs claudebox "go"  # mount multiple directories
CLAUDEBOX_MOUNT_STUFF=/host/path:/container/path claudebox "do stuff"      # explicit source:dest mapping
CLAUDEBOX_MOUNT_RO=/data:/data:ro claudebox "read the data"                # read-only mount
```

If the value contains `:`, it is passed directly as Docker `-v` syntax. Otherwise, the same path is used on both host and container sides.
