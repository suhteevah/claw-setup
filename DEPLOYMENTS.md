# Deployment Index

Three independent Claude Code agent mesh deployments, each with their own
fleet, orchestrator, and distributed compilation cluster.

## Deployments

| Deployment | Orchestrator | Fleet Size | Status | Path |
|-----------|-------------|------------|--------|------|
| **Matt's Fleet** | `arch-orchestrator` | 9 machines | Production ready | `./` (root) |
| **Dr Paper** (Swoop) | `dr-paper` | 9 machines | Production ready | `./deployments/swoop-dr-paper/` |
| **FCP** (First Choice Plastics) | `fcp-laptop` | 1 machine (expanding) | Production ready | `./deployments/fcp/` |

## Matt's Fleet

Central command for the primary deployment.
- **Orchestrator:** Arch Linux box (`arch-orchestrator`)
- **Agents:** MacBook 1, iMac, 3x RPi (headless), MacBook 2 + 2x Windows (human)
- **See:** `DEPLOY.md`

## Dr Paper (Swoop)

Swoop's command and control system. Mirrors Matt's fleet architecture.
- **Orchestrator:** Dedicated Linux box (`dr-paper`)
- **Agents:** MacBook 1, iMac, 3x RPi (headless), MacBook 2 + 2x Windows (human)
- **See:** `deployments/swoop-dr-paper/DEPLOY.md`

## FCP (First Choice Plastics)

Lean starter deployment. Grows in phases.
- **Phase 1 (now):** Windows gaming laptop only (`fcp-laptop`)
- **Phase 2 (planned):** Add Raspberry Pi (`fcp-rpi`)
- **Phase 3 (if things go well):** Add Mac Mini (`fcp-mac-mini`)
- **See:** `deployments/fcp/DEPLOY.md`

## Directory Structure

```
distcc-for-claw-project/
  DEPLOY.md                        # Matt's fleet deployment guide
  DEPLOYMENTS.md                   # This file (index of all deployments)
  setup-scripts/                   # Matt's fleet setup scripts
  service-files/                   # Matt's fleet service configs
  monitoring/                      # Matt's fleet monitoring

  deployments/
    swoop-dr-paper/
      DEPLOY.md                    # Dr Paper deployment guide
      setup-scripts/
        01-linux-orchestrator.sh   # Dr Paper brain
        02-macos-headless-agent.sh # Swoop's Macs (headless)
        03-macos-workstation.sh    # Swoop's Mac (interactive)
        04-raspberry-pi.sh         # Swoop's Pis
        05-windows-workstation.ps1 # Swoop's Windows machines
      service-files/
        systemd/                   # Linux service definitions
        launchd/                   # macOS service definitions
      monitoring/
        fleet-health-check.sh      # Dr Paper fleet health check
        install-monitoring.sh      # Install monitoring on Dr Paper

    fcp/
      DEPLOY.md                    # FCP deployment guide (phased)
      setup-scripts/
        01-windows-primary.ps1     # Gaming laptop (Phase 1)
        01b-enable-orchestrator.ps1 # Enable fleet coordination (Phase 2)
        02-raspberry-pi.sh         # Add Pi (Phase 2)
        03-mac-mini.sh             # Add Mac Mini (Phase 3)
      service-files/
        systemd/                   # Pi service definition
      monitoring/
        fleet-health-check.sh      # Lightweight fleet check
```

## Key Differences Between Deployments

| Feature | Matt's Fleet | Dr Paper | FCP |
|---------|-------------|----------|-----|
| Orchestrator OS | Arch Linux | Any Linux | Windows (laptop) |
| Fleet size | 9 machines | 9 machines | 1-3 machines |
| Icecream scheduler | `arch-orchestrator` | `dr-paper` | `fcp-laptop` (WSL) |
| Full autonomy nodes | 6 | 6 | 1-2 |
| Human workstations | 3 | 3 | 1 |
| Cross-compile | x86_64 + ARM | x86_64 + ARM | x86_64 + ARM (Phase 2) |
