#!/bin/bash
set -euo pipefail

# =============================================================================
# C&C Server Bootstrap — openSUSE MicroOS
# Central orchestrator for Claude Code agent mesh + icecream distributed builds
#
# Why MicroOS:
#   - Atomic/immutable OS (btrfs transactional updates, auto-rollback)
#   - Security-hardened (AppArmor enforcing, read-only root, TPM2 FDE)
#   - openSUSE invented icecream — first-class native support
#   - Auto-updates that can't brick the system (snapshot + rollback)
#   - Zero Canonical/Ubuntu involvement
#
# What this sets up:
#   - Tailscale mesh VPN (secure inter-machine networking)
#   - Icecream scheduler + local worker (distributed compilation)
#   - Podman toolbox for mutable dev workloads (Node.js, Deno, Claude Code)
#   - Claude Code + AgentAPI (headless AI agent)
#   - claude-code-by-agents orchestrator (multi-agent dispatch)
#   - Ollama LLM server (if GPU detected, otherwise uses LAN Ollama)
#   - Model Load Optimizer plugin (intelligent model routing)
#   - OpenClaw gateway (chat + Discord + dashboard)
#   - Firewalld rules for all services
#   - Systemd services for everything (auto-start on boot)
#
# Usage:
#   # On a fresh openSUSE MicroOS install (or from live disk):
#   curl -sL https://raw.githubusercontent.com/suhteevah/claw-setup/main/cnc-server-bootstrap.sh | bash
#
#   # Or download and run:
#   curl -O https://raw.githubusercontent.com/suhteevah/claw-setup/main/cnc-server-bootstrap.sh
#   chmod +x cnc-server-bootstrap.sh
#   sudo ./cnc-server-bootstrap.sh
#
# Requirements:
#   - openSUSE MicroOS (fresh install, SSH enabled)
#   - Internet connection
#   - Anthropic API key (get one at https://console.anthropic.com)
#   - (Optional) Discrete GPU for local LLM inference (defaults to LAN Ollama at 192.168.10.242)
#
# Post-install:
#   MicroOS is atomic — most package installs require a reboot to take effect.
#   This script handles the reboot coordination and can be re-run safely.
# =============================================================================

# ── Colors & helpers ──────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[  OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail()  { echo -e "${RED}[FAIL]${NC} $1"; }
phase() { echo -e "\n${BOLD}${YELLOW}=== $1 ===${NC}\n"; }

# ── Root check ────────────────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
    fail "This script must be run as root. Try: sudo bash $0"
    exit 1
fi

# ── OS detection ──────────────────────────────────────────────────────────────

if [ ! -f /etc/os-release ]; then
    fail "Cannot detect OS. Is this openSUSE MicroOS?"
    exit 1
fi

source /etc/os-release

if [[ "${ID:-}" != "opensuse-microos" && "${ID:-}" != "opensuse-tumbleweed-microos" ]]; then
    warn "Expected openSUSE MicroOS but found: ${PRETTY_NAME:-unknown}"
    echo ""
    echo "This script is designed for openSUSE MicroOS."
    echo "It may work on Tumbleweed but is untested."
    read -p "Continue anyway? [y/N] " FORCE_CONTINUE
    if [[ "${FORCE_CONTINUE,,}" != "y" ]]; then
        echo "Aborted."
        exit 1
    fi
fi

# ── State file (for re-run after reboot) ──────────────────────────────────────

STATE_FILE="/root/.cnc-bootstrap-state"
CURRENT_PHASE=1

if [ -f "$STATE_FILE" ]; then
    source "$STATE_FILE"
    info "Resuming from Phase ${CURRENT_PHASE} (previous run detected)"
fi

save_state() {
    cat > "$STATE_FILE" << EOF
CURRENT_PHASE=$1
TS_HOSTNAME="${TS_HOSTNAME:-cnc-server}"
MAX_JOBS="${MAX_JOBS:-}"
LAN_OLLAMA_IP="${LAN_OLLAMA_IP:-}"
LAN_OLLAMA_URL="${LAN_OLLAMA_URL:-}"
GPU_NAME="${GPU_NAME:-}"
GPU_VRAM_GB="${GPU_VRAM_GB:-0}"
GPU_VENDOR="${GPU_VENDOR:-}"
OLLAMA_INSTALLED="${OLLAMA_INSTALLED:-0}"
OLLAMA_MODEL="${OLLAMA_MODEL:-}"
SELECTED_MODEL="${SELECTED_MODEL:-}"
SIDECAR_MODEL="${SIDECAR_MODEL:-}"
NEEDS_REBOOT="${NEEDS_REBOOT:-0}"
EOF
}

echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║     C&C Server Bootstrap — openSUSE MicroOS          ║"
echo "║     Claude Code Agent Mesh Orchestrator               ║"
echo "║     Atomic · Hardened · Zero Canonical                ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Configuration prompts (only on first run) ─────────────────────────────────

if [ "$CURRENT_PHASE" -le 1 ]; then
    read -p "Tailscale hostname for this server [cnc-server]: " TS_HOSTNAME
    TS_HOSTNAME="${TS_HOSTNAME:-cnc-server}"

    read -p "Max compile jobs (press Enter for auto-detect): " MAX_JOBS
    if [ -z "$MAX_JOBS" ]; then
        TOTAL_CORES=$(nproc)
        MAX_JOBS=$(( TOTAL_CORES > 2 ? TOTAL_CORES - 2 : 1 ))
        info "Auto-detected: ${TOTAL_CORES} cores, reserving 2 → ${MAX_JOBS} compile jobs"
    fi

    read -p "LAN Ollama server IP [192.168.10.242]: " LAN_OLLAMA_IP
    LAN_OLLAMA_IP="${LAN_OLLAMA_IP:-192.168.10.242}"
    LAN_OLLAMA_URL="http://${LAN_OLLAMA_IP}:11434"

    GPU_NAME=""
    GPU_VRAM_GB=0
    GPU_VENDOR=""
    OLLAMA_INSTALLED=0
    OLLAMA_MODEL=""
    SELECTED_MODEL=""
    SIDECAR_MODEL=""
    NEEDS_REBOOT=0

    echo ""
    info "Hostname:     ${TS_HOSTNAME}"
    info "Compile jobs: ${MAX_JOBS}"
    [ -n "$LAN_OLLAMA_URL" ] && info "LAN Ollama:   ${LAN_OLLAMA_URL}"
    echo ""
    read -p "Continue? [Y/n] " CONFIRM
    if [[ "${CONFIRM,,}" == "n" ]]; then
        echo "Aborted."
        exit 0
    fi
fi


# ==============================================================================
# Phase 1: Transactional Update — Core Packages
# ==============================================================================
if [ "$CURRENT_PHASE" -le 1 ]; then
    phase "Phase 1: Transactional Update — Core Packages"

    info "Installing core packages via transactional-update..."
    info "This creates a new btrfs snapshot — takes a minute."

    transactional-update --non-interactive pkg install \
        git curl wget jq htop tmux \
        gcc gcc-c++ make ccache clang lld \
        ripgrep \
        icecream icecream-clang-wrappers \
        podman podman-docker distrobox \
        nodejs20 npm20 \
        tailscale \
        firewalld

    ok "Packages staged in new snapshot"
    warn "A reboot is needed to activate the new snapshot."
    NEEDS_REBOOT=1

    save_state 2
    echo ""
    echo -e "${BOLD}${YELLOW}>>> REBOOT REQUIRED <<<${NC}"
    echo "Run: sudo reboot"
    echo "Then re-run this script: sudo bash cnc-server-bootstrap.sh"
    echo ""
    exit 0
fi


# ==============================================================================
# Phase 2: Verify packages + Tailscale
# ==============================================================================
if [ "$CURRENT_PHASE" -le 2 ]; then
    phase "Phase 2: Verify Packages + Tailscale"

    # Verify the transactional update took effect
    for cmd in git clang iceccd node tailscale podman; do
        if command -v "$cmd" &>/dev/null; then
            ok "$cmd: $(command -v $cmd)"
        else
            fail "$cmd not found! The transactional-update may not have applied."
            fail "Try: sudo transactional-update --non-interactive pkg install $cmd && sudo reboot"
            exit 1
        fi
    done

    NODE_VER=$(node --version 2>/dev/null || echo "unknown")
    ok "Node.js ${NODE_VER}"

    # Tailscale
    systemctl enable --now tailscaled

    echo ""
    echo -e "${BOLD}>>> Tailscale needs authentication.${NC}"
    echo -e "    Run: ${CYAN}sudo tailscale up --hostname ${TS_HOSTNAME}${NC}"
    echo "    Then follow the URL in your browser to authenticate."
    echo ""
    read -p "Press Enter after Tailscale is authenticated... "

    TS_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
    ok "Tailscale active — IP: ${TS_IP}"

    save_state 3
fi


# ==============================================================================
# Phase 3: Icecream Scheduler + Worker
# ==============================================================================
if [ "$CURRENT_PHASE" -le 3 ]; then
    phase "Phase 3: Icecream Distributed Compilation"

    mkdir -p /opt/icecc-envs

    # Configure worker
    if [ -f /etc/sysconfig/icecream ]; then
        sed -i 's/^ICECREAM_SCHEDULER_HOST=.*/ICECREAM_SCHEDULER_HOST="localhost"/' /etc/sysconfig/icecream
        sed -i "s/^ICECREAM_MAX_JOBS=.*/ICECREAM_MAX_JOBS=\"${MAX_JOBS}\"/" /etc/sysconfig/icecream
    fi

    # Enable services (MicroOS uses the same systemd services as Tumbleweed)
    systemctl enable --now icecc-scheduler.service 2>/dev/null || {
        warn "icecc-scheduler.service not found. Starting manually."
        nohup icecc-scheduler -d -l /var/log/icecc-scheduler.log &>/dev/null &
    }

    systemctl enable --now iceccd.service 2>/dev/null || {
        warn "iceccd.service not found. Trying alternatives."
        for svc in icecc-daemon icecc; do
            if systemctl list-unit-files | grep -q "^${svc}.service"; then
                systemctl enable --now "${svc}.service"
                break
            fi
        done
    }

    ok "Icecream scheduler + worker running (${MAX_JOBS} jobs)"

    # Create clang toolchain tarball
    info "Creating clang toolchain tarball..."
    cd /tmp
    icecc-create-env --clang /usr/bin/clang /usr/bin/clang++ 2>/dev/null || true
    TARBALL=$(ls -t /tmp/*.tar.gz 2>/dev/null | head -1)
    if [ -n "$TARBALL" ]; then
        mv "$TARBALL" /opt/icecc-envs/x86_64-clang.tar.gz
        ok "Toolchain: /opt/icecc-envs/x86_64-clang.tar.gz"
    fi

    save_state 4
fi


# ==============================================================================
# Phase 4: GPU Detection + NVIDIA Drivers + Ollama
# ==============================================================================
if [ "$CURRENT_PHASE" -le 4 ]; then
    phase "Phase 4: GPU Detection + Ollama"

    # Detect NVIDIA
    if lspci 2>/dev/null | grep -qi nvidia; then
        info "NVIDIA GPU detected."

        if command -v nvidia-smi &>/dev/null; then
            GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d '\n')
            GPU_VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d '\n')
            GPU_VRAM_GB=$(( GPU_VRAM_MB / 1024 ))
            GPU_VENDOR="NVIDIA"
            ok "GPU: ${GPU_NAME} — ${GPU_VRAM_GB} GB VRAM"
        else
            warn "NVIDIA GPU detected but no driver loaded."
            echo ""
            echo "  To install NVIDIA drivers on MicroOS:"
            echo "    sudo transactional-update --non-interactive pkg install nvidia-driver-G06-signed"
            echo "    sudo reboot"
            echo "    Then re-run this script."
            echo ""
            GPU_NAME=$(lspci | grep -i nvidia | head -1 | sed 's/.*: //')
            GPU_VENDOR="NVIDIA"
            GPU_VRAM_GB=2  # conservative guess
            read -p "Continue without NVIDIA drivers? [Y/n] " SKIP_NV
            if [[ "${SKIP_NV,,}" == "n" ]]; then
                save_state 4
                echo "Install the drivers, reboot, and re-run this script."
                exit 0
            fi
        fi
    fi

    # Detect AMD
    if [ -z "$GPU_VENDOR" ] && lspci 2>/dev/null | grep -i "vga\|3d" | grep -qi "amd\|radeon"; then
        AMD_CARD=$(lspci | grep -i "vga\|3d" | grep -i "amd\|radeon" | grep -iv "cezanne\|renoir\|barcelo\|phoenix\|rembrandt" | head -1 || true)
        if [ -n "$AMD_CARD" ]; then
            GPU_NAME=$(echo "$AMD_CARD" | sed 's/.*: //')
            GPU_VENDOR="AMD"
            GPU_VRAM_GB=4  # conservative
            ok "GPU: ${GPU_NAME} — ~${GPU_VRAM_GB} GB VRAM (estimated)"
        fi
    fi

    if [ -z "$GPU_VENDOR" ]; then
        info "No discrete GPU detected (Intel onboard only)."
        info "This machine is best as an orchestrator, not an inference node."
        echo ""

        if [ -n "$LAN_OLLAMA_URL" ]; then
            ok "Will use LAN Ollama at ${LAN_OLLAMA_URL} for inference"
            SELECTED_MODEL="qwen2.5-coder:7b"
            SIDECAR_MODEL=""
            OLLAMA_INSTALLED=0
            OLLAMA_MODEL=""
        else
            echo "  No discrete GPU and no LAN Ollama configured."
            echo "  Options:"
            echo "    1) Skip local Ollama — use only remote API (anthropic/claude-sonnet-4-5)"
            echo "    2) Install Ollama anyway (CPU-only, will be slow)"
            echo "    3) Specify a LAN Ollama server now"
            echo ""
            read -p "  Choice [1/2/3]: " OLLAMA_CHOICE
            case "${OLLAMA_CHOICE}" in
                2)
                    info "Installing Ollama for CPU-only inference..."
                    INSTALL_LOCAL_OLLAMA=1
                    ;;
                3)
                    read -p "  LAN Ollama IP (e.g. 192.168.10.242): " LAN_OLLAMA_IP
                    LAN_OLLAMA_URL="http://${LAN_OLLAMA_IP}:11434"
                    ok "Will use LAN Ollama at ${LAN_OLLAMA_URL}"
                    SELECTED_MODEL="qwen2.5-coder:7b"
                    SIDECAR_MODEL=""
                    OLLAMA_INSTALLED=0
                    OLLAMA_MODEL=""
                    INSTALL_LOCAL_OLLAMA=0
                    ;;
                *)
                    info "Skipping local Ollama. Will use anthropic/claude-sonnet-4-5 as primary."
                    SELECTED_MODEL=""
                    SIDECAR_MODEL=""
                    OLLAMA_INSTALLED=0
                    OLLAMA_MODEL=""
                    INSTALL_LOCAL_OLLAMA=0
                    ;;
            esac
        fi
    else
        INSTALL_LOCAL_OLLAMA=1
    fi

    # Install Ollama if we have a GPU or user explicitly opted in
    if [ "${INSTALL_LOCAL_OLLAMA:-1}" = "1" ]; then
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
            info "GPU tier: Large — primary + sidecar"
        elif [ "$GPU_VRAM_GB" -ge 8 ]; then
            SELECTED_MODEL="qwen2.5-coder:7b"
            SIDECAR_MODEL="deepseek-coder-v2:lite"
            info "GPU tier: Medium — primary + lite sidecar"
        elif [ "$GPU_VRAM_GB" -ge 4 ]; then
            SELECTED_MODEL="qwen2.5-coder:7b"
            SIDECAR_MODEL=""
            info "GPU tier: Small — primary only"
        else
            SELECTED_MODEL="qwen2.5-coder:7b"
            SIDECAR_MODEL=""
            info "CPU-only — lightweight model"
        fi

        info "Pulling ${SELECTED_MODEL}... (may take a while)"
        if ollama pull "$SELECTED_MODEL" 2>/dev/null; then
            OLLAMA_INSTALLED=1
            OLLAMA_MODEL="$SELECTED_MODEL"
            ok "Primary: ${SELECTED_MODEL}"
        else
            warn "Failed to pull ${SELECTED_MODEL}"
        fi

        if [ -n "$SIDECAR_MODEL" ]; then
            info "Pulling sidecar: ${SIDECAR_MODEL}..."
            ollama pull "$SIDECAR_MODEL" 2>/dev/null && ok "Sidecar: ${SIDECAR_MODEL}" || warn "Failed to pull sidecar"
        fi

        # Expose Ollama to LAN
        mkdir -p /etc/systemd/system/ollama.service.d
        cat > /etc/systemd/system/ollama.service.d/override.conf << 'EOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0"
EOF
        systemctl daemon-reload
        systemctl restart ollama
        ok "Ollama exposed on 0.0.0.0:11434 (LAN accessible)"
    fi

    save_state 5
fi


# ==============================================================================
# Phase 5: Claude Code + AgentAPI (via npm in overlay)
# ==============================================================================
if [ "$CURRENT_PHASE" -le 5 ]; then
    phase "Phase 5: Claude Code + AgentAPI"

    # On MicroOS, /usr/local is writable. npm global installs go there.
    npm install -g @anthropic-ai/claude-code 2>/dev/null || {
        # If /usr is read-only, install to /usr/local manually
        warn "npm global install failed on read-only root. Installing to /usr/local."
        mkdir -p /usr/local/lib/node_modules
        npm install --prefix /usr/local -g @anthropic-ai/claude-code
    }
    CLAUDE_VER=$(claude --version 2>/dev/null || echo "installed")
    ok "Claude Code: ${CLAUDE_VER}"

    # AgentAPI binary
    ARCH_HW=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    curl -fsSL \
        "https://github.com/coder/agentapi/releases/latest/download/agentapi-linux-${ARCH_HW}" \
        -o /usr/local/bin/agentapi
    chmod +x /usr/local/bin/agentapi
    ok "AgentAPI installed"

    # Service user
    if ! id claude-agent &>/dev/null; then
        useradd -r -m -s /bin/bash claude-agent
        ok "User 'claude-agent' created"
    fi

    save_state 6
fi


# ==============================================================================
# Phase 6: API Key
# ==============================================================================
if [ "$CURRENT_PHASE" -le 6 ]; then
    phase "Phase 6: Anthropic API Key"

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

    echo ""
    echo -e "${BOLD}>>> Authenticate Claude Code:${NC}"
    echo -e "    Run: ${CYAN}sudo -u claude-agent claude auth login${NC}"
    echo ""
    read -p "Press Enter after authenticating... "

    save_state 7
fi


# ==============================================================================
# Phase 7: Deno + Orchestrator
# ==============================================================================
if [ "$CURRENT_PHASE" -le 7 ]; then
    phase "Phase 7: Orchestrator (claude-code-by-agents)"

    if ! sudo -u claude-agent bash -c 'command -v deno' &>/dev/null; then
        sudo -u claude-agent bash -c 'curl -fsSL https://deno.land/install.sh | sh'
        echo 'export PATH="$HOME/.deno/bin:$PATH"' | sudo -u claude-agent tee -a /home/claude-agent/.bashrc > /dev/null
    fi
    ok "Deno installed"

    if [ ! -d /opt/claude-code-by-agents ]; then
        git clone https://github.com/baryhuang/claude-code-by-agents.git /opt/claude-code-by-agents
        chown -R claude-agent:claude-agent /opt/claude-code-by-agents
        cd /opt/claude-code-by-agents/backend
        sudo -u claude-agent /home/claude-agent/.deno/bin/deno install
        ok "Orchestrator installed"
    else
        ok "Orchestrator already present"
    fi

    save_state 8
fi


# ==============================================================================
# Phase 8: Model Load Optimizer Plugin + OpenClaw Config
# ==============================================================================
if [ "$CURRENT_PHASE" -le 8 ]; then
    phase "Phase 8: Model Load Optimizer + OpenClaw Config"

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
        warn "Plugin clone failed. Install manually later."
    fi

    # Determine best Ollama endpoint and model config
    OPTIMIZER_OLLAMA_HOST="http://localhost:11434"
    if [ "$OLLAMA_INSTALLED" != "1" ] && [ -n "$LAN_OLLAMA_URL" ]; then
        OPTIMIZER_OLLAMA_HOST="$LAN_OLLAMA_URL"
    fi

    # Build OpenClaw config based on what's available
    if [ "$OLLAMA_INSTALLED" = "1" ] || [ -n "$LAN_OLLAMA_URL" ]; then
        # Ollama available (local or LAN) — use it as primary
        PRIMARY_MODEL="${OLLAMA_MODEL:-qwen2.5-coder:7b}"
        PRIMARY_REF="ollama/${PRIMARY_MODEL}"
        SIDECAR_CFG_MODEL="${SIDECAR_MODEL:-}"

        SIDECAR_MODELS_JSON=""
        SIDECAR_FALLBACK_JSON=""
        SIDECAR_OPT_JSON='"sidecarModel": "",'
        OPTIMIZER_PRIMARY="${PRIMARY_MODEL}"
        OPTIMIZER_PRELOAD="true"

        if [ -n "$SIDECAR_CFG_MODEL" ]; then
            SIDECAR_MODELS_JSON="\"ollama/${SIDECAR_CFG_MODEL}\": { \"alias\": \"sidecar\" },"
            SIDECAR_FALLBACK_JSON="\"ollama/${SIDECAR_CFG_MODEL}\","
            SIDECAR_OPT_JSON="\"sidecarModel\": \"${SIDECAR_CFG_MODEL}\","
        fi

        OLLAMA_ENV_JSON='"OLLAMA_API_KEY": "ollama-local"'
        OLLAMA_AUTH_JSON='"ollama:default": { "provider": "ollama", "mode": "api_key" }'
    else
        # No Ollama anywhere — pure Anthropic API
        PRIMARY_REF="anthropic/claude-sonnet-4-5"
        SIDECAR_MODELS_JSON=""
        SIDECAR_FALLBACK_JSON=""
        SIDECAR_OPT_JSON='"sidecarModel": "",'
        OPTIMIZER_PRIMARY=""
        OPTIMIZER_PRELOAD="false"
        OLLAMA_ENV_JSON=""
        OLLAMA_AUTH_JSON=""
        info "No Ollama configured — using Anthropic API as primary"
    fi

    sudo -u claude-agent tee "$OPENCLAW_DIR/openclaw.json" > /dev/null << OCEOF
{
  "env": { ${OLLAMA_ENV_JSON} },
  "auth": {
    "profiles": {
      "anthropic:default": { "provider": "anthropic", "mode": "api_key" }$([ -n "$OLLAMA_AUTH_JSON" ] && echo ", $OLLAMA_AUTH_JSON")
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "${PRIMARY_REF}",
        "fallbacks": [${SIDECAR_FALLBACK_JSON} "anthropic/claude-sonnet-4-5"]
      },
      "models": {
        "${PRIMARY_REF}": { "alias": "primary" },
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
          "primaryModel": "${OPTIMIZER_PRIMARY}",
          ${SIDECAR_OPT_JSON}
          "fallbackModel": "anthropic/claude-sonnet-4-5",
          "keepAliveMinutes": 30,
          "gpuMemoryThreshold": 0.85,
          "healthCheckIntervalSec": 30,
          "preloadOnStart": ${OPTIMIZER_PRELOAD},
          "autoRoute": true,
          "dashboardEnabled": true
        }
      }
    }
  }
}
OCEOF

    ok "OpenClaw config written"
    save_state 9
fi


# ==============================================================================
# Phase 9: Systemd Services
# ==============================================================================
if [ "$CURRENT_PHASE" -le 9 ]; then
    phase "Phase 9: Systemd Services"

        # Only depend on ollama.service if it's installed locally
    OLLAMA_AFTER=""
    if systemctl list-unit-files ollama.service &>/dev/null 2>&1; then
        OLLAMA_AFTER=" ollama.service"
    fi

    cat > /etc/systemd/system/claude-agentapi.service << EOF
[Unit]
Description=Claude Code AgentAPI Server
After=network-online.target tailscaled.service${OLLAMA_AFTER}
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
    save_state 10
fi


# ==============================================================================
# Phase 10: Firewalld
# ==============================================================================
if [ "$CURRENT_PHASE" -le 10 ]; then
    phase "Phase 10: Firewall (firewalld)"

    systemctl enable --now firewalld

    # SSH (should be open already)
    firewall-cmd --permanent --add-service=ssh

    # Tailscale interface — trust it fully
    firewall-cmd --permanent --zone=trusted --add-interface=tailscale0 2>/dev/null || true

    # Icecream
    firewall-cmd --permanent --add-port=8765/tcp   # scheduler
    firewall-cmd --permanent --add-port=8766/tcp   # telnet monitor
    firewall-cmd --permanent --add-port=10245/tcp  # worker

    # Ollama (only if running locally)
    if systemctl list-unit-files ollama.service &>/dev/null 2>&1; then
        firewall-cmd --permanent --add-port=11434/tcp
    fi

    # AgentAPI
    firewall-cmd --permanent --add-port=3284/tcp

    # OpenClaw gateway
    firewall-cmd --permanent --add-port=18789/tcp

    # Orchestrator web UI
    firewall-cmd --permanent --add-port=8080/tcp

    firewall-cmd --reload

    ok "Firewalld configured"
    save_state 11
fi


# ==============================================================================
# Phase 11: Verification
# ==============================================================================
phase "Phase 11: Verification"

echo ""
echo -e "${BOLD}Service Status:${NC}"

check_svc() {
    local name=$1
    local st
    st=$(systemctl is-active "$name" 2>/dev/null || echo "not found")
    if [ "$st" = "active" ]; then
        echo -e "  ${GREEN}●${NC} ${name}: active"
    else
        echo -e "  ${RED}●${NC} ${name}: ${st}"
    fi
}

check_svc "tailscaled"
check_svc "icecc-scheduler"
check_svc "iceccd"
systemctl list-unit-files ollama.service &>/dev/null 2>&1 && check_svc "ollama" || echo -e "  ${YELLOW}○${NC} ollama: not installed (using LAN: ${LAN_OLLAMA_URL:-none})"
check_svc "claude-agentapi"
check_svc "claude-orchestrator"
check_svc "firewalld"

echo ""
echo -e "${BOLD}Network:${NC}"
TS_IP=$(tailscale ip -4 2>/dev/null || echo "not connected")
echo "  Tailscale IP: ${TS_IP}"
echo "  Hostname:     ${TS_HOSTNAME}"

echo ""
echo -e "${BOLD}Models:${NC}"
echo "  Primary:  ${PRIMARY_REF:-anthropic/claude-sonnet-4-5}"
if [ "$OLLAMA_INSTALLED" = "1" ]; then
    [ -n "${SIDECAR_MODEL:-}" ] && echo "  Sidecar:  ollama/${SIDECAR_MODEL}"
    echo "  Source:   Local Ollama (localhost:11434)"
elif [ -n "${LAN_OLLAMA_URL:-}" ]; then
    echo "  Source:   LAN Ollama (${LAN_OLLAMA_URL})"
fi
echo "  Fallback: anthropic/claude-sonnet-4-5"

echo ""
echo -e "${BOLD}GPU:${NC}"
if [ -n "${GPU_VENDOR:-}" ]; then
    echo "  ${GPU_VENDOR} ${GPU_NAME} — ${GPU_VRAM_GB} GB VRAM"
else
    echo "  No discrete GPU (CPU-only inference)"
fi

echo ""
echo -e "${BOLD}OS:${NC}"
echo "  ${PRETTY_NAME:-openSUSE MicroOS}"
echo "  Kernel: $(uname -r)"
echo "  Atomic: btrfs transactional-update"

# Clean state file — bootstrap complete
rm -f "$STATE_FILE"


# ==============================================================================
# Summary
# ==============================================================================
echo ""
echo -e "${BOLD}${GREEN}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║     C&C Server is ONLINE                              ║"
echo "║     openSUSE MicroOS · Atomic · Hardened               ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "${BOLD}Endpoints:${NC}"
echo "  Orchestrator UI:  http://${TS_HOSTNAME}:8080"
echo "  OpenClaw:         http://${TS_HOSTNAME}:18789"
echo "  AgentAPI:         http://${TS_HOSTNAME}:3284"
if systemctl list-unit-files ollama.service &>/dev/null 2>&1; then
    echo "  Ollama API:       http://${TS_HOSTNAME}:11434"
else
    echo "  Ollama API:       ${LAN_OLLAMA_URL:-not configured} (remote)"
fi
echo "  Icecream Monitor: telnet ${TS_HOSTNAME} 8766"
echo ""

echo -e "${BOLD}Deploy agents on fleet machines:${NC}"
echo "  Windows: irm https://raw.githubusercontent.com/suhteevah/claw-setup/main/swoop-windows-bootstrap.ps1 | iex"
echo "  Mac:     bash <(curl -sL https://raw.githubusercontent.com/suhteevah/claw-setup/main/fcp-mac-bootstrap.sh)"
echo "  Pi:      bash <(curl -sL https://raw.githubusercontent.com/suhteevah/claw-setup/main/fcp-pi-bootstrap.sh)"
echo "  Linux:   bash <(curl -sL https://raw.githubusercontent.com/suhteevah/claw-setup/main/dr-paper-bootstrap.sh)"
echo ""

echo -e "${BOLD}MicroOS management:${NC}"
echo "  transactional-update               # Apply pending updates (needs reboot)"
echo "  transactional-update rollback       # Rollback last update"
echo "  snapper list                        # List btrfs snapshots"
echo "  snapper rollback <N>                # Rollback to snapshot N"
echo ""

echo -e "${BOLD}Service management:${NC}"
echo "  journalctl -u claude-agentapi -f     # Agent logs"
echo "  journalctl -u claude-orchestrator -f  # Orchestrator logs"
if systemctl list-unit-files ollama.service &>/dev/null 2>&1; then
    echo "  journalctl -u ollama -f               # Ollama logs"
    echo "  ollama list                            # Show pulled models"
fi
echo "  systemctl restart claude-agentapi     # Restart agent"
echo "  tailscale status                       # Mesh status"
echo ""

echo -e "${BOLD}Security:${NC}"
echo "  AppArmor: enforcing (default)"
echo "  Root FS:  read-only (btrfs snapshot)"
echo "  Updates:  atomic (transactional-update + auto-reboot)"
echo ""
