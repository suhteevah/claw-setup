#!/bin/bash
set -euo pipefail

# =============================================================================
# Arch Linux Orchestrator Setup
# Run this on: arch-orchestrator (x86_64 Arch Linux)
# Role: Central orchestrator + icecream scheduler + build worker + Claude agent
# =============================================================================

echo "=== Phase 1: System Update ==="
sudo pacman -Syu --noconfirm

echo "=== Phase 2: Install Base Dependencies ==="
sudo pacman -S --noconfirm --needed \
  nodejs npm git ripgrep base-devel ccache clang \
  tailscale icecream curl jq

echo "=== Phase 3: Tailscale ==="
sudo systemctl enable --now tailscaled
echo ">>> Run: sudo tailscale up --hostname arch-orchestrator"
echo ">>> Then authenticate in your browser."
read -p "Press Enter after Tailscale is authenticated..."

echo "=== Phase 4: Icecream Scheduler + Worker ==="
# Create icecc environments directory
sudo mkdir -p /opt/icecc-envs

# Start the scheduler (only on this machine)
sudo systemctl enable --now icecc-scheduler.service

# Configure iceccd worker
if [ -f /etc/conf.d/icecream ]; then
  sudo sed -i 's/^#\?ICECC_SCHEDULER_HOST=.*/ICECC_SCHEDULER_HOST="localhost"/' /etc/conf.d/icecream
else
  echo 'ICECC_SCHEDULER_HOST="localhost"' | sudo tee /etc/conf.d/icecream
fi
sudo systemctl enable --now iceccd.service

# Create native x86_64 toolchain tarball
echo "Creating x86_64 Clang toolchain tarball..."
cd /tmp
icecc-create-env --clang /usr/bin/clang /usr/bin/clang++ 2>/dev/null || true
TARBALL=$(ls -t /tmp/*.tar.gz 2>/dev/null | head -1)
if [ -n "$TARBALL" ]; then
  sudo mv "$TARBALL" /opt/icecc-envs/x86_64-clang.tar.gz
  echo "Toolchain tarball created: /opt/icecc-envs/x86_64-clang.tar.gz"
else
  echo "WARNING: Could not create toolchain tarball. Create manually later."
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
agentapi --version || echo "AgentAPI installed (version check may not be supported)"

echo "=== Phase 7: Create claude-agent user ==="
if ! id claude-agent &>/dev/null; then
  sudo useradd -r -m -s /bin/bash claude-agent
  echo "Created user: claude-agent"
else
  echo "User claude-agent already exists"
fi

echo "=== Phase 8: API Key Setup ==="
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
  echo "API key file already exists at /etc/claude/api-key"
fi

echo "=== Phase 9: Install Service Files ==="
# Copy service files (assumes they're in ../service-files/systemd/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="${SCRIPT_DIR}/../service-files/systemd"

if [ -f "${SERVICE_DIR}/claude-agentapi.service" ]; then
  sudo cp "${SERVICE_DIR}/claude-agentapi.service" /etc/systemd/system/
  sudo cp "${SERVICE_DIR}/claude-orchestrator.service" /etc/systemd/system/
  sudo systemctl daemon-reload
  echo "Service files installed"
else
  echo "WARNING: Service files not found in ${SERVICE_DIR}. Install manually."
fi

echo "=== Phase 10: Authenticate Claude Code ==="
echo ">>> You must authenticate Claude Code once interactively."
echo ">>> Run as claude-agent: sudo -u claude-agent claude auth login"
read -p "Press Enter after authenticating..."

echo "=== Phase 11: Install Orchestrator (claude-code-by-agents) ==="
# Install Deno
if ! command -v deno &>/dev/null; then
  curl -fsSL https://deno.land/install.sh | sudo -u claude-agent sh
  echo 'export PATH="/home/claude-agent/.deno/bin:$PATH"' | sudo -u claude-agent tee -a /home/claude-agent/.bashrc > /dev/null
fi

# Clone orchestrator
if [ ! -d /opt/claude-code-by-agents ]; then
  sudo git clone https://github.com/baryhuang/claude-code-by-agents.git /opt/claude-code-by-agents
  sudo chown -R claude-agent:claude-agent /opt/claude-code-by-agents
  cd /opt/claude-code-by-agents/backend
  sudo -u claude-agent /home/claude-agent/.deno/bin/deno install
fi

echo "=== Phase 12: GPU Detection + Ollama ==="
SHARED_MODULE="${SCRIPT_DIR}/../shared/ollama-gpu-detect.sh"
if [ -f "$SHARED_MODULE" ]; then
  source "$SHARED_MODULE"
  install_ollama_with_model
else
  echo "WARNING: ollama-gpu-detect.sh not found. Skipping Ollama."
  echo "Copy shared/ollama-gpu-detect.sh to the project root and re-run."
fi

echo "=== Phase 13: Start Services ==="
sudo systemctl enable --now claude-agentapi.service
sudo systemctl enable --now claude-orchestrator.service

echo ""
echo "=========================================="
echo "  Arch Linux Orchestrator Setup Complete  "
echo "=========================================="
echo ""
echo "Services running:"
echo "  - Tailscale:        $(sudo tailscale status --json | jq -r '.Self.HostName // "check manually"')"
echo "  - icecc-scheduler:  $(systemctl is-active icecc-scheduler)"
echo "  - iceccd:           $(systemctl is-active iceccd)"
echo "  - claude-agentapi:  $(systemctl is-active claude-agentapi)"
echo "  - claude-orchestr.: $(systemctl is-active claude-orchestrator)"
if [ "$OLLAMA_INSTALLED" = "1" ]; then
echo "  - Ollama model:     ${OLLAMA_MODEL}"
fi
echo ""
echo "Next steps:"
echo "  1. Verify icecream:   icecream-sundae"
echo "  2. Verify AgentAPI:   curl http://localhost:3284/status"
echo "  3. Verify orchestrator: open http://localhost:8080 in browser"
echo "  4. Set up other machines and register them as agents"
