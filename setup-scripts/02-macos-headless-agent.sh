#!/bin/bash
set -euo pipefail

# =============================================================================
# macOS Headless Agent Setup
# Run this on: MacBook 1 (Intel) and iMac (Intel)
# Role: Headless Claude Code agent (root access) + icecream build worker
# =============================================================================

HOSTNAME="${1:-}"
if [ -z "$HOSTNAME" ]; then
  echo "Usage: $0 <hostname>"
  echo "  e.g.: $0 macbook1"
  echo "  e.g.: $0 imac"
  exit 1
fi

echo "=== Setting up ${HOSTNAME} as headless Claude Code agent ==="

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
echo ">>> Then run: sudo tailscale up --hostname ${HOSTNAME}"
read -p "Press Enter after Tailscale is authenticated..."

echo "=== Phase 4: Icecream ==="
brew install icecream

# macOS may need an icecc user for the daemon chroot
if ! dscl . -read /Users/icecc &>/dev/null 2>&1; then
  echo "Creating icecc system user..."
  sudo dscl . -create /Users/icecc
  sudo dscl . -create /Users/icecc UserShell /usr/bin/false
  # Find unused UID
  ICECC_UID=$(dscl . -list /Users UniqueID | awk '{print $2}' | sort -n | tail -1 | awk '{print $1+1}')
  sudo dscl . -create /Users/icecc UniqueID "$ICECC_UID"
  sudo dscl . -create /Users/icecc PrimaryGroupID 20
  sudo dscl . -create /Users/icecc NFSHomeDirectory /var/empty
  echo "Created icecc user with UID ${ICECC_UID}"
fi

# Check if the intended scheduler (arch-orchestrator) is reachable
ICECC_SCHEDULER="arch-orchestrator"
ICECC_MODE="worker"
echo ""
echo "Checking if icecream scheduler (${ICECC_SCHEDULER}) is reachable..."
if command -v tailscale &>/dev/null && tailscale ping --timeout 3s "${ICECC_SCHEDULER}" &>/dev/null 2>&1; then
  echo "  [OK] Scheduler reachable at ${ICECC_SCHEDULER}"
else
  echo "  [WARN] Scheduler at ${ICECC_SCHEDULER} is not reachable."
  echo ""
  echo "  Options:"
  echo "    1) Run this machine as a TEMPORARY SCHEDULER (recommended if orchestrator is down)"
  echo "    2) Skip icecream for now (install only, configure later)"
  echo "    3) Enter a different scheduler hostname"
  echo ""
  read -p "  Choose [1/2/3]: " ICECC_CHOICE
  case "${ICECC_CHOICE}" in
    1)
      ICECC_MODE="scheduler"
      echo "  This machine will run as a temporary icecream scheduler + worker."
      echo "  When arch-orchestrator is back online, switch back with:"
      echo "    brew services stop icecc-scheduler"
      echo "    sudo launchctl load /Library/LaunchDaemons/org.icecc.iceccd.plist"
      ;;
    3)
      read -p "  Enter scheduler hostname or IP: " CUSTOM_SCHEDULER
      if [ -n "${CUSTOM_SCHEDULER:-}" ]; then
        ICECC_SCHEDULER="$CUSTOM_SCHEDULER"
      fi
      ;;
    *)
      ICECC_MODE="skip"
      echo "  Skipping icecream service config. Run this script again when scheduler is ready."
      ;;
  esac
fi

echo "=== Phase 5: Claude Code ==="
npm install -g @anthropic-ai/claude-code
claude --version

echo "=== Phase 6: AgentAPI ==="
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH_HW=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
sudo curl -fsSL \
  "https://github.com/coder/agentapi/releases/latest/download/agentapi-${OS}-${ARCH_HW}" \
  -o /usr/local/bin/agentapi
sudo chmod +x /usr/local/bin/agentapi

echo "=== Phase 7: API Key Setup ==="
sudo mkdir -p /etc/claude
sudo chmod 700 /etc/claude
if [ ! -f /etc/claude/api-key ]; then
  read -sp "Enter your Anthropic API key: " API_KEY
  echo
  echo "ANTHROPIC_API_KEY=${API_KEY}" | sudo tee /etc/claude/api-key > /dev/null
  sudo chmod 600 /etc/claude/api-key
  echo "API key saved"
else
  echo "API key already configured"
fi

echo "=== Phase 8: Authenticate Claude Code ==="
echo ">>> Run: claude auth login"
echo ">>> Authenticate in your browser."
read -p "Press Enter after authenticating..."

echo "=== Phase 9: Install LaunchDaemons ==="
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHD_DIR="${SCRIPT_DIR}/../service-files/launchd"

# Install icecream services based on mode chosen in Phase 4
if [ "$ICECC_MODE" = "scheduler" ]; then
  echo "Starting icecream scheduler on this machine..."
  brew services start icecc-scheduler 2>/dev/null || true
  # Also run iceccd locally pointing to localhost
  sudo iceccd -d -s localhost -u icecc 2>/dev/null || true
  echo "icecream scheduler + local worker started"
elif [ "$ICECC_MODE" = "worker" ]; then
  if [ -f "${LAUNCHD_DIR}/org.icecc.iceccd.plist" ]; then
    # Substitute the scheduler hostname if it was changed
    if [ "$ICECC_SCHEDULER" != "arch-orchestrator" ]; then
      sed "s|arch-orchestrator|${ICECC_SCHEDULER}|g" \
        "${LAUNCHD_DIR}/org.icecc.iceccd.plist" > /tmp/org.icecc.iceccd.plist
      sudo mv /tmp/org.icecc.iceccd.plist /Library/LaunchDaemons/
    else
      sudo cp "${LAUNCHD_DIR}/org.icecc.iceccd.plist" /Library/LaunchDaemons/
    fi
    sudo launchctl load /Library/LaunchDaemons/org.icecc.iceccd.plist
    echo "iceccd worker started (scheduler: ${ICECC_SCHEDULER})"
  fi
else
  echo "Icecream skipped. To configure later:"
  echo "  sudo iceccd -d -s <scheduler-hostname> -u icecc"
fi

# Install AgentAPI launchd plist
if [ -f "${LAUNCHD_DIR}/com.claude.agentapi.plist" ]; then
  # Substitute API key into plist
  API_KEY=$(grep ANTHROPIC_API_KEY /etc/claude/api-key | cut -d= -f2)
  sed "s|__ANTHROPIC_API_KEY__|${API_KEY}|g" \
    "${LAUNCHD_DIR}/com.claude.agentapi.plist" > /tmp/com.claude.agentapi.plist
  sudo mv /tmp/com.claude.agentapi.plist ~/Library/LaunchAgents/
  launchctl load ~/Library/LaunchAgents/com.claude.agentapi.plist
  echo "AgentAPI service installed and started"
fi

# Allow incoming connections on port 3284 (AgentAPI) and 10245 (iceccd)
echo ">>> You may need to allow incoming connections in System Preferences > Firewall"

echo "=== GPU Detection + Ollama ==="
SHARED_MODULE="${SCRIPT_DIR}/../shared/ollama-gpu-detect.sh"
if [ -f "$SHARED_MODULE" ]; then
  source "$SHARED_MODULE"
  install_ollama_with_model
else
  echo "WARNING: ollama-gpu-detect.sh not found. Skipping Ollama."
fi

echo ""
echo "=========================================="
echo "  macOS Headless Agent Setup Complete     "
echo "  Hostname: ${HOSTNAME}                   "
if [ "$ICECC_MODE" = "scheduler" ]; then
echo "  Icecream: TEMPORARY SCHEDULER           "
elif [ "$ICECC_MODE" = "worker" ]; then
echo "  Icecream: Worker -> ${ICECC_SCHEDULER}  "
else
echo "  Icecream: Skipped (configure later)     "
fi
echo "=========================================="
echo ""
echo "Verify:"
echo "  - Tailscale: tailscale status"
echo "  - AgentAPI:  curl http://localhost:3284/status"
if [ "$ICECC_MODE" = "scheduler" ]; then
echo "  - Scheduler: icecream-sundae (or icemon)"
echo ""
echo "  When arch-orchestrator is back online:"
echo "    brew services stop icecc-scheduler"
echo "    sudo iceccd -d -s arch-orchestrator -u icecc"
elif [ "$ICECC_MODE" = "worker" ]; then
echo "  - iceccd:    Check with icemon on another machine"
fi
if [ "${OLLAMA_INSTALLED:-0}" = "1" ]; then
echo "  - Ollama:    ${OLLAMA_MODEL}"
fi
