#!/bin/bash

dbg() { [ "${DEBUG:-}" = "true" ] && echo "[DEBUG $(date +%H:%M:%S.%3N)] $*" >&2; }

dbg "entrypoint start, args: $*"
dbg "CLAUDE_CONTAINER_NAME=$CLAUDE_CONTAINER_NAME"
dbg "CLAUDE_WORKSPACE=$CLAUDE_WORKSPACE"

# fix docker socket permissions by matching the container's docker group GID to the socket's GID
if [ -S /var/run/docker.sock ]; then
	SOCKET_GID=$(stat -c '%g' /var/run/docker.sock)
	CURRENT_DOCKER_GID=$(getent group docker | cut -d: -f3)
	if [ "$SOCKET_GID" != "$CURRENT_DOCKER_GID" ]; then
		dbg "fixing docker socket GID: $CURRENT_DOCKER_GID -> $SOCKET_GID"
		groupmod -g "$SOCKET_GID" docker
	fi
fi
dbg "docker socket done"

# match claude user's UID/GID to the host directory owner (skip if root)
if [ -n "$CLAUDE_WORKSPACE" ] && [ -d "$CLAUDE_WORKSPACE" ]; then
	HOST_UID=$(stat -c '%u' "$CLAUDE_WORKSPACE")
	HOST_GID=$(stat -c '%g' "$CLAUDE_WORKSPACE")
	CURRENT_UID=$(id -u claude)
	CURRENT_GID=$(id -g claude)

	if [ "$HOST_UID" != "0" ] && [ "$HOST_GID" != "0" ]; then
		if [ "$HOST_GID" != "$CURRENT_GID" ]; then
			dbg "fixing GID: $CURRENT_GID -> $HOST_GID"
			groupmod -g "$HOST_GID" claude
		fi
		if [ "$HOST_UID" != "$CURRENT_UID" ]; then
			dbg "fixing UID: $CURRENT_UID -> $HOST_UID"
			usermod -u "$HOST_UID" claude
		fi
		dbg "chown -R claude:claude /home/claude"
		chown -R claude:claude /home/claude
		dbg "chown done"
	fi
fi
dbg "uid/gid matching done"

WORKSPACE_DIR="${CLAUDE_WORKSPACE:-/workspace}"

dbg "WORKSPACE_DIR=$WORKSPACE_DIR"

# create CLAUDE.md if it doesn't exist in workspace
if [ ! -f "$WORKSPACE_DIR/CLAUDE.md" ]; then
	dbg "creating CLAUDE.md in workspace"
	cat >"$WORKSPACE_DIR/CLAUDE.md" <<'CLAUDEMD'
# Available Tools in This Container

You are running in a Docker container with full sudo access. Here's what you have:

## Languages & Runtimes
- **Go 1.25.5** - /usr/local/go/bin/go
- **Python 3.12.11** (via pyenv) - default python
- **Node.js LTS** - with npm

## Go Tools
- golangci-lint - linter aggregator
- gopls - language server
- dlv - delve debugger
- staticcheck - static analysis
- gomodifytags - struct tag modifier
- impl - interface implementation generator
- gotests - test generator
- gofumpt - stricter gofmt

## Python Tools
- flake8 - linter
- black - formatter
- isort - import sorter
- autoflake - remove unused imports
- pyright - type checker
- mypy - type checker
- vulture - dead code finder
- pytest, pytest-cov - testing
- pipenv, poetry - dependency management
- pyenv - python version management

## Node.js Tools
- eslint, prettier - linting/formatting
- typescript, ts-node - TypeScript
- yarn, pnpm - package managers
- nodemon, pm2 - process management
- create-react-app, @vue/cli, @angular/cli - framework CLIs
- express-generator - Express scaffolding
- newman - Postman CLI
- http-server, serve - static servers
- lighthouse - performance auditing
- @storybook/cli - component development

## Infrastructure & DevOps
- terraform - infrastructure as code
- kubectl - Kubernetes CLI
- helm - Kubernetes package manager
- docker, docker-compose - containerization
- gh - GitHub CLI

## Databases & Data
- sqlite3 - SQLite CLI
- postgresql-client (psql) - PostgreSQL CLI
- mysql-client - MySQL CLI
- redis-tools (redis-cli) - Redis CLI

## Shell & System Tools
- git - version control
- curl, wget, httpie - HTTP clients
- jq - JSON processor
- tree - directory visualization
- fd-find (fdfind) - fast file finder
- ripgrep (rg) - fast grep
- bat - cat with syntax highlighting
- exa - modern ls
- silversearcher-ag (ag) - code search
- shellcheck - shell script linter
- shfmt - shell formatter
- tmux - terminal multiplexer
- htop - process viewer

## C/C++ Tools
- gcc, g++, make, cmake - compilation
- clang-format - code formatter
- valgrind - memory debugging
- gdb - debugger
- strace, ltrace - tracing

## Notes
- You have passwordless sudo access
- Docker socket may be mounted for docker-in-docker
- pyenv at /usr/local/pyenv
- Go tools at /usr/local/bin
- claude CLI at ~/.claude (native install, can self-update)
CLAUDEMD
fi

# ensure .claude.json has required native install properties
# this helps users who mount their existing .claude directory
CLAUDE_CONFIG_DIR="/home/claude/.claude"
CLAUDE_JSON="$CLAUDE_CONFIG_DIR/.claude.json"

mkdir -p "$CLAUDE_CONFIG_DIR"

dbg "configuring .claude.json"
if [ -f "$CLAUDE_JSON" ]; then
	UPDATED=$(jq '.installMethod = "native" | .autoUpdates = false | .autoUpdatesProtectedForNative = true' "$CLAUDE_JSON")
	echo "$UPDATED" > "$CLAUDE_JSON"
else
	cp /claude/.claude.json "$CLAUDE_JSON"
fi

UPDATED=$(jq --arg dir "$WORKSPACE_DIR" '.projects[$dir].hasTrustDialogAccepted = true' "$CLAUDE_JSON")
echo "$UPDATED" > "$CLAUDE_JSON"
chown -R claude:claude "$CLAUDE_CONFIG_DIR"
dbg ".claude.json done"

# run init scripts on first container create (marker lives in container filesystem, not on mount)
INIT_MARKER="/var/run/claude-initialized"
if [ ! -f "$INIT_MARKER" ]; then
	INIT_DIR="/home/claude/.claude/init.d"
	if [ -d "$INIT_DIR" ]; then
		dbg "first run: executing init scripts from $INIT_DIR"
		for script in "$INIT_DIR"/*.sh; do
			[ ! -f "$script" ] && continue
			dbg "init: running $script"
			bash "$script"
			dbg "init: $script exited with $?"
		done
	fi
	touch "$INIT_MARKER"
	dbg "init marker created"
fi

# build the command to run as claude
CMD="cd \"$WORKSPACE_DIR\""
CMD="$CMD && export HOME=/home/claude"
CMD="$CMD && export CLAUDE_CONFIG_DIR=/home/claude/.claude"
CMD="$CMD && mkdir -p /home/claude/.claude/bin"
CMD="$CMD && export PATH=/home/claude/.claude/bin:\$PATH"

if [ -n "$CLAUDE_GIT_NAME" ]; then
	CMD="$CMD && git config --global user.name \"$CLAUDE_GIT_NAME\""
fi

if [ -n "$CLAUDE_GIT_EMAIL" ]; then
	CMD="$CMD && git config --global user.email \"$CLAUDE_GIT_EMAIL\""
fi

# load auth env vars from file (for existing containers that can't get new env vars)
AUTH_FILE="/home/claude/.claude/.${CLAUDE_CONTAINER_NAME}-auth"
dbg "auth file: $AUTH_FILE (exists: $([ -f "$AUTH_FILE" ] && echo yes || echo no))"
if [ -f "$AUTH_FILE" ]; then
	while IFS='=' read -r name value; do
		if [ -n "$value" ]; then
			dbg "auth: loading $name from file"
			CMD="$CMD && export $name=\"$value\""
		fi
	done < "$AUTH_FILE"
fi

ARGS_FILE="/home/claude/.claude/.${CLAUDE_CONTAINER_NAME}-args"
UPDATE_FILE="/home/claude/.claude/.${CLAUDE_CONTAINER_NAME}-update"
if [ "${1:-}" = "setup-token" ]; then
	dbg "mode: setup-token"
	CMD="$CMD && exec claude setup-token"
elif [ -f "$ARGS_FILE" ]; then
	# args file takes priority (subsequent runs on _prog container via docker start)
	ESCAPED_ARGS=$(cat "$ARGS_FILE")
	rm -f "$ARGS_FILE"
	dbg "mode: programmatic (subsequent), args: $ESCAPED_ARGS"
	CMD="$CMD && exec claude --dangerously-skip-permissions --continue $ESCAPED_ARGS"
elif [ $# -gt 0 ]; then
	ESCAPED_ARGS=$(printf '%q ' "$@")
	dbg "mode: programmatic (first run), args: $ESCAPED_ARGS"
	CMD="$CMD && (claude --dangerously-skip-permissions --continue $ESCAPED_ARGS || exec claude --dangerously-skip-permissions $ESCAPED_ARGS)"
else
	dbg "mode: interactive"
	if [ -f "$UPDATE_FILE" ]; then
		rm -f "$UPDATE_FILE"
		dbg "running claude update"
		CMD="$CMD && claude update"
	fi
	CMD="$CMD && (claude --dangerously-skip-permissions --continue || exec claude --dangerously-skip-permissions)"
fi

CLAUDE_UID=$(id -u claude)
CLAUDE_GID=$(id -g claude)
dbg "exec: setpriv --reuid=$CLAUDE_UID --regid=$CLAUDE_GID --init-groups bash -c \"...\""
dbg "CMD: $CMD"
exec setpriv --reuid="$CLAUDE_UID" --regid="$CLAUDE_GID" --init-groups bash -c "$CMD"
