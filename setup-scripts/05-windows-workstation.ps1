# =============================================================================
# Windows Human Workstation Setup (PowerShell)
# Run this on: Windows Desktop or Windows Laptop
# Role: Interactive Claude Code (human at keyboard) + icecream build worker
# Run as Administrator: Right-click PowerShell > Run as Administrator
#
# Usage: .\05-windows-workstation.ps1 [-Hostname <name>]
#   e.g.: .\05-windows-workstation.ps1 -Hostname windows-desktop
#   e.g.: .\05-windows-workstation.ps1 -Hostname windows-laptop
# =============================================================================

param(
    [string]$Hostname = ""
)

$ErrorActionPreference = "Stop"

if (-not $Hostname) {
    $Hostname = Read-Host "Enter Tailscale hostname for this machine (e.g., windows-desktop or windows-laptop)"
}

Write-Host "=== Setting up $Hostname as Windows workstation ===" -ForegroundColor Cyan

# --- Phase 1: Check prerequisites ---
Write-Host "`n=== Phase 1: Prerequisites ===" -ForegroundColor Yellow

# Check if running as admin
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
    exit 1
}

# Check/install Chocolatey
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Write-Host "Installing Chocolatey..."
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
}

# --- Phase 2: Install dependencies ---
Write-Host "`n=== Phase 2: Install Dependencies ===" -ForegroundColor Yellow
choco install -y nodejs-lts git ripgrep ccache

# Refresh PATH
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

Write-Host "Node.js: $(node --version)"
Write-Host "npm: $(npm --version)"

# --- Phase 3: Tailscale ---
Write-Host "`n=== Phase 3: Tailscale ===" -ForegroundColor Yellow
if (-not (Get-Command tailscale -ErrorAction SilentlyContinue)) {
    choco install -y tailscale
}
Write-Host ">>> Open Tailscale and authenticate."
Write-Host ">>> Then run in CMD: tailscale up --hostname $Hostname"
Read-Host "Press Enter after Tailscale is authenticated"

# --- Phase 4: Icecream (via WSL or Docker) ---
Write-Host "`n=== Phase 4: Icecream Build Worker ===" -ForegroundColor Yellow
Write-Host @"
Icecream does not have a native Windows build.
Options for participating in the compile cluster:

Option A (Recommended): Install WSL2 with Ubuntu, then inside WSL:
  sudo apt install -y icecc
  Edit /etc/default/icecc: ICECC_SCHEDULER_HOST="arch-orchestrator"
  sudo systemctl enable --now icecc-daemon

Option B: Run iceccd in a Docker container:
  docker run -d --name iceccd --network host \
    -e ICECC_SCHEDULER_HOST=arch-orchestrator \
    your-icecc-image

Option C: Skip icecream on Windows, use this machine for Claude Code only.
"@

# --- Phase 5: Claude Code ---
Write-Host "`n=== Phase 5: Claude Code ===" -ForegroundColor Yellow
npm install -g @anthropic-ai/claude-code
claude --version

# --- Phase 6: GPU Detection + Ollama ---
Write-Host "`n=== Phase 6: GPU Detection + Ollama ===" -ForegroundColor Yellow

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SharedModule = Join-Path (Split-Path -Parent $ScriptDir) "shared\ollama-gpu-detect.ps1"

# Try local shared dir first, then project root shared dir
if (-not (Test-Path $SharedModule)) {
    $SharedModule = Join-Path (Split-Path -Parent (Split-Path -Parent $ScriptDir)) "shared\ollama-gpu-detect.ps1"
}

if (Test-Path $SharedModule) {
    . $SharedModule
    Install-OllamaWithModel
} else {
    Write-Host "  WARNING: ollama-gpu-detect.ps1 not found at $SharedModule" -ForegroundColor Yellow
    Write-Host "  Skipping Ollama setup. Copy shared/ollama-gpu-detect.ps1 and re-run." -ForegroundColor Yellow
}

# --- Phase 7: Shell profile ---
Write-Host "`n=== Phase 7: Shell Profile ===" -ForegroundColor Yellow

$profilePath = $PROFILE
if (-not (Test-Path $profilePath)) {
    New-Item -Path $profilePath -ItemType File -Force | Out-Null
}

Write-Host @"

========================================
  Windows Workstation Setup Complete
  Hostname: $Hostname
========================================

Usage:
  - Run Claude Code interactively: claude
  - For icecream, use WSL2 (see Option A above)

Verify:
  - Tailscale: tailscale status
  - Claude Code: claude --version
"@

if ($script:OllamaInstalled) {
    Write-Host "  - Ollama model: $($script:OllamaModel)" -ForegroundColor Green
    Write-Host "  - Test: ollama run $($script:OllamaModel) 'Hello world in C'" -ForegroundColor Gray
} else {
    Write-Host "  - Ollama: not installed (no discrete GPU detected)" -ForegroundColor Gray
}

Write-Host @"

This machine is configured as a human workstation.
Claude Code runs interactively with you at the keyboard.
"@
