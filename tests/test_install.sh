#!/bin/bash

# Tests install.sh end-to-end inside an isolated Ubuntu runner container (DinD via shared docker.sock).
# Builds the minimal claudebox image from local Dockerfile, runs install.sh inside the runner,
# verifies binary placement/permissions, then exercises the installed `claudebox` programmatically.

INSTALL_RUNNER_IMAGE="claudebox-install-runner:test"
MINIMAL_IMAGE_TAG="psyb0t/claudebox:latest-minimal"

_install_build_runner() {
    local dockerfile_dir
    dockerfile_dir=$(mktemp -d "$WORKDIR/tests/.tmp-install-runner-XXXXX")
    cat > "$dockerfile_dir/Dockerfile" <<'EOF'
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    docker.io openssh-client curl ca-certificates sudo bash jq && \
    rm -rf /var/lib/apt/lists/*
RUN userdel -r ubuntu 2>/dev/null || true && \
    useradd -m -s /bin/bash -u 1000 tester && \
    echo "tester ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/tester
USER tester
WORKDIR /home/tester
EOF
    docker build -t "$INSTALL_RUNNER_IMAGE" "$dockerfile_dir" >/dev/null 2>&1
    local rc=$?
    rm -rf "$dockerfile_dir"
    return $rc
}

_install_build_minimal() {
    docker build --target minimal -t "$MINIMAL_IMAGE_TAG" "$WORKDIR" >/dev/null 2>&1
}

test_install_minimal_end_to_end() {
    echo "  building install runner image..."
    if ! _install_build_runner; then
        echo "  FAIL: failed to build install runner image"
        return 1
    fi

    echo "  building minimal claudebox image (target=minimal)..."
    if ! _install_build_minimal; then
        echo "  FAIL: failed to build $MINIMAL_IMAGE_TAG"
        return 1
    fi

    # host-side scratch dir mapped into the runner at the SAME path so that any
    # `docker run -v <path>:...` issued from inside the runner resolves on the host.
    local host_dir
    host_dir=$(mktemp -d "$WORKDIR/tests/.tmp-install-XXXXX")
    chmod 777 "$host_dir"
    mkdir -p "$host_dir/home" "$host_dir/workspace" "$host_dir/repo"
    cp "$WORKDIR/install.sh" "$host_dir/repo/install.sh"
    cp "$WORKDIR/wrapper.sh" "$host_dir/repo/wrapper.sh"
    chmod 755 "$host_dir/repo/install.sh" "$host_dir/repo/wrapper.sh"
    # tester uid is 1000 inside the runner; chown so it can write
    chown -R 1000:1000 "$host_dir" 2>/dev/null || sudo chown -R 1000:1000 "$host_dir"

    local sock_gid
    sock_gid=$(stat -c '%g' /var/run/docker.sock)

    local container_name="claudebox-install-test-$$-$RANDOM"

    # run install.sh + invoke claudebox programmatically inside the runner
    local out rc
    out=$(docker run --rm \
        --name "$container_name" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        --group-add "$sock_gid" \
        -v "$host_dir:$host_dir" \
        -e HOME="$host_dir/home" \
        -e CLAUDEBOX_MINIMAL=1 \
        -e CLAUDEBOX_SKIP_PULL=1 \
        -e CLAUDEBOX_ENV_CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
        -e TEST_HOST_DIR="$host_dir" \
        -e TEST_MODEL="$TEST_MODEL" \
        "$INSTALL_RUNNER_IMAGE" bash -c '
set -e
cd "$TEST_HOST_DIR/repo"
bash ./install.sh

# verify binary exists, is executable, mode 755, in /usr/local/bin
BIN=/usr/local/bin/claudebox
[ -x "$BIN" ] || { echo "MARKER_FAIL_BIN_MISSING"; exit 10; }
mode=$(stat -c %a "$BIN")
[ "$mode" = "755" ] || { echo "MARKER_FAIL_BIN_MODE=$mode"; exit 11; }
owner=$(stat -c %U "$BIN")
[ "$owner" = "root" ] || { echo "MARKER_FAIL_BIN_OWNER=$owner"; exit 12; }

# verify ssh key created in $HOME/.ssh/claudebox
[ -f "$HOME/.ssh/claudebox/id_ed25519" ] || { echo "MARKER_FAIL_SSHKEY_MISSING"; exit 13; }
[ -f "$HOME/.ssh/claudebox/id_ed25519.pub" ] || { echo "MARKER_FAIL_SSHPUB_MISSING"; exit 14; }
key_mode=$(stat -c %a "$HOME/.ssh/claudebox/id_ed25519")
# ssh-keygen creates with 600
[ "$key_mode" = "600" ] || { echo "MARKER_FAIL_SSHKEY_MODE=$key_mode"; exit 15; }

# verify ~/.claude dir exists
[ -d "$HOME/.claude" ] || { echo "MARKER_FAIL_CLAUDEDIR_MISSING"; exit 16; }

echo "MARKER_INSTALL_OK"

# now run claudebox programmatically (relies on docker socket -> host daemon)
cd "$TEST_HOST_DIR/workspace"
claudebox -p "respond with exactly INSTALLPONG" \
    --model "$TEST_MODEL" --output-format text --no-continue
' 2>&1)
    rc=$?

    # cleanup workspace prog containers spawned via wrapper
    docker ps -a --format '{{.Names}}' | grep "^claude-${host_dir//\//_}_workspace" | xargs -r docker rm -f >/dev/null 2>&1 || true
    rm -rf "$host_dir" 2>/dev/null || sudo rm -rf "$host_dir"
    docker rmi -f "$INSTALL_RUNNER_IMAGE" >/dev/null 2>&1 || true

    if [ $rc -ne 0 ]; then
        echo "  FAIL: installer test exited $rc"
        echo "  output (last 50 lines):"
        echo "$out" | tail -50 | sed 's/^/    /'
        return 1
    fi

    assert_contains "$out" "MARKER_INSTALL_OK" "installer placed binary, key, dirs correctly" || return 1
    assert_contains "$out" "INSTALLPONG" "claudebox runs programmatically post-install" || return 1
    assert_not_contains "$out" "MARKER_FAIL_" "no install verification failures" || return 1
}

ALL_TESTS+=(
    test_install_minimal_end_to_end
)
