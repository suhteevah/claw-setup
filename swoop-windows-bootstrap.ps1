# =============================================================================
# Dr Paper -- Windows Gaming Laptop Bootstrap (Swoop)
# Self-contained: download and run. All dependencies embedded inline.
#
# Usage (PowerShell as Administrator):
#   irm https://raw.githubusercontent.com/suhteevah/claw-setup/main/swoop-windows-bootstrap.ps1 | iex
#   OR: .\swoop-windows-bootstrap.ps1
#
# Role: Interactive Claude Code + icecream build worker (via WSL)
#       Connects to Dr Paper orchestrator + LAN Ollama (192.168.10.242)
# =============================================================================

$ErrorActionPreference = "Stop"

Write-Host @"

============================================
  Dr Paper -- Windows Workstation Bootstrap
============================================

"@ -ForegroundColor Cyan

# --- Hostname ---
$Hostname = Read-Host "Enter Tailscale hostname (e.g., swoop-windows-desktop or swoop-windows-laptop)"
if (-not $Hostname) { $Hostname = "swoop-windows" }

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
Write-Host "`n=== Phase 4: Icecream ===" -ForegroundColor Yellow
Write-Host @"

Icecream has no native Windows build. Options:
  A) Install WSL2 with Ubuntu, then:
       sudo apt install -y icecc
       Edit /etc/default/icecc: ICECC_SCHEDULER_HOST="dr-paper"
  B) Skip icecream, use this machine for Claude Code only.

"@ -ForegroundColor White

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
4. Create a new key (name it "dr-paper")
5. Copy the key

Then run: claude auth login

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
# Phase 7: LAN Ollama Discovery
# =============================================================================
Write-Host "`n=== Phase 7: LAN Ollama Discovery ===" -ForegroundColor Yellow
Write-Host "  Dr Paper's network has an existing Ollama server." -ForegroundColor White
$LanOllamaReachable = $false

Write-Host "  Default: 192.168.10.242 (press Enter to accept)" -ForegroundColor Gray
$lanHost = Read-Host "Ollama server hostname/IP [192.168.10.242]"
if (-not $lanHost) { $lanHost = "192.168.10.242" }
if ($lanHost -and $lanHost -ne "skip") {
    $lanUrl = "http://${lanHost}:11434"
    Write-Host "  Testing ${lanUrl}..." -ForegroundColor Gray
    try {
        $response = Invoke-WebRequest -Uri "${lanUrl}/api/tags" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        Write-Host "  [OK] LAN Ollama reachable!" -ForegroundColor Green
        $LanOllamaReachable = $true
    } catch {
        Write-Host "  [FAIL] Could not connect to ${lanUrl}" -ForegroundColor Yellow
        Write-Host @"

  To fix this on the Ollama server:
    1. Set: export OLLAMA_HOST=0.0.0.0
    2. Restart Ollama: sudo systemctl restart ollama
    3. Or use Tailscale for secure cross-network access
"@ -ForegroundColor Gray
    }
}

# =============================================================================
# Phase 8: OpenClaw + Model Load Optimizer
# =============================================================================
Write-Host "`n=== Phase 8: OpenClaw + Model Load Optimizer ===" -ForegroundColor Yellow

if ($script:OllamaInstalled) {
    $openclawDir = "$env:USERPROFILE\.openclaw"
    $pluginDir = "$openclawDir\plugins\model-load-optimizer"

    if (-not (Test-Path $openclawDir)) {
        New-Item -ItemType Directory -Path $openclawDir -Force | Out-Null
    }

    # Clone and build the optimizer plugin
    if (-not (Test-Path $pluginDir)) {
        Write-Host "  Cloning model-load-optimizer..." -ForegroundColor White
        git clone https://github.com/suhteevah/model-load-optimizer.git $pluginDir 2>$null
        if (-not (Test-Path "$pluginDir\package.json")) {
            Write-Host "  WARNING: Clone failed. Create $pluginDir manually and retry." -ForegroundColor Yellow
        }
    }

    if (Test-Path "$pluginDir\package.json") {
        Write-Host "  Building model-load-optimizer..." -ForegroundColor White
        Push-Location $pluginDir
        npm install --silent 2>$null
        npm run build 2>$null
        Pop-Location
        Write-Host "  Plugin built." -ForegroundColor Green
    }

    # Determine Ollama host (prefer LAN if reachable)
    $ollamaHostUrl = "http://localhost:11434"
    if ($LanOllamaReachable) {
        $ollamaHostUrl = $lanUrl
    }

    # Determine model roles
    $primaryModel = "qwen2.5-coder:7b"
    $sidecarModel = $script:OllamaModel
    if ($script:OllamaModel -eq "qwen2.5-coder:7b" -or $script:OllamaModel -eq "qwen2.5-coder:1.5b") {
        $primaryModel = $script:OllamaModel
        $sidecarModel = ""
    }

    # Write openclaw.json
    $configPath = "$openclawDir\openclaw.json"
    $pluginPathEscaped = $pluginDir.Replace('\', '\\')

    $modelsBlock = @"
        "ollama/$primaryModel": { "alias": "primary" }
"@
    $fallbacksBlock = '"anthropic/claude-sonnet-4-5"'
    if ($sidecarModel) {
        $modelsBlock = @"
        "ollama/$primaryModel": { "alias": "primary" },
        "ollama/$sidecarModel": { "alias": "sidecar" },
"@
        $fallbacksBlock = @"
"ollama/$sidecarModel",
          "anthropic/claude-sonnet-4-5"
"@
    }

    $optimizerConfig = @"
      "model-load-optimizer": {
        "enabled": true,
        "config": {
          "ollamaHost": "$ollamaHostUrl",
          "primaryModel": "$primaryModel",
          "sidecarModel": "$sidecarModel",
          "fallbackModel": "anthropic/claude-sonnet-4-5",
          "keepAliveMinutes": 30,
          "gpuMemoryThreshold": 0.85,
          "healthCheckIntervalSec": 30,
          "preloadOnStart": true,
          "autoRoute": true,
          "dashboardEnabled": true
        }
      }
"@

    $openclawJson = @"
{
  "env": { "OLLAMA_API_KEY": "ollama-local" },
  "auth": {
    "profiles": {
      "ollama:default": { "provider": "ollama", "mode": "api_key" }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "ollama/$primaryModel",
        "fallbacks": [$fallbacksBlock]
      },
      "models": {
$modelsBlock
        "anthropic/claude-sonnet-4-5": { "alias": "sonnet" }
      }
    }
  },
  "plugins": {
    "load": {
      "paths": ["$pluginPathEscaped"]
    },
    "entries": {
$optimizerConfig
    }
  }
}
"@

    $openclawJson | Out-File -FilePath $configPath -Encoding utf8
    Write-Host "  OpenClaw config written to $configPath" -ForegroundColor Green
    Write-Host "  Ollama host: $ollamaHostUrl" -ForegroundColor Cyan
    Write-Host "  Primary: ollama/$primaryModel" -ForegroundColor Cyan
    if ($sidecarModel) {
        Write-Host "  Sidecar: ollama/$sidecarModel" -ForegroundColor Cyan
    }
} else {
    Write-Host "  Skipping (no Ollama models installed)" -ForegroundColor Yellow
}

# =============================================================================
# Summary
# =============================================================================
Write-Host @"

============================================
  $Hostname connected to Dr Paper
============================================

Usage:
  claude                  (interactive Claude Code)
  tailscale status        (verify network)
"@

if ($script:OllamaInstalled) {
    Write-Host "  Ollama (local): $($script:OllamaModel)" -ForegroundColor Green
    Write-Host "  Test: ollama run $($script:OllamaModel) 'Hello world in C'" -ForegroundColor Gray
}
if ($LanOllamaReachable) {
    Write-Host "  Ollama (LAN):   ${lanUrl}" -ForegroundColor Green
    Write-Host "  Use: `$env:OLLAMA_HOST='${lanHost}:11434'; ollama run <model>" -ForegroundColor Gray
}
