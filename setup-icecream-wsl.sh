#!/bin/bash
# =============================================================================
# Temporary Icecream Scheduler + Worker Setup for WSL2
# Run this inside WSL2 Ubuntu on the Windows gaming laptop
#
# This machine becomes the temporary scheduler until the Arch box is fixed.
# All other machines (Macs, Pis, iMac) point their ICECC_SCHEDULER_HOST here.
#
# Usage: bash setup-icecream-wsl.sh
# =============================================================================

set -e

echo ""
echo "============================================"
echo "  Icecream Scheduler + Worker (WSL2)"
echo "  Temporary until Arch box is repaired"
echo "============================================"
echo ""

# --- Get Tailscale hostname ---
TAILSCALE_HOSTNAME=""
if command -v tailscale &>/dev/null; then
    TAILSCALE_HOSTNAME=$(tailscale status --json 2>/dev/null | grep -o '"Self":true' -A5 | head -1 || true)
    # Actually get the hostname properly
    TAILSCALE_HOSTNAME=$(tailscale status 2>/dev/null | head -1 | awk '{print $2}' || true)
fi

if [ -z "$TAILSCALE_HOSTNAME" ]; then
    # WSL shares the Windows host's Tailscale, use Windows hostname
    WIN_HOSTNAME=$(hostname 2>/dev/null || echo "unknown")
    echo "  Note: WSL shares Windows Tailscale (hostname: $WIN_HOSTNAME)"
    echo "  Other machines should use Tailscale IP or Windows hostname"
fi

# --- Install icecream ---
echo ""
echo "=== Installing icecream ==="
sudo apt-get update -qq
sudo apt-get install -y icecc icecc-monitor

# --- Configure as SCHEDULER ---
echo ""
echo "=== Configuring as Scheduler ==="

# Create scheduler config
sudo tee /etc/default/icecc-scheduler > /dev/null << 'SCHED_EOF'
# Icecream Scheduler Configuration
# This machine is the TEMPORARY scheduler
ICECC_SCHEDULER_PORT=8765
ICECC_SCHEDULER_LOG=/var/log/icecc-scheduler.log

# Allow all networks (Tailscale + LAN)
ICECC_SCHEDULER_NETNAME=""
SCHED_EOF

# --- Configure as WORKER too ---
echo ""
echo "=== Configuring as Worker ==="

# Point worker at localhost (we ARE the scheduler)
sudo tee /etc/default/icecc > /dev/null << 'WORKER_EOF'
# Icecream Worker Configuration
ICECC_SCHEDULER_HOST="localhost"
ICECC_MAX_JOBS=""
ICECC_NICE=5
ICECC_LOG_FILE=/var/log/iceccd.log
ICECC_ALLOW_REMOTE=yes
WORKER_EOF

# --- Detect CPU cores for job count ---
CORES=$(nproc 2>/dev/null || echo 4)
echo "  Detected $CORES CPU cores"

# WSL2 gets all the host cores, but leave some for Windows
WSL_JOBS=$((CORES > 4 ? CORES - 2 : CORES))
echo "  Setting max jobs to $WSL_JOBS (reserving 2 for Windows)"
sudo sed -i "s/ICECC_MAX_JOBS=\"\"/ICECC_MAX_JOBS=\"$WSL_JOBS\"/" /etc/default/icecc

# --- Start services ---
echo ""
echo "=== Starting Icecream Services ==="

# WSL2 doesn't use systemd by default in older versions
# Try systemd first, fall back to manual start
if command -v systemctl &>/dev/null && systemctl is-system-running &>/dev/null 2>&1; then
    echo "  Using systemd..."
    sudo systemctl enable --now icecc-scheduler.service 2>/dev/null || true
    sudo systemctl enable --now icecc-daemon.service 2>/dev/null || true

    sleep 2
    echo "  Scheduler: $(systemctl is-active icecc-scheduler.service 2>/dev/null || echo 'unknown')"
    echo "  Worker:    $(systemctl is-active icecc-daemon.service 2>/dev/null || echo 'unknown')"
else
    echo "  No systemd - starting manually..."

    # Kill any existing instances
    sudo pkill icecc-scheduler 2>/dev/null || true
    sudo pkill iceccd 2>/dev/null || true
    sleep 1

    # Start scheduler
    sudo /usr/sbin/icecc-scheduler -d -l /var/log/icecc-scheduler.log
    echo "  Scheduler started (PID: $(pgrep icecc-scheduler))"

    # Start worker
    sudo /usr/sbin/iceccd -d -s localhost -m $WSL_JOBS -l /var/log/iceccd.log
    echo "  Worker started (PID: $(pgrep iceccd))"
fi

# --- Create startup script ---
echo ""
echo "=== Creating Auto-Start Script ==="

STARTUP_SCRIPT="$HOME/start-icecream.sh"
cat > "$STARTUP_SCRIPT" << 'STARTUP_EOF'
#!/bin/bash
# Start icecream scheduler + worker in WSL2
# Run this after WSL starts: bash ~/start-icecream.sh

echo "Starting icecream scheduler..."
sudo /usr/sbin/icecc-scheduler -d -l /var/log/icecc-scheduler.log 2>/dev/null
echo "Starting icecream worker..."
CORES=$(nproc)
JOBS=$((CORES > 4 ? CORES - 2 : CORES))
sudo /usr/sbin/iceccd -d -s localhost -m $JOBS -l /var/log/iceccd.log 2>/dev/null
echo "Icecream running. Scheduler PID: $(pgrep icecc-scheduler), Worker PID: $(pgrep iceccd)"
STARTUP_EOF
chmod +x "$STARTUP_SCRIPT"

echo "  Created: $STARTUP_SCRIPT"
echo "  Run after each WSL restart: bash ~/start-icecream.sh"

# --- Create environment setup for icecc usage ---
echo ""
echo "=== Creating Build Environment ==="

cat >> "$HOME/.bashrc" << 'BASHRC_EOF'

# --- Icecream distributed compilation ---
export PATH="/usr/lib/icecc/bin:$PATH"
export CCACHE_PREFIX=icecc
# Use icecc for cmake projects:
# cmake -DCMAKE_C_COMPILER=/usr/lib/icecc/bin/cc -DCMAKE_CXX_COMPILER=/usr/lib/icecc/bin/c++ ..
BASHRC_EOF

# --- Verify ---
echo ""
echo "=== Verification ==="

sleep 2

if pgrep -x icecc-scheduler > /dev/null; then
    echo "  [OK] Scheduler running on port 8765"
else
    echo "  [WARN] Scheduler not detected"
fi

if pgrep -x iceccd > /dev/null; then
    echo "  [OK] Worker running ($WSL_JOBS jobs max)"
else
    echo "  [WARN] Worker not detected"
fi

# Test connectivity
if command -v icecc &>/dev/null; then
    echo "  [OK] icecc compiler wrapper installed"
fi

# --- Get the IP other machines should point to ---
echo ""
echo "============================================"
echo "  Icecream Scheduler Active"
echo "============================================"
echo ""
echo "  This machine is now the TEMPORARY scheduler."
echo "  Other machines should set their scheduler to:"
echo ""

# Get WSL2 IP (accessible from Windows)
WSL_IP=$(ip addr show eth0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
echo "  WSL2 IP:        $WSL_IP (from Windows host only)"

# Get Windows host IP via Tailscale
if command -v tailscale &>/dev/null; then
    TS_IP=$(tailscale ip -4 2>/dev/null || true)
    if [ -n "$TS_IP" ]; then
        echo "  Tailscale IP:   $TS_IP (from any Tailscale machine)"
    fi
fi

echo ""
echo "  On remote machines, set:"
echo "    ICECC_SCHEDULER_HOST=\"<ip-above>\""
echo ""
echo "  Monitor:"
echo "    icemon                    (GUI, if X11/Wayland available)"
echo "    icecc --show-jobs         (CLI)"
echo ""
echo "  Auto-start after WSL reboot:"
echo "    bash ~/start-icecream.sh"
echo ""
