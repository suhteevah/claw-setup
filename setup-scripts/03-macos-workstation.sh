#!/bin/bash
set -euo pipefail

# =============================================================================
# macOS Human Workstation Setup
# Run this on: MacBook 2 (Intel)
# Role: Interactive Claude Code (human at keyboard) + icecream build worker
# =============================================================================

echo "=== Setting up MacBook 2 as human workstation ==="

echo "=== Phase 1: Install Homebrew (if needed) ==="
if ! command -v brew &>/dev/null; then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

echo "=== Phase 2: Install Dependencies ==="
brew update
brew install node@20 git ripgrep ccache

echo "=== Phase 3: Tailscale ==="
if ! brew list --cask tailscale &>/dev/null; then
  brew install --cask tailscale
fi
echo ">>> Open Tailscale.app and authenticate."
echo ">>> Then run: sudo tailscale up --hostname macbook2"
read -p "Press Enter after Tailscale is authenticated..."

echo "=== Phase 4: Icecream Worker ==="
brew install icecream

if ! dscl . -read /Users/icecc &>/dev/null 2>&1; then
  echo "Creating icecc system user..."
  sudo dscl . -create /Users/icecc
  sudo dscl . -create /Users/icecc UserShell /usr/bin/false
  ICECC_UID=$(dscl . -list /Users UniqueID | awk '{print $2}' | sort -n | tail -1 | awk '{print $1+1}')
  sudo dscl . -create /Users/icecc UniqueID "$ICECC_UID"
  sudo dscl . -create /Users/icecc PrimaryGroupID 20
  sudo dscl . -create /Users/icecc NFSHomeDirectory /var/empty
fi

echo "=== Phase 5: Claude Code ==="
npm install -g @anthropic-ai/claude-code
claude --version

echo "=== Phase 6: Install iceccd LaunchDaemon ==="
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHD_DIR="${SCRIPT_DIR}/../service-files/launchd"

if [ -f "${LAUNCHD_DIR}/org.icecc.iceccd.plist" ]; then
  sudo cp "${LAUNCHD_DIR}/org.icecc.iceccd.plist" /Library/LaunchDaemons/
  sudo launchctl load /Library/LaunchDaemons/org.icecc.iceccd.plist
  echo "iceccd service installed and started"
fi

echo "=== Phase 7: Shell Profile Setup ==="
PROFILE="${HOME}/.zshrc"
if [ -f "${HOME}/.bashrc" ] && [ ! -f "${HOME}/.zshrc" ]; then
  PROFILE="${HOME}/.bashrc"
fi

# Add icecc + ccache to PATH
if ! grep -q "icecc/bin" "$PROFILE" 2>/dev/null; then
  cat >> "$PROFILE" << 'SHELLEOF'

# Icecream distributed compilation
export PATH=/usr/local/lib/icecc/bin:$PATH
export CCACHE_PREFIX=icecc
SHELLEOF
  echo "Added icecc to ${PROFILE}"
fi

echo ""
echo "=========================================="
echo "  macOS Workstation Setup Complete        "
echo "=========================================="
echo ""
echo "Usage:"
echo "  - Run Claude Code interactively: claude"
echo "  - Optionally enable agent mode:"
echo "    agentapi server --type claude --allowed-hosts '*' -- claude \\"
echo "      --allowedTools 'Read,Edit,Bash(make *),Bash(git *)' \\"
echo "      --max-budget-usd 5.00"
echo ""
echo "  - Compile with icecream: make -j\$(nproc) CC=icecc CXX=icecc"
