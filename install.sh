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

echo "📦 Pulling latest Claude Code image..."
docker pull psyb0t/claude-code:latest

echo "📝 Creating claude command script..."
sudo tee /usr/local/bin/claude <<'EOF' >/dev/null
#!/usr/bin/env bash

# Git identity - use env var if set, otherwise empty
CLAUDE_GIT_NAME="${CLAUDE_GIT_NAME:-}"
CLAUDE_GIT_EMAIL="${CLAUDE_GIT_EMAIL:-}"

# Convert PWD to a valid container name (slashes to underscores)
sanitized_pwd=$(echo "$PWD" | sed 's/\//_/g')
container_name="claude-${sanitized_pwd}"

DOCKER_ARGS=(
    --network host
    -e CLAUDE_GIT_NAME="$CLAUDE_GIT_NAME"
    -e CLAUDE_GIT_EMAIL="$CLAUDE_GIT_EMAIL"
    -e CLAUDE_WORKSPACE="$PWD"
    -e CLAUDE_CONTAINER_NAME="$container_name"
    -v "$HOME/.ssh/claude-code:/home/claude/.ssh"
    -v "$HOME/.claude:/home/claude/.claude"
    -v "$PWD:$PWD"
    -v /var/run/docker.sock:/var/run/docker.sock
)

# forward auth env vars to the container and save them for existing containers
AUTH_FILE="$HOME/.claude/.${container_name}-auth"
[ -n "$ANTHROPIC_API_KEY" ] && DOCKER_ARGS+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
[ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] && DOCKER_ARGS+=(-e "CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN")
printf '%s\n' "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}" "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN:-}" > "$AUTH_FILE"

# check for --no-update before anything else
NO_UPDATE=0
REMAINING_ARGS=()
for arg in "$@"; do
    if [ "$arg" = "--no-update" ]; then
        NO_UPDATE=1
        continue
    fi
    REMAINING_ARGS+=("$arg")
done
set -- "${REMAINING_ARGS[@]}"

# setup-token — throwaway container, token is saved to mounted ~/.claude
if [ "${1:-}" = "setup-token" ]; then
    docker run -it --rm --name "${container_name}_setup_$$" "${DOCKER_ARGS[@]}" psyb0t/claude-code:latest setup-token
    exit 0
fi

# Parse and validate args
if [ $# -gt 0 ]; then
    EPHEMERAL=0
    NEEDS_VERBOSE=0
    PASS_ARGS=(-p)
    EXPECT_VALUE=""
    for arg in "$@"; do
        if [ "$arg" = "--ephemeral" ]; then
            EPHEMERAL=1
            continue
        fi

        if [ -n "$EXPECT_VALUE" ]; then
            case "$EXPECT_VALUE" in
                --output-format)
                    case "$arg" in
                        text|json) ;;
                        stream-json) NEEDS_VERBOSE=1 ;;
                        *) echo "❌ Invalid output format: $arg (allowed: text, json, stream-json)"; exit 1 ;;
                    esac
                    ;;
            esac
            PASS_ARGS+=("$EXPECT_VALUE" "$arg")
            EXPECT_VALUE=""
            continue
        fi

        case "$arg" in
            -p|--print)
                # already added, skip
                ;;
            --output-format)
                EXPECT_VALUE="$arg"
                ;;
            --output-format=*)
                fmt="${arg#--output-format=}"
                case "$fmt" in
                    text|json) ;;
                    stream-json) NEEDS_VERBOSE=1 ;;
                    *) echo "❌ Invalid output format: $fmt (allowed: text, json, stream-json)"; exit 1 ;;
                esac
                PASS_ARGS+=("$arg")
                ;;
            -*)
                echo "❌ Unknown flag: $arg (allowed: -p, --print, --output-format, --ephemeral, --no-update)"
                exit 1
                ;;
            *)
                # positional arg = prompt
                PASS_ARGS+=("$arg")
                ;;
        esac
    done

    if [ -n "$EXPECT_VALUE" ]; then
        echo "❌ Missing value for $EXPECT_VALUE"
        exit 1
    fi

    [ "$NEEDS_VERBOSE" = "1" ] && PASS_ARGS+=(--verbose)

    if [ "$EPHEMERAL" = "1" ]; then
        RUN_ARGS=(--rm --name "${container_name}_ephemeral_$$")
        [ -t 1 ] && RUN_ARGS+=(-t)
        docker run -i "${RUN_ARGS[@]}" "${DOCKER_ARGS[@]}" psyb0t/claude-code:latest "${PASS_ARGS[@]}"
        exit 0
    fi

    # Programmatic mode — same container as interactive, pass args via file
    printf '%q ' "${PASS_ARGS[@]}" > "$HOME/.claude/.${container_name}-args"
    trap 'rm -f "$HOME/.claude/.${container_name}-args"' EXIT
fi

# signal update via file (env vars don't work with docker start)
UPDATE_FILE="$HOME/.claude/.${container_name}-update"
if [ $# -eq 0 ] && [ "$NO_UPDATE" = "0" ]; then
    touch "$UPDATE_FILE"
else
    rm -f "$UPDATE_FILE"
fi

# Wait for container to not be running (another session might be using it)
if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
    echo "⏳ Container '$container_name' is busy. Waiting for it to finish..."
    for i in 1 2 3; do
        sleep $((5 * i))
        if ! docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
            echo "✅ Container is free."
            break
        fi
        echo "   attempt $i/3..."
    done
    if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
        echo "❌ Container is still busy after 3 attempts. Try again later."
        rm -f "$HOME/.claude/.${container_name}-args"
        exit 1
    fi
fi

# Start existing container or create new one
if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
    echo "🔄 Starting container '$container_name'..."
    docker start -ai "$container_name"
else
    echo "🔧 Creating container '$container_name'..."
    docker run -it --name "$container_name" "${DOCKER_ARGS[@]}" psyb0t/claude-code:latest
fi
EOF

echo "🔧 Making claude command executable..."
sudo chmod +x /usr/local/bin/claude

echo "✅ Claude Code setup complete! You can now use 'claude' command from any directory."
echo ""
echo "🔑 Don't forget to add your public key to GitHub:"
echo "   $HOME/.ssh/claude-code/id_ed25519.pub"
