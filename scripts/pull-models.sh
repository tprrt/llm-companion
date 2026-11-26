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
#   ./pull-models.sh --yes        # skip the confirmation prompt (non-interactive)
#
# Hardware detection can be overridden, e.g. to select CPU models on a GPU host
# or to preview another machine's picks with --list:
#   LLM_ACCEL=cpu|rocm|cuda  LLM_VRAM_GB=N  LLM_RAM_GB=N (total RAM)
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
CONFIRM_YES=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)        MODE="all";        shift ;;
        --list)       LIST_ONLY=true;    shift ;;
        --reserve)    [[ $# -ge 2 ]] || die "--reserve requires a value"
                      RESERVE_GB="$2";  shift 2 ;;
        --yes|-y)     CONFIRM_YES=true;  shift ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ "${RESERVE_GB}" =~ ^[0-9]+$ ]] || die "--reserve must be a whole number of GB, got: ${RESERVE_GB}"

# ── Hardware detection ────────────────────────────────────────────────────────
ARCH=$(uname -m)   # x86_64 | aarch64

ACCEL="cpu"
VRAM_GB=0
ACCEL_LABEL="CPU only"

# Same rules as detect-hardware.sh, which picks the image Ansible builds: an
# SMI tool reporting less than GPU_MIN_VRAM_GB (e.g. an APU's shared
# framebuffer) is not a usable GPU, and an unusable ROCm device must not hide
# a real NVIDIA one.
GPU_MIN_VRAM_GB=2
ROCM_VRAM_GB=0
CUDA_VRAM_GB=0
if command -v rocm-smi &>/dev/null && rocm-smi &>/dev/null; then
    ROCM_VRAM_GB=$(rocm-smi --showmeminfo vram 2>/dev/null \
        | awk '/Total Memory/ {sum += $NF} END {printf "%.0f", sum/1024/1024/1024}')
fi
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
    CUDA_VRAM_GB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null \
        | awk '{sum += $1} END {printf "%.0f", sum/1024}')
fi

if [[ ${ROCM_VRAM_GB} -ge ${GPU_MIN_VRAM_GB} ]]; then
    ACCEL="rocm"
    VRAM_GB="${ROCM_VRAM_GB}"
    ACCEL_LABEL="AMD ROCm — ${VRAM_GB} GB VRAM"
elif [[ ${CUDA_VRAM_GB} -ge ${GPU_MIN_VRAM_GB} ]]; then
    ACCEL="cuda"
    VRAM_GB="${CUDA_VRAM_GB}"
    ACCEL_LABEL="NVIDIA CUDA — ${VRAM_GB} GB VRAM"
fi

TOTAL_RAM_GB=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)

# Detection overrides (see Usage).
if [[ -n "${LLM_ACCEL:-}" ]]; then
    case "${LLM_ACCEL}" in
        cpu)  ACCEL="cpu";  ACCEL_LABEL="CPU only (LLM_ACCEL)" ;;
        rocm) ACCEL="rocm"; ACCEL_LABEL="AMD ROCm (LLM_ACCEL)" ;;
        cuda) ACCEL="cuda"; ACCEL_LABEL="NVIDIA CUDA (LLM_ACCEL)" ;;
        *) die "LLM_ACCEL must be cpu, rocm or cuda, got: ${LLM_ACCEL}" ;;
    esac
    [[ "${ACCEL}" == "cpu" ]] && VRAM_GB=0
fi
if [[ -n "${LLM_VRAM_GB:-}" ]]; then
    [[ "${LLM_VRAM_GB}" =~ ^[0-9]+$ ]] || die "LLM_VRAM_GB must be a whole number, got: ${LLM_VRAM_GB}"
    VRAM_GB="${LLM_VRAM_GB}"
    ACCEL_LABEL="${ACCEL_LABEL} — ${VRAM_GB} GB VRAM"
fi
if [[ -n "${LLM_RAM_GB:-}" ]]; then
    [[ "${LLM_RAM_GB}" =~ ^[0-9]+$ ]] || die "LLM_RAM_GB must be a whole number, got: ${LLM_RAM_GB}"
    TOTAL_RAM_GB="${LLM_RAM_GB}"
fi
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
# categories  : comma-separated — coding, vision, general, embedding, task
#               order within each category = quality rank (first = best)
#
# GPU models are listed first so that priority lists naturally prefer them
# when a GPU is available, falling back to CPU models when not.

declare -a MODELS=(
    # ── GPU models ──────────────────────────────────────────────────────────
    # Coding model for hosts with 32 GB+ of VRAM: MoE with 39.8B total and
    # ~2.5B active parameters per token, against 27B for the dense model
    # below. Publisher-reported SWE-bench Verified 74.2. The 23 GB of
    # weights leave no room for a 32k KV cache on a 24 GB card, hence the
    # 32 GB gate. Apache 2.0. Not benchmarked here (no GPU).
    "Flint 40B|flint:40b|0|32|32768||any|any_gpu|coding|MoE 40B/2.5B-active; agentic coding; Apache 2.0; ~23 GB weights"

    # Best all-round model for GPU hosts: dense 27B with vision, tool use and
    # thinking; covers coding, vision and general from a single pull. Actual
    # Q4_K_M weight is 18 GB; ctx=32768 needs ~5 GB of KV cache headroom on top
    # (agentic editing keeps whole files + tool-call history in context), so
    # gate at 24 GB.
    "Qwen3.8 27B|qwen3.8:27b|0|24|32768||any|any_gpu|coding,vision,general|Newest Qwen; agentic coding + vision + thinking in one model; ~18 GB weights"

    # Vision + general model for 20-23 GB cards and the alternative to
    # Qwen3.8 27B above with fewer active parameters: MoE with 25.2B total and
    # 3.8B active. Q4_K_M weight is 16-18 GB; the 20 GB gate assumes Gemma 4's
    # sliding-window attention keeps the 16k KV cache small. Not benchmarked
    # here (no GPU).
    "Gemma 4 26B|gemma4:26b|0|20|16384||any|any_gpu|vision,general|MoE 25B/3.8B-active; thinking + vision; ~18 GB weights"

    # Mid-GPU vision + general model (12-19 GB VRAM). Actual Q4_K_M weight is
    # 7.7 GB; 16384 ctx plus KV cache fits a 12 GB card.
    "Gemma 4 12B|gemma4:12b|0|12|16384||any|any_gpu|vision,general|Native multimodal; mid-GPU tier; ~7.7 GB weights"

    # GPU coding model for 12-23 GB cards: the CPU tier's MiMo-V2.6 9B at
    # Q8_0 (10 GB) with a 32k context. At Q4_K_M and 16k it used ~1 GB above
    # its weights on CPU; the 12 GB gate extrapolates from that. Replaces
    # qwen2.5-coder:14b, whose 7B and 1.5B siblings write tool calls as plain
    # text.
    "MiMo-V2.6 9B Q8|mimo-v2.6:9b-q8_0|0|12|32768||any|any_gpu|coding|Code + agent fine-tune of Qwen3.5-9B at Q8; tools + vision; ~10 GB"

    # ── CUDA models (NVIDIA CUDA, ≥ 24 GB VRAM) ─────────────────────────────
    # MoE alternative to Qwen3.8 27B: 33B total / 3B active → faster tokens at
    # similar VRAM, built for agentic coding and long-horizon work. Actual
    # weight is 20 GB; with KV cache at 32k ctx it needs a 24 GB card.
    "Laguna XS 2.1|laguna-xs-2.1|0|24|32768||any|cuda|coding|MoE 33B/3B-active; agentic coding; faster than dense 27B; ~20 GB weights"

    # ── CPU models (any architecture) ───────────────────────────────────────
    # Gates are the resident memory measured with Ollama 0.40.18 at the listed
    # context on a Zen 5 laptop CPU (Ryzen AI 7 350, 8 cores), rounded up.
    # Speeds below are prompt / generation tokens per second on that machine,
    # for a ~1.8K-token code prompt. All of these return real tool calls; the
    # Qwen2.5-Coder models they replace wrote tool calls as plain JSON text,
    # which Ollama does not turn into tool_calls, so agents never saw them.
    #
    # These models think by default and ignore a "/no_think" system prompt on
    # Ollama 0.40.x; disable thinking per request instead (Ollama "think":
    # false, or "reasoning_effort": "none" on /v1).

    # Best CPU coding model: Xiaomi's code/agent fine-tune of Qwen3.5-9B, with
    # vision. 71 / 6.7 tok/s, 7.6 GB at 16k.
    "MiMo-V2.6 9B|mimo-v2.6:9b|8|0|16384||any|cpu|coding|Code + agent fine-tune of Qwen3.5-9B; tools + vision; ~6.6 GB"

    # Fastest model in the 8 GB class: 201 / 16.5 tok/s, 2.5x the 9B models,
    # with tools and vision. 7.3 GB at 8k. The "4B" in "e4b" is *effective*
    # parameters; the download is 6.6 GB.
    "Gemma 4 4B|gemma4:e4b|8|0|8192||any|cpu|vision,general|Native multimodal; fastest 8 GB pick; ~6.6 GB weights"

    # Coding at 5-7 GB: 121 / 11.8 tok/s, 4.3 GB at 16k.
    "Qwen3.5 4B|qwen3.5:4b|5|0|16384||any|cpu|coding|Tools + vision + thinking; ~3.3 GB"

    # Vision + general at 5-7 GB: 182 / 14.3 tok/s, 4.9 GB at 16k.
    "Ministral-3 3B|ministral-3:3b|5|0|16384||any|cpu|vision,general|Vision; 40+ languages; fast; ~3 GB"

    # ── CPU models (≤ 2 GB effective RAM) ───────────────────────────────────
    # Coding + vision on constrained devices: 484 / 31.7 tok/s, 1.7 GB at 4k.
    "Qwen3.5 0.8B|qwen3.5:0.8b|2|0|4096||any|cpu|coding,vision|Tools + vision; smallest catalogue model; ~1.3 GB"

    # General chat on constrained devices: 318 / 30.5 tok/s, 1.3 GB at 4k,
    # 256K native context.
    "LFM3 1.7B|lfm3:1.7b|2|0|4096||any|cpu|general|Hybrid model for local agents; tools + thinking; ~1.1 GB"

    # ── Any-arch embedding model (≤ 1 GB RAM) ───────────────────────────────
    # Required by Open WebUI for RAG / document search (RAG_EMBEDDING_MODEL in
    # the stack manifests); always pull. 3,040 tok/s on the CPU above vs
    # 2,292 for nomic-embed-text, 1.0 GB resident. 2K context, ample for Open
    # WebUI's default ~1,000-character chunks.
    "EmbeddingGemma 300M|embeddinggemma:300m|1|0|2048||any|cpu|embedding|Open WebUI RAG / document search embedding; ~620 MB"
)

# ── Category priority lists (best tag first) ──────────────────────────────────
# The selection algorithm picks the first tag in each list that passes the
# hardware check. GPU models are listed before CPU models so a GPU host
# naturally gets the best GPU model without any explicit GPU/CPU branching.
# shellcheck disable=SC2034  # referenced via nameref (local -n) in find_best
CODING_PRIORITY=(     "flint:40b" "qwen3.8:27b" "laguna-xs-2.1" "mimo-v2.6:9b-q8_0" "mimo-v2.6:9b" "qwen3.5:4b" "qwen3.5:0.8b" )
# shellcheck disable=SC2034
VISION_PRIORITY=(     "qwen3.8:27b" "gemma4:26b" "gemma4:12b" "gemma4:e4b" "ministral-3:3b" "qwen3.5:0.8b" )
# shellcheck disable=SC2034
GENERAL_PRIORITY=(    "qwen3.8:27b" "gemma4:26b" "gemma4:12b" "gemma4:e4b" "ministral-3:3b" "lfm3:1.7b" )
# shellcheck disable=SC2034
EMBEDDING_PRIORITY=(  "embeddinggemma:300m" )
# TASK_MODEL (see kube/stack.yml.j2) needs a tiny model that is always created regardless
# of hardware tier, independent of whichever model wins the categories above —
# otherwise Open WebUI's title-generation / search-query background tasks 404.
# With thinking disabled (TASK_MODEL_PARAMS), qwen3.5:0.8b wrote a clean
# 6-word title in 9 tokens / 0.3 s; lfm3:1.7b needed 56 tokens and ignored the
# length limit.
# shellcheck disable=SC2034
TASK_PRIORITY=(        "qwen3.5:0.8b" )

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
        *) return 1 ;;
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
        *) echo "unknown accel: ${accel}" ;;
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
    for pair in "coding:CODING_PRIORITY" "vision:VISION_PRIORITY" "general:GENERAL_PRIORITY" "embedding:EMBEDDING_PRIORITY" "task:TASK_PRIORITY"; do
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
if ! $CONFIRM_YES; then
    echo -n "Proceed? [y/N] "
    read -r confirm
    [[ "${confirm,,}" == "y" ]] || { info "Aborted."; exit 0; }
fi
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
info "Done. Use the variant tags (e.g. mimo-v2.6-9b-16k) in opencode.json."
