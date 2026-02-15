#!/bin/bash
set -euo pipefail

# =============================================================================
# Raspberry Pi Setup
# Run this on: Each Raspberry Pi (must be 64-bit / aarch64)
# Role: Headless Claude Code agent (root access) + icecream build worker
# =============================================================================

HOSTNAME="${1:-}"
if [ -z "$HOSTNAME" ]; then
  echo "Usage: $0 <hostname>"
  echo "  e.g.: $0 rpi1"
  echo "  e.g.: $0 rpi2"
  exit 1
fi

# Verify 64-bit
ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ]; then
  echo "ERROR: This Pi is running a 32-bit OS (${ARCH})."
  echo "Claude Code requires 64-bit (aarch64)."
  echo "Reflash with 64-bit Raspberry Pi OS and re-run this script."
  exit 1
fi

echo "=== Setting up ${HOSTNAME} (aarch64) as headless Claude Code agent ==="

echo "=== Phase 1: System Update ==="
sudo apt update && sudo apt upgrade -y

echo "=== Phase 2: Install Dependencies ==="
sudo apt install -y git ripgrep build-essential ccache clang curl jq

echo "=== Phase 3: Install Node.js 20 ==="
if ! command -v node &>/dev/null || [ "$(node -v | cut -d. -f1 | tr -d v)" -lt 20 ]; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y nodejs
fi
echo "Node.js: $(node --version)"

echo "=== Phase 4: Tailscale ==="
if ! command -v tailscale &>/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
sudo systemctl enable --now tailscaled
echo ">>> Run: sudo tailscale up --hostname ${HOSTNAME}"
echo ">>> Authenticate in your browser."
read -p "Press Enter after Tailscale is authenticated..."

echo "=== Phase 5: Icecream Worker ==="
sudo apt install -y icecc

# Configure scheduler host
ICECC_CONF="/etc/default/icecc"
if [ -f "$ICECC_CONF" ]; then
  sudo sed -i 's/^#\?ICECC_SCHEDULER_HOST=.*/ICECC_SCHEDULER_HOST="arch-orchestrator"/' "$ICECC_CONF"
else
  echo 'ICECC_SCHEDULER_HOST="arch-orchestrator"' | sudo tee "$ICECC_CONF"
fi

# Determine service name (varies by distro)
if systemctl list-unit-files | grep -q "icecc-daemon"; then
  ICECC_SERVICE="icecc-daemon.service"
elif systemctl list-unit-files | grep -q "iceccd"; then
  ICECC_SERVICE="iceccd.service"
else
  ICECC_SERVICE="icecc.service"
fi
sudo systemctl enable --now "$ICECC_SERVICE" || echo "WARNING: Could not start ${ICECC_SERVICE}. Check manually."

# Create aarch64 toolchain tarball
echo "Creating aarch64 Clang toolchain tarball..."
sudo mkdir -p /opt/icecc-envs
cd /tmp
icecc-create-env --clang /usr/bin/clang /usr/bin/clang++ 2>/dev/null || true
TARBALL=$(ls -t /tmp/*.tar.gz 2>/dev/null | head -1)
if [ -n "$TARBALL" ]; then
  sudo mv "$TARBALL" /opt/icecc-envs/aarch64-clang.tar.gz
  echo "Toolchain tarball: /opt/icecc-envs/aarch64-clang.tar.gz"
  echo ">>> Copy this to the orchestrator:"
  echo "    scp /opt/icecc-envs/aarch64-clang.tar.gz arch-orchestrator:/opt/icecc-envs/"
fi

echo "=== Phase 6: Claude Code ==="
export DISABLE_AUTOUPDATER=1
sudo npm install -g @anthropic-ai/claude-code
claude --version

echo "=== Phase 7: AgentAPI ==="
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH_HW=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
sudo curl -fsSL \
  "https://github.com/coder/agentapi/releases/latest/download/agentapi-${OS}-${ARCH_HW}" \
  -o /usr/local/bin/agentapi
sudo chmod +x /usr/local/bin/agentapi

echo "=== Phase 8: Create claude-agent user ==="
if ! id claude-agent &>/dev/null; then
  sudo useradd -r -m -s /bin/bash claude-agent
fi

echo "=== Phase 9: API Key Setup ==="
sudo mkdir -p /etc/claude
sudo chmod 700 /etc/claude
if [ ! -f /etc/claude/api-key ]; then
  read -sp "Enter your Anthropic API key: " API_KEY
  echo
  echo "ANTHROPIC_API_KEY=${API_KEY}" | sudo tee /etc/claude/api-key > /dev/null
  sudo chmod 600 /etc/claude/api-key
  sudo chown claude-agent:claude-agent /etc/claude/api-key
fi

echo "=== Phase 10: Authenticate Claude Code ==="
echo ">>> Run: sudo -u claude-agent claude auth login"
read -p "Press Enter after authenticating..."

echo "=== Phase 11: Install Service File ==="
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="${SCRIPT_DIR}/../service-files/systemd"

if [ -f "${SERVICE_DIR}/claude-agentapi.service" ]; then
  sudo cp "${SERVICE_DIR}/claude-agentapi.service" /etc/systemd/system/
  # Adjust budget for Pi (lower than orchestrator)
  sudo sed -i 's/--max-budget-usd 10.00/--max-budget-usd 5.00/' /etc/systemd/system/claude-agentapi.service
  # Set memory limit for Pi
  if ! grep -q "MemoryMax" /etc/systemd/system/claude-agentapi.service; then
    sudo sed -i '/\[Service\]/a MemoryMax=512M' /etc/systemd/system/claude-agentapi.service
  fi
  sudo systemctl daemon-reload
  sudo systemctl enable --now claude-agentapi.service
  echo "AgentAPI service started"
fi

echo "=== GPU Detection + Ollama ==="
SHARED_MODULE="${SCRIPT_DIR}/../shared/ollama-gpu-detect.sh"
if [ -f "$SHARED_MODULE" ]; then
  source "$SHARED_MODULE"
  install_ollama_with_model
else
  echo "No discrete GPU expected on Pi. Skipping Ollama."
fi

echo ""
echo "=========================================="
echo "  Raspberry Pi Setup Complete             "
echo "  Hostname: ${HOSTNAME}                   "
echo "  Architecture: $(uname -m)               "
echo "  RAM: $(free -h | awk '/^Mem:/{print $2}')"
echo "=========================================="
echo ""
echo "Verify:"
echo "  - Tailscale:  tailscale status"
echo "  - AgentAPI:   curl http://localhost:3284/status"
echo "  - iceccd:     systemctl status ${ICECC_SERVICE}"
if [ "$OLLAMA_INSTALLED" = "1" ]; then
echo "  - Ollama:     ${OLLAMA_MODEL}"
fi
