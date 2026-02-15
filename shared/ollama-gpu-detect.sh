#!/bin/bash
# =============================================================================
# GPU Detection + Ollama Tiered Model Installer (Bash)
# Shared module -- sourced by all Linux/macOS deployment scripts
#
# Usage: source /path/to/ollama-gpu-detect.sh && install_ollama_with_model
#
# Logic:
#   1. Detect discrete NVIDIA or AMD GPUs (skip Intel integrated)
#   2. Query VRAM amount (nvidia-smi, rocm-smi, or system_profiler on macOS)
#   3. Install Ollama if a capable GPU is found
#   4. Pull the best model that fits in VRAM:
#        12GB+ → deepseek-coder-v2:16b   (large)
#        8-11  → deepseek-coder-v2:lite   (medium)
#        4-7   → deepseek-coder:6.7b      (medium-small)
#        2-3   → qwen2.5-coder:1.5b       (small)
#        <2    → skip entirely
#
# Exports: OLLAMA_INSTALLED (0/1), OLLAMA_MODEL (string or empty)
# =============================================================================

OLLAMA_INSTALLED=0
OLLAMA_MODEL=""

detect_gpu() {
    # Returns: GPU_NAME, GPU_VRAM_GB, GPU_VENDOR
    # Sets globals for the best (most VRAM) discrete GPU found

    GPU_NAME=""
    GPU_VRAM_GB=0
    GPU_VENDOR=""

    local os_type
    os_type="$(uname -s)"

    if [ "$os_type" = "Darwin" ]; then
        _detect_gpu_macos
    else
        _detect_gpu_linux
    fi
}

_detect_gpu_linux() {
    local best_vram=0
    local best_name=""
    local best_vendor=""

    # --- NVIDIA via nvidia-smi ---
    if command -v nvidia-smi &>/dev/null; then
        local nv_name nv_vram_mib
        nv_name=$(nvidia-smi --query-gpu=name --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d '\n')
        nv_vram_mib=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d '\n')

        if [ -n "$nv_vram_mib" ] && [ "$nv_vram_mib" -gt 0 ] 2>/dev/null; then
            local nv_vram_gb=$(( nv_vram_mib / 1024 ))
            echo "  [NVIDIA] ${nv_name} -- ${nv_vram_gb} GB VRAM"
            if [ "$nv_vram_gb" -gt "$best_vram" ]; then
                best_vram=$nv_vram_gb
                best_name="$nv_name"
                best_vendor="NVIDIA"
            fi
        fi
    fi

    # --- AMD via rocm-smi ---
    if command -v rocm-smi &>/dev/null; then
        local amd_vram_mib
        amd_vram_mib=$(rocm-smi --showmeminfo vram --json 2>/dev/null | grep -o '"Total Memory (B)":[0-9]*' | head -1 | grep -o '[0-9]*$')
        local amd_name
        amd_name=$(rocm-smi --showproductname 2>/dev/null | grep "Card Series" | head -1 | sed 's/.*: *//')

        if [ -n "$amd_vram_mib" ] && [ "$amd_vram_mib" -gt 0 ] 2>/dev/null; then
            local amd_vram_gb=$(( amd_vram_mib / 1073741824 ))
            echo "  [AMD] ${amd_name:-AMD GPU} -- ${amd_vram_gb} GB VRAM"
            if [ "$amd_vram_gb" -gt "$best_vram" ]; then
                best_vram=$amd_vram_gb
                best_name="${amd_name:-AMD GPU}"
                best_vendor="AMD"
            fi
        fi
    fi

    # --- Fallback: lspci + /sys ---
    if [ "$best_vram" -eq 0 ] && command -v lspci &>/dev/null; then
        # Check for NVIDIA cards via lspci
        local nv_pci
        nv_pci=$(lspci | grep -i "vga\|3d\|display" | grep -i nvidia | head -1)
        if [ -n "$nv_pci" ]; then
            local card_name
            card_name=$(echo "$nv_pci" | sed 's/.*: //')
            echo "  [NVIDIA] ${card_name} (VRAM unknown -- nvidia-smi not available)"
            echo "  WARNING: Install NVIDIA drivers for proper VRAM detection"
            # Assume 2GB minimum if we can see the card but can't query VRAM
            best_vram=2
            best_name="$card_name"
            best_vendor="NVIDIA"
        fi

        # Check for AMD cards via lspci
        local amd_pci
        amd_pci=$(lspci | grep -i "vga\|3d\|display" | grep -i "amd\|radeon\|ati" | grep -iv "cezanne\|renoir\|barcelo\|phoenix\|rembrandt\|raphael" | head -1)
        if [ -n "$amd_pci" ]; then
            local card_name
            card_name=$(echo "$amd_pci" | sed 's/.*: //')
            echo "  [AMD] ${card_name} (VRAM unknown -- rocm-smi not available)"
            if [ "$best_vram" -eq 0 ]; then
                best_vram=2
                best_name="$card_name"
                best_vendor="AMD"
            fi
        fi
    fi

    # Skip Intel integrated
    if [ "$best_vendor" = "" ]; then
        local intel_gpu
        intel_gpu=$(lspci 2>/dev/null | grep -i "vga\|3d\|display" | grep -i intel | head -1)
        if [ -n "$intel_gpu" ]; then
            echo "  [SKIP] $(echo "$intel_gpu" | sed 's/.*: //') (integrated GPU)"
        fi
    fi

    GPU_NAME="$best_name"
    GPU_VRAM_GB=$best_vram
    GPU_VENDOR="$best_vendor"
}

_detect_gpu_macos() {
    # macOS: use system_profiler
    local gpu_info
    gpu_info=$(system_profiler SPDisplaysDataType 2>/dev/null)

    if [ -z "$gpu_info" ]; then
        echo "  Could not query GPU info on macOS"
        return
    fi

    local best_vram=0
    local best_name=""
    local best_vendor=""

    # Parse chipset model and VRAM lines
    local current_name=""
    while IFS= read -r line; do
        if echo "$line" | grep -q "Chipset Model:"; then
            current_name=$(echo "$line" | sed 's/.*Chipset Model: *//')
        fi
        if echo "$line" | grep -q "VRAM"; then
            local vram_str
            vram_str=$(echo "$line" | grep -oE '[0-9]+ [A-Z]+' | head -1)
            local vram_val
            vram_val=$(echo "$vram_str" | grep -oE '[0-9]+')
            local vram_unit
            vram_unit=$(echo "$vram_str" | grep -oE '[A-Z]+')

            local vram_gb=0
            if [ "$vram_unit" = "GB" ]; then
                vram_gb=$vram_val
            elif [ "$vram_unit" = "MB" ]; then
                vram_gb=$(( vram_val / 1024 ))
            fi

            # Determine vendor from name
            local vendor="Unknown"
            if echo "$current_name" | grep -qi "nvidia\|geforce\|gtx\|rtx\|quadro"; then
                vendor="NVIDIA"
            elif echo "$current_name" | grep -qi "amd\|radeon\|rx"; then
                vendor="AMD"
            elif echo "$current_name" | grep -qi "apple\|m1\|m2\|m3\|m4"; then
                vendor="Apple"
            elif echo "$current_name" | grep -qi "intel"; then
                echo "  [SKIP] ${current_name} (integrated GPU)"
                continue
            fi

            echo "  [${vendor}] ${current_name} -- ${vram_gb} GB VRAM"

            if [ "$vram_gb" -gt "$best_vram" ]; then
                best_vram=$vram_gb
                best_name="$current_name"
                best_vendor="$vendor"
            fi
        fi
    done <<< "$gpu_info"

    # Apple Silicon unified memory -- use a portion for ML
    if [ "$best_vendor" = "Apple" ] || [ "$best_vram" -eq 0 ]; then
        local total_mem_gb
        total_mem_gb=$(( $(sysctl -n hw.memsize 2>/dev/null) / 1073741824 ))
        if [ "$total_mem_gb" -ge 16 ]; then
            # Apple Silicon shares RAM with GPU; allocate ~75% for model
            local usable=$(( total_mem_gb * 3 / 4 ))
            echo "  [Apple Silicon] Unified memory: ${total_mem_gb} GB (usable for ML: ~${usable} GB)"
            if [ "$usable" -gt "$best_vram" ]; then
                best_vram=$usable
                best_name="${current_name:-Apple Silicon}"
                best_vendor="Apple"
            fi
        fi
    fi

    GPU_NAME="$best_name"
    GPU_VRAM_GB=$best_vram
    GPU_VENDOR="$best_vendor"
}

select_ollama_model() {
    local vram=$1

    if [ "$vram" -ge 12 ]; then
        SELECTED_MODEL="deepseek-coder-v2:16b"
        SELECTED_TIER="Large"
        SELECTED_DESC="16B params, best code quality, needs ~12GB VRAM"
    elif [ "$vram" -ge 8 ]; then
        SELECTED_MODEL="deepseek-coder-v2:lite"
        SELECTED_TIER="Medium"
        SELECTED_DESC="Lite variant, good balance of quality and speed"
    elif [ "$vram" -ge 4 ]; then
        SELECTED_MODEL="deepseek-coder:6.7b"
        SELECTED_TIER="Medium-Small"
        SELECTED_DESC="6.7B params, solid code completion"
    elif [ "$vram" -ge 2 ]; then
        SELECTED_MODEL="qwen2.5-coder:1.5b"
        SELECTED_TIER="Small"
        SELECTED_DESC="1.5B params, fast, low VRAM"
    else
        SELECTED_MODEL=""
        SELECTED_TIER=""
        SELECTED_DESC=""
    fi
}

install_ollama_with_model() {
    echo ""
    echo "=== GPU Detection ==="

    detect_gpu

    if [ -z "$GPU_NAME" ] || [ "$GPU_VRAM_GB" -lt 2 ]; then
        if [ -n "$GPU_NAME" ]; then
            echo "  GPU found (${GPU_NAME}) but VRAM too low (${GPU_VRAM_GB} GB)."
        else
            echo "  No discrete GPU detected."
        fi
        echo "  Skipping Ollama installation."
        return
    fi

    echo ""
    echo "  Best GPU: ${GPU_VENDOR} ${GPU_NAME} -- ${GPU_VRAM_GB} GB VRAM"

    # Select model
    select_ollama_model "$GPU_VRAM_GB"

    if [ -z "$SELECTED_MODEL" ]; then
        echo "  Could not determine appropriate model. Skipping."
        return
    fi

    echo ""
    echo "  Selected model:"
    echo "    Tier:  ${SELECTED_TIER}"
    echo "    Model: ${SELECTED_MODEL}"
    echo "    Info:  ${SELECTED_DESC}"

    # Install Ollama
    echo ""
    echo "=== Installing Ollama ==="

    if command -v ollama &>/dev/null; then
        echo "  Ollama already installed: $(ollama --version 2>&1 || echo 'version unknown')"
    else
        echo "  Downloading and installing Ollama..."
        local os_type
        os_type="$(uname -s)"

        if [ "$os_type" = "Darwin" ]; then
            # macOS: brew install
            if command -v brew &>/dev/null; then
                brew install ollama
            else
                echo "  ERROR: Homebrew not found. Install Ollama manually: https://ollama.com/download"
                return
            fi
        else
            # Linux: official install script
            curl -fsSL https://ollama.com/install.sh | sh
        fi

        if ! command -v ollama &>/dev/null; then
            echo "  ERROR: Ollama installation failed. Install manually: https://ollama.com/download"
            return
        fi
        echo "  Ollama installed successfully."
    fi

    # Ensure ollama is serving
    if ! curl -s http://localhost:11434/api/tags &>/dev/null; then
        echo "  Starting Ollama server..."
        if [ "$(uname -s)" = "Linux" ] && command -v systemctl &>/dev/null; then
            sudo systemctl enable --now ollama 2>/dev/null || ollama serve &>/dev/null &
        else
            ollama serve &>/dev/null &
        fi
        sleep 3
    fi

    # Pull model
    echo ""
    echo "=== Pulling Model: ${SELECTED_MODEL} ==="
    echo "  This may take several minutes..."

    if ollama pull "$SELECTED_MODEL"; then
        echo "  Model pulled successfully!"
        OLLAMA_INSTALLED=1
        OLLAMA_MODEL="$SELECTED_MODEL"
    else
        echo "  WARNING: Model pull may have failed. Try manually: ollama pull ${SELECTED_MODEL}"
    fi

    # Summary
    echo ""
    echo "  ================================"
    echo "  Ollama Setup Summary"
    echo "  ================================"
    echo "  GPU:   ${GPU_VENDOR} ${GPU_NAME}"
    echo "  VRAM:  ${GPU_VRAM_GB} GB"
    echo "  Model: ${SELECTED_MODEL} (${SELECTED_TIER})"
    echo "  ================================"
    echo ""
    echo "  Test: ollama run ${SELECTED_MODEL} 'Write a hello world in C'"
}
