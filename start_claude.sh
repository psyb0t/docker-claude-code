#!/bin/bash

mkdir -p "$HOME/.claude"
export CLAUDE_CONFIG_DIR="$HOME/.claude"

if [ -n "$CLAUDE_GITHUB_NAME" ]; then
    git config --global user.name "$CLAUDE_GITHUB_NAME"
fi

if [ -n "$CLAUDE_GITHUB_EMAIL" ]; then
    git config --global user.email "$CLAUDE_GITHUB_EMAIL"
fi

# create CLAUDE.md if it doesn't exist in workspace
if [ ! -f "/workspace/CLAUDE.md" ]; then
    cat > /workspace/CLAUDE.md << 'CLAUDEMD'
# Available Tools in This Container

You are running in a Docker container with full sudo access. Here's what you have:

## Languages & Runtimes
- **Go 1.24.5** - /usr/local/go/bin/go
- **Python 3.12** (via pyenv) - default python
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

sudo claude update
exec claude --dangerously-skip-permissions
