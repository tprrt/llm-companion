#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Thomas Perrot <thomas.perrot@tupi.fr>
# SPDX-License-Identifier: GPL-3.0-only

# =============================================================================
# render-stack.sh — Render kube/stack.yml.j2 for one Ollama build target
#
# Usage:
#   ./render-stack.sh <cpu|rocm|cuda> [OUTPUT]
#
# Writes the rendered Pod manifest to OUTPUT, or to stdout when OUTPUT is
# omitted. Uses Ansible's template engine, the same one the llm_stack role
# uses, so the result matches what a playbook run deploys.
#
# ROCm GFX override: set HSA_OVERRIDE_GFX_VERSION in the environment (e.g.
# 11.0.0), matching the ollama_hsa_override_gfx_version Ansible variable.
# TLS: set LLM_TLS_HOSTNAMES to a comma-separated list of host names and IPs
# (e.g. llm.lan,192.168.1.10), matching the llm_tls_hostnames variable.
# Chat thinking: LLM_CHAT_THINKING=true|false overrides the default (off for
# cpu, on otherwise), matching the llm_chat_thinking variable.
# KV cache: OLLAMA_KV_CACHE_TYPE=q8_0|q4_0, matching ollama_kv_cache_type.
#
# Requires: ansible-core (the `ansible` command).
# =============================================================================

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $# -ge 1 && $# -le 2 ]] || die "Usage: $0 <cpu|rocm|cuda> [OUTPUT]"
TARGET="$1"
case "${TARGET}" in
    cpu|rocm|cuda) ;;
    *) die "Unknown build target '${TARGET}' (expected cpu, rocm or cuda)" ;;
esac
command -v ansible &>/dev/null || die "ansible not found; install ansible-core"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_DIR="$(dirname -- "${SCRIPT_DIR}")"

OUT="$(mktemp)"
trap 'rm -f "${OUT}"' EXIT

EXTRA_VARS=$(python3 -c 'import json, sys; print(json.dumps({
    "ollama_build_target": sys.argv[1],
    "llm_repo_dir": sys.argv[2],
    "ollama_hsa_override_gfx_version": sys.argv[3],
    "llm_tls_hostnames": [h.strip() for h in sys.argv[4].split(",") if h.strip()],
    "llm_chat_thinking": sys.argv[5] if sys.argv[5] else sys.argv[1] != "cpu",
    "ollama_kv_cache_type": sys.argv[6]}))' \
    "${TARGET}" "${REPO_DIR}" "${HSA_OVERRIDE_GFX_VERSION:-}" "${LLM_TLS_HOSTNAMES:-}" "${LLM_CHAT_THINKING:-}" \
    "${OLLAMA_KV_CACHE_TYPE:-}")

ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_INVENTORY_UNPARSED_WARNING=false \
    ansible localhost -c local -m ansible.builtin.template \
        -a "src=${REPO_DIR}/kube/stack.yml.j2 dest=${OUT} mode=0600" \
        -e "${EXTRA_VARS}" >/dev/null \
    || die "Rendering failed; re-run with: ansible localhost -c local -m ansible.builtin.template -a 'src=${REPO_DIR}/kube/stack.yml.j2 dest=${OUT}' -e '${EXTRA_VARS}'"

if [[ $# -eq 2 ]]; then
    install -m 0644 "${OUT}" "$2"
else
    cat "${OUT}"
fi
