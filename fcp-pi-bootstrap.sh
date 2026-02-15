#!/bin/bash
set -euo pipefail

# =============================================================================
# FCP (First Choice Plastics) -- Raspberry Pi Bootstrap
# Self-contained: curl this and run. All dependencies embedded inline.
#
# Usage: bash <(curl -sL <url>) fcp-pi
#   or:  bash fcp-pi-bootstrap.sh fcp-pi
# =============================================================================

HOSTNAME="${1:-fcp-pi}"

ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ]; then
  echo "ERROR: 32-bit OS detected (${ARCH}). Claude Code requires 64-bit."
  echo "Reflash with 64-bit Raspberry Pi OS and re-run."
  exit 1
fi

echo "============================================"
echo "  First Choice Plastics -- Pi Bootstrap"
echo "  Setting up: ${HOSTNAME}"
echo "============================================"

# === Phase 1: System Update ===
echo ""
echo "=== Phase 1: System Update ==="
sudo apt update && sudo apt upgrade -y
sudo apt install -y git ripgrep build-essential ccache clang curl jq

# === Phase 2: Node.js 20 ===
echo "=== Phase 2: Node.js 20 ==="
if ! command -v node &>/dev/null || [ "$(node -v | cut -d. -f1 | tr -d v)" -lt 20 ]; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y nodejs
fi
echo "Node.js: $(node --version)"

# === Phase 3: Tailscale ===
echo "=== Phase 3: Tailscale ==="
command -v tailscale &>/dev/null || (curl -fsSL https://tailscale.com/install.sh | sh)
sudo systemctl enable --now tailscaled
echo ">>> Run: sudo tailscale up --hostname ${HOSTNAME}"
read -p "Press Enter after authenticated..."

# === Phase 4: Icecream Worker ===
echo "=== Phase 4: Icecream Worker ==="
sudo apt install -y icecc

# Check if fcp-laptop scheduler is reachable
ICECC_SCHEDULER="fcp-laptop"
ICECC_MODE="worker"
echo ""
echo "Checking if icecream scheduler (${ICECC_SCHEDULER}) is reachable..."
if command -v tailscale &>/dev/null && tailscale ping --timeout 3s "${ICECC_SCHEDULER}" &>/dev/null 2>&1; then
  echo "  [OK] Scheduler reachable at ${ICECC_SCHEDULER}"
else
  echo "  [WARN] Scheduler at ${ICECC_SCHEDULER} is not reachable."
  echo ""
  echo "  Options:"
  echo "    1) Run this Pi as a TEMPORARY SCHEDULER"
  echo "    2) Skip icecream for now (configure later)"
  echo "    3) Enter a different scheduler hostname"
  echo ""
  read -p "  Choose [1/2/3]: " ICECC_CHOICE
  case "${ICECC_CHOICE}" in
    1)
      ICECC_MODE="scheduler"
      echo "  Will run as temporary scheduler + worker."
      ;;
    3)
      read -p "  Enter scheduler hostname or IP: " CUSTOM_SCHEDULER
      if [ -n "${CUSTOM_SCHEDULER:-}" ]; then
        ICECC_SCHEDULER="$CUSTOM_SCHEDULER"
      fi
      ;;
    *)
      ICECC_MODE="skip"
      echo "  Skipping icecream."
      ;;
  esac
fi

if [ "$ICECC_MODE" = "scheduler" ]; then
  # Start scheduler on this Pi
  nohup icecc-scheduler -d &>/dev/null &
  echo "  icecc-scheduler started"
  ICECC_SCHEDULER="localhost"
fi

if [ "$ICECC_MODE" != "skip" ]; then
  ICECC_CONF="/etc/default/icecc"
  if [ -f "$ICECC_CONF" ]; then
    sudo sed -i "s/^#\?ICECC_SCHEDULER_HOST=.*/ICECC_SCHEDULER_HOST=\"${ICECC_SCHEDULER}\"/" "$ICECC_CONF"
  else
    echo "ICECC_SCHEDULER_HOST=\"${ICECC_SCHEDULER}\"" | sudo tee "$ICECC_CONF"
  fi
  for svc in icecc-daemon iceccd icecc; do
    if systemctl list-unit-files | grep -q "^${svc}.service"; then
      sudo systemctl enable --now "${svc}.service"
      break
    fi
  done
fi

# === Phase 5: Claude Code ===
echo "=== Phase 5: Claude Code ==="
export DISABLE_AUTOUPDATER=1
sudo npm install -g @anthropic-ai/claude-code

# === Phase 6: AgentAPI ===
echo "=== Phase 6: AgentAPI ==="
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH_HW=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
sudo curl -fsSL \
  "https://github.com/coder/agentapi/releases/latest/download/agentapi-${OS}-${ARCH_HW}" \
  -o /usr/local/bin/agentapi
sudo chmod +x /usr/local/bin/agentapi

# === Phase 7: Agent User + API Key ===
echo "=== Phase 7: Agent User + API Key ==="
if ! id claude-agent &>/dev/null; then
  sudo useradd -r -m -s /bin/bash claude-agent
fi

echo ""
echo "You need an Anthropic API key: https://console.anthropic.com/"
echo ""
sudo mkdir -p /etc/claude && sudo chmod 700 /etc/claude
if [ ! -f /etc/claude/api-key ]; then
  read -sp "Enter Anthropic API key: " API_KEY
  echo
  echo "ANTHROPIC_API_KEY=${API_KEY}" | sudo tee /etc/claude/api-key > /dev/null
  sudo chmod 600 /etc/claude/api-key
  sudo chown claude-agent:claude-agent /etc/claude/api-key
  echo "API key saved"
else
  echo "API key already configured"
fi

# === Phase 8: Authenticate ===
echo "=== Phase 8: Authenticate Claude Code ==="
echo ">>> Run: sudo -u claude-agent claude auth login"
read -p "Press Enter after authenticating..."

# === Phase 9: Systemd Service (inline) ===
echo "=== Phase 9: Install AgentAPI Service ==="

cat > /tmp/claude-agentapi.service << 'EOF'
[Unit]
Description=Claude Code AgentAPI (FCP Pi)
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
User=claude-agent
WorkingDirectory=/home/claude-agent
EnvironmentFile=/etc/claude/api-key
ExecStart=/usr/local/bin/agentapi server --type claude -- claude \
  --dangerously-skip-permissions \
  --max-budget-usd 5.00
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=claude-agentapi

[Install]
WantedBy=multi-user.target
EOF

sudo mv /tmp/claude-agentapi.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now claude-agentapi.service
echo "AgentAPI service installed and started"

# === Phase 10: GPU Detection ===
echo "=== Phase 10: GPU Check ==="
# Pis typically have no discrete GPU -- check anyway
GPU_FOUND=0
if command -v lspci &>/dev/null; then
  NV_PCI=$(lspci 2>/dev/null | grep -i "vga\|3d\|display" | grep -iv "intel" | head -1 || true)
  if [ -n "$NV_PCI" ]; then
    echo "  Found: ${NV_PCI}"
    GPU_FOUND=1
  fi
fi
if [ "$GPU_FOUND" -eq 0 ]; then
  echo "  No discrete GPU detected (expected for Pi). Skipping Ollama."
fi

# === Phase 11: OpenClaw Config ===
echo "=== Phase 11: OpenClaw Config ==="

OPENCLAW_DIR="/home/claude-agent/.openclaw"
sudo -u claude-agent mkdir -p "$OPENCLAW_DIR"

# Pi has no local Ollama - use remote fallback only
sudo -u claude-agent tee "$OPENCLAW_DIR/openclaw.json" > /dev/null << 'OCEOF'
{
  "auth": {
    "profiles": {
      "anthropic:default": { "provider": "anthropic", "mode": "api_key" }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "anthropic/claude-sonnet-4-5",
        "fallbacks": []
      },
      "models": {
        "anthropic/claude-sonnet-4-5": { "alias": "sonnet" }
      }
    }
  }
}
OCEOF

echo "  OpenClaw config written (remote-only, no local Ollama)"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "============================================"
echo "  FCP Raspberry Pi ONLINE"
echo "  Hostname: ${HOSTNAME}"
echo "  Arch: $(uname -m)"
echo "  RAM: $(free -h | awk '/^Mem:/{print $2}')"
if [ "$ICECC_MODE" = "scheduler" ]; then
echo "  Icecream: TEMPORARY SCHEDULER"
elif [ "$ICECC_MODE" = "worker" ]; then
echo "  Icecream: Worker -> ${ICECC_SCHEDULER}"
else
echo "  Icecream: Skipped"
fi
echo "============================================"
echo ""
echo "Verify from the laptop:"
echo "  curl http://${HOSTNAME}:3284/status"
echo "  tailscale ping ${HOSTNAME}"
