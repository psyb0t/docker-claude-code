#!/bin/bash

# fix docker socket permissions by matching the container's docker group GID to the socket's GID
if [ -S /var/run/docker.sock ]; then
	SOCKET_GID=$(stat -c '%g' /var/run/docker.sock)
	CURRENT_DOCKER_GID=$(getent group docker | cut -d: -f3)
	if [ "$SOCKET_GID" != "$CURRENT_DOCKER_GID" ]; then
		groupmod -g "$SOCKET_GID" docker
	fi
fi

# match claude user's UID/GID to the host directory owner
if [ -n "$CLAUDE_WORKSPACE" ] && [ -d "$CLAUDE_WORKSPACE" ]; then
	HOST_UID=$(stat -c '%u' "$CLAUDE_WORKSPACE")
	HOST_GID=$(stat -c '%g' "$CLAUDE_WORKSPACE")
	CURRENT_UID=$(id -u claude)
	CURRENT_GID=$(id -g claude)

	if [ "$HOST_GID" != "$CURRENT_GID" ]; then
		groupmod -g "$HOST_GID" claude
	fi
	if [ "$HOST_UID" != "$CURRENT_UID" ]; then
		usermod -u "$HOST_UID" claude
	fi

	# fix home directory ownership after UID/GID change
	chown -R claude:claude /home/claude
fi

WORKSPACE_DIR="${CLAUDE_WORKSPACE:-/workspace}"

# create CLAUDE.md if it doesn't exist in workspace
if [ ! -f "$WORKSPACE_DIR/CLAUDE.md" ]; then
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
- pyenv is installed system-wide at /usr/local/pyenv
CLAUDEMD
fi

# build the command to run as claude
# we use su with a login shell to get the proper environment
CMD="cd \"$WORKSPACE_DIR\""
CMD="$CMD && export HOME=/home/claude"
CMD="$CMD && export CLAUDE_CONFIG_DIR=/home/claude/.claude"
CMD="$CMD && mkdir -p /home/claude/.claude"

if [ -n "$CLAUDE_GIT_NAME" ]; then
	CMD="$CMD && git config --global user.name \"$CLAUDE_GIT_NAME\""
fi

if [ -n "$CLAUDE_GIT_EMAIL" ]; then
	CMD="$CMD && git config --global user.email \"$CLAUDE_GIT_EMAIL\""
fi

CMD="$CMD && claude update && exec claude --dangerously-skip-permissions"

exec su - claude -c "$CMD"
