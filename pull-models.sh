#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Thomas Perrot <thomas.perrot@tupi.fr>
# SPDX-License-Identifier: GPL-3.0-only

# =============================================================================
# pull-models.sh — Pull and configure models for the running Ollama container
#
# Auto-detects architecture, accelerator (CPU / AMD ROCm / NVIDIA CUDA), and
# available RAM or VRAM, then selects the best fitting model per use case.
#
# Usage:
#   ./pull-models.sh              # best model per category (default)
#   ./pull-models.sh --all        # all models that fit the hardware
#   ./pull-models.sh --list       # dry run — show what would be pulled
#   ./pull-models.sh --reserve N  # reserve N GB RAM (OS + stack + context, default: 2)
#
# Categories:
#   coding  — agentic tool use, multi-file edits, OpenCode sessions
#   vision  — image / schematic input, multilingual tasks
#   general — chat, reasoning, quick one-shot questions
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERR]${NC}   $*" >&2; exit 1; }

# ── Options ───────────────────────────────────────────────────────────────────
# Container name follows the podman play kube convention: <pod>-<container>
CONTAINER_NAME="llm-companion-ollama"
RESERVE_GB=2
MODE="best"     # "best" | "all"
LIST_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)     MODE="all";        shift ;;
        --list)    LIST_ONLY=true;    shift ;;
        --reserve) RESERVE_GB="$2";  shift 2 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

# ── Hardware detection ────────────────────────────────────────────────────────
ARCH=$(uname -m)   # x86_64 | aarch64

ACCEL="cpu"
VRAM_GB=0
ACCEL_LABEL="CPU only"

if command -v rocm-smi &>/dev/null && rocm-smi &>/dev/null 2>&1; then
    ACCEL="rocm"
    VRAM_GB=$(rocm-smi --showmeminfo vram 2>/dev/null \
        | awk '/Total Memory/ {sum += $NF} END {printf "%.0f", sum/1024/1024}')
    ACCEL_LABEL="AMD ROCm — ${VRAM_GB} GB VRAM"
elif command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
    ACCEL="cuda"
    VRAM_GB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null \
        | awk '{sum += $1} END {printf "%.0f", sum/1024}')
    ACCEL_LABEL="NVIDIA CUDA — ${VRAM_GB} GB VRAM"
fi

TOTAL_RAM_GB=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)
EFFECTIVE_RAM_GB=$(( TOTAL_RAM_GB - RESERVE_GB ))
[[ ${EFFECTIVE_RAM_GB} -lt 0 ]] && EFFECTIVE_RAM_GB=0

echo ""
info "Architecture : ${ARCH}"
info "Accelerator  : ${ACCEL_LABEL}"
info "RAM          : ${TOTAL_RAM_GB} GB total — ${RESERVE_GB} GB reserved — ${EFFECTIVE_RAM_GB} GB effective"
echo ""

# ── Container check ───────────────────────────────────────────────────────────
if ! $LIST_ONLY; then
    podman inspect "${CONTAINER_NAME}" &>/dev/null || \
        die "Container '${CONTAINER_NAME}' is not running.\n  systemctl --user start llm-companion"
fi

# ── Model catalogue ───────────────────────────────────────────────────────────
# Format: "name|tag|min_ram_gb|min_vram_gb|ctx|extra_modelfile|arch|accel|categories|note"
#
# arch        : any | x86_64 | aarch64
# accel       : cpu | rocm | cuda | any_gpu
# min_ram_gb  : effective RAM gate for CPU models  (0 = no CPU RAM check)
# min_vram_gb : VRAM gate for GPU models           (0 = no VRAM check)
# categories  : comma-separated — coding, vision, general
#               order within each category = quality rank (first = best)
#
# GPU models are listed first so that priority lists naturally prefer them
# when a GPU is available, falling back to CPU models when not.

declare -a MODELS=(
    # ── GPU models ──────────────────────────────────────────────────────────
    # Best-in-class for agentic SWE work; requires a GPU with ≥ 16 GB VRAM.
    # ctx=32768: Devstral is purpose-built for multi-file agentic editing; the
    # larger context window (vs 16384 for CPU models) fits whole files + tool
    # call history without truncation. GPU VRAM makes the extra KV cache
    # (~2 GB over 16k) affordable; CPU hosts use 16k to avoid OOM.
    "Devstral-Small-2 24B|devstral-small-2:24b|0|16|32768||any|any_gpu|coding|SWE-bench leader, purpose-built agentic coding, ~15 GB"

    # Best GPU general + vision model; complements Devstral on the same host.
    "Ministral-3 14B|ministral-3:14b|0|14|16384||any|any_gpu|vision,general|High-quality Ministral; vision; ~9 GB"

    # Best GPU coding model for hosts with 10–15 GB VRAM (fills Devstral gap).
    "Qwen2.5-Coder 14B|qwen2.5-coder:14b|0|10|32768||any|any_gpu|coding|Reliable tool-call format; mid-GPU tier; ~9 GB"

    # ── CUDA models (NVIDIA CUDA, ≥ 20 GB VRAM) ─────────────────────────────
    # Larger coding model for the 24 GB VRAM tier; fills the gap between
    # Devstral-Small-2 (16 GB gate) and smaller any_gpu models.
    "Qwen2.5-Coder 32B|qwen2.5-coder:32b|0|20|32768||any|cuda|coding|Top open coding model; 24 GB tier; ~20 GB"

    # Best open reasoning model at the 24 GB VRAM tier; chain-of-thought native.
    "DeepSeek-R1 32B|deepseek-r1:32b|0|20|32768||any|cuda|general|Top open reasoning; chain-of-thought; 24 GB tier; ~20 GB"

    # ── x86_64 CPU models (8 GB+ RAM) ──────────────────────────────────────
    # Best open agentic model at the 8 GB CPU tier; native multimodal (vision
    # built-in). Replaces both Qwen3 8B (coding+general) and Ministral-3 8B
    # (vision) with a single model. Thinking disabled for tool calls.
    "Qwen3.5 9B|qwen3.5:9b|8|0|16384|SYSTEM \"/no_think\"|x86_64|cpu|coding,vision,general|Native multimodal; better than Qwen3 8B across all tasks; ~5.5 GB"

    # Most reliable tool-call format compatibility — use if Qwen3 breaks tools.
    "Qwen2.5-Coder 7B|qwen2.5-coder:7b|6|0|16384||x86_64|cpu|coding|Most reliable tool-call format; ~4.5 GB"

    # Best open reasoning model at the 6 GB CPU tier; chain-of-thought native.
    "DeepSeek-R1 7B|deepseek-r1:7b|6|0|16384||x86_64|cpu|general|Best CPU reasoning; chain-of-thought; ~5 GB"

    # ── Any-arch CPU models (4 GB RAM) ─────────────────────────────────────
    # Smallest vision-capable model; also useful as a fast general fallback.
    "Ministral-3 3B|ministral-3:3b|4|0|16384||any|cpu|vision,general|Vision; 40+ languages; fast fallback; ~2 GB"

    # Google Gemma 4 4B edge — native multimodal; clear upgrade over Gemma 3 4B.
    "Gemma 4 4B|gemma4:e4b|4|0|8192||any|cpu|vision,general|Native multimodal; Gemma 4 edge model; strong reasoning; ~2.5 GB"

    # ── Any-arch CPU models (≤ 2 GB RAM) ───────────────────────────────────
    # Best code + tool-call model for constrained devices (ARM64, 2 GB+).
    # ctx=4096: weights ~1 GB + KV cache ~0.3 GB = ~1.3 GB total.
    # (ctx=16384 would add ~1.5 GB KV cache, exceeding the 2 GB effective RAM budget.)
    "Qwen2.5-Coder 1.5B|qwen2.5-coder:1.5b|2|0|4096||any|cpu|coding|Best code + tool-call at sub-2 GB; ~1.3 GB at ctx=4k"

    # Best reasoning model for constrained devices; thinking disabled.
    # ctx=4096: weights ~1.1 GB + KV cache ~0.44 GB = ~1.5 GB total.
    # (ctx=16384 would add ~1.75 GB KV cache, pushing total to ~3.1 GB.)
    "Qwen3 1.7B|qwen3:1.7b|2|0|4096|SYSTEM \"/no_think\"|any|cpu|general|Best reasoning at sub-2 GB; thinking disabled; ~1.5 GB at ctx=4k"

    # Smallest vision model; fills vision gap on ARM64 and ≤ 2 GB hosts.
    "Moondream 2 1.8B|moondream:1.8b|2|0|2048||any|cpu|vision|Smallest vision model; image QA; ~1.1 GB"

    # ── Any-arch embedding model (≤ 1 GB RAM) ───────────────────────────────
    # Required by Open WebUI for RAG / document search; always pull.
    "Nomic Embed Text|nomic-embed-text|1|0|8192||any|cpu|embedding|Open WebUI RAG / document search embedding; ~274 MB"
)

# ── Category priority lists (best tag first) ──────────────────────────────────
# The selection algorithm picks the first tag in each list that passes the
# hardware check. GPU models are listed before CPU models so a GPU host
# naturally gets the best GPU model without any explicit GPU/CPU branching.
# shellcheck disable=SC2034  # referenced via nameref (local -n) in find_best
CODING_PRIORITY=(     "devstral-small-2:24b" "qwen2.5-coder:32b" "qwen2.5-coder:14b" "qwen3.5:9b" "qwen2.5-coder:7b" "qwen2.5-coder:1.5b" )
# shellcheck disable=SC2034
VISION_PRIORITY=(     "ministral-3:14b"      "qwen3.5:9b" "gemma4:e4b" "ministral-3:3b" "moondream:1.8b" )
# shellcheck disable=SC2034
GENERAL_PRIORITY=(    "deepseek-r1:32b" "ministral-3:14b" "qwen3.5:9b" "deepseek-r1:7b" "gemma4:e4b" "ministral-3:3b" "qwen3:1.7b" )
# shellcheck disable=SC2034
EMBEDDING_PRIORITY=(  "nomic-embed-text" )

# ── Hardware compatibility ────────────────────────────────────────────────────
# model_fits: returns 0 if the model can run on this hardware, 1 otherwise.
# get_skip_reason: prints a human-readable explanation of why it was skipped.

model_fits() {
    local arch="$1" accel="$2" min_ram="$3" min_vram="$4"
    [[ "$arch" == "any" || "$arch" == "$ARCH" ]] || return 1
    case "$accel" in
        cpu)
            [[ "$EFFECTIVE_RAM_GB" -ge "$min_ram" ]] || return 1 ;;
        rocm)
            [[ "$ACCEL" == "rocm" && "$VRAM_GB" -ge "$min_vram" ]] || return 1 ;;
        cuda)
            [[ "$ACCEL" == "cuda" && "$VRAM_GB" -ge "$min_vram" ]] || return 1 ;;
        any_gpu)
            [[ "$ACCEL" != "cpu" && "$VRAM_GB" -ge "$min_vram" ]] || return 1 ;;
    esac
    return 0
}

get_skip_reason() {
    local arch="$1" accel="$2" min_ram="$3" min_vram="$4"
    [[ "$arch" == "any" || "$arch" == "$ARCH" ]] \
        || { echo "need ${arch}"; return; }
    case "$accel" in
        cpu)
            [[ "$EFFECTIVE_RAM_GB" -ge "$min_ram" ]] \
                || { echo "need ${min_ram} GB RAM, have ${EFFECTIVE_RAM_GB} GB"; return; } ;;
        rocm)
            [[ "$ACCEL" == "rocm" ]] \
                || { echo "need AMD ROCm"; return; }
            [[ "$VRAM_GB" -ge "$min_vram" ]] \
                || { echo "need ${min_vram} GB VRAM, have ${VRAM_GB} GB"; return; } ;;
        cuda)
            [[ "$ACCEL" == "cuda" ]] \
                || { echo "need NVIDIA CUDA"; return; }
            [[ "$VRAM_GB" -ge "$min_vram" ]] \
                || { echo "need ${min_vram} GB VRAM, have ${VRAM_GB} GB"; return; } ;;
        any_gpu)
            [[ "$ACCEL" != "cpu" ]] \
                || { echo "need GPU (ROCm or CUDA)"; return; }
            [[ "$VRAM_GB" -ge "$min_vram" ]] \
                || { echo "need ${min_vram} GB VRAM, have ${VRAM_GB} GB"; return; } ;;
    esac
}

# ── Find best fitting model for a category ────────────────────────────────────
find_best() {
    local -n _prio="$1"
    for tag in "${_prio[@]}"; do
        for entry in "${MODELS[@]}"; do
            IFS='|' read -r _n model_tag min_ram min_vram _ctx _ex arch accel _cats _note <<< "$entry"
            [[ "$model_tag" == "$tag" ]] || continue
            model_fits "$arch" "$accel" "$min_ram" "$min_vram" && echo "$model_tag" && return
        done
    done
    echo ""
}

# ── Build pull set ────────────────────────────────────────────────────────────
declare -A PULL_USES    # tag → "use case" label shown in the table
declare -a PULL_ORDER=()

if [[ "$MODE" == "best" ]]; then
    for pair in "coding:CODING_PRIORITY" "vision:VISION_PRIORITY" "general:GENERAL_PRIORITY" "embedding:EMBEDDING_PRIORITY"; do
        use="${pair%%:*}"
        pvar="${pair##*:}"
        best=$(find_best "$pvar")
        if [[ -n "$best" ]]; then
            if [[ -v PULL_USES["$best"] ]]; then
                PULL_USES["$best"]+=" + ${use}"
            else
                PULL_USES["$best"]="${use}"
                PULL_ORDER+=("$best")
            fi
        else
            warn "No fitting model found for '${use}' on this hardware."
        fi
    done
else
    # --all: every model that passes the hardware check
    for entry in "${MODELS[@]}"; do
        IFS='|' read -r _n model_tag min_ram min_vram _ctx _ex arch accel categories _note <<< "$entry"
        model_fits "$arch" "$accel" "$min_ram" "$min_vram" || continue
        PULL_USES["$model_tag"]="${categories//,/ + }"
        PULL_ORDER+=("$model_tag")
    done
fi

# ── Print table ───────────────────────────────────────────────────────────────
size_label() {
    # GPU models show VRAM; CPU models show RAM.
    local accel="$1" min_ram="$2" min_vram="$3"
    [[ "$accel" == "cpu" ]] && echo "${min_ram}G RAM" || echo "${min_vram}G VRAM"
}

echo "────────────────────────────────────────────────────────────────────────────────────────────────"
printf "  ${BOLD}%-22s %-28s %-10s %-6s %-22s${NC}\n" "Model" "Tag" "Size" "Status" "Use case"
echo "────────────────────────────────────────────────────────────────────────────────────────────────"

for entry in "${MODELS[@]}"; do
    IFS='|' read -r name model_tag min_ram min_vram ctx extra arch accel categories _note <<< "$entry"
    size=$(size_label "$accel" "$min_ram" "$min_vram")

    if [[ -v PULL_USES["$model_tag"] ]]; then
        label="PULL"; [[ "$MODE" == "best" ]] && label="BEST"
        printf "  %-22s %-28s %-10s ${GREEN}%-6s${NC} %s\n" \
            "$name" "$model_tag" "$size" "$label" "${PULL_USES[$model_tag]}"
    else
        reason=$(get_skip_reason "$arch" "$accel" "$min_ram" "$min_vram")
        printf "  %-22s %-28s %-10s ${CYAN}%-6s${NC} %s\n" \
            "$name" "$model_tag" "$size" "skip" "$reason"
    fi
done
echo "────────────────────────────────────────────────────────────────────────────────────────────────"
echo ""

$LIST_ONLY && exit 0

[[ ${#PULL_ORDER[@]} -eq 0 ]] && {
    warn "No models to pull for this hardware."
    warn "Use --all to override, or --reserve 1 to reduce the safety margin."
    exit 0
}

# ── Confirm ───────────────────────────────────────────────────────────────────
echo -n "Proceed? [y/N] "
read -r confirm
[[ "${confirm,,}" == "y" ]] || { info "Aborted."; exit 0; }
echo ""

# ── Pull helper ───────────────────────────────────────────────────────────────
pull_and_configure() {
    local model="$1" ctx="$2" extra="${3:-}"
    local variant
    variant="${model/:/-}-$(( ctx / 1024 ))k"

    info "Pulling ${model}..."
    # Use -t only when running in a terminal (avoids TTY errors when scripted).
    local tty_flag=""
    [[ -t 0 ]] && tty_flag="-t"
    # shellcheck disable=SC2086
    podman exec -i ${tty_flag} "${CONTAINER_NAME}" ollama pull "${model}"

    info "Creating context variant: ${variant} (num_ctx=${ctx})..."
    local modelfile_body
    modelfile_body="FROM ${model}
PARAMETER num_ctx ${ctx}
PARAMETER temperature 0.15"
    [[ -n "${extra}" ]] && modelfile_body="${modelfile_body}
${extra}"

    podman exec -i "${CONTAINER_NAME}" bash -c "
        cat > /tmp/Modelfile_work << 'MODELEOF'
${modelfile_body}
MODELEOF
        ollama create \"${variant}\" -f /tmp/Modelfile_work
        rm /tmp/Modelfile_work
    "
    info "  ✓ ${variant} ready — use this tag in opencode.json"
}

# ── Pull loop ─────────────────────────────────────────────────────────────────
for tag in "${PULL_ORDER[@]}"; do
    for entry in "${MODELS[@]}"; do
        IFS='|' read -r name model_tag min_ram min_vram ctx extra arch accel categories _note <<< "$entry"
        [[ "$model_tag" == "$tag" ]] || continue
        echo ""
        info "━━ ${name} (${model_tag}) — ${PULL_USES[$tag]} ━━"
        pull_and_configure "$model_tag" "$ctx" "$extra"
        break
    done
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
info "Installed models:"
podman exec "${CONTAINER_NAME}" ollama list
echo ""
info "Done. Use the variant tags (e.g. qwen3-8b-16k) in opencode.json."
