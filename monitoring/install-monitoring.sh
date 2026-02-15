#!/bin/bash
# =============================================================================
# Install monitoring on the Arch Linux orchestrator
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing fleet health check..."

# Install the health check script
sudo cp "${SCRIPT_DIR}/fleet-health-check.sh" /usr/local/bin/fleet-health-check.sh
sudo chmod +x /usr/local/bin/fleet-health-check.sh

# Create log file
sudo touch /var/log/fleet-health.log
sudo chmod 644 /var/log/fleet-health.log

# Install cron job (every 5 minutes)
CRON_LINE="*/5 * * * * /usr/local/bin/fleet-health-check.sh >> /var/log/fleet-health.log 2>&1"
(crontab -l 2>/dev/null | grep -v fleet-health-check; echo "$CRON_LINE") | crontab -

echo "Monitoring installed."
echo "  - Health check: /usr/local/bin/fleet-health-check.sh"
echo "  - Log file:     /var/log/fleet-health.log"
echo "  - Cron:         every 5 minutes"
echo ""
echo "Run manually: fleet-health-check.sh"

# Optional: install icecream-sundae for compile monitoring
if command -v cargo &>/dev/null; then
  echo "Installing icecream-sundae (terminal compile monitor)..."
  cargo install icecream-sundae
  echo "Run: icecream-sundae"
else
  echo "To install icecream-sundae, install Rust first: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
fi
