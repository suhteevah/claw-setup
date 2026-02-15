# =============================================================================
# Matt's Fleet -- Windows Gaming Laptop Bootstrap
# Self-contained: download and run. All dependencies embedded inline.
#
# Usage (PowerShell as Administrator):
#   irm tinyurl.com/XXXXX | iex
#   OR: .\matt-windows-bootstrap.ps1
#
# Role: Interactive Claude Code (human workstation) + icecream build worker (WSL)
#       Connects to arch-orchestrator (or iMac as temp scheduler)
# =============================================================================

$ErrorActionPreference = "Stop"

Write-Host @"

============================================
  Matt's Fleet -- Windows Laptop Bootstrap
============================================

"@ -ForegroundColor Cyan

# --- Hostname ---
$Hostname = Read-Host "Enter Tailscale hostname (e.g., matt-windows-desktop or matt-windows-laptop)"
if (-not $Hostname) { $Hostname = "matt-windows" }

Write-Host "`nSetting up: $Hostname" -ForegroundColor Cyan

# --- Admin check ---
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "ERROR: Right-click PowerShell > Run as Administrator" -ForegroundColor Red
    exit 1
}

# === Phase 1: Chocolatey ===
Write-Host "`n=== Phase 1: Package Manager ===" -ForegroundColor Yellow
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
}

# === Phase 2: Dependencies ===
Write-Host "`n=== Phase 2: Dependencies ===" -ForegroundColor Yellow
choco install -y nodejs-lts git ripgrep ccache

$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
Write-Host "Node.js: $(node --version)"
Write-Host "npm: $(npm --version)"

# === Phase 3: Tailscale ===
Write-Host "`n=== Phase 3: Tailscale ===" -ForegroundColor Yellow
if (-not (Get-Command tailscale -ErrorAction SilentlyContinue)) {
    choco install -y tailscale
}
Write-Host @"

>>> Open the Tailscale app and sign in.
>>> Then run: tailscale up --hostname $Hostname

"@ -ForegroundColor White
Read-Host "Press Enter after Tailscale is set up"

# === Phase 4: Icecream (WSL) ===
Write-Host "`n=== Phase 4: Icecream Build Worker ===" -ForegroundColor Yellow

# Detect which scheduler is up
$schedulerHost = $null
$schedulerName = ""

Write-Host "  Checking for icecream scheduler..." -ForegroundColor Gray

# Try arch-orchestrator first
try {
    $result = tailscale ping --timeout 3s arch-orchestrator 2>$null
    if ($LASTEXITCODE -eq 0) {
        $schedulerHost = "arch-orchestrator"
        $schedulerName = "Arch orchestrator"
        Write-Host "  [OK] arch-orchestrator is up" -ForegroundColor Green
    }
} catch {}

# Try iMac as fallback (temp scheduler)
if (-not $schedulerHost) {
    try {
        $result = tailscale ping --timeout 3s imac 2>$null
        if ($LASTEXITCODE -eq 0) {
            $schedulerHost = "imac"
            $schedulerName = "iMac (temp scheduler)"
            Write-Host "  [OK] iMac temp scheduler is up" -ForegroundColor Green
        }
    } catch {}
}

if (-not $schedulerHost) {
    Write-Host "  [WARN] No scheduler found. Enter one manually or skip." -ForegroundColor Yellow
    $custom = Read-Host "  Scheduler hostname (or 'skip')"
    if ($custom -and $custom -ne "skip") {
        $schedulerHost = $custom
        $schedulerName = $custom
    }
}

if ($schedulerHost) {
    Write-Host @"

Icecream does not have a native Windows build.
Your scheduler is: $schedulerName ($schedulerHost)

Recommended: Install WSL2 with Ubuntu, then inside WSL run:
  sudo apt install -y icecc
  sudo sed -i 's/^#\?ICECC_SCHEDULER_HOST=.*/ICECC_SCHEDULER_HOST="$schedulerHost"/' /etc/default/icecc
  sudo systemctl enable --now icecc-daemon

Alternative: Skip icecream on Windows, use for Claude Code only.

"@ -ForegroundColor White
} else {
    Write-Host "  Skipping icecream for now." -ForegroundColor Yellow
}

# === Phase 5: Claude Code ===
Write-Host "`n=== Phase 5: Claude Code ===" -ForegroundColor Yellow
npm install -g @anthropic-ai/claude-code

Write-Host @"

============================================
  ANTHROPIC API KEY REQUIRED
============================================

You need an API key to use Claude Code.

1. Go to: https://console.anthropic.com/
2. Create an account (or sign in)
3. Go to API Keys
4. Create a new key
5. Copy the key

Then run: claude auth login
   OR set: `$env:ANTHROPIC_API_KEY = "your-key-here"

"@ -ForegroundColor Yellow

Write-Host ">>> Run 'claude auth login' now to authenticate." -ForegroundColor White
Read-Host "Press Enter after you've authenticated Claude Code"

try {
    $version = claude --version 2>&1
    Write-Host "Claude Code: $version" -ForegroundColor Green
} catch {
    Write-Host "WARNING: Could not verify. Run 'claude --version' manually." -ForegroundColor Yellow
}

# =============================================================================
# Phase 6: GPU Detection + Ollama (INLINED)
# =============================================================================
Write-Host "`n=== Phase 6: GPU Detection + Ollama ===" -ForegroundColor Yellow

$script:OllamaInstalled = $false
$script:OllamaModel = $null

# --- GPU Detection (inlined) ---
$gpus = @()
try {
    $adapters = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop
    foreach ($adapter in $adapters) {
        $name = $adapter.Name
        $vramBytes = $adapter.AdapterRAM

        if ($name -match "Intel|UHD|HD Graphics|Iris") {
            Write-Host "  [SKIP] $name (integrated GPU)" -ForegroundColor Gray
            continue
        }
        if ($name -match "Microsoft|Basic Display|Remote") {
            Write-Host "  [SKIP] $name (virtual/basic)" -ForegroundColor Gray
            continue
        }

        $vendor = "Unknown"
        if ($name -match "NVIDIA|GeForce|RTX|GTX|Quadro|Tesla") { $vendor = "NVIDIA" }
        elseif ($name -match "AMD|Radeon|RX|Vega") { $vendor = "AMD" }

        $vramGB = 0
        if ($vramBytes -and $vramBytes -gt 0) {
            $vramGB = [math]::Round($vramBytes / 1GB, 1)
        }

        # WMI caps at 4GB; try nvidia-smi for real VRAM
        if ($vendor -eq "NVIDIA" -and $vramGB -le 4) {
            $nvPaths = @("C:\Windows\System32\nvidia-smi.exe", "C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe")
            foreach ($p in $nvPaths) {
                if (Test-Path $p) {
                    try {
                        $out = & $p --query-gpu=memory.total --format=csv,noheader,nounits 2>$null
                        if ($out) { $vramGB = [math]::Round([int]($out.Trim().Split("`n")[0]) / 1024, 1) }
                    } catch {}
                    break
                }
            }
            if ($vramGB -le 4) {
                try {
                    $out = nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null
                    if ($out) { $vramGB = [math]::Round([int]($out.Trim().Split("`n")[0]) / 1024, 1) }
                } catch {}
            }
        }

        # AMD: try registry for real VRAM
        if ($vendor -eq "AMD" -and $vramGB -le 4) {
            try {
                $regPaths = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}" -ErrorAction SilentlyContinue
                foreach ($rp in $regPaths) {
                    $props = Get-ItemProperty $rp.PSPath -ErrorAction SilentlyContinue
                    if ($props.'HardwareInformation.qwMemorySize') {
                        $vramGB = [math]::Round([uint64]$props.'HardwareInformation.qwMemorySize' / 1GB, 1)
                        break
                    }
                    if ($props.'HardwareInformation.MemorySize') {
                        $vramGB = [math]::Round([uint64]$props.'HardwareInformation.MemorySize' / 1GB, 1)
                        break
                    }
                }
            } catch {}
        }

        if ($vendor -ne "Unknown") {
            $gpus += [PSCustomObject]@{ Name = $name; VRAM_GB = $vramGB; Vendor = $vendor }
        }
    }
} catch {
    Write-Host "  WARNING: Could not query GPU info: $_" -ForegroundColor Yellow
}

if ($gpus.Count -eq 0) {
    Write-Host "  No discrete GPU detected. Skipping Ollama." -ForegroundColor Yellow
} else {
    $bestGpu = $gpus | Sort-Object VRAM_GB -Descending | Select-Object -First 1
    Write-Host "  Best GPU: $($bestGpu.Vendor) $($bestGpu.Name) -- $($bestGpu.VRAM_GB) GB VRAM" -ForegroundColor Cyan

    if ($bestGpu.VRAM_GB -lt 2) {
        Write-Host "  VRAM too low. Skipping Ollama." -ForegroundColor Yellow
    } else {
        # Tiered model selection
        $modelInfo = $null
        if ($bestGpu.VRAM_GB -ge 12) {
            $modelInfo = @{ Model = "deepseek-coder-v2:16b"; Tier = "Large"; Desc = "16B params, best quality" }
        } elseif ($bestGpu.VRAM_GB -ge 8) {
            $modelInfo = @{ Model = "deepseek-coder-v2:lite"; Tier = "Medium"; Desc = "Lite variant, balanced" }
        } elseif ($bestGpu.VRAM_GB -ge 4) {
            $modelInfo = @{ Model = "deepseek-coder:6.7b"; Tier = "Medium-Small"; Desc = "6.7B params, solid" }
        } elseif ($bestGpu.VRAM_GB -ge 2) {
            $modelInfo = @{ Model = "qwen2.5-coder:1.5b"; Tier = "Small"; Desc = "1.5B params, fast" }
        }

        if ($modelInfo) {
            Write-Host "  Selected: $($modelInfo.Model) ($($modelInfo.Tier))" -ForegroundColor Green

            if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
                Write-Host "  Downloading Ollama installer..." -ForegroundColor White
                $installerPath = "$env:TEMP\OllamaSetup.exe"
                try {
                    Invoke-WebRequest -Uri "https://ollama.com/download/OllamaSetup.exe" -OutFile $installerPath -UseBasicParsing
                    Start-Process -FilePath $installerPath -ArgumentList "/SILENT" -Wait -NoNewWindow
                    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
                } catch {
                    Write-Host "  ERROR: Install Ollama manually: https://ollama.com/download" -ForegroundColor Red
                }
            }

            if (Get-Command ollama -ErrorAction SilentlyContinue) {
                $ollamaProc = Get-Process ollama -ErrorAction SilentlyContinue
                if (-not $ollamaProc) {
                    Start-Process ollama -ArgumentList "serve" -WindowStyle Hidden
                    Start-Sleep -Seconds 3
                }
                Write-Host "  Pulling $($modelInfo.Model)... (may take a while)" -ForegroundColor White
                & ollama pull $modelInfo.Model
                if ($LASTEXITCODE -eq 0) {
                    $script:OllamaInstalled = $true
                    $script:OllamaModel = $modelInfo.Model
                    Write-Host "  Model ready!" -ForegroundColor Green
                }
            }
        }
    }
}

# =============================================================================
# Phase 7: Shell Profile
# =============================================================================
Write-Host "`n=== Phase 7: Shell Profile ===" -ForegroundColor Yellow
$profilePath = $PROFILE
if (-not (Test-Path $profilePath)) {
    New-Item -Path $profilePath -ItemType File -Force | Out-Null
    Write-Host "  Created PowerShell profile at $profilePath" -ForegroundColor Gray
}

# =============================================================================
# Summary
# =============================================================================
Write-Host @"

============================================
  Matt's Windows Laptop ONLINE
  Hostname: $Hostname
============================================

Usage:
  claude                  Interactive Claude Code
  claude -p "task"        One-shot task
  tailscale status        Check mesh network

"@

if ($schedulerHost) {
    Write-Host "  Icecream scheduler: $schedulerName ($schedulerHost)" -ForegroundColor Cyan
    Write-Host "  Set up WSL icecc worker to connect to it" -ForegroundColor Gray
} else {
    Write-Host "  Icecream: not configured (set up later)" -ForegroundColor Gray
}

if ($script:OllamaInstalled) {
    Write-Host "  Ollama: $($script:OllamaModel)" -ForegroundColor Green
    Write-Host "  Test:   ollama run $($script:OllamaModel) 'Hello world in C'" -ForegroundColor Gray
} else {
    Write-Host "  Ollama: not installed" -ForegroundColor Gray
}

Write-Host @"

This is a human workstation -- Claude Code runs interactively.
When arch-orchestrator is back, you can optionally run as an agent too.

"@
