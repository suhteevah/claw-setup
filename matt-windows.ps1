# =============================================================================
# Matt's Fleet -- Windows Gaming Laptop Bootstrap
# Self-contained: download and run. All dependencies embedded inline.
#
# Usage (PowerShell as Administrator):
#   irm tinyurl.com/29jk9v83 | iex
#   OR: .\matt-windows-bootstrap.ps1
#
# Role: Primary powerhouse workstation (RTX 3070 Ti, high-end CPU)
#       Interactive Claude Code + icecream build worker (WSL)
#       Local Ollama for code inference + mesh network node
#       Connects to arch-orchestrator (or iMac as temp scheduler)
# =============================================================================

$ErrorActionPreference = "Stop"

Write-Host @"

============================================
  Matt's Fleet -- Windows Powerhouse Setup
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
$existingModels = @()

# --- Check for existing Ollama installation ---
$ollamaCmd = $null
$ollamaSearchPaths = @(
    "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe",
    "$env:ProgramFiles\Ollama\ollama.exe",
    "C:\Users\Matt\AppData\Local\Programs\Ollama\ollama.exe"
)

# Try PATH first
try {
    $ollamaCmd = Get-Command ollama -ErrorAction Stop
    Write-Host "  Ollama already installed: $($ollamaCmd.Source)" -ForegroundColor Green
} catch {
    # Try known install paths
    foreach ($p in $ollamaSearchPaths) {
        if (Test-Path $p) {
            $ollamaCmd = $p
            Write-Host "  Ollama found at: $p" -ForegroundColor Green
            break
        }
    }
}

# If Ollama exists, check what models are already pulled
if ($ollamaCmd) {
    try {
        $ollamaExe = if ($ollamaCmd -is [string]) { $ollamaCmd } else { $ollamaCmd.Source }
        $listOutput = & $ollamaExe list 2>$null
        if ($listOutput) {
            Write-Host "  Existing models:" -ForegroundColor Cyan
            $listOutput | ForEach-Object {
                if ($_ -notmatch "^NAME") {
                    $modelName = ($_ -split '\s+')[0]
                    if ($modelName) {
                        $existingModels += $modelName
                        Write-Host "    - $modelName" -ForegroundColor White
                    }
                }
            }
        }
    } catch {}
}

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

# --- Detect system RAM for hybrid GPU+CPU model selection ---
$systemRamGB = 0
try {
    $systemRamGB = [math]::Round((Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 0)
} catch {}
Write-Host "  System RAM: ${systemRamGB} GB DDR5" -ForegroundColor Cyan

if ($gpus.Count -eq 0) {
    Write-Host "  No discrete GPU detected." -ForegroundColor Yellow
    # Even without GPU, 64GB+ RAM can run CPU-only models
    if ($systemRamGB -ge 32) {
        Write-Host "  But with ${systemRamGB}GB RAM, CPU-only models are viable." -ForegroundColor White
    } else {
        Write-Host "  Skipping Ollama." -ForegroundColor Yellow
    }
} else {
    $bestGpu = $gpus | Sort-Object VRAM_GB -Descending | Select-Object -First 1
    Write-Host "  GPU:        $($bestGpu.Vendor) $($bestGpu.Name) -- $($bestGpu.VRAM_GB) GB VRAM" -ForegroundColor Cyan
}

# Compute effective capacity: VRAM + RAM available for partial offload
# Ollama auto-splits layers between GPU and RAM when model exceeds VRAM
$effectiveVram = if ($bestGpu) { $bestGpu.VRAM_GB } else { 0 }
$ramBudget = [math]::Max(0, $systemRamGB - 16)  # reserve 16GB for OS + apps
$effectiveCapacity = $effectiveVram + $ramBudget
Write-Host "  Effective model capacity: ${effectiveCapacity} GB (${effectiveVram}GB VRAM + ${ramBudget}GB RAM)" -ForegroundColor Cyan

if ($effectiveCapacity -lt 2) {
    Write-Host "  Not enough capacity for any model. Skipping Ollama." -ForegroundColor Yellow
} else {
    # =========================================================================
    # Hybrid tiered selection: GPU primary + CPU sidecar
    # With 64GB+ RAM and a GPU, we can partial-offload larger models
    # Ollama handles the GPU/CPU split automatically per-layer
    # =========================================================================

    # Primary model: biggest model that fits in VRAM+RAM combined
    $primaryModel = $null
    if ($effectiveCapacity -ge 20) {
        # 20GB+ effective = can run 16B with GPU acceleration on first layers
        $primaryModel = @{ Model = "deepseek-coder-v2:16b"; Tier = "Large (GPU+RAM hybrid)"; Desc = "16B params, partial GPU offload, ~20-30 tok/s"; SizeGB = 9.5 }
    } elseif ($effectiveCapacity -ge 12) {
        $primaryModel = @{ Model = "deepseek-coder-v2:16b"; Tier = "Large (GPU+RAM hybrid)"; Desc = "16B params, most layers on GPU"; SizeGB = 9.5 }
    } elseif ($effectiveCapacity -ge 8) {
        $primaryModel = @{ Model = "deepseek-coder-v2:lite"; Tier = "Medium"; Desc = "Lite variant, fits entirely in VRAM"; SizeGB = 5 }
    } elseif ($effectiveCapacity -ge 4) {
        $primaryModel = @{ Model = "deepseek-coder:6.7b"; Tier = "Medium-Small"; Desc = "6.7B params, solid code quality"; SizeGB = 4 }
    } elseif ($effectiveCapacity -ge 2) {
        $primaryModel = @{ Model = "qwen2.5-coder:1.5b"; Tier = "Small"; Desc = "1.5B params, fast"; SizeGB = 1 }
    }

    # CPU sidecar: fast model that runs entirely in RAM for parallel requests
    $sidecarModel = $null
    if ($systemRamGB -ge 32 -and $primaryModel) {
        $sidecarModel = @{ Model = "qwen2.5-coder:7b"; Tier = "CPU sidecar"; Desc = "Runs in DDR5, ~15-20 tok/s, no GPU contention"; SizeGB = 4.5 }
    }

    Write-Host ""
    if ($primaryModel) {
        Write-Host "  Primary model (GPU+RAM): $($primaryModel.Model) ($($primaryModel.Tier))" -ForegroundColor Green
        Write-Host "    $($primaryModel.Desc)" -ForegroundColor Gray
    }
    if ($sidecarModel) {
        Write-Host "  Sidecar model (CPU-only): $($sidecarModel.Model) ($($sidecarModel.Tier))" -ForegroundColor Green
        Write-Host "    $($sidecarModel.Desc)" -ForegroundColor Gray
    }

    # Install Ollama if not present
    if (-not $ollamaCmd) {
        Write-Host ""
        Write-Host "  Downloading Ollama installer..." -ForegroundColor White
        $installerPath = "$env:TEMP\OllamaSetup.exe"
        try {
            Invoke-WebRequest -Uri "https://ollama.com/download/OllamaSetup.exe" -OutFile $installerPath -UseBasicParsing
            Start-Process -FilePath $installerPath -ArgumentList "/SILENT" -Wait -NoNewWindow
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        } catch {
            Write-Host "  ERROR: Install Ollama manually: https://ollama.com/download" -ForegroundColor Red
        }
    } else {
        Write-Host "  Ollama already installed, skipping download." -ForegroundColor Green
    }

    # Resolve the working ollama executable
    $ollamaExe = $null
    try { $ollamaExe = (Get-Command ollama -ErrorAction Stop).Source } catch {}
    if (-not $ollamaExe) {
        foreach ($p in $ollamaSearchPaths) {
            if (Test-Path $p) { $ollamaExe = $p; break }
        }
    }

    if ($ollamaExe) {
        # Ensure server is running
        $ollamaProc = Get-Process ollama -ErrorAction SilentlyContinue
        if (-not $ollamaProc) {
            Start-Process $ollamaExe -ArgumentList "serve" -WindowStyle Hidden
            Start-Sleep -Seconds 3
        }

        # --- Pull primary model ---
        if ($primaryModel) {
            $alreadyHasPrimary = $existingModels | Where-Object { $_ -like "$($primaryModel.Model)*" }
            if ($alreadyHasPrimary) {
                Write-Host "  $($primaryModel.Model) already pulled!" -ForegroundColor Green
                $script:OllamaInstalled = $true
                $script:OllamaModel = $primaryModel.Model
            } else {
                if ($existingModels.Count -gt 0) {
                    Write-Host ""
                    Write-Host "  Your ${systemRamGB}GB RAM + $($bestGpu.VRAM_GB)GB VRAM can handle:" -ForegroundColor White
                    Write-Host "    $($primaryModel.Model) -- $($primaryModel.Desc)" -ForegroundColor Green
                    Write-Host "  Ollama auto-splits layers: GPU handles what fits, RAM handles the rest." -ForegroundColor Gray
                    Write-Host ""
                    $pullChoice = Read-Host "  Pull $($primaryModel.Model)? (y/n, keeps existing models)"
                } else {
                    $pullChoice = "y"
                }

                if ($pullChoice -match "^[yY]") {
                    Write-Host "  Pulling $($primaryModel.Model)... (~$($primaryModel.SizeGB)GB download)" -ForegroundColor White
                    & $ollamaExe pull $primaryModel.Model
                    if ($LASTEXITCODE -eq 0) {
                        $script:OllamaInstalled = $true
                        $script:OllamaModel = $primaryModel.Model
                        Write-Host "  Primary model ready!" -ForegroundColor Green
                    }
                } else {
                    if ($existingModels.Count -gt 0) {
                        $script:OllamaInstalled = $true
                        $script:OllamaModel = $existingModels[0]
                    }
                }
            }
        }

        # --- Pull sidecar model ---
        if ($sidecarModel) {
            $alreadyHasSidecar = $existingModels | Where-Object { $_ -like "$($sidecarModel.Model)*" }
            if ($alreadyHasSidecar) {
                Write-Host "  $($sidecarModel.Model) already pulled (CPU sidecar ready)!" -ForegroundColor Green
                $script:OllamaSidecar = $sidecarModel.Model
            } else {
                Write-Host ""
                Write-Host "  Also recommended: $($sidecarModel.Model) as CPU-only sidecar" -ForegroundColor White
                Write-Host "    Runs entirely in DDR5, handles parallel requests without touching GPU" -ForegroundColor Gray
                $sidecarChoice = Read-Host "  Pull $($sidecarModel.Model) as sidecar? (y/n)"
                if ($sidecarChoice -match "^[yY]") {
                    Write-Host "  Pulling $($sidecarModel.Model)... (~$($sidecarModel.SizeGB)GB download)" -ForegroundColor White
                    & $ollamaExe pull $sidecarModel.Model
                    if ($LASTEXITCODE -eq 0) {
                        $script:OllamaSidecar = $sidecarModel.Model
                        Write-Host "  Sidecar model ready!" -ForegroundColor Green
                    }
                }
            }
        }

        # --- List all models ---
        Write-Host ""
        Write-Host "  All models on this machine:" -ForegroundColor Cyan
        try {
            $finalList = & $ollamaExe list 2>$null
            $finalList | ForEach-Object {
                if ($_ -notmatch "^NAME") { Write-Host "    $_" -ForegroundColor White }
            }
        } catch {}
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
  Matt's Windows Powerhouse ONLINE
  Hostname: $Hostname
============================================

"@

Write-Host "  RAM:    ${systemRamGB} GB DDR5" -ForegroundColor Cyan
if ($bestGpu) {
    Write-Host "  GPU:    $($bestGpu.Vendor) $($bestGpu.Name) ($($bestGpu.VRAM_GB) GB VRAM)" -ForegroundColor Cyan
}

if ($schedulerHost) {
    Write-Host "  Icecc:  $schedulerName ($schedulerHost)" -ForegroundColor Cyan
    Write-Host "          Set up WSL icecc worker to connect" -ForegroundColor Gray
} else {
    Write-Host "  Icecc:  not configured (set up later)" -ForegroundColor Gray
}

if ($script:OllamaInstalled) {
    Write-Host "  Ollama: $($script:OllamaModel) (GPU primary)" -ForegroundColor Green
    Write-Host "  Test:   ollama run $($script:OllamaModel) 'Write a hello world in C'" -ForegroundColor Gray
}
if ($script:OllamaSidecar) {
    Write-Host "  Sidecar: $($script:OllamaSidecar) (CPU/DDR5, parallel)" -ForegroundColor Green
    Write-Host "  Test:   ollama run $($script:OllamaSidecar) 'Write a hello world in C'" -ForegroundColor Gray
}
if (-not $script:OllamaInstalled -and -not $script:OllamaSidecar) {
    Write-Host "  Ollama: not configured" -ForegroundColor Gray
}

Write-Host @"

Usage:
  claude                  Interactive Claude Code
  claude -p "task"        One-shot task
  tailscale status        Check mesh network

  Ollama auto-splits large models across GPU + DDR5.
  Sidecar model runs entirely in RAM for parallel requests.

This machine is your powerhouse workstation.
Claude Code runs interactively with you at the keyboard.
When arch-orchestrator is back, it can also join the agent mesh.

"@
