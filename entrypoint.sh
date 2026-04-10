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
		PARALLEL=$(( $(nproc) / 2 ))
		[ "$PARALLEL" -lt 1 ] && PARALLEL=1
		dbg "chown /home/claude (only misowned, $PARALLEL parallel)"
		find /home/claude \( ! -user "$HOST_UID" -o ! -group "$HOST_GID" \) -print0 | xargs -0 -r -P "$PARALLEL" chown claude:claude
		dbg "chown done"
	fi
fi
dbg "uid/gid matching done"

WORKSPACE_DIR="${CLAUDE_WORKSPACE:-/workspace}"

dbg "WORKSPACE_DIR=$WORKSPACE_DIR"

# generate CLAUDE.md template (baked per image variant, reusable across workspaces)
CLAUDE_MD_TEMPLATE="/home/claude/.claude/CLAUDE.md.template"
if [ ! -f "$CLAUDE_MD_TEMPLATE" ]; then
	dbg "generating CLAUDE.md template (variant: ${CLAUDE_IMAGE_VARIANT:-full})"
	{
		cat <<'CLAUDEMD_HEADER'
# Available Tools in This Container

You are running in a Docker container with full sudo access. Here's what you have:

## Pre-installed
- **Node.js LTS** - with npm
- **Docker CE** with Docker Compose
- git, curl, wget, jq
CLAUDEMD_HEADER

		if [ "${CLAUDE_IMAGE_VARIANT:-full}" = "full" ]; then
			cat <<'CLAUDEMD_FULL'

## Languages & Runtimes
- **Go 1.26.1** - /usr/local/go/bin/go
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
CLAUDEMD_FULL
		else
			cat <<'CLAUDEMD_MINIMAL'

## Minimal Image
This is the minimal variant. Only basic tools are pre-installed (git, curl, wget, jq, Node.js, Docker).
You have passwordless sudo access — install whatever you need with apt-get, pip, npm, go install, etc.
CLAUDEMD_MINIMAL
		fi

		cat <<'CLAUDEMD_NOTES'

## Notes
- You have passwordless sudo access
- Docker socket may be mounted for docker-in-docker. The workspace is mounted at the exact same path as on the host, so when running docker commands with volume mounts, use the workspace path as the base (e.g. -v "$PWD/data:/data" will resolve correctly on the host)
- claude CLI at ~/.claude (native install, can self-update)
- ~/.claude/bin is in PATH — custom scripts placed here by the user are available to you
- ~/.claude/init.d/*.sh scripts run once on first container create (not on subsequent starts)
- Extra host directories may be mounted via CLAUDE_MOUNT_* env vars — check what's available if you need files outside the workspace

## IMPORTANT
If you need to overwrite or restructure this CLAUDE.md file for your project, FIRST save the container environment notes above to your memory or to a separate file (e.g. ~/.claude/CONTAINER.md) so you don't lose the container-specific information. These notes are auto-generated only on first run and won't be recreated if the file already exists.
CLAUDEMD_NOTES
	} > "$CLAUDE_MD_TEMPLATE"
	chown claude:claude "$CLAUDE_MD_TEMPLATE"
	dbg "CLAUDE.md template created"
fi

# generate system hint (appended to every claude invocation via --append-system-prompt)
SYSTEM_HINT_FILE="/home/claude/.claude/system-hint.txt"
if [ ! -f "$SYSTEM_HINT_FILE" ]; then
	cat > "$SYSTEM_HINT_FILE" <<SYSHINT
You are running in a Docker container (${CLAUDE_IMAGE_VARIANT:-full} image) with passwordless sudo access. ~/.claude/bin is in PATH — custom user scripts may be available there. Docker socket may be mounted for docker-in-docker. The workspace path inside the container matches the host path so docker volume mounts from within this container resolve correctly on the host.
SYSHINT
	chown claude:claude "$SYSTEM_HINT_FILE"
	dbg "system hint created"
fi

# copy template to workspace if CLAUDE.md doesn't exist there
if [ ! -f "$WORKSPACE_DIR/CLAUDE.md" ]; then
	cp "$CLAUDE_MD_TEMPLATE" "$WORKSPACE_DIR/CLAUDE.md"
	chown claude:claude "$WORKSPACE_DIR/CLAUDE.md"
	dbg "CLAUDE.md copied to $WORKSPACE_DIR"
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

# api mode — run fastapi server instead of claude
if [ "${CLAUDE_MODE_API:-}" = "1" ]; then
	dbg "mode: api server (port ${CLAUDE_MODE_API_PORT:-8080})"
	mkdir -p /workspaces
	chown claude:claude /workspaces
	CLAUDE_UID=$(id -u claude)
	CLAUDE_GID=$(id -g claude)
	exec setpriv --reuid="$CLAUDE_UID" --regid="$CLAUDE_GID" --init-groups \
		bash -c "export HOME=/home/claude && export CLAUDE_CONFIG_DIR=/home/claude/.claude && export PATH=/home/claude/.claude/bin:/home/claude/.local/bin:\$PATH && exec python3 /home/claude/api_server.py"
fi

# telegram mode — run telegram bot instead of claude
if [ "${CLAUDE_MODE_TELEGRAM:-}" = "1" ]; then
	dbg "mode: telegram bot"
	mkdir -p /workspaces
	chown claude:claude /workspaces
	CLAUDE_UID=$(id -u claude)
	CLAUDE_GID=$(id -g claude)
	exec setpriv --reuid="$CLAUDE_UID" --regid="$CLAUDE_GID" --init-groups \
		bash -c "export HOME=/home/claude && export CLAUDE_CONFIG_DIR=/home/claude/.claude && export PATH=/home/claude/.claude/bin:/home/claude/.local/bin:\$PATH && exec python3 /home/claude/telegram_bot.py"
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

# build combined append-system-prompt: hint + always-skills
COMBINED_APPEND=""
if [ -f "$SYSTEM_HINT_FILE" ]; then
	COMBINED_APPEND=$(cat "$SYSTEM_HINT_FILE")
fi
ALWAYS_SKILLS_DIR="/home/claude/.claude/.always-skills"
if [ -d "$ALWAYS_SKILLS_DIR" ]; then
	dbg "scanning always-skills: $ALWAYS_SKILLS_DIR"
	_skill_count=0
	while IFS= read -r -d '' skill_file; do
		skill_content=$(cat "$skill_file")
		if [ -n "$skill_content" ]; then
			skill_block="[Skill file: ${skill_file}]

${skill_content}"
			if [ -n "$COMBINED_APPEND" ]; then
				COMBINED_APPEND="${COMBINED_APPEND}

${skill_block}"
			else
				COMBINED_APPEND="$skill_block"
			fi
			_skill_count=$(( _skill_count + 1 ))
			dbg "always-skill loaded: $skill_file"
		fi
	done < <(find "$ALWAYS_SKILLS_DIR" -name "SKILL.md" -print0 2>/dev/null | sort -z)
	dbg "always-skills total: $_skill_count"
fi
SYSTEM_HINT_FLAG=""
if [ -n "$COMBINED_APPEND" ]; then
	SYSTEM_HINT_FLAG="--append-system-prompt $(printf '%q' "$COMBINED_APPEND")"
fi

# detect --no-continue and --resume in args (affects whether we auto-add --continue)
_skip_auto_continue() {
	for a in "$@"; do
		case "$a" in
			--no-continue|--resume|--resume=*) return 0 ;;
		esac
	done
	return 1
}

# strip --no-continue from args (not a real claude flag)
_strip_no_continue() {
	for a in "$@"; do
		[ "$a" = "--no-continue" ] && continue
		printf '%q ' "$a"
	done
}

if [ "${1:-}" = "setup-token" ]; then
	dbg "mode: setup-token"
	CMD="$CMD && exec claude setup-token"
elif [ -f "$ARGS_FILE" ]; then
	# args file takes priority (subsequent runs on _prog container via docker start)
	ESCAPED_ARGS=$(cat "$ARGS_FILE")
	rm -f "$ARGS_FILE"
	dbg "mode: programmatic (subsequent), args: $ESCAPED_ARGS"
	# check if --no-continue or --resume is in the escaped args
	if echo "$ESCAPED_ARGS" | grep -qE '\-\-no-continue|\-\-resume'; then
		ESCAPED_ARGS="${ESCAPED_ARGS//--no-continue/}"
		CMD="$CMD && exec claude --dangerously-skip-permissions $SYSTEM_HINT_FLAG $ESCAPED_ARGS"
	else
		CMD="$CMD && exec claude --dangerously-skip-permissions --continue $SYSTEM_HINT_FLAG $ESCAPED_ARGS"
	fi
elif [ $# -gt 0 ]; then
	if _skip_auto_continue "$@"; then
		ESCAPED_ARGS=$(_strip_no_continue "$@")
		dbg "mode: programmatic (first run, no auto-continue), args: $ESCAPED_ARGS"
		CMD="$CMD && exec claude --dangerously-skip-permissions $SYSTEM_HINT_FLAG $ESCAPED_ARGS"
	else
		ESCAPED_ARGS=$(printf '%q ' "$@")
		dbg "mode: programmatic (first run), args: $ESCAPED_ARGS"
		CMD="$CMD && (claude --dangerously-skip-permissions --continue $SYSTEM_HINT_FLAG $ESCAPED_ARGS || exec claude --dangerously-skip-permissions $SYSTEM_HINT_FLAG $ESCAPED_ARGS)"
	fi
else
	dbg "mode: interactive"
	if [ -f "$UPDATE_FILE" ]; then
		rm -f "$UPDATE_FILE"
		dbg "running claude update"
		CMD="$CMD && claude update"
	fi
	NO_CONTINUE_FILE="/home/claude/.claude/.${CLAUDE_CONTAINER_NAME}-no-continue"
	if [ -f "$NO_CONTINUE_FILE" ]; then
		rm -f "$NO_CONTINUE_FILE"
		dbg "no-continue flag set, skipping --continue"
		CMD="$CMD && exec claude --dangerously-skip-permissions $SYSTEM_HINT_FLAG"
	else
		CMD="$CMD && (claude --dangerously-skip-permissions --continue $SYSTEM_HINT_FLAG || exec claude --dangerously-skip-permissions $SYSTEM_HINT_FLAG)"
	fi
fi


CLAUDE_UID=$(id -u claude)
CLAUDE_GID=$(id -g claude)
dbg "exec: setpriv --reuid=$CLAUDE_UID --regid=$CLAUDE_GID --init-groups bash -c \"...\""
dbg "CMD: $CMD"
exec setpriv --reuid="$CLAUDE_UID" --regid="$CLAUDE_GID" --init-groups bash -c "$CMD"
