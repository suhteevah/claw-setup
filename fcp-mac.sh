#!/bin/bash
set -euo pipefail

# =============================================================================
# FCP (First Choice Plastics) -- Mac Mini Bootstrap
# Self-contained: curl this and run. All dependencies embedded inline.
#
# Usage: bash <(curl -sL <url>) fcp-mac
#   or:  bash fcp-mac-bootstrap.sh fcp-mac
#
# Role: Headless Claude Code agent + icecream worker
#       Can optionally become icecream scheduler
# =============================================================================

HOSTNAME="${1:-fcp-mac}"

echo "============================================"
echo "  First Choice Plastics -- Mac Mini Bootstrap"
echo "  Setting up: ${HOSTNAME}"
echo "============================================"

# === Phase 1: Homebrew ===
echo ""
echo "=== Phase 1: Homebrew ==="
if ! command -v brew &>/dev/null; then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# === Phase 2: Dependencies ===
echo "=== Phase 2: Dependencies ==="
brew update
brew install node@20 git ripgrep ccache

# === Phase 3: Tailscale ===
echo "=== Phase 3: Tailscale ==="
if ! brew list --cask tailscale &>/dev/null; then
  brew install --cask tailscale
fi
echo ">>> Open Tailscale.app and authenticate."
echo ">>> Then run: sudo tailscale up --hostname ${HOSTNAME}"
read -p "Press Enter after Tailscale is authenticated..."

# === Phase 4: Icecream ===
echo "=== Phase 4: Icecream ==="
brew install icecream

# Create icecc user if needed
if ! dscl . -read /Users/icecc &>/dev/null 2>&1; then
  echo "Creating icecc system user..."
  sudo dscl . -create /Users/icecc
  sudo dscl . -create /Users/icecc UserShell /usr/bin/false
  ICECC_UID=$(dscl . -list /Users UniqueID | awk '{print $2}' | sort -n | tail -1 | awk '{print $1+1}')
  sudo dscl . -create /Users/icecc UniqueID "$ICECC_UID"
  sudo dscl . -create /Users/icecc PrimaryGroupID 20
  sudo dscl . -create /Users/icecc NFSHomeDirectory /var/empty
  echo "Created icecc user with UID ${ICECC_UID}"
fi

# Check scheduler reachability
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
  echo "    1) Run this Mac Mini as the SCHEDULER (recommended if laptop is off)"
  echo "    2) Skip icecream for now (configure later)"
  echo "    3) Enter a different scheduler hostname"
  echo ""
  read -p "  Choose [1/2/3]: " ICECC_CHOICE
  case "${ICECC_CHOICE}" in
    1)
      ICECC_MODE="scheduler"
      echo "  Will run as scheduler + worker."
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

# === Phase 7: API Key ===
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

# === Phase 8: Authenticate ===
echo "=== Phase 8: Authenticate Claude Code ==="
echo ">>> Run: claude auth login"
read -p "Press Enter after authenticating..."

# === Phase 9: Services ===
echo "=== Phase 9: Install Services ==="

# Icecream
if [ "$ICECC_MODE" = "scheduler" ]; then
  echo "Starting icecream scheduler..."
  brew services start icecc-scheduler 2>/dev/null || true
  sudo iceccd -d -s localhost -u icecc 2>/dev/null || true
  echo "icecream scheduler + local worker started"
elif [ "$ICECC_MODE" = "worker" ]; then
  # Write iceccd plist inline
  cat > /tmp/org.icecc.iceccd.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>org.icecc.iceccd</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/sbin/iceccd</string>
    <string>-s</string>
    <string>__SCHEDULER__</string>
    <string>-u</string>
    <string>icecc</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/iceccd.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/iceccd.err</string>
</dict>
</plist>
PLIST
  sed -i '' "s|__SCHEDULER__|${ICECC_SCHEDULER}|g" /tmp/org.icecc.iceccd.plist
  sudo mv /tmp/org.icecc.iceccd.plist /Library/LaunchDaemons/
  sudo launchctl load /Library/LaunchDaemons/org.icecc.iceccd.plist
  echo "iceccd worker started (scheduler: ${ICECC_SCHEDULER})"
else
  echo "Icecream skipped."
fi

# AgentAPI launchd plist (inline)
API_KEY=$(grep ANTHROPIC_API_KEY /etc/claude/api-key | cut -d= -f2)
cat > /tmp/com.claude.agentapi.plist << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.claude.agentapi</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/agentapi</string>
    <string>server</string>
    <string>--type</string>
    <string>claude</string>
    <string>--allowed-hosts</string>
    <string>*</string>
    <string>--</string>
    <string>claude</string>
    <string>--dangerously-skip-permissions</string>
    <string>--max-budget-usd</string>
    <string>10.00</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>ANTHROPIC_API_KEY</key>
    <string>${API_KEY}</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/claude-agentapi.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/claude-agentapi.err</string>
</dict>
</plist>
PLIST
mkdir -p ~/Library/LaunchAgents
sudo mv /tmp/com.claude.agentapi.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.claude.agentapi.plist
echo "AgentAPI service installed and started"

echo ">>> You may need to allow incoming connections in System Preferences > Firewall"

# =============================================================================
# Phase 10: GPU Detection + Ollama (embedded inline)
# =============================================================================
echo "=== Phase 10: GPU Detection + Ollama ==="

OLLAMA_INSTALLED=0
OLLAMA_MODEL=""

_detect_gpu_macos() {
    local gpu_info
    gpu_info=$(system_profiler SPDisplaysDataType 2>/dev/null)
    if [ -z "$gpu_info" ]; then
        echo "  Could not query GPU info"; return
    fi

    local best_vram=0 best_name="" best_vendor="" current_name=""
    while IFS= read -r line; do
        if echo "$line" | grep -q "Chipset Model:"; then
            current_name=$(echo "$line" | sed 's/.*Chipset Model: *//')
        fi
        if echo "$line" | grep -q "VRAM"; then
            local vram_str vram_val vram_unit vram_gb=0
            vram_str=$(echo "$line" | grep -oE '[0-9]+ [A-Z]+' | head -1)
            vram_val=$(echo "$vram_str" | grep -oE '[0-9]+')
            vram_unit=$(echo "$vram_str" | grep -oE '[A-Z]+')
            [ "$vram_unit" = "GB" ] && vram_gb=$vram_val
            [ "$vram_unit" = "MB" ] && vram_gb=$(( vram_val / 1024 ))

            local vendor="Unknown"
            echo "$current_name" | grep -qi "nvidia\|geforce\|gtx\|rtx\|quadro" && vendor="NVIDIA"
            echo "$current_name" | grep -qi "amd\|radeon\|rx" && vendor="AMD"
            echo "$current_name" | grep -qi "apple\|m1\|m2\|m3\|m4" && vendor="Apple"
            if echo "$current_name" | grep -qi "intel"; then
                echo "  [SKIP] ${current_name} (integrated)"; continue
            fi
            echo "  [${vendor}] ${current_name} -- ${vram_gb} GB VRAM"
            if [ "$vram_gb" -gt "$best_vram" ]; then
                best_vram=$vram_gb; best_name="$current_name"; best_vendor="$vendor"
            fi
        fi
    done <<< "$gpu_info"

    # Apple Silicon unified memory
    if [ "$best_vendor" = "Apple" ] || [ "$best_vram" -eq 0 ]; then
        local total_mem_gb
        total_mem_gb=$(( $(sysctl -n hw.memsize 2>/dev/null) / 1073741824 ))
        if [ "$total_mem_gb" -ge 16 ]; then
            local usable=$(( total_mem_gb * 3 / 4 ))
            echo "  [Apple Silicon] Unified memory: ${total_mem_gb} GB (~${usable} GB for ML)"
            if [ "$usable" -gt "$best_vram" ]; then
                best_vram=$usable; best_name="${current_name:-Apple Silicon}"; best_vendor="Apple"
            fi
        fi
    fi

    GPU_NAME="$best_name"; GPU_VRAM_GB=$best_vram; GPU_VENDOR="$best_vendor"
}

GPU_NAME="" GPU_VRAM_GB=0 GPU_VENDOR=""
_detect_gpu_macos

if [ -z "$GPU_NAME" ] || [ "$GPU_VRAM_GB" -lt 2 ]; then
    echo "  No usable GPU detected. Skipping Ollama."
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
            if command -v brew &>/dev/null; then
                brew install ollama
            else
                echo "  Install Ollama manually: https://ollama.com/download"
            fi
        fi

        if command -v ollama &>/dev/null; then
            if ! curl -s http://localhost:11434/api/tags &>/dev/null; then
                ollama serve &>/dev/null &
                sleep 3
            fi
            echo "  Pulling ${SELECTED_MODEL}... (this may take a while)"
            if ollama pull "$SELECTED_MODEL"; then
                OLLAMA_INSTALLED=1
                OLLAMA_MODEL="$SELECTED_MODEL"
                echo "  Model ready!"
            fi
        fi
    fi
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "============================================"
echo "  FCP Mac Mini ONLINE"
echo "  Hostname: ${HOSTNAME}"
if [ "$ICECC_MODE" = "scheduler" ]; then
echo "  Icecream: SCHEDULER"
elif [ "$ICECC_MODE" = "worker" ]; then
echo "  Icecream: Worker -> ${ICECC_SCHEDULER}"
else
echo "  Icecream: Skipped"
fi
echo "============================================"
echo ""
echo "Verify:"
echo "  - Tailscale: tailscale status"
echo "  - AgentAPI:  curl http://localhost:3284/status"
if [ "$ICECC_MODE" = "scheduler" ]; then
echo "  - Scheduler: icecream-sundae"
echo ""
echo "  To promote permanently to scheduler:"
echo "    brew services start icecc-scheduler"
echo "    Then update other machines to point to ${HOSTNAME}"
fi
if [ "$OLLAMA_INSTALLED" = "1" ]; then
echo "  - Ollama: ${OLLAMA_MODEL}"
echo "  - Test: ollama run ${OLLAMA_MODEL} 'Hello world in C'"
fi
echo ""
echo "Verify from the laptop:"
echo "  curl http://${HOSTNAME}:3284/status"
