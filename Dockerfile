FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# base install dump
RUN apt-get update && \
    apt-get install -y \
    git curl gnupg ca-certificates build-essential make cmake \
    python3 python3-pip python-is-python3 \
    nano vim htop tmux wget unzip zip tar \
    net-tools iputils-ping dnsutils software-properties-common \
    lsb-release pkg-config libssl-dev sudo apt-transport-https \
    jq tree fd-find ripgrep bat exa silversearcher-ag \
    shellcheck shfmt clang-format valgrind gdb strace ltrace \
    sqlite3 postgresql-client mysql-client redis-tools \
    httpie gh \
    && rm -rf /var/lib/apt/lists/*

# install go 1.24.5 (detect architecture)
ARG TARGETARCH
RUN curl -fsSL https://go.dev/dl/go1.24.5.linux-${TARGETARCH}.tar.gz | tar -xzC /usr/local && \
    echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/environment && \
    echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/bash.bashrc
ENV PATH=$PATH:/usr/local/go/bin

# install golangci-lint + other go tools
RUN curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/HEAD/install.sh | sh -s -- -b /usr/local/bin latest

# install additional go dev tools
RUN CGO_ENABLED=0 go install golang.org/x/tools/gopls@latest && \
    CGO_ENABLED=0 go install github.com/go-delve/delve/cmd/dlv@latest && \
    CGO_ENABLED=0 go install honnef.co/go/tools/cmd/staticcheck@latest && \
    CGO_ENABLED=0 go install github.com/fatih/gomodifytags@latest && \
    CGO_ENABLED=0 go install github.com/josharian/impl@latest && \
    CGO_ENABLED=0 go install github.com/cweill/gotests/gotests@latest && \
    CGO_ENABLED=0 go install mvdan.cc/gofumpt@latest

# install terraform, kubectl
RUN curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /etc/apt/keyrings/hashicorp.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list && \
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list && \
    apt-get update && \
    apt-get install -y terraform kubectl && \
    rm -rf /var/lib/apt/lists/*

# install helm using the official install script (more reliable than apt)
RUN curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# install latest node.js
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# install python linters and formatters + more dev tools
RUN pip3 install --no-cache-dir \
    flake8 \
    black \
    isort \
    autoflake \
    pyright \
    mypy \
    vulture \
    pytest \
    pytest-cov \
    requests \
    beautifulsoup4 \
    lxml \
    pyyaml \
    toml \
    pipenv \
    poetry

# install docker
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt-get update && \
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin && \
    rm -rf /var/lib/apt/lists/*

# install claude cli + additional npm tools
RUN npm install -g @anthropic-ai/claude-code@2.0.61 \
    eslint \
    prettier \
    typescript \
    ts-node \
    @typescript-eslint/parser \
    @typescript-eslint/eslint-plugin \
    nodemon \
    pm2 \
    yarn \
    pnpm \
    create-react-app \
    @vue/cli \
    @angular/cli \
    express-generator \
    newman \
    http-server \
    serve \
    lighthouse \
    @storybook/cli

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

if [ -n "\$CLAUDE_GITHUB_NAME" ]; then
    git config --global user.name "\$CLAUDE_GITHUB_NAME"
fi

if [ -n "\$CLAUDE_GITHUB_EMAIL" ]; then
    git config --global user.email "\$CLAUDE_GITHUB_EMAIL"
fi

sudo claude update
exec claude --dangerously-skip-permissions "\$@"
EOF

RUN chmod +x /home/claude/start_claude.sh && \
    chown -R 1000:1000 /home/claude

# run as claude, master of his sandbox
USER claude
ENTRYPOINT ["/home/claude/start_claude.sh"]
