#!/usr/bin/env bash

echo "🚀 Starting Claude Code setup..."

# Check for Docker
if ! command -v docker &>/dev/null; then
	echo "❌ Docker is not installed. Please install Docker first."
	exit 1
fi

echo "📁 Creating ~/.claude directory..."
mkdir -p ~/.claude

echo "🔐 Creating SSH directory for Claude Code..."
mkdir -p "$HOME/.ssh/claude-code"

if [ -f "$HOME/.ssh/claude-code/id_ed25519" ]; then
	echo "🔑 SSH key already exists at $HOME/.ssh/claude-code/id_ed25519"
	read -rp "   Replace existing key? [y/N] " response
	if [[ "$response" =~ ^[Yy]$ ]]; then
		echo "🗝️ Generating new SSH key for Claude..."
		ssh-keygen -t ed25519 -C "claude@claude.ai" -f "$HOME/.ssh/claude-code/id_ed25519" -N ""
	else
		echo "   Keeping existing key."
	fi
else
	echo "🗝️ Generating SSH key for Claude..."
	ssh-keygen -t ed25519 -C "claude@claude.ai" -f "$HOME/.ssh/claude-code/id_ed25519" -N ""
fi

echo "📝 Creating claude command script..."
sudo tee /usr/local/bin/claude <<'EOF' >/dev/null
#!/usr/bin/env bash

# Git identity - use env var if set, otherwise empty
CLAUDE_GIT_NAME="${CLAUDE_GIT_NAME:-}"
CLAUDE_GIT_EMAIL="${CLAUDE_GIT_EMAIL:-}"

# Convert PWD to a valid container name (slashes to underscores)
sanitized_pwd=$(echo "$PWD" | sed 's/\//_/g')
container_name="claude-${sanitized_pwd}"

# Check if the container is running
if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
    echo "🟢 Container '$container_name' is running. Attaching..."
    docker attach "$container_name"
    exit 0
fi

# Check if container exists but stopped
if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
    echo "🔄 Container '$container_name' exists. Starting and attaching..."
    docker start -ai "$container_name"
    exit 0
fi

echo "🔧 Creating and running new container: '$container_name'"
docker run -it \
    --network host \
    -e CLAUDE_GIT_NAME="$CLAUDE_GIT_NAME" \
    -e CLAUDE_GIT_EMAIL="$CLAUDE_GIT_EMAIL" \
    -e CLAUDE_WORKSPACE="$PWD" \
    -v "$HOME/.ssh/claude-code:/home/claude/.ssh" \
    -v "$HOME/.claude:/home/claude/.claude" \
    -v "$PWD:$PWD" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    --name "$container_name" \
    psyb0t/claude-code:latest
EOF

echo "🔧 Making claude command executable..."
sudo chmod +x /usr/local/bin/claude

echo "✅ Claude Code setup complete! You can now use 'claude' command from any directory."
echo ""
echo "🔑 Don't forget to add your public key to GitHub:"
echo "   $HOME/.ssh/claude-code/id_ed25519.pub"
