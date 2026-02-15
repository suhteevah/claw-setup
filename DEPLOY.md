# Claude Code Agent Mesh + Distributed Compilation Cluster

## Fleet Overview

| Machine | Hostname | Role | Setup Script |
|---------|----------|------|-------------|
| Arch Linux (i7-4790K, 32GB, GTX 980) | `arch-orchestrator` | Central orchestrator + scheduler + worker | `01-arch-orchestrator.sh` |
| MacBook 1 (Intel) | `macbook1` | Headless agent + worker | `02-macos-headless-agent.sh macbook1` |
| iMac (Intel) | `imac` | Headless agent + worker | `02-macos-headless-agent.sh imac` |
| MacBook 2 (Intel) | `macbook2` | Interactive (human) + worker | `03-macos-workstation.sh` |
| Raspberry Pi 1 | `rpi1` | Headless agent + worker | `04-raspberry-pi.sh rpi1` |
| Raspberry Pi 2 | `rpi2` | Headless agent + worker | `04-raspberry-pi.sh rpi2` |
| Raspberry Pi 3 | `rpi3` | Headless agent + worker | `04-raspberry-pi.sh rpi3` |
| Windows PC (desktop) | `windows-desktop` | Interactive (human) + worker (via WSL) | `05-windows-workstation.ps1` |
| Windows Laptop (8+ cores, 16GB+) | `windows-laptop` | Interactive (human) + worker (via WSL) | `05-windows-workstation.ps1` |

## Architecture

```
                [You: MacBook 2 / Windows Desktop / Windows Laptop]
                              |
                    [Orchestrator Web UI]
                    arch-orchestrator:8080
                              |
              +-------+-------+-------+-------+
              |       |       |       |       |
          AgentAPI AgentAPI AgentAPI AgentAPI AgentAPI
          :3284    :3284    :3284    :3284    :3284
          macbook1  imac    rpi1    rpi2    rpi3
              |       |       |       |       |
          claude-p claude-p claude-p claude-p claude-p
          (headless agents with root access)

                    [Icecream Scheduler]
                    arch-orchestrator:8765
                              |
          All machines run iceccd, jobs routed to fastest node
```

## Deployment Order

### Step 1: Network (all machines)
Run on each machine to install Tailscale and join the mesh:
```bash
# Linux: sudo pacman -S tailscale / sudo apt install tailscale
# macOS: brew install --cask tailscale
# Windows: choco install tailscale
# Then: tailscale up --hostname <name>
```

Verify: `tailscale ping arch-orchestrator` from every machine.

### Step 2: Arch Orchestrator (first!)
```bash
chmod +x setup-scripts/01-arch-orchestrator.sh
./setup-scripts/01-arch-orchestrator.sh
```
This installs the icecream scheduler, Claude Code, AgentAPI, and the orchestrator.

### Step 3: macOS Headless Agents
On MacBook 1:
```bash
chmod +x setup-scripts/02-macos-headless-agent.sh
./setup-scripts/02-macos-headless-agent.sh macbook1
```
On iMac:
```bash
./setup-scripts/02-macos-headless-agent.sh imac
```

### Step 4: macOS Workstation
On MacBook 2:
```bash
chmod +x setup-scripts/03-macos-workstation.sh
./setup-scripts/03-macos-workstation.sh
```

### Step 5: Raspberry Pis
On each Pi (must be 64-bit!):
```bash
chmod +x setup-scripts/04-raspberry-pi.sh
./setup-scripts/04-raspberry-pi.sh rpi1  # or rpi2, rpi3
```

### Step 6: Windows Workstations
Run PowerShell as Administrator on each Windows machine:
```powershell
# On Windows Desktop:
.\setup-scripts\05-windows-workstation.ps1
# When prompted for Tailscale hostname, use: windows-desktop

# On Windows Laptop:
.\setup-scripts\05-windows-workstation.ps1
# When prompted for Tailscale hostname, use: windows-laptop
```

### Step 7: Cross-Compilation Tarballs
After all machines are set up:
```bash
# The Arch and Pi scripts already create tarballs in /opt/icecc-envs/
# Distribute them:
for host in macbook1 macbook2 imac rpi1 rpi2 rpi3; do
  ssh $host "sudo mkdir -p /opt/icecc-envs"
  scp /opt/icecc-envs/*.tar.gz ${host}:/opt/icecc-envs/
done
```

### Step 8: Monitoring
On the Arch box:
```bash
chmod +x monitoring/install-monitoring.sh
./monitoring/install-monitoring.sh
```

### Step 9: Register Agents
Open `http://arch-orchestrator:8080` and register each agent endpoint:
- `http://localhost:3284` (arch-local)
- `http://macbook1:3284` (macbook1-agent)
- `http://imac:3284` (imac-agent)
- `http://rpi1:3284` (rpi1-agent)
- `http://rpi2:3284` (rpi2-agent)
- `http://rpi3:3284` (rpi3-agent)

## Verification Checklist

- [ ] `tailscale ping <hostname>` works from orchestrator to all nodes
- [ ] `icecream-sundae` shows all nodes connected to scheduler
- [ ] `curl http://macbook1:3284/status` returns OK from orchestrator
- [ ] `curl http://imac:3284/status` returns OK from orchestrator
- [ ] `curl http://rpi1:3284/status` returns OK from orchestrator
- [ ] Orchestrator web UI shows all registered agents
- [ ] Test compile: `CC=icecc make -j20` distributes across cluster
- [ ] Test agent dispatch: send task via orchestrator, verify remote execution

## Useful Commands

```bash
# Check all agent statuses
fleet-health-check.sh

# Watch compilation in real-time
icecream-sundae

# View agent logs (on Linux)
journalctl -u claude-agentapi -f

# View agent logs (on macOS)
tail -f /tmp/claude-agentapi.log

# Restart an agent (Linux)
sudo systemctl restart claude-agentapi

# Restart an agent (macOS)
launchctl unload ~/Library/LaunchAgents/com.claude.agentapi.plist
launchctl load ~/Library/LaunchAgents/com.claude.agentapi.plist

# Send a task to a specific agent directly
curl -X POST http://macbook1:3284/message \
  -H 'Content-Type: application/json' \
  -d '{"content": "List files in the current directory"}'

# Compile for aarch64 from x86_64 using cross-toolchain
export ICECC_VERSION="/opt/icecc-envs/aarch64-clang.tar.gz,x86_64:/opt/icecc-envs/x86_64-clang.tar.gz"
CC=icecc CXX=icecc make -j40
```

## Budget Caps

| Machine | Max $/session | Rationale |
|---------|--------------|-----------|
| Arch orchestrator | $20 | Task decomposition is token-heavy |
| MacBook 1 / iMac | $10 | Standard worker tasks |
| Raspberry Pis | $5 | Simpler tasks, limited resources |
| MacBook 2 / Windows (both) | $5 | Human-supervised, lower autonomous spend |

## File Structure

```
distcc-for-claw-project/
  setup-scripts/
    01-arch-orchestrator.sh      # Arch Linux: orchestrator + scheduler
    02-macos-headless-agent.sh   # macOS: headless agent (MacBook 1, iMac)
    03-macos-workstation.sh      # macOS: human workstation (MacBook 2)
    04-raspberry-pi.sh           # RPi: headless agent
    05-windows-workstation.ps1   # Windows: human workstation
  service-files/
    systemd/
      claude-agentapi.service    # Linux: AgentAPI daemon
      claude-orchestrator.service # Arch: orchestrator daemon
    launchd/
      com.claude.agentapi.plist  # macOS: AgentAPI daemon
      org.icecc.iceccd.plist     # macOS: icecream daemon
  monitoring/
    fleet-health-check.sh        # Health check for all agents
    install-monitoring.sh         # Install monitoring on orchestrator
  DEPLOY.md                      # This file
```
