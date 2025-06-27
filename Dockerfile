FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install base packages
RUN apt-get update && \
    apt-get install -y \
    git \
    curl \
    gnupg \
    ca-certificates \
    build-essential \
    make \
    cmake \
    python3 \
    python3-pip \
    python-is-python3 \
    nano \
    vim \
    htop \
    tmux \
    wget \
    unzip \
    zip \
    tar \
    net-tools \
    iputils-ping \
    dnsutils \
    software-properties-common \
    lsb-release \
    pkg-config \
    libssl-dev && \
    rm -rf /var/lib/apt/lists/*

# Install Node.js 20
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# Install Claude tool globally
RUN npm install -g @anthropic-ai/claude-code@latest

# Create user 'claude' with UID 1000
RUN useradd -u 1000 -ms /bin/bash claude

# Create workspace
WORKDIR /workspace

# Add the startup script
COPY <<EOF /home/claude/start_claude.sh
#!/bin/bash

mkdir -p "\$HOME/.claude"

cat <<CONFIG > "\$HOME/.claude/settings.json"
{
  "includeCoAuthoredBy": false
}
CONFIG

export CLAUDE_CONFIG_DIR="\$HOME/.claude"

git config --global user.name "\$GH_NAME"
git config --global user.email "\$GH_EMAIL"

claude update
exec claude --dangerously-skip-permissions "\$@"
EOF

# Make sure script is owned by claude and executable
RUN chmod +x /home/claude/start_claude.sh && \
    chown -R 1000:1000 /home/claude

# Switch to claude user (UID 1000)
USER claude

# Set entrypoint
ENTRYPOINT ["/home/claude/start_claude.sh"]
