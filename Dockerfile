FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# core essentials
RUN apt-get update && apt-get install -y \
    git curl wget gnupg ca-certificates sudo apt-transport-https \
    software-properties-common lsb-release \
    && rm -rf /var/lib/apt/lists/*

# build tools
RUN apt-get update && apt-get install -y \
    build-essential make cmake pkg-config libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# python base (system python for bootstrapping)
RUN apt-get update && apt-get install -y \
    python3 python3-pip python-is-python3 \
    && rm -rf /var/lib/apt/lists/*

# editors and terminal
RUN apt-get update && apt-get install -y \
    nano vim htop tmux \
    && rm -rf /var/lib/apt/lists/*

# archive tools
RUN apt-get update && apt-get install -y \
    unzip zip tar \
    && rm -rf /var/lib/apt/lists/*

# networking tools
RUN apt-get update && apt-get install -y \
    net-tools iputils-ping dnsutils \
    && rm -rf /var/lib/apt/lists/*

# cli tools
RUN apt-get update && apt-get install -y \
    jq tree fd-find ripgrep bat exa silversearcher-ag \
    shellcheck shfmt httpie gh \
    && rm -rf /var/lib/apt/lists/*

# c/c++ tools
RUN apt-get update && apt-get install -y \
    clang-format valgrind gdb strace ltrace \
    && rm -rf /var/lib/apt/lists/*

# database clients
RUN apt-get update && apt-get install -y \
    sqlite3 postgresql-client mysql-client redis-tools \
    && rm -rf /var/lib/apt/lists/*

# pyenv dependencies
RUN apt-get update && apt-get install -y \
    libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev \
    libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev \
    && rm -rf /var/lib/apt/lists/*

# go 1.25.5
ARG TARGETARCH
RUN curl -fsSL https://go.dev/dl/go1.25.5.linux-${TARGETARCH}.tar.gz | tar -xzC /usr/local && \
    echo 'export PATH="$PATH:/usr/local/go/bin"' > /etc/profile.d/go.sh
ENV PATH=$PATH:/usr/local/go/bin

# go tools
RUN curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/HEAD/install.sh | sh -s -- -b /usr/local/bin latest
RUN CGO_ENABLED=0 go install golang.org/x/tools/gopls@latest && mv /root/go/bin/gopls /usr/local/bin/
RUN CGO_ENABLED=0 go install github.com/go-delve/delve/cmd/dlv@latest && mv /root/go/bin/dlv /usr/local/bin/
RUN CGO_ENABLED=0 go install honnef.co/go/tools/cmd/staticcheck@latest && mv /root/go/bin/staticcheck /usr/local/bin/
RUN CGO_ENABLED=0 go install github.com/fatih/gomodifytags@latest && mv /root/go/bin/gomodifytags /usr/local/bin/
RUN CGO_ENABLED=0 go install github.com/josharian/impl@latest && mv /root/go/bin/impl /usr/local/bin/
RUN CGO_ENABLED=0 go install github.com/cweill/gotests/gotests@latest && mv /root/go/bin/gotests /usr/local/bin/
RUN CGO_ENABLED=0 go install mvdan.cc/gofumpt@latest && mv /root/go/bin/gofumpt /usr/local/bin/

# terraform
RUN curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /etc/apt/keyrings/hashicorp.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list && \
    apt-get update && apt-get install -y terraform && rm -rf /var/lib/apt/lists/*

# kubectl
RUN curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list && \
    apt-get update && apt-get install -y kubectl && rm -rf /var/lib/apt/lists/*

# helm
RUN curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# node.js
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y nodejs && rm -rf /var/lib/apt/lists/*

# pyenv + python 3.12.11 (system-wide)
ENV PYENV_ROOT="/usr/local/pyenv"
ENV PATH="$PYENV_ROOT/shims:$PYENV_ROOT/bin:$PATH"
RUN curl https://pyenv.run | bash && \
    eval "$(pyenv init -)" && \
    pyenv install 3.12.11 && \
    pyenv global 3.12.11 && \
    echo 'export PYENV_ROOT="/usr/local/pyenv"' > /etc/profile.d/pyenv.sh && \
    echo 'export PATH="$PYENV_ROOT/shims:$PYENV_ROOT/bin:$PATH"' >> /etc/profile.d/pyenv.sh

# python linters/formatters
RUN pip install --no-cache-dir flake8 black isort autoflake pyright mypy vulture

# python testing
RUN pip install --no-cache-dir pytest pytest-cov

# python libs
RUN pip install --no-cache-dir requests beautifulsoup4 lxml pyyaml toml

# python package managers
RUN pip install --no-cache-dir pipenv poetry

# docker
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt-get update && \
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin && \
    rm -rf /var/lib/apt/lists/*

# node.js tools (global, these don't need auto-update)
RUN npm install -g eslint prettier typescript ts-node @typescript-eslint/parser @typescript-eslint/eslint-plugin
RUN npm install -g nodemon pm2 yarn pnpm
RUN npm install -g create-react-app @vue/cli @angular/cli express-generator
RUN npm install -g newman http-server serve lighthouse @storybook/cli

# create 'claude' user with sudo and docker access
RUN useradd -u 1000 -ms /bin/bash claude && \
    usermod -aG sudo claude && \
    usermod -aG docker claude && \
    mkdir -p /home/claude/.ssh && \
    ssh-keyscan github.com gitlab.com bitbucket.org >> /home/claude/.ssh/known_hosts 2>/dev/null && \
    chown -R claude:claude /home/claude

# passwordless sudo
COPY <<EOF /etc/sudoers.d/claude-nopass
claude ALL=(ALL) NOPASSWD:ALL
EOF
RUN chmod 440 /etc/sudoers.d/claude-nopass

# claude CLI under user home (so it can self-update)
USER claude
ENV NPM_CONFIG_PREFIX="/home/claude/.npm-global"
ENV PATH="/home/claude/.npm-global/bin:$PATH"
RUN npm install -g @anthropic-ai/claude-code@2.1.1 && \
    echo 'export NPM_CONFIG_PREFIX="$HOME/.npm-global"' >> ~/.profile && \
    echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> ~/.profile

# back to root for entrypoint
USER root

# workspace
WORKDIR /workspace

# entrypoint
COPY entrypoint.sh /home/claude/entrypoint.sh
RUN chmod +x /home/claude/entrypoint.sh

ENTRYPOINT ["/home/claude/entrypoint.sh"]
