#!/bin/bash
# =============================================================================
# Fleet Health Check Script
# Deploy on: Arch Linux orchestrator
# Run via cron: */5 * * * * /usr/local/bin/fleet-health-check.sh
# =============================================================================

set -uo pipefail

# Configuration
AGENTS=(
  "localhost:3284|arch-local"
  "macbook1:3284|macbook1-agent"
  "imac:3284|imac-agent"
  "rpi1:3284|rpi1-agent"
  "rpi2:3284|rpi2-agent"
  "rpi3:3284|rpi3-agent"
)

LOGFILE="/var/log/fleet-health.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

echo "=== Fleet Health Check: ${TIMESTAMP} ===" | tee -a "$LOGFILE"

# Check AgentAPI endpoints
echo "--- Claude Code Agents ---" | tee -a "$LOGFILE"
AGENTS_UP=0
AGENTS_DOWN=0

for entry in "${AGENTS[@]}"; do
  IFS='|' read -r endpoint name <<< "$entry"
  status=$(curl -s --connect-timeout 3 "http://${endpoint}/status" 2>/dev/null)
  if [ $? -eq 0 ] && [ -n "$status" ]; then
    echo "[OK]   ${name} (${endpoint}): ${status}" | tee -a "$LOGFILE"
    ((AGENTS_UP++))
  else
    echo "[DOWN] ${name} (${endpoint}): unreachable" | tee -a "$LOGFILE"
    ((AGENTS_DOWN++))
  fi
done

echo "Agents: ${AGENTS_UP} up, ${AGENTS_DOWN} down" | tee -a "$LOGFILE"

# Check Icecream scheduler
echo "--- Icecream Scheduler ---" | tee -a "$LOGFILE"
if systemctl is-active --quiet icecc-scheduler 2>/dev/null; then
  echo "[OK]   icecc-scheduler: active" | tee -a "$LOGFILE"
else
  echo "[DOWN] icecc-scheduler: inactive" | tee -a "$LOGFILE"
fi

# Check local iceccd
if systemctl is-active --quiet iceccd 2>/dev/null; then
  echo "[OK]   iceccd (local): active" | tee -a "$LOGFILE"
else
  echo "[DOWN] iceccd (local): inactive" | tee -a "$LOGFILE"
fi

# Check Tailscale connectivity to each node
echo "--- Tailscale Network ---" | tee -a "$LOGFILE"
HOSTS=("macbook1" "macbook2" "imac" "rpi1" "rpi2" "rpi3" "windows-desktop" "windows-laptop")
for host in "${HOSTS[@]}"; do
  if tailscale ping --timeout 3s "$host" &>/dev/null; then
    echo "[OK]   ${host}: reachable" | tee -a "$LOGFILE"
  else
    echo "[DOWN] ${host}: unreachable via Tailscale" | tee -a "$LOGFILE"
  fi
done

# Check orchestrator
echo "--- Orchestrator ---" | tee -a "$LOGFILE"
if systemctl is-active --quiet claude-orchestrator 2>/dev/null; then
  echo "[OK]   claude-orchestrator: active" | tee -a "$LOGFILE"
else
  echo "[DOWN] claude-orchestrator: inactive" | tee -a "$LOGFILE"
fi

echo "" | tee -a "$LOGFILE"
