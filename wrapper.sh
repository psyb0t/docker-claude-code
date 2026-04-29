#!/usr/bin/env bash

# CLAUDEBOX_* is the canonical prefix. CLAUDE_* names remain supported for backwards compat.
DEBUG="${CLAUDEBOX_ENV_DEBUG:-${DEBUG:-}}"

dbg() { [ "${DEBUG:-}" = "true" ] && echo "[DEBUG $(date +%H:%M:%S.%3N)] $*" >&2; }

CLAUDE_IMAGE="${CLAUDEBOX_IMAGE:-${CLAUDE_IMAGE:-}}"
_minimal="${CLAUDEBOX_MINIMAL:-${CLAUDE_MINIMAL:-}}"
if [ -z "$CLAUDE_IMAGE" ]; then
    if [ -n "$_minimal" ]; then
        CLAUDE_IMAGE="psyb0t/claudebox:latest-minimal"
    else
        CLAUDE_IMAGE="psyb0t/claudebox:latest"
    fi
fi

CLAUDE_GIT_NAME="${CLAUDEBOX_GIT_NAME:-${CLAUDE_GIT_NAME:-}}"
CLAUDE_GIT_EMAIL="${CLAUDEBOX_GIT_EMAIL:-${CLAUDE_GIT_EMAIL:-}}"
CLAUDE_DIR="${CLAUDEBOX_DATA_DIR:-${CLAUDE_DATA_DIR:-$HOME/.claude}}"
CLAUDE_SSH="${CLAUDEBOX_SSH_DIR:-${CLAUDE_SSH_DIR:-$HOME/.ssh/claudebox}}"

# auth: prefer CLAUDEBOX_ENV_*, fall back to legacy direct vars
ANTHROPIC_API_KEY="${CLAUDEBOX_ENV_ANTHROPIC_API_KEY:-${ANTHROPIC_API_KEY:-}}"
CLAUDE_CODE_OAUTH_TOKEN="${CLAUDEBOX_ENV_CLAUDE_CODE_OAUTH_TOKEN:-${CLAUDE_CODE_OAUTH_TOKEN:-}}"

# Convert PWD to a valid container name (slashes to underscores)
sanitized_pwd=$(echo "$PWD" | sed 's/\//_/g')
container_name="${CLAUDEBOX_CONTAINER_NAME:-${CLAUDE_CONTAINER_NAME:-claude-${sanitized_pwd}}}"
dbg "container_name=$container_name"
dbg "CLAUDE_DIR=$CLAUDE_DIR"
dbg "CLAUDE_SSH=$CLAUDE_SSH"
dbg "PWD=$PWD"

DOCKER_ARGS=(
    --network host
    -e CLAUDEBOX_GIT_NAME="$CLAUDE_GIT_NAME"
    -e CLAUDEBOX_GIT_EMAIL="$CLAUDE_GIT_EMAIL"
    -e CLAUDEBOX_WORKSPACE="$PWD"
    -e CLAUDEBOX_CONTAINER_NAME="$container_name"
    -v "$CLAUDE_SSH:/home/claude/.ssh"
    -v "$CLAUDE_DIR:/home/claude/.claude"
    -v "$PWD:$PWD"
    -v /var/run/docker.sock:/var/run/docker.sock
)

# forward env vars to the container
[ -n "$ANTHROPIC_API_KEY" ] && DOCKER_ARGS+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
[ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] && DOCKER_ARGS+=(-e "CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN")
[ "$DEBUG" = "true" ] && DOCKER_ARGS+=(-e "DEBUG=true")


# forward CLAUDEBOX_ENV_* / CLAUDE_ENV_* vars (strip prefix: FOO=bar)
while IFS='=' read -r name value; do
    case "$name" in
        CLAUDEBOX_ENV_*) stripped="${name#CLAUDEBOX_ENV_}" ;;
        CLAUDE_ENV_*)    stripped="${name#CLAUDE_ENV_}" ;;
        *) continue ;;
    esac
    DOCKER_ARGS+=(-e "$stripped=$value")
    dbg "forwarding env: $stripped"
done < <(env | grep -E "^(CLAUDEBOX_ENV_|CLAUDE_ENV_)")

# mount extra volumes via CLAUDEBOX_MOUNT_* / CLAUDE_MOUNT_*
while IFS='=' read -r name value; do
    case "$value" in
        *:*) DOCKER_ARGS+=(-v "$value") ;;
        *)   DOCKER_ARGS+=(-v "$value:$value") ;;
    esac
    dbg "mounting volume: $value"
done < <(env | grep -E "^(CLAUDEBOX_MOUNT_|CLAUDE_MOUNT_)")

dbg "ANTHROPIC_API_KEY set: $([ -n "$ANTHROPIC_API_KEY" ] && echo yes || echo no)"
dbg "CLAUDE_CODE_OAUTH_TOKEN set: $([ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] && echo yes || echo no)"
AUTH_CONTENT=$(printf '%s\n' "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}" "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN:-}")
echo "$AUTH_CONTENT" > "$CLAUDE_DIR/.${container_name}-auth"
chmod 600 "$CLAUDE_DIR/.${container_name}-auth"
echo "$AUTH_CONTENT" > "$CLAUDE_DIR/.${container_name}_prog-auth"
chmod 600 "$CLAUDE_DIR/.${container_name}_prog-auth"
dbg "wrote auth files"

# updates are disabled by default; pass --update to opt in
DO_UPDATE=0
REMAINING_ARGS=()
for arg in "$@"; do
    if [ "$arg" = "--update" ]; then
        DO_UPDATE=1
        continue
    fi
    REMAINING_ARGS+=("$arg")
done
set -- "${REMAINING_ARGS[@]}"

# setup-token — throwaway container, token is saved to mounted ~/.claude
if [ "${1:-}" = "setup-token" ]; then
    docker run -it --rm --name "${container_name}_setup_$$" "${DOCKER_ARGS[@]}" $CLAUDE_IMAGE setup-token
    exit 0
fi

# stop — kill running interactive container for this workspace
if [ "${1:-}" = "stop" ]; then
    if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
        docker stop "$container_name" >/dev/null 2>&1
        echo "stopped $container_name"
    else
        echo "nothing running"
    fi
    exit 0
fi

# clear-session — remove project session files for current workspace
if [ "${1:-}" = "clear-session" ]; then
    project_path=$(echo "$PWD" | sed 's|/|-|g')
    project_dir="$CLAUDE_DIR/projects/${project_path}"
    if [ -d "$project_dir" ]; then
        rm -rf "$project_dir"
        echo "cleared session for $PWD"
    else
        echo "no session found for $PWD (looked in $project_dir)"
    fi
    exit 0
fi

# passthrough commands — run in throwaway container, bypass entrypoint
case "${1:-}" in
    -v|--version|doctor|auth|mcp)
        docker run --rm --entrypoint claude "${DOCKER_ARGS[@]}" $CLAUDE_IMAGE "$@"
        exit 0
        ;;
esac

# Parse and validate args
if [ $# -gt 0 ]; then
    NEEDS_VERBOSE=0
    HAS_OUTPUT_FORMAT=0
    HAS_PROMPT=0
    HAS_PRINT=0
    HAS_NO_CONTINUE=0
    JSON_VERBOSE=0
    PASS_ARGS=(-p)
    EXPECT_VALUE=""
    for arg in "$@"; do
        if [ -n "$EXPECT_VALUE" ]; then
            case "$EXPECT_VALUE" in
                --output-format)
                    HAS_OUTPUT_FORMAT=1
                    case "$arg" in
                        text|json) ;;
                        stream-json) NEEDS_VERBOSE=1 ;;
                        json-verbose) JSON_VERBOSE=1; NEEDS_VERBOSE=1 ;;
                        *) echo "❌ Invalid output format: $arg (allowed: text, json, json-verbose, stream-json)"; exit 1 ;;
                    esac
                    ;;
                --model|--system-prompt|--append-system-prompt|--json-schema|--effort|--resume) ;;
            esac
            PASS_ARGS+=("$EXPECT_VALUE" "$arg")
            EXPECT_VALUE=""
            continue
        fi

        case "$arg" in
            -p|--print)
                HAS_PRINT=1
                ;;
            --no-continue)
                HAS_NO_CONTINUE=1
                PASS_ARGS+=("$arg")
                ;;
            --output-format|--model|--system-prompt|--append-system-prompt|--json-schema|--effort|--resume)
                EXPECT_VALUE="$arg"
                ;;
            --output-format=*)
                HAS_OUTPUT_FORMAT=1
                fmt="${arg#--output-format=}"
                case "$fmt" in
                    text|json) ;;
                    stream-json) NEEDS_VERBOSE=1 ;;
                    json-verbose) JSON_VERBOSE=1; NEEDS_VERBOSE=1 ;;
                    *) echo "❌ Invalid output format: $fmt (allowed: text, json, json-verbose, stream-json)"; exit 1 ;;
                esac
                PASS_ARGS+=("$arg")
                ;;
            --model=*|--system-prompt=*|--append-system-prompt=*|--json-schema=*|--effort=*|--resume=*)
                PASS_ARGS+=("$arg")
                ;;
            -*)
                echo "❌ Unknown flag: $arg (allowed: -p, --print, --output-format, --model, --system-prompt, --append-system-prompt, --json-schema, --effort, --resume, --no-continue, --update)"
                exit 1
                ;;
            *)
                if [ "$HAS_PRINT" = "0" ]; then
                    echo "❌ Unknown command: $arg"
                    echo "   Use -p or --print for programmatic mode: claude -p \"your prompt\""
                    exit 1
                fi
                # positional arg = prompt
                HAS_PROMPT=1
                PASS_ARGS+=("$arg")
                ;;
        esac
    done

    if [ -n "$EXPECT_VALUE" ]; then
        echo "❌ Missing value for $EXPECT_VALUE"
        exit 1
    fi

    if [ "$HAS_PROMPT" = "1" ]; then
        [ "$NEEDS_VERBOSE" = "1" ] && PASS_ARGS+=(--verbose)

        # determine pipe mode and fix args for json-verbose
        PIPE_MODE=""
        if [ "$HAS_OUTPUT_FORMAT" = "0" ]; then
            PASS_ARGS+=(--output-format text)
        elif [ "$JSON_VERBOSE" = "1" ]; then
            PIPE_MODE="json-verbose"
            FIXED_ARGS=()
            for a in "${PASS_ARGS[@]}"; do
                case "$a" in
                    json-verbose) FIXED_ARGS+=(stream-json) ;;
                    --output-format=json-verbose) FIXED_ARGS+=(--output-format=stream-json) ;;
                    *) FIXED_ARGS+=("$a") ;;
                esac
            done
            PASS_ARGS=("${FIXED_ARGS[@]}")
        else
            # detect json or stream-json in args
            for a in "${PASS_ARGS[@]}"; do
                case "$a" in
                    json|--output-format=json) PIPE_MODE="json" ;;
                    stream-json|--output-format=stream-json) PIPE_MODE="stream-json" ;;
                esac
            done
        fi

        dbg "PASS_ARGS: ${PASS_ARGS[*]}"
        dbg "PIPE_MODE: $PIPE_MODE"

        # Programmatic mode — own container, no TTY
        prog_name="${container_name}_prog"
        dbg "prog container: $prog_name"
        prog_rc=0
        if ! docker ps -a --format '{{.Names}}' | grep -q "^${prog_name}$"; then
            dbg "prog: container does not exist, creating with docker run"
            if [ -n "$PIPE_MODE" ]; then
                docker run --name "$prog_name" "${DOCKER_ARGS[@]}" -e CLAUDEBOX_CONTAINER_NAME="$prog_name" $CLAUDE_IMAGE "${PASS_ARGS[@]}" \
                    | docker run --rm -i --entrypoint python3 $CLAUDE_IMAGE /home/claude/jsonpipe.py "$PIPE_MODE"
                prog_rc=${PIPESTATUS[0]}
            else
                docker run --name "$prog_name" "${DOCKER_ARGS[@]}" -e CLAUDEBOX_CONTAINER_NAME="$prog_name" $CLAUDE_IMAGE "${PASS_ARGS[@]}"
                prog_rc=$?
            fi
            dbg "prog: docker run exited with $prog_rc"
        else
            dbg "prog: container exists, writing args file and starting"
            trap 'rm -f "$CLAUDE_DIR/.${prog_name}-args"' EXIT
            printf '%q ' "${PASS_ARGS[@]}" > "$CLAUDE_DIR/.${prog_name}-args"
            dbg "prog: docker start -a $prog_name"
            if [ -n "$PIPE_MODE" ]; then
                docker start -a "$prog_name" \
                    | docker run --rm -i --entrypoint python3 $CLAUDE_IMAGE /home/claude/jsonpipe.py "$PIPE_MODE"
                prog_rc=${PIPESTATUS[0]}
            else
                docker start -a "$prog_name"
                prog_rc=$?
            fi
            dbg "prog: docker start exited with $prog_rc"
        fi
        exit "$prog_rc"
    fi

    # flag-only args (no prompt): fall through to interactive mode
    [ "$HAS_NO_CONTINUE" = "1" ] && touch "$CLAUDE_DIR/.${container_name}-no-continue"
fi

# signal update via file (env vars don't work with docker start)
UPDATE_FILE="$CLAUDE_DIR/.${container_name}-update"
if [ "$DO_UPDATE" = "1" ]; then
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
    docker run -it --name "$container_name" "${DOCKER_ARGS[@]}" $CLAUDE_IMAGE
fi
