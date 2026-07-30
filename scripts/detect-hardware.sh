#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Thomas Perrot <thomas.perrot@tupi.fr>
# SPDX-License-Identifier: GPL-3.0-only

# =============================================================================
# detect-hardware.sh — probe CPU/RAM/accelerator, print the matching
#                       ollama_build_target
#
# Self-contained: no sourcing, no sibling-file dependency, so it can be
# piped over ssh to a host that doesn't have this repo checked out yet:
#   ssh myhost 'bash -s' < scripts/detect-hardware.sh
#
# Prints shell-sourceable KEY=value lines to stdout:
#   ARCH=x86_64
#   CPU_COUNT=8
#   RAM_GB=32
#   ACCEL=cpu
#   VRAM_GB=0
#   OLLAMA_BUILD_TARGET=cpu
#
# GPU_MIN_VRAM_GB gates rocm/cuda detection: rocm-smi/nvidia-smi succeeding
# only proves the SMI *monitoring* interface works, not that the device has
# real compute VRAM. Integrated/APU GPUs commonly respond to rocm-smi with a
# few hundred MB of shared framebuffer memory — well under the threshold —
# and correctly fall back to cpu instead of building a GPU image that can't
# actually accelerate inference.
#
# Exits 1 (no stdout, message on stderr) if both AMD ROCm and NVIDIA CUDA
# report above-threshold devices on the same host — ambiguous; set
# ollama_build_target manually in that case (see
# ansible/inventory/host_vars/<hostname>.yml).
# =============================================================================

set -euo pipefail

GPU_MIN_VRAM_GB=2

rocm_vram_gb() {
    rocm-smi --showmeminfo vram 2>/dev/null \
        | awk '/Total Memory/ {sum += $NF} END {printf "%.0f", sum/1024/1024/1024}'
}

cuda_vram_gb() {
    nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null \
        | awk '{sum += $1} END {printf "%.0f", sum/1024}'
}

ROCM_VRAM_GB=0
CUDA_VRAM_GB=0

if command -v rocm-smi &>/dev/null && rocm-smi &>/dev/null 2>&1; then
    ROCM_VRAM_GB=$(rocm_vram_gb)
fi

if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
    CUDA_VRAM_GB=$(cuda_vram_gb)
fi

HAS_ROCM=false
HAS_CUDA=false
[[ ${ROCM_VRAM_GB} -ge ${GPU_MIN_VRAM_GB} ]] && HAS_ROCM=true
[[ ${CUDA_VRAM_GB} -ge ${GPU_MIN_VRAM_GB} ]] && HAS_CUDA=true

if $HAS_ROCM && $HAS_CUDA; then
    echo "Both AMD ROCm (${ROCM_VRAM_GB} GB) and NVIDIA CUDA (${CUDA_VRAM_GB} GB) detected on this host — ambiguous." >&2
    echo "Set ollama_build_target manually in ansible/inventory/host_vars/<hostname>.yml" >&2
    exit 1
fi

ARCH=$(uname -m)
CPU_COUNT=$(nproc)
ACCEL="cpu"
VRAM_GB=0

if $HAS_ROCM; then
    ACCEL="rocm"
    VRAM_GB="${ROCM_VRAM_GB}"
elif $HAS_CUDA; then
    ACCEL="cuda"
    VRAM_GB="${CUDA_VRAM_GB}"
fi

RAM_GB=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)

echo "ARCH=${ARCH}"
echo "CPU_COUNT=${CPU_COUNT}"
echo "RAM_GB=${RAM_GB}"
echo "ACCEL=${ACCEL}"
echo "VRAM_GB=${VRAM_GB}"
echo "OLLAMA_BUILD_TARGET=${ACCEL}"
