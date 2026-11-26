#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Thomas Perrot <thomas.perrot@tupi.fr>
# SPDX-License-Identifier: GPL-3.0-only

# =============================================================================
# tests/pull-models.sh — Check pull-models.sh's model selection per hardware
#
# Runs `pull-models.sh --list` with faked hardware (LLM_ACCEL, LLM_VRAM_GB,
# LLM_RAM_GB) and compares the picked model of every category with the
# expected one. Catches catalogue, gate and priority-list mistakes before
# they reach a host. Needs no container and no network.
#
# Usage: tests/pull-models.sh
# =============================================================================

set -euo pipefail

SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/scripts/pull-models.sh"
rc=0

# Prints the "category=tag" picks, sorted, on one line.
picks() {
    LLM_ACCEL="$1" LLM_VRAM_GB="$2" LLM_RAM_GB="$3" bash "${SCRIPT}" --list 2>/dev/null \
        | sed 's/\x1b\[[0-9;]*m//g' \
        | awk '/ BEST / {
                   tag = $0; sub(/^ +.{22} /, "", tag); sub(/ .*/, "", tag)
                   uses = $0; sub(/^.* BEST +/, "", uses)
                   n = split(uses, u, / \+ /)
                   for (i = 1; i <= n; i++) print u[i] "=" tag
               }' \
        | sort | tr '\n' ' ' | sed 's/ $//'
}

# expect ACCEL VRAM_GB TOTAL_RAM_GB "category=tag ..." (sorted by category)
expect() {
    local got
    got="$(picks "$1" "$2" "$3")"
    if [[ "${got}" == "$4" ]]; then
        printf 'ok    %-5s vram=%-3s ram=%-3s\n' "$1" "$2" "$3"
    else
        printf 'FAIL  %-5s vram=%-3s ram=%-3s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3" "$4" "${got}"
        rc=1
    fi
}

# Default reserve is 2 GB, so effective RAM = total - 2.
expect cpu  0  3  "embedding=embeddinggemma:300m"
expect cpu  0  4  "coding=qwen3.5:0.8b embedding=embeddinggemma:300m general=lfm3:1.7b task=qwen3.5:0.8b vision=qwen3.5:0.8b"
expect cpu  0  7  "coding=qwen3.5:4b embedding=embeddinggemma:300m general=ministral-3:3b task=qwen3.5:0.8b vision=ministral-3:3b"
expect cpu  0  10 "coding=mimo-v2.6:9b embedding=embeddinggemma:300m general=gemma4:e4b task=qwen3.5:0.8b vision=gemma4:e4b"
expect rocm 4  10 "coding=mimo-v2.6:9b embedding=embeddinggemma:300m general=gemma4:e4b task=qwen3.5:0.8b vision=gemma4:e4b"
expect rocm 12 32 "coding=mimo-v2.6:9b-q8_0 embedding=embeddinggemma:300m general=gemma4:12b task=qwen3.5:0.8b vision=gemma4:12b"
expect rocm 20 32 "coding=mimo-v2.6:9b-q8_0 embedding=embeddinggemma:300m general=gemma4:26b task=qwen3.5:0.8b vision=gemma4:26b"
expect rocm 24 32 "coding=qwen3.8:27b embedding=embeddinggemma:300m general=qwen3.8:27b task=qwen3.5:0.8b vision=qwen3.8:27b"
expect cuda 24 32 "coding=qwen3.8:27b embedding=embeddinggemma:300m general=qwen3.8:27b task=qwen3.5:0.8b vision=qwen3.8:27b"
expect cuda 32 64 "coding=flint:40b embedding=embeddinggemma:300m general=qwen3.8:27b task=qwen3.5:0.8b vision=qwen3.8:27b"
expect rocm 48 64 "coding=flint:40b embedding=embeddinggemma:300m general=qwen3.8:27b task=qwen3.5:0.8b vision=qwen3.8:27b"

exit "${rc}"
