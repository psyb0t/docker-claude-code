FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# base install dump
RUN apt-get update && \
    apt-get install -y \
    git curl gnupg ca-certificates build-essential make cmake \
    python3 python3-pip python-is-python3 \
    nano vim htop tmux wget unzip zip tar \
    net-tools iputils-ping dnsutils software-properties-common \
    lsb-release pkg-config libssl-dev sudo && \
    rm -rf /var/lib/apt/lists/*

# node 20
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# install claude cli
RUN npm install -g @anthropic-ai/claude-code@latest

# create 'claude' user with full sudo access
RUN useradd -u 1000 -ms /bin/bash claude && \
    usermod -aG sudo claude

# grant passwordless sudo to claude for EVERYTHING
COPY <<EOF /etc/sudoers.d/claude-nopass
claude ALL=(ALL) NOPASSWD:ALL
EOF

RUN chmod 440 /etc/sudoers.d/claude-nopass

# workspace and warm cache
WORKDIR /workspace

# start script – your format, your style, no bloated bs
COPY <<EOF /home/claude/start_claude.sh
#!/bin/bash

mkdir -p "\$HOME/.claude"
export CLAUDE_CONFIG_DIR="\$HOME/.claude"

git config --global user.name "\$GH_NAME"
git config --global user.email "\$GH_EMAIL"

sudo claude update
exec claude --dangerously-skip-permissions "\$@"
EOF

RUN chmod +x /home/claude/start_claude.sh && \
    chown -R 1000:1000 /home/claude

# run as claude, master of his sandbox
USER claude
ENTRYPOINT ["/home/claude/start_claude.sh"]
