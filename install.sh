#!/usr/bin/env bash

echo "🚀 Starting Claude Code setup..."

echo "📁 Creating ~/.claude directory..."
mkdir -p ~/.claude

echo "🔐 Creating SSH directory for Claude Code..."
mkdir -p "$HOME/.ssh/claude-code"

echo "🗝️ Generating SSH key for Claude..."
ssh-keygen -t ed25519 -C "claude@claude.ai" -f "$HOME/.ssh/claude-code/id_ed25519" -N ""

echo "📝 Creating claude command script..."
sudo tee /usr/local/bin/claude << 'EOF' > /dev/null
#!/usr/bin/env bash

# Convert PWD to a valid container name (slashes to underscores)
sanitized_pwd=$(echo "$PWD" | sed 's/\//_/g')
container_name="claude-${sanitized_pwd}"

# Check if the container exists
if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
    echo "🟢 Container '$container_name' exists."
    docker stop "$container_name"
    docker start "$container_name"
    docker attach "$container_name"
else
    echo "🔧 Creating and running new container: '$container_name'"
    docker run -it \
        --network host \
        -e GH_NAME="claude" \
        -e GH_EMAIL="claude@example.com" \
        -v $HOME/.ssh/claude-code:/home/claude/.ssh \
        -v $HOME/.claude:/home/claude/.claude \
        -v "$(pwd)":/workspace \
        -v /var/run/docker.sock:/var/run/docker.sock \
        --name "$container_name" \
        psyb0t/claude-code:latest "$@"
fi
EOF

echo "🔧 Making claude command executable..."
sudo chmod +x /usr/local/bin/claude

echo "✅ Claude Code setup complete! You can now use 'claude' command from any directory."
