#!/bin/bash
set -euo pipefail

# =============================================================================
# Dr Paper -- Linux Orchestrator Bootstrap
# Self-contained: curl this and run. All dependencies embedded inline.
#
# Usage: bash <(curl -sL <url>) dr-paper
#   or:  bash dr-paper-bootstrap.sh dr-paper
#
# Role: Central orchestrator + icecream scheduler + build worker
#       Hosts claude-code-by-agents for multi-agent dispatch
#       Connects to existing LAN Ollama (default: 192.168.10.242)
# =============================================================================

HOSTNAME="${1:-dr-paper}"

echo "============================================"
echo "  Dr Paper -- Orchestrator Bootstrap"
echo "  Hostname: ${HOSTNAME}"
echo "============================================"

# === Phase 1: System Update ===
echo ""
echo "=== Phase 1: System Update ==="
if command -v pacman &>/dev/null; then
  PKG="pacman"
  sudo pacman -Syu --noconfirm
elif command -v apt &>/dev/null; then
  PKG="apt"
  sudo apt update && sudo apt upgrade -y
elif command -v dnf &>/dev/null; then
  PKG="dnf"
  sudo dnf upgrade -y
else
  echo "ERROR: Unsupported package manager."
  exit 1
fi

# === Phase 2: Dependencies ===
echo "=== Phase 2: Dependencies ==="
case $PKG in
  pacman)
    sudo pacman -S --noconfirm --needed \
      nodejs npm git ripgrep base-devel ccache clang tailscale icecream curl jq
    ;;
  apt)
    sudo apt install -y git ripgrep build-essential ccache clang curl jq
    if ! command -v node &>/dev/null || [ "$(node -v | cut -d. -f1 | tr -d v)" -lt 20 ]; then
      curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
      sudo apt-get install -y nodejs
    fi
    if ! command -v tailscale &>/dev/null; then
      curl -fsSL https://tailscale.com/install.sh | sh
    fi
    sudo apt install -y icecc
    ;;
  dnf)
    sudo dnf install -y nodejs npm git ripgrep gcc gcc-c++ ccache clang curl jq
    if ! command -v tailscale &>/dev/null; then
      curl -fsSL https://tailscale.com/install.sh | sh
    fi
    sudo dnf install -y icecream || echo "WARNING: Install icecream manually"
    ;;
esac

# === Phase 3: Tailscale ===
echo "=== Phase 3: Tailscale ==="
sudo systemctl enable --now tailscaled
echo ">>> Run: sudo tailscale up --hostname ${HOSTNAME}"
echo ">>> Authenticate in your browser."
read -p "Press Enter after Tailscale is authenticated..."

# === Phase 4: Icecream Scheduler + Worker ===
echo "=== Phase 4: Icecream Scheduler + Worker ==="
sudo mkdir -p /opt/icecc-envs

# Start scheduler
if systemctl list-unit-files | grep -q icecc-scheduler; then
  sudo systemctl enable --now icecc-scheduler.service
else
  echo "Starting icecc-scheduler manually..."
  nohup icecc-scheduler -d &>/dev/null &
  echo "WARNING: No systemd unit for icecc-scheduler. Consider creating one."
fi

# Configure worker to point to localhost (this is the scheduler)
if [ -f /etc/conf.d/icecream ]; then
  sudo sed -i 's/^#\?ICECC_SCHEDULER_HOST=.*/ICECC_SCHEDULER_HOST="localhost"/' /etc/conf.d/icecream
elif [ -f /etc/default/icecc ]; then
  sudo sed -i 's/^#\?ICECC_SCHEDULER_HOST=.*/ICECC_SCHEDULER_HOST="localhost"/' /etc/default/icecc
fi

for svc in iceccd icecc-daemon icecc; do
  if systemctl list-unit-files | grep -q "^${svc}.service"; then
    sudo systemctl enable --now "${svc}.service"
    break
  fi
done

# Create toolchain tarball
echo "Creating toolchain tarball..."
cd /tmp
icecc-create-env --clang /usr/bin/clang /usr/bin/clang++ 2>/dev/null || true
TARBALL=$(ls -t /tmp/*.tar.gz 2>/dev/null | head -1)
if [ -n "$TARBALL" ]; then
  sudo mv "$TARBALL" /opt/icecc-envs/x86_64-clang.tar.gz
  echo "Toolchain: /opt/icecc-envs/x86_64-clang.tar.gz"
fi

# === Phase 5: Claude Code ===
echo "=== Phase 5: Claude Code ==="
npm install -g @anthropic-ai/claude-code
claude --version

# === Phase 6: AgentAPI ===
echo "=== Phase 6: AgentAPI ==="
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH_HW=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
sudo curl -fsSL \
  "https://github.com/coder/agentapi/releases/latest/download/agentapi-${OS}-${ARCH_HW}" \
  -o /usr/local/bin/agentapi
sudo chmod +x /usr/local/bin/agentapi

# === Phase 7: Agent User ===
echo "=== Phase 7: Agent User ==="
if ! id claude-agent &>/dev/null; then
  sudo useradd -r -m -s /bin/bash claude-agent
fi

# === Phase 8: API Key ===
echo "=== Phase 8: API Key Setup ==="
echo ""
echo "You need an Anthropic API key."
echo "Get one at: https://console.anthropic.com/"
echo ""
sudo mkdir -p /etc/claude
sudo chmod 700 /etc/claude
if [ ! -f /etc/claude/api-key ]; then
  read -sp "Enter your Anthropic API key: " API_KEY
  echo
  echo "ANTHROPIC_API_KEY=${API_KEY}" | sudo tee /etc/claude/api-key > /dev/null
  sudo chmod 600 /etc/claude/api-key
  sudo chown claude-agent:claude-agent /etc/claude/api-key
  echo "API key saved to /etc/claude/api-key"
else
  echo "API key file already exists"
fi

# === Phase 9: Systemd Services (inline) ===
echo "=== Phase 9: Install Service Files ==="

# AgentAPI service
cat > /tmp/claude-agentapi.service << 'EOF'
[Unit]
Description=Claude Code AgentAPI (Dr Paper fleet)
After=network-online.target tailscaled.service
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
cat > /tmp/claude-orchestrator.service << 'EOF'
[Unit]
Description=Dr Paper Orchestrator (claude-code-by-agents)
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
SyslogIdentifier=dr-paper

[Install]
WantedBy=multi-user.target
EOF

sudo mv /tmp/claude-agentapi.service /etc/systemd/system/
sudo mv /tmp/claude-orchestrator.service /etc/systemd/system/
sudo systemctl daemon-reload

# === Phase 10: Authenticate Claude Code ===
echo "=== Phase 10: Authenticate Claude Code ==="
echo ">>> Run: sudo -u claude-agent claude auth login"
echo ">>> Authenticate in your browser."
read -p "Press Enter after authenticating..."

# === Phase 11: Orchestrator (claude-code-by-agents) ===
echo "=== Phase 11: Install Orchestrator ==="
if ! command -v deno &>/dev/null; then
  curl -fsSL https://deno.land/install.sh | sudo -u claude-agent sh
  echo 'export PATH="/home/claude-agent/.deno/bin:$PATH"' | sudo -u claude-agent tee -a /home/claude-agent/.bashrc > /dev/null
fi

if [ ! -d /opt/claude-code-by-agents ]; then
  sudo git clone https://github.com/baryhuang/claude-code-by-agents.git /opt/claude-code-by-agents
  sudo chown -R claude-agent:claude-agent /opt/claude-code-by-agents
  cd /opt/claude-code-by-agents/backend
  sudo -u claude-agent /home/claude-agent/.deno/bin/deno install
fi

# === Phase 12: GPU Detection + Local Ollama (inline) ===
echo "=== Phase 12: GPU Detection + Local Ollama ==="

OLLAMA_INSTALLED=0
OLLAMA_MODEL=""
GPU_NAME=""
GPU_VRAM_GB=0
GPU_VENDOR=""

# --- GPU Detection (Linux, inline) ---
_detect_gpu_linux() {
    local best_vram=0 best_name="" best_vendor=""

    # NVIDIA via nvidia-smi
    if command -v nvidia-smi &>/dev/null; then
        local nv_name nv_vram_mib
        nv_name=$(nvidia-smi --query-gpu=name --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d '\n')
        nv_vram_mib=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d '\n')
        if [ -n "$nv_vram_mib" ] && [ "$nv_vram_mib" -gt 0 ] 2>/dev/null; then
            local nv_vram_gb=$(( nv_vram_mib / 1024 ))
            echo "  [NVIDIA] ${nv_name} -- ${nv_vram_gb} GB VRAM"
            if [ "$nv_vram_gb" -gt "$best_vram" ]; then
                best_vram=$nv_vram_gb; best_name="$nv_name"; best_vendor="NVIDIA"
            fi
        fi
    fi

    # AMD via rocm-smi
    if command -v rocm-smi &>/dev/null; then
        local amd_vram_mib
        amd_vram_mib=$(rocm-smi --showmeminfo vram --json 2>/dev/null | grep -o '"Total Memory (B)":[0-9]*' | head -1 | grep -o '[0-9]*$')
        local amd_name
        amd_name=$(rocm-smi --showproductname 2>/dev/null | grep "Card Series" | head -1 | sed 's/.*: *//')
        if [ -n "$amd_vram_mib" ] && [ "$amd_vram_mib" -gt 0 ] 2>/dev/null; then
            local amd_vram_gb=$(( amd_vram_mib / 1073741824 ))
            echo "  [AMD] ${amd_name:-AMD GPU} -- ${amd_vram_gb} GB VRAM"
            if [ "$amd_vram_gb" -gt "$best_vram" ]; then
                best_vram=$amd_vram_gb; best_name="${amd_name:-AMD GPU}"; best_vendor="AMD"
            fi
        fi
    fi

    # Fallback: lspci
    if [ "$best_vram" -eq 0 ] && command -v lspci &>/dev/null; then
        local nv_pci
        nv_pci=$(lspci | grep -i "vga\|3d\|display" | grep -i nvidia | head -1 || true)
        if [ -n "$nv_pci" ]; then
            local card_name=$(echo "$nv_pci" | sed 's/.*: //')
            echo "  [NVIDIA] ${card_name} (VRAM unknown -- install drivers)"
            best_vram=2; best_name="$card_name"; best_vendor="NVIDIA"
        fi

        local amd_pci
        amd_pci=$(lspci | grep -i "vga\|3d\|display" | grep -i "amd\|radeon\|ati" | grep -iv "cezanne\|renoir\|barcelo\|phoenix\|rembrandt\|raphael" | head -1 || true)
        if [ -n "$amd_pci" ] && [ "$best_vram" -eq 0 ]; then
            local card_name=$(echo "$amd_pci" | sed 's/.*: //')
            echo "  [AMD] ${card_name} (VRAM unknown -- install rocm-smi)"
            best_vram=2; best_name="$card_name"; best_vendor="AMD"
        fi
    fi

    if [ -z "$best_vendor" ]; then
        local intel_gpu
        intel_gpu=$(lspci 2>/dev/null | grep -i "vga\|3d\|display" | grep -i intel | head -1 || true)
        if [ -n "$intel_gpu" ]; then
            echo "  [SKIP] $(echo "$intel_gpu" | sed 's/.*: //') (integrated GPU)"
        fi
    fi

    GPU_NAME="$best_name"; GPU_VRAM_GB=$best_vram; GPU_VENDOR="$best_vendor"
}

_detect_gpu_linux

if [ -z "$GPU_NAME" ] || [ "$GPU_VRAM_GB" -lt 2 ]; then
    if [ -n "$GPU_NAME" ]; then
        echo "  GPU found (${GPU_NAME}) but VRAM too low (${GPU_VRAM_GB} GB)."
    else
        echo "  No discrete GPU detected."
    fi
    echo "  Skipping local Ollama installation."
else
    echo "  Best GPU: ${GPU_VENDOR} ${GPU_NAME} -- ${GPU_VRAM_GB} GB VRAM"

    # Tiered model selection
    if [ "$GPU_VRAM_GB" -ge 12 ]; then
        SELECTED_MODEL="deepseek-coder-v2:16b"; SELECTED_TIER="Large"
    elif [ "$GPU_VRAM_GB" -ge 8 ]; then
        SELECTED_MODEL="deepseek-coder-v2:lite"; SELECTED_TIER="Medium"
    elif [ "$GPU_VRAM_GB" -ge 4 ]; then
        SELECTED_MODEL="deepseek-coder:6.7b"; SELECTED_TIER="Medium-Small"
    elif [ "$GPU_VRAM_GB" -ge 2 ]; then
        SELECTED_MODEL="qwen2.5-coder:1.5b"; SELECTED_TIER="Small"
    else
        SELECTED_MODEL=""
    fi

    if [ -n "${SELECTED_MODEL:-}" ]; then
        echo "  Selected: ${SELECTED_MODEL} (${SELECTED_TIER})"

        if ! command -v ollama &>/dev/null; then
            curl -fsSL https://ollama.com/install.sh | sh
        fi

        if command -v ollama &>/dev/null; then
            if [ "$(uname -s)" = "Linux" ] && command -v systemctl &>/dev/null; then
                sudo systemctl enable --now ollama 2>/dev/null || ollama serve &>/dev/null &
            else
                ollama serve &>/dev/null &
            fi
            sleep 3

            echo "  Pulling ${SELECTED_MODEL}... (this may take a while)"
            if ollama pull "$SELECTED_MODEL"; then
                OLLAMA_INSTALLED=1
                OLLAMA_MODEL="$SELECTED_MODEL"
                echo "  Model ready!"
            fi
        fi
    fi
fi

# === Phase 12b: LAN Ollama Configuration ===
echo ""
echo "=== Phase 12b: Existing LAN Ollama ==="
echo ""
echo "Dr Paper's network has an existing Ollama server."
echo ""
echo "  Default: 192.168.10.242 (press Enter to accept)"
echo ""
echo "  Options:"
echo "    - Press Enter for 192.168.10.242"
echo "    - Tailscale hostname (e.g., 'swoops-ollama-server')"
echo "    - Different LAN IP"
echo "    - 'skip' to configure later"
echo ""
read -p "Ollama server hostname/IP [192.168.10.242]: " OLLAMA_LAN_HOST
OLLAMA_LAN_HOST="${OLLAMA_LAN_HOST:-192.168.10.242}"
LAN_OLLAMA_REACHABLE=0

if [ -n "$OLLAMA_LAN_HOST" ] && [ "$OLLAMA_LAN_HOST" != "skip" ]; then
  OLLAMA_LAN_PORT=11434
  OLLAMA_LAN_URL="http://${OLLAMA_LAN_HOST}:${OLLAMA_LAN_PORT}"

  echo ""
  echo "Testing connection to ${OLLAMA_LAN_URL}..."
  if curl -s --connect-timeout 5 "${OLLAMA_LAN_URL}/api/tags" &>/dev/null; then
    echo "  [OK] Connected! Listing available models:"
    curl -s "${OLLAMA_LAN_URL}/api/tags" | jq -r '.models[]?.name // empty' 2>/dev/null | while read -r model; do
      echo "    - ${model}"
    done
    LAN_OLLAMA_REACHABLE=1
  else
    echo "  [FAIL] Could not connect to ${OLLAMA_LAN_URL}"
    echo ""
    echo "  To fix on the Ollama server:"
    echo "    export OLLAMA_HOST=0.0.0.0"
    echo "    sudo systemctl restart ollama"
    echo ""
    read -p "Fix it now and press Enter to re-test, or type 'skip': " RETRY
    if [ "$RETRY" != "skip" ]; then
      if curl -s --connect-timeout 5 "${OLLAMA_LAN_URL}/api/tags" &>/dev/null; then
        echo "  [OK] Connected!"
        LAN_OLLAMA_REACHABLE=1
      else
        echo "  [FAIL] Still can't connect. Configure later."
      fi
    fi
  fi

  # Save LAN Ollama config
  if [ "$LAN_OLLAMA_REACHABLE" = "1" ]; then
    sudo mkdir -p /etc/claude
    echo "OLLAMA_LAN_URL=${OLLAMA_LAN_URL}" | sudo tee /etc/claude/ollama-lan.conf > /dev/null
    echo "OLLAMA_LAN_HOST=${OLLAMA_LAN_HOST}" | sudo tee -a /etc/claude/ollama-lan.conf > /dev/null
    sudo chmod 644 /etc/claude/ollama-lan.conf
    echo ""
    echo "  LAN Ollama configured: ${OLLAMA_LAN_URL}"
    echo "  Config saved to /etc/claude/ollama-lan.conf"
  fi
else
  echo "  Skipping LAN Ollama. Configure later with:"
  echo "    /etc/claude/ollama-lan.conf"
fi

# === Phase 12c: OpenClaw + Model Load Optimizer ===
echo "=== Phase 12c: OpenClaw + Model Load Optimizer ==="

OPENCLAW_DIR="/home/claude-agent/.openclaw"
PLUGIN_DIR="$OPENCLAW_DIR/plugins/model-load-optimizer"

sudo -u claude-agent mkdir -p "$OPENCLAW_DIR/plugins"

if [ ! -d "$PLUGIN_DIR" ]; then
    echo "  Cloning model-load-optimizer..."
    sudo -u claude-agent git clone https://github.com/suhteevah/model-load-optimizer.git "$PLUGIN_DIR" 2>/dev/null
    if [ ! -f "$PLUGIN_DIR/package.json" ]; then
        echo "  WARNING: Clone failed. Create $PLUGIN_DIR manually and retry."
    fi
fi

if [ -f "$PLUGIN_DIR/package.json" ]; then
    echo "  Building model-load-optimizer..."
    cd "$PLUGIN_DIR"
    sudo -u claude-agent npm install --silent 2>/dev/null
    sudo -u claude-agent npm run build 2>/dev/null
    echo "  Plugin built."
fi

# Determine best Ollama endpoint
OPTIMIZER_OLLAMA_HOST="http://localhost:11434"
if [ "$OLLAMA_INSTALLED" != "1" ] && [ "$LAN_OLLAMA_REACHABLE" = "1" ]; then
    OPTIMIZER_OLLAMA_HOST="$OLLAMA_LAN_URL"
fi

# Determine models
PRIMARY_MODEL="qwen2.5-coder:7b"
SIDECAR_MODEL=""
if [ "$OLLAMA_INSTALLED" = "1" ] && [ -n "$OLLAMA_MODEL" ]; then
    if [ "$OLLAMA_MODEL" != "qwen2.5-coder:7b" ]; then
        SIDECAR_MODEL="$OLLAMA_MODEL"
    else
        PRIMARY_MODEL="$OLLAMA_MODEL"
    fi
fi

FALLBACKS='"anthropic/claude-sonnet-4-5"'
SIDECAR_MODELS_ENTRY=""
SIDECAR_OPTIMIZER_LINE='"sidecarModel": "",'
if [ -n "$SIDECAR_MODEL" ]; then
    FALLBACKS="\"ollama/$SIDECAR_MODEL\", \"anthropic/claude-sonnet-4-5\""
    SIDECAR_MODELS_ENTRY="\"ollama/$SIDECAR_MODEL\": { \"alias\": \"sidecar\" },"
    SIDECAR_OPTIMIZER_LINE="\"sidecarModel\": \"$SIDECAR_MODEL\","
fi

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
        "primary": "ollama/$PRIMARY_MODEL",
        "fallbacks": [$FALLBACKS]
      },
      "models": {
        "ollama/$PRIMARY_MODEL": { "alias": "primary" },
        $SIDECAR_MODELS_ENTRY
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
  "plugins": {
    "load": {
      "paths": ["$PLUGIN_DIR"]
    },
    "entries": {
      "model-load-optimizer": {
        "enabled": true,
        "config": {
          "ollamaHost": "$OPTIMIZER_OLLAMA_HOST",
          "primaryModel": "$PRIMARY_MODEL",
          $SIDECAR_OPTIMIZER_LINE
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

echo "  OpenClaw config: $OPENCLAW_DIR/openclaw.json"
echo "  Ollama endpoint: $OPTIMIZER_OLLAMA_HOST"
echo "  Primary: ollama/$PRIMARY_MODEL"
[ -n "$SIDECAR_MODEL" ] && echo "  Sidecar: ollama/$SIDECAR_MODEL"

# === Phase 13: Start Services ===
echo "=== Phase 13: Start Services ==="
sudo systemctl enable --now claude-agentapi.service
sudo systemctl enable --now claude-orchestrator.service

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "============================================"
echo "  Dr Paper is ONLINE"
echo "============================================"
echo ""
echo "Services:"
echo "  - icecc-scheduler:   $(systemctl is-active icecc-scheduler 2>/dev/null || echo 'check manually')"
echo "  - claude-agentapi:   $(systemctl is-active claude-agentapi 2>/dev/null || echo 'check manually')"
echo "  - claude-orchestr.:  $(systemctl is-active claude-orchestrator 2>/dev/null || echo 'check manually')"
if [ "$OLLAMA_INSTALLED" = "1" ]; then
echo "  - Ollama (local):    ${OLLAMA_MODEL}"
fi
if [ "$LAN_OLLAMA_REACHABLE" = "1" ]; then
echo "  - Ollama (LAN):      ${OLLAMA_LAN_URL}"
fi
echo "  - Model Optimizer:   model-load-optimizer plugin active"
echo ""
echo "Next:"
echo "  1. Open http://${HOSTNAME}:8080 in a browser"
echo "  2. Deploy agents on other machines"
echo "  3. Register them in Dr Paper's web UI"
echo ""
echo "Health check:"
echo "  curl http://localhost:3284/status"
echo "  tailscale status"
