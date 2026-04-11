#!/usr/bin/env bash

BIN_NAME="${1:-${CLAUDE_BIN_NAME:-claudebox}}"
INSTALL_DIR="${CLAUDE_INSTALL_DIR:-/usr/local/bin}"
BIN_PATH="$INSTALL_DIR/$BIN_NAME"

echo "🚀 Starting Claude Code setup (binary: $BIN_NAME)..."

# Check for Docker
if ! command -v docker &>/dev/null; then
	echo "❌ Docker is not installed. Please install Docker first."
	exit 1
fi

echo "📁 Creating ~/.claude directory..."
mkdir -p ~/.claude

echo "🔐 Creating SSH directory for Claude Code..."
mkdir -p "$HOME/.ssh/claudebox"

if [ -f "$HOME/.ssh/claudebox/id_ed25519" ]; then
	echo "🔑 SSH key already exists at $HOME/.ssh/claudebox/id_ed25519"
	read -rp "   Replace existing key? [y/N] " response
	if [[ "$response" =~ ^[Yy]$ ]]; then
		echo "🗝️ Generating new SSH key for Claude..."
		ssh-keygen -t ed25519 -C "claude@claude.ai" -f "$HOME/.ssh/claudebox/id_ed25519" -N ""
	else
		echo "   Keeping existing key."
	fi
else
	echo "🗝️ Generating SSH key for Claude..."
	ssh-keygen -t ed25519 -C "claude@claude.ai" -f "$HOME/.ssh/claudebox/id_ed25519" -N ""
fi

CLAUDE_TAG="latest"
[ -n "$CLAUDE_MINIMAL" ] && CLAUDE_TAG="latest-minimal"
echo "📦 Pulling Claude Code image (tag: $CLAUDE_TAG)..."
docker pull "psyb0t/claudebox:$CLAUDE_TAG"

# get wrapper.sh — from same dir if running locally, otherwise download from GitHub
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-/dev/null}")" 2>/dev/null && pwd)"
WRAPPER_TMP="$(mktemp /tmp/claude-wrapper-XXXXXX.sh)"
if [ -f "$SCRIPT_DIR/wrapper.sh" ]; then
	echo "📝 Using local wrapper.sh..."
	cp "$SCRIPT_DIR/wrapper.sh" "$WRAPPER_TMP"
else
	echo "📝 Downloading wrapper.sh..."
	curl -fsSL "https://raw.githubusercontent.com/psyb0t/claudebox/master/wrapper.sh" -o "$WRAPPER_TMP"
fi

echo "📝 Installing $BIN_NAME to $BIN_PATH..."
sudo cp "$WRAPPER_TMP" "$BIN_PATH"
rm -f "$WRAPPER_TMP"

echo "🔧 Making $BIN_NAME command executable..."
sudo chmod +x "$BIN_PATH"

echo "✅ Claude Code setup complete! You can now use '$BIN_NAME' command from any directory."
echo ""
echo "🔑 Don't forget to add your public key to GitHub:"
echo "   $HOME/.ssh/claudebox/id_ed25519.pub"
