FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

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

RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

RUN useradd -ms /bin/bash claude

WORKDIR /workspace

RUN npm install -g @anthropic-ai/claude-code

COPY <<EOF /usr/local/bin/start_claude.sh
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

RUN chmod +x /usr/local/bin/start_claude.sh && \
    chown claude:claude /usr/local/bin/start_claude.sh

USER claude

ENTRYPOINT ["/usr/local/bin/start_claude.sh"]
