# =============================================================================
# GPU Detection + Ollama Tiered Model Installer (PowerShell)
# Shared module -- sourced by all Windows deployment scripts
#
# Logic:
#   1. Detect all GPUs via WMI
#   2. Identify discrete NVIDIA or AMD GPUs (skip Intel integrated)
#   3. Query VRAM amount
#   4. Install Ollama if a capable GPU is found
#   5. Pull the best model that fits in VRAM:
#        - 12GB+ VRAM  → deepseek-coder-v2:16b  (large, best quality)
#        - 8-11GB VRAM → deepseek-coder-v2:lite  (medium, balanced)
#        - 4-7GB VRAM  → deepseek-coder:6.7b     (medium-small)
#        - 2-3GB VRAM  → qwen2.5-coder:1.5b      (small, fast)
#        - <2GB / none  → skip Ollama entirely
#
# Returns: $script:OllamaInstalled (bool), $script:OllamaModel (string or $null)
# =============================================================================

function Get-GpuInfo {
    <#
    .SYNOPSIS
    Detects discrete GPUs and returns VRAM info.
    Returns an array of objects with Name, VRAM_GB, Vendor properties.
    #>

    $gpus = @()

    try {
        $adapters = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop

        foreach ($adapter in $adapters) {
            $name = $adapter.Name
            $vramBytes = $adapter.AdapterRAM

            # Skip Intel integrated GPUs
            if ($name -match "Intel|UHD|HD Graphics|Iris") {
                Write-Host "  [SKIP] $name (integrated GPU)" -ForegroundColor Gray
                continue
            }

            # Skip Microsoft Basic Display Adapter / Remote Desktop
            if ($name -match "Microsoft|Basic Display|Remote") {
                Write-Host "  [SKIP] $name (virtual/basic)" -ForegroundColor Gray
                continue
            }

            # Determine vendor
            $vendor = "Unknown"
            if ($name -match "NVIDIA|GeForce|RTX|GTX|Quadro|Tesla") {
                $vendor = "NVIDIA"
            } elseif ($name -match "AMD|Radeon|RX|Vega") {
                $vendor = "AMD"
            }

            # Calculate VRAM in GB
            # WMI AdapterRAM is a uint32, maxes out at 4GB (4294967295)
            # For cards with >4GB, try nvidia-smi or fall back to registry
            $vramGB = 0

            if ($vramBytes -and $vramBytes -gt 0) {
                $vramGB = [math]::Round($vramBytes / 1GB, 1)
            }

            # If VRAM shows 4GB but it's a card that likely has more, try nvidia-smi
            if ($vendor -eq "NVIDIA" -and $vramGB -le 4) {
                $nvidiaSmiVram = Get-NvidiaSmiVram
                if ($nvidiaSmiVram -gt 0) {
                    $vramGB = $nvidiaSmiVram
                }
            }

            # AMD: try reading from registry for actual VRAM
            if ($vendor -eq "AMD" -and $vramGB -le 4) {
                $regVram = Get-AmdRegistryVram
                if ($regVram -gt 0) {
                    $vramGB = $regVram
                }
            }

            if ($vendor -ne "Unknown") {
                $gpus += [PSCustomObject]@{
                    Name    = $name
                    VRAM_GB = $vramGB
                    Vendor  = $vendor
                }
            }
        }
    }
    catch {
        Write-Host "  WARNING: Could not query GPU info: $_" -ForegroundColor Yellow
    }

    return $gpus
}

function Get-NvidiaSmiVram {
    <#
    .SYNOPSIS
    Queries nvidia-smi for total GPU memory. Returns VRAM in GB or 0.
    #>

    $nvidiaSmiPaths = @(
        "C:\Windows\System32\nvidia-smi.exe",
        "C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe"
    )

    foreach ($smiPath in $nvidiaSmiPaths) {
        if (Test-Path $smiPath) {
            try {
                $output = & $smiPath --query-gpu=memory.total --format=csv,noheader,nounits 2>$null
                if ($output) {
                    # nvidia-smi returns MiB
                    $totalMiB = [int]($output.Trim().Split("`n")[0])
                    return [math]::Round($totalMiB / 1024, 1)
                }
            }
            catch { }
        }
    }

    # Try PATH
    try {
        $output = nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null
        if ($output) {
            $totalMiB = [int]($output.Trim().Split("`n")[0])
            return [math]::Round($totalMiB / 1024, 1)
        }
    }
    catch { }

    return 0
}

function Get-AmdRegistryVram {
    <#
    .SYNOPSIS
    Reads AMD GPU VRAM from the Windows registry. Returns GB or 0.
    #>

    try {
        $regPaths = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}" -ErrorAction SilentlyContinue
        foreach ($path in $regPaths) {
            $props = Get-ItemProperty $path.PSPath -ErrorAction SilentlyContinue
            if ($props.'HardwareInformation.qwMemorySize') {
                $bytes = [uint64]$props.'HardwareInformation.qwMemorySize'
                return [math]::Round($bytes / 1GB, 1)
            }
            if ($props.'HardwareInformation.MemorySize') {
                $bytes = [uint64]$props.'HardwareInformation.MemorySize'
                return [math]::Round($bytes / 1GB, 1)
            }
        }
    }
    catch { }

    return 0
}

function Select-OllamaModel {
    param(
        [double]$VramGB
    )

    <#
    .SYNOPSIS
    Selects the best Ollama model for code tasks based on available VRAM.
    #>

    if ($VramGB -ge 12) {
        return @{
            Model       = "deepseek-coder-v2:16b"
            Tier        = "Large"
            Description = "16B params, best code quality, needs ~12GB VRAM"
        }
    }
    elseif ($VramGB -ge 8) {
        return @{
            Model       = "deepseek-coder-v2:lite"
            Tier        = "Medium"
            Description = "Lite variant, good balance of quality and speed"
        }
    }
    elseif ($VramGB -ge 4) {
        return @{
            Model       = "deepseek-coder:6.7b"
            Tier        = "Medium-Small"
            Description = "6.7B params, solid code completion"
        }
    }
    elseif ($VramGB -ge 2) {
        return @{
            Model       = "qwen2.5-coder:1.5b"
            Tier        = "Small"
            Description = "1.5B params, fast, low VRAM"
        }
    }
    else {
        return $null
    }
}

function Install-OllamaWithModel {
    <#
    .SYNOPSIS
    Main entry point. Detects GPU, installs Ollama, pulls appropriate model.
    Sets $script:OllamaInstalled and $script:OllamaModel.
    #>

    $script:OllamaInstalled = $false
    $script:OllamaModel = $null

    Write-Host "`n=== GPU Detection ===" -ForegroundColor Yellow
    $gpus = Get-GpuInfo

    if ($gpus.Count -eq 0) {
        Write-Host "  No discrete GPU detected. Skipping Ollama installation." -ForegroundColor Yellow
        Write-Host "  (Intel integrated / no GPU = CPU-only, not supported)" -ForegroundColor Gray
        return
    }

    # Pick the best GPU (most VRAM)
    $bestGpu = $gpus | Sort-Object VRAM_GB -Descending | Select-Object -First 1

    Write-Host ""
    Write-Host "  Detected GPU(s):" -ForegroundColor Cyan
    foreach ($gpu in $gpus) {
        $marker = if ($gpu -eq $bestGpu) { " <<<" } else { "" }
        Write-Host "    $($gpu.Vendor) $($gpu.Name) -- $($gpu.VRAM_GB) GB VRAM${marker}" -ForegroundColor White
    }

    if ($bestGpu.VRAM_GB -lt 2) {
        Write-Host ""
        Write-Host "  GPU found ($($bestGpu.Name)) but VRAM too low ($($bestGpu.VRAM_GB) GB)." -ForegroundColor Yellow
        Write-Host "  Skipping Ollama. Minimum 2GB discrete VRAM required." -ForegroundColor Yellow
        return
    }

    # Select model
    $modelInfo = Select-OllamaModel -VramGB $bestGpu.VRAM_GB

    if (-not $modelInfo) {
        Write-Host "  Could not determine appropriate model. Skipping." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "  Selected model:" -ForegroundColor Cyan
    Write-Host "    Tier:  $($modelInfo.Tier)" -ForegroundColor White
    Write-Host "    Model: $($modelInfo.Model)" -ForegroundColor Green
    Write-Host "    Info:  $($modelInfo.Description)" -ForegroundColor Gray
    Write-Host "    VRAM:  $($bestGpu.VRAM_GB) GB ($($bestGpu.Vendor) $($bestGpu.Name))" -ForegroundColor Gray

    # Install Ollama
    Write-Host "`n=== Installing Ollama ===" -ForegroundColor Yellow

    if (Get-Command ollama -ErrorAction SilentlyContinue) {
        Write-Host "  Ollama already installed: $(ollama --version 2>&1)" -ForegroundColor Green
    }
    else {
        Write-Host "  Downloading Ollama installer..." -ForegroundColor White
        $installerUrl = "https://ollama.com/download/OllamaSetup.exe"
        $installerPath = "$env:TEMP\OllamaSetup.exe"

        try {
            Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
            Write-Host "  Running installer (this may take a minute)..." -ForegroundColor White
            Start-Process -FilePath $installerPath -ArgumentList "/SILENT" -Wait -NoNewWindow
            # Refresh PATH
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

            if (Get-Command ollama -ErrorAction SilentlyContinue) {
                Write-Host "  Ollama installed successfully." -ForegroundColor Green
            }
            else {
                Write-Host "  WARNING: Ollama installed but not in PATH yet. Restart terminal after setup." -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "  ERROR: Failed to download/install Ollama: $_" -ForegroundColor Red
            Write-Host "  Install manually from https://ollama.com/download" -ForegroundColor Yellow
            return
        }
    }

    # Pull the selected model
    Write-Host "`n=== Pulling Model: $($modelInfo.Model) ===" -ForegroundColor Yellow
    Write-Host "  This may take several minutes depending on your connection..." -ForegroundColor Gray

    try {
        # Ensure ollama serve is running
        $ollamaProcess = Get-Process ollama -ErrorAction SilentlyContinue
        if (-not $ollamaProcess) {
            Start-Process ollama -ArgumentList "serve" -WindowStyle Hidden
            Start-Sleep -Seconds 3
        }

        & ollama pull $modelInfo.Model
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Model pulled successfully!" -ForegroundColor Green
            $script:OllamaInstalled = $true
            $script:OllamaModel = $modelInfo.Model
        }
        else {
            Write-Host "  WARNING: Model pull may have failed. Try manually: ollama pull $($modelInfo.Model)" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "  ERROR pulling model: $_" -ForegroundColor Red
        Write-Host "  Try manually: ollama pull $($modelInfo.Model)" -ForegroundColor Yellow
    }

    # Summary
    Write-Host ""
    Write-Host "  ================================" -ForegroundColor Cyan
    Write-Host "  Ollama Setup Summary" -ForegroundColor Cyan
    Write-Host "  ================================" -ForegroundColor Cyan
    Write-Host "  GPU:   $($bestGpu.Vendor) $($bestGpu.Name)" -ForegroundColor White
    Write-Host "  VRAM:  $($bestGpu.VRAM_GB) GB" -ForegroundColor White
    Write-Host "  Model: $($modelInfo.Model) ($($modelInfo.Tier))" -ForegroundColor Green
    Write-Host "  ================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Test it: ollama run $($modelInfo.Model) 'Write a hello world in C'" -ForegroundColor Gray
}

# Export for dot-sourcing
# Usage from another script:
#   . .\shared\ollama-gpu-detect.ps1
#   Install-OllamaWithModel
