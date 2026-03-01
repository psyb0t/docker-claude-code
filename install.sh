#!/usr/bin/env bash

BIN_NAME="${1:-${CLAUDE_BIN_NAME:-claude}}"
BIN_PATH="/usr/local/bin/$BIN_NAME"

echo "🚀 Starting Claude Code setup (binary: $BIN_NAME)..."

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

echo "📝 Creating $BIN_NAME command script..."
sudo tee "$BIN_PATH" <<'EOF' >/dev/null
#!/usr/bin/env bash

dbg() { [ "${DEBUG:-}" = "true" ] && echo "[DEBUG $(date +%H:%M:%S.%3N)] $*" >&2; }

# Git identity - use env var if set, otherwise empty
CLAUDE_GIT_NAME="${CLAUDE_GIT_NAME:-}"
CLAUDE_GIT_EMAIL="${CLAUDE_GIT_EMAIL:-}"

# Claude data dir - override with CLAUDE_DATA_DIR env var
CLAUDE_DIR="${CLAUDE_DATA_DIR:-$HOME/.claude}"

# Convert PWD to a valid container name (slashes to underscores)
sanitized_pwd=$(echo "$PWD" | sed 's/\//_/g')
container_name="claude-${sanitized_pwd}"
dbg "container_name=$container_name"
dbg "CLAUDE_DIR=$CLAUDE_DIR"
dbg "PWD=$PWD"

DOCKER_ARGS=(
    --network host
    -e CLAUDE_GIT_NAME="$CLAUDE_GIT_NAME"
    -e CLAUDE_GIT_EMAIL="$CLAUDE_GIT_EMAIL"
    -e CLAUDE_WORKSPACE="$PWD"
    -e CLAUDE_CONTAINER_NAME="$container_name"
    -v "$HOME/.ssh/claude-code:/home/claude/.ssh"
    -v "$CLAUDE_DIR:/home/claude/.claude"
    -v "$PWD:$PWD"
    -v /var/run/docker.sock:/var/run/docker.sock
)

# forward env vars to the container
[ -n "$ANTHROPIC_API_KEY" ] && DOCKER_ARGS+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
[ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] && DOCKER_ARGS+=(-e "CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN")
[ "$DEBUG" = "true" ] && DOCKER_ARGS+=(-e "DEBUG=true")
dbg "ANTHROPIC_API_KEY set: $([ -n "$ANTHROPIC_API_KEY" ] && echo yes || echo no)"
dbg "CLAUDE_CODE_OAUTH_TOKEN set: $([ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] && echo yes || echo no)"
AUTH_CONTENT=$(printf '%s\n' "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}" "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN:-}")
echo "$AUTH_CONTENT" > "$CLAUDE_DIR/.${container_name}-auth"
echo "$AUTH_CONTENT" > "$CLAUDE_DIR/.${container_name}_prog-auth"
dbg "wrote auth files"

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
    PROGRAMMATIC=1
    EPHEMERAL=0
    NEEDS_VERBOSE=0
    HAS_OUTPUT_FORMAT=0
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
                    HAS_OUTPUT_FORMAT=1
                    case "$arg" in
                        text|json) ;;
                        stream-json) NEEDS_VERBOSE=1 ;;
                        *) echo "❌ Invalid output format: $arg (allowed: text, json, stream-json)"; exit 1 ;;
                    esac
                    ;;
                --model) ;;
            esac
            PASS_ARGS+=("$EXPECT_VALUE" "$arg")
            EXPECT_VALUE=""
            continue
        fi

        case "$arg" in
            -p|--print)
                # already added, skip
                ;;
            --output-format|--model)
                EXPECT_VALUE="$arg"
                ;;
            --output-format=*)
                HAS_OUTPUT_FORMAT=1
                fmt="${arg#--output-format=}"
                case "$fmt" in
                    text|json) ;;
                    stream-json) NEEDS_VERBOSE=1 ;;
                    *) echo "❌ Invalid output format: $fmt (allowed: text, json, stream-json)"; exit 1 ;;
                esac
                PASS_ARGS+=("$arg")
                ;;
            --model=*)
                PASS_ARGS+=("$arg")
                ;;
            -*)
                echo "❌ Unknown flag: $arg (allowed: -p, --print, --output-format, --model, --ephemeral, --no-update)"
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
    [ "$HAS_OUTPUT_FORMAT" = "0" ] && PASS_ARGS+=(--output-format text)

    dbg "PASS_ARGS: ${PASS_ARGS[*]}"
    dbg "EPHEMERAL=$EPHEMERAL NEEDS_VERBOSE=$NEEDS_VERBOSE"

    if [ "$EPHEMERAL" = "1" ]; then
        dbg "ephemeral: docker run -i --rm --name ${container_name}_ephemeral_$$"
        docker run -i --rm --name "${container_name}_ephemeral_$$" "${DOCKER_ARGS[@]}" psyb0t/claude-code:latest "${PASS_ARGS[@]}"
        dbg "ephemeral: docker exited with $?"
        exit 0
    fi

    # Programmatic mode — own container, no TTY
    prog_name="${container_name}_prog"
    dbg "prog container: $prog_name"
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${prog_name}$"; then
        dbg "prog: container does not exist, creating with docker run -i"
        docker run -i --name "$prog_name" "${DOCKER_ARGS[@]}" -e CLAUDE_CONTAINER_NAME="$prog_name" psyb0t/claude-code:latest "${PASS_ARGS[@]}"
        dbg "prog: docker run exited with $?"
    else
        dbg "prog: container exists, writing args file and starting"
        printf '%q ' "${PASS_ARGS[@]}" > "$CLAUDE_DIR/.${prog_name}-args"
        trap 'rm -f "$CLAUDE_DIR/.${prog_name}-args"' EXIT
        dbg "prog: docker start -ai $prog_name"
        docker start -ai "$prog_name"
        dbg "prog: docker start exited with $?"
    fi
    exit 0
fi

# signal update via file (env vars don't work with docker start)
UPDATE_FILE="$CLAUDE_DIR/.${container_name}-update"
if [ "$NO_UPDATE" = "0" ]; then
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
        echo "❌ Container is still busy after 3 attempts. Try again later." >&2
        exit 1
    fi
fi

# Interactive — start existing container or create new one
if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
    echo "🔄 Starting container '$container_name'..."
    docker start -ai "$container_name"
else
    echo "🔧 Creating container '$container_name'..."
    docker run -it --name "$container_name" "${DOCKER_ARGS[@]}" psyb0t/claude-code:latest
fi
EOF

echo "🔧 Making $BIN_NAME command executable..."
sudo chmod +x "$BIN_PATH"

echo "✅ Claude Code setup complete! You can now use '$BIN_NAME' command from any directory."
echo ""
echo "🔑 Don't forget to add your public key to GitHub:"
echo "   $HOME/.ssh/claude-code/id_ed25519.pub"
