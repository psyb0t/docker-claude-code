#!/usr/bin/env bash

echo "🚀 Starting Claude Code setup..."

# Check for Docker
if ! command -v docker &> /dev/null; then
    echo "❌ Docker is not installed. Please install Docker first."
    exit 1
fi

echo "📁 Creating ~/.claude directory..."
mkdir -p ~/.claude

echo "🔐 Creating SSH directory for Claude Code..."
mkdir -p "$HOME/.ssh/claude-code"

echo "🗝️ Generating SSH key for Claude..."
ssh-keygen -t ed25519 -C "claude@claude.ai" -f "$HOME/.ssh/claude-code/id_ed25519" -N ""

echo "📝 Creating claude command script..."
sudo tee /usr/local/bin/claude << 'EOF' > /dev/null
#!/usr/bin/env bash

# Git identity - use env var if set, otherwise empty
CLAUDE_GITHUB_NAME="${CLAUDE_GITHUB_NAME:-}"
CLAUDE_GITHUB_EMAIL="${CLAUDE_GITHUB_EMAIL:-}"

# Convert PWD to a valid container name (slashes to underscores)
sanitized_pwd=$(echo "$PWD" | sed 's/\//_/g')
container_name="claude-${sanitized_pwd}"

# Check if the container is running
if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
    echo "🟢 Container '$container_name' is running. Executing claude..."
    docker exec -it "$container_name" claude --dangerously-skip-permissions "$@"
    exit 0
fi

# Check if container exists but stopped
if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
    echo "🔄 Container '$container_name' exists but stopped. Removing and recreating..."
    docker rm "$container_name" > /dev/null
fi

echo "🔧 Creating and running new container: '$container_name'"
docker run -it \
    --network host \
    -e CLAUDE_GITHUB_NAME="$CLAUDE_GITHUB_NAME" \
    -e CLAUDE_GITHUB_EMAIL="$CLAUDE_GITHUB_EMAIL" \
    -v $HOME/.ssh/claude-code:/home/claude/.ssh \
    -v $HOME/.claude:/home/claude/.claude \
    -v "$(pwd)":/workspace \
    -v /var/run/docker.sock:/var/run/docker.sock \
    --name "$container_name" \
    psyb0t/claude-code:latest "$@"
EOF

echo "🔧 Making claude command executable..."
sudo chmod +x /usr/local/bin/claude

echo "✅ Claude Code setup complete! You can now use 'claude' command from any directory."
echo ""
echo "🔑 Don't forget to add your public key to GitHub:"
echo "   $HOME/.ssh/claude-code/id_ed25519.pub"
