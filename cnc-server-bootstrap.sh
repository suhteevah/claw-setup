#!/bin/bash
set -euo pipefail

# =============================================================================
# C&C Server Bootstrap — Ubuntu Server 24.04 LTS
# Central orchestrator for Claude Code agent mesh + icecream distributed builds
#
# What this sets up:
#   - Tailscale mesh VPN (secure inter-machine networking)
#   - Icecream scheduler + local worker (distributed compilation)
#   - Claude Code + AgentAPI (headless AI agent)
#   - claude-code-by-agents orchestrator (multi-agent dispatch)
#   - Ollama LLM server (if GPU detected)
#   - Model Load Optimizer plugin (intelligent model routing)
#   - OpenClaw gateway (chat + Discord + dashboard)
#   - Firewall rules for all services
#   - Systemd services for everything (auto-start on boot)
#
# Usage:
#   # On a fresh Ubuntu Server 24.04 LTS install:
#   curl -sL https://raw.githubusercontent.com/suhteevah/claw-setup/main/cnc-server-bootstrap.sh | bash
#
#   # Or download and run:
#   wget https://raw.githubusercontent.com/suhteevah/claw-setup/main/cnc-server-bootstrap.sh
#   chmod +x cnc-server-bootstrap.sh
#   sudo ./cnc-server-bootstrap.sh
#
# Requirements:
#   - Ubuntu Server 24.04 LTS (fresh install, SSH server enabled)
#   - Internet connection
#   - Anthropic API key (get one at https://console.anthropic.com)
#   - (Optional) NVIDIA GPU for local LLM inference
# =============================================================================

# ── Colors & helpers ──────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail()  { echo -e "${RED}[FAIL]${NC} $1"; }
phase() { echo -e "\n${BOLD}${YELLOW}=== $1 ===${NC}\n"; }

# ── Root check ────────────────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
    fail "This script must be run as root. Try: sudo bash $0"
    exit 1
fi

REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════╗"
echo "║     C&C Server Bootstrap                     ║"
echo "║     Claude Code Agent Mesh Orchestrator       ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Configuration prompts ─────────────────────────────────────────────────────

read -p "Tailscale hostname for this server [cnc-server]: " TS_HOSTNAME
TS_HOSTNAME="${TS_HOSTNAME:-cnc-server}"

read -p "Max compile jobs (press Enter for auto-detect): " MAX_JOBS
if [ -z "$MAX_JOBS" ]; then
    TOTAL_CORES=$(nproc)
    MAX_JOBS=$(( TOTAL_CORES > 2 ? TOTAL_CORES - 2 : 1 ))
    info "Auto-detected: ${TOTAL_CORES} cores, reserving 2 → ${MAX_JOBS} compile jobs"
fi

read -p "LAN Ollama server IP (press Enter to skip, or e.g. 192.168.10.242): " LAN_OLLAMA_IP
LAN_OLLAMA_URL=""
if [ -n "$LAN_OLLAMA_IP" ]; then
    LAN_OLLAMA_URL="http://${LAN_OLLAMA_IP}:11434"
fi

echo ""
info "Hostname: ${TS_HOSTNAME}"
info "Compile jobs: ${MAX_JOBS}"
[ -n "$LAN_OLLAMA_URL" ] && info "LAN Ollama: ${LAN_OLLAMA_URL}"
echo ""
read -p "Continue? [Y/n] " CONFIRM
if [[ "${CONFIRM,,}" == "n" ]]; then
    echo "Aborted."
    exit 0
fi


# ==============================================================================
# Phase 1: System Update + Core Dependencies
# ==============================================================================
phase "Phase 1: System Update + Core Dependencies"

export DEBIAN_FRONTEND=noninteractive

apt update
apt upgrade -y
apt install -y \
    git curl wget jq htop tmux \
    build-essential ccache clang lld \
    ripgrep fd-find \
    icecc \
    ufw \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release

ok "Core packages installed"


# ==============================================================================
# Phase 2: Node.js 20 LTS
# ==============================================================================
phase "Phase 2: Node.js 20 LTS"

if ! command -v node &>/dev/null || [ "$(node -v | cut -d. -f1 | tr -d v)" -lt 20 ]; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt install -y nodejs
fi

NODE_VER=$(node --version)
NPM_VER=$(npm --version)
ok "Node.js ${NODE_VER}, npm ${NPM_VER}"


# ==============================================================================
# Phase 3: Tailscale
# ==============================================================================
phase "Phase 3: Tailscale Mesh VPN"

if ! command -v tailscale &>/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | bash
fi

systemctl enable --now tailscaled

echo ""
echo -e "${BOLD}>>> Tailscale needs authentication.${NC}"
echo -e "    Run: ${CYAN}sudo tailscale up --hostname ${TS_HOSTNAME}${NC}"
echo "    Then follow the URL in your browser to authenticate."
echo ""
read -p "Press Enter after Tailscale is authenticated... "

TS_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
ok "Tailscale active — IP: ${TS_IP}"


# ==============================================================================
# Phase 4: Icecream Scheduler + Worker
# ==============================================================================
phase "Phase 4: Icecream Distributed Compilation"

# Configure scheduler
mkdir -p /opt/icecc-envs

# Configure worker to use localhost scheduler
if [ -f /etc/default/icecc ]; then
    sed -i 's/^#\?ICECC_SCHEDULER_HOST=.*/ICECC_SCHEDULER_HOST="localhost"/' /etc/default/icecc
    sed -i "s/^#\?ICECC_MAX_JOBS=.*/ICECC_MAX_JOBS=\"${MAX_JOBS}\"/" /etc/default/icecc
fi

# Enable services
systemctl enable --now icecc-scheduler.service 2>/dev/null || {
    warn "No systemd unit for icecc-scheduler. Starting manually."
    nohup icecc-scheduler -d -l /var/log/icecc-scheduler.log &>/dev/null &
}

for svc in iceccd icecc-daemon icecc; do
    if systemctl list-unit-files | grep -q "^${svc}.service"; then
        systemctl enable --now "${svc}.service"
        ok "Icecream worker: ${svc}.service (${MAX_JOBS} jobs)"
        break
    fi
done

# Create clang toolchain tarball for distribution
info "Creating clang toolchain tarball..."
cd /tmp
icecc-create-env --clang /usr/bin/clang /usr/bin/clang++ 2>/dev/null || true
TARBALL=$(ls -t /tmp/*.tar.gz 2>/dev/null | head -1)
if [ -n "$TARBALL" ]; then
    mv "$TARBALL" /opt/icecc-envs/x86_64-clang.tar.gz
    ok "Toolchain: /opt/icecc-envs/x86_64-clang.tar.gz"
fi


# ==============================================================================
# Phase 5: GPU Detection + NVIDIA Drivers + Ollama
# ==============================================================================
phase "Phase 5: GPU Detection + Ollama"

GPU_NAME=""
GPU_VRAM_GB=0
GPU_VENDOR=""
OLLAMA_INSTALLED=0
OLLAMA_MODEL=""

# Detect NVIDIA
if lspci 2>/dev/null | grep -qi nvidia; then
    info "NVIDIA GPU detected. Installing drivers..."
    apt install -y ubuntu-drivers-common
    ubuntu-drivers autoinstall 2>/dev/null || warn "Auto-install failed. May need manual driver install."

    # Check if nvidia-smi works (driver loaded)
    if command -v nvidia-smi &>/dev/null; then
        GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d '\n')
        GPU_VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d '\n')
        GPU_VRAM_GB=$(( GPU_VRAM_MB / 1024 ))
        GPU_VENDOR="NVIDIA"
        ok "GPU: ${GPU_NAME} — ${GPU_VRAM_GB} GB VRAM"
    else
        warn "NVIDIA GPU found but drivers not loaded. May need reboot."
        GPU_NAME=$(lspci | grep -i nvidia | head -1 | sed 's/.*: //')
        GPU_VENDOR="NVIDIA"
        # Assume at least 2GB if we can detect the card
        GPU_VRAM_GB=2
    fi
fi

# Detect AMD
if [ -z "$GPU_VENDOR" ] && lspci 2>/dev/null | grep -i "vga\|3d" | grep -qi "amd\|radeon"; then
    AMD_CARD=$(lspci | grep -i "vga\|3d" | grep -i "amd\|radeon" | grep -iv "cezanne\|renoir\|barcelo\|phoenix\|rembrandt" | head -1 || true)
    if [ -n "$AMD_CARD" ]; then
        GPU_NAME=$(echo "$AMD_CARD" | sed 's/.*: //')
        GPU_VENDOR="AMD"
        if command -v rocm-smi &>/dev/null; then
            GPU_VRAM_MB=$(rocm-smi --showmeminfo vram --json 2>/dev/null | grep -o '"Total Memory (B)":[0-9]*' | head -1 | grep -o '[0-9]*$')
            GPU_VRAM_GB=$(( GPU_VRAM_MB / 1073741824 ))
        else
            GPU_VRAM_GB=4  # conservative guess
            warn "Install rocm-smi for accurate VRAM detection"
        fi
        ok "GPU: ${GPU_NAME} — ${GPU_VRAM_GB} GB VRAM (estimated)"
    fi
fi

if [ -z "$GPU_VENDOR" ]; then
    info "No discrete GPU detected. Ollama will run CPU-only or use LAN server."
fi

# Install Ollama regardless (useful even CPU-only for small models)
if ! command -v ollama &>/dev/null; then
    info "Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
fi

systemctl enable --now ollama 2>/dev/null || {
    warn "Ollama service not found. Starting manually."
    ollama serve &>/dev/null &
    sleep 3
}

# Model selection based on VRAM
if [ "$GPU_VRAM_GB" -ge 12 ]; then
    SELECTED_MODEL="deepseek-coder-v2:16b"
    SIDECAR_MODEL="qwen2.5-coder:7b"
    info "GPU tier: Large — pulling primary + sidecar models"
elif [ "$GPU_VRAM_GB" -ge 8 ]; then
    SELECTED_MODEL="qwen2.5-coder:7b"
    SIDECAR_MODEL="deepseek-coder-v2:lite"
    info "GPU tier: Medium — pulling primary + lite sidecar"
elif [ "$GPU_VRAM_GB" -ge 4 ]; then
    SELECTED_MODEL="qwen2.5-coder:7b"
    SIDECAR_MODEL=""
    info "GPU tier: Small — pulling primary model only"
else
    SELECTED_MODEL="qwen2.5-coder:7b"
    SIDECAR_MODEL=""
    info "No GPU / low VRAM — pulling lightweight model for CPU"
fi

# Pull models
info "Pulling ${SELECTED_MODEL}... (this may take a while)"
if ollama pull "$SELECTED_MODEL" 2>/dev/null; then
    OLLAMA_INSTALLED=1
    OLLAMA_MODEL="$SELECTED_MODEL"
    ok "Primary model: ${SELECTED_MODEL}"
else
    warn "Failed to pull ${SELECTED_MODEL}"
fi

if [ -n "$SIDECAR_MODEL" ]; then
    info "Pulling sidecar: ${SIDECAR_MODEL}..."
    ollama pull "$SIDECAR_MODEL" 2>/dev/null && ok "Sidecar: ${SIDECAR_MODEL}" || warn "Failed to pull ${SIDECAR_MODEL}"
fi

# Expose Ollama to LAN (for other machines to use)
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/override.conf << 'EOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0"
EOF
systemctl daemon-reload
systemctl restart ollama
ok "Ollama exposed on 0.0.0.0:11434 (LAN accessible)"


# ==============================================================================
# Phase 6: Claude Code + AgentAPI
# ==============================================================================
phase "Phase 6: Claude Code + AgentAPI"

# Install Claude Code
npm install -g @anthropic-ai/claude-code
CLAUDE_VER=$(claude --version 2>/dev/null || echo "unknown")
ok "Claude Code: ${CLAUDE_VER}"

# Install AgentAPI
ARCH_HW=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
curl -fsSL \
    "https://github.com/coder/agentapi/releases/latest/download/agentapi-linux-${ARCH_HW}" \
    -o /usr/local/bin/agentapi
chmod +x /usr/local/bin/agentapi
ok "AgentAPI installed"

# Create service user
if ! id claude-agent &>/dev/null; then
    useradd -r -m -s /bin/bash claude-agent
    ok "User 'claude-agent' created"
fi


# ==============================================================================
# Phase 7: API Key
# ==============================================================================
phase "Phase 7: Anthropic API Key"

mkdir -p /etc/claude
chmod 700 /etc/claude

if [ ! -f /etc/claude/api-key ]; then
    echo ""
    echo -e "${BOLD}You need an Anthropic API key.${NC}"
    echo "  1. Go to: https://console.anthropic.com/"
    echo "  2. Create or sign into your account"
    echo "  3. Go to API Keys → Create new key"
    echo ""
    read -sp "Paste your Anthropic API key: " API_KEY
    echo
    echo "ANTHROPIC_API_KEY=${API_KEY}" > /etc/claude/api-key
    chmod 600 /etc/claude/api-key
    chown claude-agent:claude-agent /etc/claude/api-key
    ok "API key saved to /etc/claude/api-key"
else
    ok "API key already configured"
fi

# Authenticate Claude Code for the agent user
echo ""
echo -e "${BOLD}>>> Authenticate Claude Code for the agent user:${NC}"
echo -e "    Run: ${CYAN}sudo -u claude-agent claude auth login${NC}"
echo ""
read -p "Press Enter after authenticating... "


# ==============================================================================
# Phase 8: Deno + claude-code-by-agents Orchestrator
# ==============================================================================
phase "Phase 8: Orchestrator (claude-code-by-agents)"

# Install Deno for the agent user
if ! sudo -u claude-agent bash -c 'command -v deno' &>/dev/null; then
    sudo -u claude-agent bash -c 'curl -fsSL https://deno.land/install.sh | sh'
    echo 'export PATH="$HOME/.deno/bin:$PATH"' | sudo -u claude-agent tee -a /home/claude-agent/.bashrc > /dev/null
fi
ok "Deno installed for claude-agent"

# Clone orchestrator
if [ ! -d /opt/claude-code-by-agents ]; then
    git clone https://github.com/baryhuang/claude-code-by-agents.git /opt/claude-code-by-agents
    chown -R claude-agent:claude-agent /opt/claude-code-by-agents
    cd /opt/claude-code-by-agents/backend
    sudo -u claude-agent /home/claude-agent/.deno/bin/deno install
    ok "Orchestrator installed"
else
    ok "Orchestrator already present"
fi


# ==============================================================================
# Phase 9: Model Load Optimizer Plugin
# ==============================================================================
phase "Phase 9: Model Load Optimizer Plugin"

OPENCLAW_DIR="/home/claude-agent/.openclaw"
PLUGIN_DIR="$OPENCLAW_DIR/plugins/model-load-optimizer"

sudo -u claude-agent mkdir -p "$OPENCLAW_DIR/plugins"

if [ ! -d "$PLUGIN_DIR" ]; then
    info "Cloning model-load-optimizer..."
    sudo -u claude-agent git clone https://github.com/suhteevah/model-load-optimizer.git "$PLUGIN_DIR" 2>/dev/null
fi

if [ -f "$PLUGIN_DIR/package.json" ]; then
    info "Building plugin..."
    cd "$PLUGIN_DIR"
    sudo -u claude-agent npm install --silent 2>/dev/null
    sudo -u claude-agent npx tsc 2>/dev/null
    ok "Model Load Optimizer built"
else
    warn "Plugin not found. Clone manually: git clone https://github.com/suhteevah/model-load-optimizer.git $PLUGIN_DIR"
fi

# Determine best Ollama host
OPTIMIZER_OLLAMA_HOST="http://localhost:11434"
if [ "$OLLAMA_INSTALLED" != "1" ] && [ -n "$LAN_OLLAMA_URL" ]; then
    OPTIMIZER_OLLAMA_HOST="$LAN_OLLAMA_URL"
fi

# Set up models for config
PRIMARY_MODEL="${OLLAMA_MODEL:-qwen2.5-coder:7b}"
SIDECAR_CFG_MODEL="${SIDECAR_MODEL:-}"

# Sidecar entries (only if we have one)
SIDECAR_MODELS_JSON=""
SIDECAR_FALLBACK_JSON=""
SIDECAR_OPT_JSON='"sidecarModel": "",'
if [ -n "$SIDECAR_CFG_MODEL" ]; then
    SIDECAR_MODELS_JSON="\"ollama/${SIDECAR_CFG_MODEL}\": { \"alias\": \"sidecar\" },"
    SIDECAR_FALLBACK_JSON="\"ollama/${SIDECAR_CFG_MODEL}\","
    SIDECAR_OPT_JSON="\"sidecarModel\": \"${SIDECAR_CFG_MODEL}\","
fi

# Write openclaw.json
sudo -u claude-agent tee "$OPENCLAW_DIR/openclaw.json" > /dev/null << OCEOF
{
  "env": { "OLLAMA_API_KEY": "ollama-local" },
  "auth": {
    "profiles": {
      "anthropic:default": { "provider": "anthropic", "mode": "api_key" },
      "ollama:default": { "provider": "ollama", "mode": "api_key" }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "ollama/${PRIMARY_MODEL}",
        "fallbacks": [${SIDECAR_FALLBACK_JSON} "anthropic/claude-sonnet-4-5"]
      },
      "models": {
        "ollama/${PRIMARY_MODEL}": { "alias": "primary" },
        ${SIDECAR_MODELS_JSON}
        "anthropic/claude-sonnet-4-5": { "alias": "sonnet" }
      },
      "maxConcurrent": 4,
      "subagents": { "maxConcurrent": 8 }
    }
  },
  "tools": {
    "agentToAgent": { "enabled": true, "allow": ["exec"] },
    "exec": { "security": "full", "ask": "off" }
  },
  "gateway": {
    "port": 18789,
    "mode": "local",
    "bind": "0.0.0.0",
    "auth": { "mode": "token" },
    "tailscale": { "mode": "off" }
  },
  "plugins": {
    "load": {
      "paths": ["${PLUGIN_DIR}"]
    },
    "entries": {
      "model-load-optimizer": {
        "enabled": true,
        "config": {
          "ollamaHost": "${OPTIMIZER_OLLAMA_HOST}",
          "primaryModel": "${PRIMARY_MODEL}",
          ${SIDECAR_OPT_JSON}
          "fallbackModel": "anthropic/claude-sonnet-4-5",
          "keepAliveMinutes": 30,
          "gpuMemoryThreshold": 0.85,
          "healthCheckIntervalSec": 30,
          "preloadOnStart": true,
          "autoRoute": true,
          "dashboardEnabled": true
        }
      }
    }
  }
}
OCEOF

ok "OpenClaw config: $OPENCLAW_DIR/openclaw.json"


# ==============================================================================
# Phase 10: Systemd Services
# ==============================================================================
phase "Phase 10: Systemd Services"

# AgentAPI service
cat > /etc/systemd/system/claude-agentapi.service << 'EOF'
[Unit]
Description=Claude Code AgentAPI Server
After=network-online.target tailscaled.service ollama.service
Wants=network-online.target

[Service]
Type=simple
User=claude-agent
WorkingDirectory=/home/claude-agent
EnvironmentFile=/etc/claude/api-key
ExecStart=/usr/local/bin/agentapi server --type claude -- claude \
  --dangerously-skip-permissions \
  --max-budget-usd 10.00
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=claude-agentapi

[Install]
WantedBy=multi-user.target
EOF

# Orchestrator service
cat > /etc/systemd/system/claude-orchestrator.service << 'EOF'
[Unit]
Description=Claude Code Orchestrator (claude-code-by-agents)
After=network-online.target claude-agentapi.service tailscaled.service
Wants=network-online.target

[Service]
Type=simple
User=claude-agent
WorkingDirectory=/opt/claude-code-by-agents/backend
EnvironmentFile=/etc/claude/api-key
Environment="DENO_DIR=/home/claude-agent/.deno"
Environment="PATH=/home/claude-agent/.deno/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=/home/claude-agent/.deno/bin/deno task dev
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=claude-orchestrator

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now claude-agentapi.service
systemctl enable --now claude-orchestrator.service

ok "Services installed and started"


# ==============================================================================
# Phase 11: Firewall
# ==============================================================================
phase "Phase 11: Firewall Configuration"

# Allow SSH
ufw allow 22/tcp comment "SSH"

# Tailscale — always allow
ufw allow in on tailscale0 comment "Tailscale mesh"

# Icecream ports
ufw allow 8765/tcp comment "Icecream scheduler"
ufw allow 8766/tcp comment "Icecream telnet monitor"
ufw allow 10245/tcp comment "Icecream worker"

# Ollama (LAN)
ufw allow 11434/tcp comment "Ollama API"

# AgentAPI
ufw allow 3284/tcp comment "AgentAPI"

# OpenClaw gateway
ufw allow 18789/tcp comment "OpenClaw gateway"

# Orchestrator web UI
ufw allow 8080/tcp comment "Orchestrator web UI"

# Enable firewall
ufw --force enable

ok "Firewall configured and enabled"


# ==============================================================================
# Phase 12: Verification
# ==============================================================================
phase "Phase 12: Verification"

echo ""
echo -e "${BOLD}Service Status:${NC}"

check_service() {
    local name=$1
    local status
    status=$(systemctl is-active "$name" 2>/dev/null || echo "not found")
    if [ "$status" = "active" ]; then
        echo -e "  ${GREEN}●${NC} ${name}: active"
    else
        echo -e "  ${RED}●${NC} ${name}: ${status}"
    fi
}

check_service "tailscaled"
check_service "icecc-scheduler"
check_service "iceccd"
check_service "ollama"
check_service "claude-agentapi"
check_service "claude-orchestrator"

echo ""
echo -e "${BOLD}Network:${NC}"
TS_IP=$(tailscale ip -4 2>/dev/null || echo "not connected")
echo "  Tailscale IP: ${TS_IP}"
echo "  Hostname:     ${TS_HOSTNAME}"

echo ""
echo -e "${BOLD}Models:${NC}"
if [ "$OLLAMA_INSTALLED" = "1" ]; then
    echo "  Primary:  ollama/${PRIMARY_MODEL}"
    [ -n "$SIDECAR_CFG_MODEL" ] && echo "  Sidecar:  ollama/${SIDECAR_CFG_MODEL}"
fi
[ -n "$LAN_OLLAMA_URL" ] && echo "  LAN:      ${LAN_OLLAMA_URL}"
echo "  Fallback: anthropic/claude-sonnet-4-5"

echo ""
echo -e "${BOLD}GPU:${NC}"
if [ -n "$GPU_VENDOR" ]; then
    echo "  ${GPU_VENDOR} ${GPU_NAME} — ${GPU_VRAM_GB} GB VRAM"
else
    echo "  No discrete GPU (CPU-only inference)"
fi


# ==============================================================================
# Summary
# ==============================================================================
echo ""
echo -e "${BOLD}${GREEN}"
echo "╔══════════════════════════════════════════════╗"
echo "║     C&C Server is ONLINE                     ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "${BOLD}Endpoints:${NC}"
echo "  Orchestrator UI:  http://${TS_HOSTNAME}:8080"
echo "  OpenClaw:         http://${TS_HOSTNAME}:18789"
echo "  AgentAPI:         http://${TS_HOSTNAME}:3284"
echo "  Ollama API:       http://${TS_HOSTNAME}:11434"
echo "  Icecream Monitor: telnet ${TS_HOSTNAME} 8766"
echo ""

echo -e "${BOLD}Next steps:${NC}"
echo "  1. On other machines, point icecream workers to: ${TS_HOSTNAME}"
echo "  2. Deploy agent bootstraps on fleet machines:"
echo "     Windows: irm https://raw.githubusercontent.com/suhteevah/claw-setup/main/swoop-windows-bootstrap.ps1 | iex"
echo "     Mac:     bash <(curl -sL https://raw.githubusercontent.com/suhteevah/claw-setup/main/fcp-mac-bootstrap.sh)"
echo "     Pi:      bash <(curl -sL https://raw.githubusercontent.com/suhteevah/claw-setup/main/fcp-pi-bootstrap.sh)"
echo "  3. Verify mesh: tailscale status"
echo "  4. Monitor compilation: icemon (GUI) or telnet localhost 8766"
echo ""

echo -e "${BOLD}Management commands:${NC}"
echo "  journalctl -u claude-agentapi -f     # Agent logs"
echo "  journalctl -u claude-orchestrator -f  # Orchestrator logs"
echo "  journalctl -u ollama -f               # Ollama logs"
echo "  systemctl restart claude-agentapi     # Restart agent"
echo "  ollama list                            # Show pulled models"
echo "  tailscale status                       # Mesh status"
echo ""

echo -e "${YELLOW}NOTE: If you installed NVIDIA drivers, a reboot may be required.${NC}"
echo -e "${YELLOW}After reboot, all services will auto-start.${NC}"
echo ""
