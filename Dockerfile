FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# base install dump
RUN apt-get update && \
    apt-get install -y \
    git curl gnupg ca-certificates build-essential make cmake \
    python3 python3-pip python-is-python3 \
    nano vim htop tmux wget unzip zip tar \
    net-tools iputils-ping dnsutils software-properties-common \
    lsb-release pkg-config libssl-dev sudo apt-transport-https && \
    rm -rf /var/lib/apt/lists/*

# install go 1.24.5
RUN curl -fsSL https://go.dev/dl/go1.24.5.linux-amd64.tar.gz | tar -xzC /usr/local && \
    echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/environment && \
    echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/bash.bashrc
ENV PATH=$PATH:/usr/local/go/bin

# install latest node.js
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# install python linters and formatters
RUN pip3 install --no-cache-dir \
    flake8 \
    black \
    isort \
    autoflake \
    pyright \
    mypy \
    vulture

# install docker
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt-get update && \
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin && \
    rm -rf /var/lib/apt/lists/*

# install claude cli
RUN npm install -g @anthropic-ai/claude-code@latest

# create 'claude' user with full sudo access and docker group
RUN useradd -u 1000 -ms /bin/bash claude && \
    usermod -aG sudo claude && \
    usermod -aG docker claude

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
