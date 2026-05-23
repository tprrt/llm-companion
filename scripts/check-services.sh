#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Thomas Perrot <thomas.perrot@tupi.fr>
# SPDX-License-Identifier: GPL-3.0-only

# =============================================================================
# check-services.sh — Health checks for the llm-companion stack
#
# Runs two sets of probes and reports OK / FAIL for each.
# Exits 0 only if all checks pass.
#
# Container health (via podman inspect):
#   Reads Podman's native health state, which is driven by the livenessProbe
#   fields in stack.yml. No curl or exec into the container needed.
#   Ollama, Open WebUI, Open Terminal, SearXNG, Caddy → healthy / unhealthy
#
# Via Caddy (from VM host — only hostPort :8080 is published):
#   Open WebUI    localhost:8080   GET /health         → HTTP 200
#   Ollama        localhost:8080   GET /ollama/api/tags → HTTP 200 (Bearer token)
#   SearXNG       localhost:8080   GET /searxng/        → HTTP 200 (Bearer token)
#
# Installed by Ansible to $HOME/.local/bin/check-services.sh on the target host.
# Also callable via: ./vm.sh check
# =============================================================================

set -uo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'

OLLAMA_API_KEY=$(grep -s OLLAMA_API_KEY "$HOME/.config/ollama/api-key.env" | cut -d= -f2- || true)

# Reads Podman's native health state for a container (derived from livenessProbe).
# Status values: healthy | unhealthy | starting | none | unknown
pod_health_check() {
    local container="$1" name="$2"
    local status
    status=$(podman inspect --format '{{.State.Health.Status}}' "${container}" 2>/dev/null || echo "unknown")
    if [[ "${status}" == "healthy" ]]; then
        printf '%b[OK]%b    %s\n' "${GREEN}" "${NC}" "${name} — ${status}"
        return 0
    else
        local cstate restarts
        cstate=$(podman inspect --format '{{.State.Status}}' "${container}" 2>/dev/null || echo "?")
        restarts=$(podman inspect --format '{{.RestartCount}}' "${container}" 2>/dev/null || echo "?")
        printf '%b[FAIL]%b  %s\n' "${RED}" "${NC}" "${name} — health:${status:-unknown} container:${cstate} restarts:${restarts}"
        if [[ "${cstate}" == "stopped" || "${cstate}" == "exited" ]]; then
            printf '         recent logs:\n'
            podman logs --tail 5 "${container}" 2>&1 | sed 's/^/           /'
        fi
        return 1
    fi
}

http_check() {
    local name="$1" url="$2" extra_args=("${@:3}")
    local code
    code=$(curl --connect-timeout 5 -s -o /dev/null -w "%{http_code}" "${extra_args[@]}" "$url" 2>/dev/null || true)
    if [[ "$code" == "200" ]]; then
        printf '%b[OK]%b    %s\n' "${GREEN}" "${NC}" "${name} — HTTP ${code}"
        return 0
    else
        printf '%b[FAIL]%b  %s\n' "${RED}" "${NC}" "${name} — HTTP ${code}"
        return 1
    fi
}

rc=0

printf '%b── Container health (podman inspect) ───────────────%b\n' "${CYAN}" "${NC}"
pod_health_check "llm-companion-ollama"        "Ollama"         || rc=1
pod_health_check "llm-companion-open-webui"    "Open WebUI"     || rc=1
pod_health_check "llm-companion-open-terminal" "Open Terminal"  || rc=1
pod_health_check "llm-companion-searxng"       "SearXNG"        || rc=1
pod_health_check "llm-companion-caddy"         "Caddy"          || rc=1

printf '%b── Via Caddy (:8080) ───────────────────────────────%b\n' "${CYAN}" "${NC}"
http_check "Open WebUI (:8080/health)"    "http://localhost:8080/health"                              || rc=1
http_check "Ollama     (:8080/ollama/)"   "http://localhost:8080/ollama/api/tags"                     \
    -H "Authorization: Bearer ${OLLAMA_API_KEY}"                                                      || rc=1
http_check "SearXNG    (:8080/searxng/)"  "http://localhost:8080/searxng/"                            \
    -H "Authorization: Bearer ${OLLAMA_API_KEY}"                                                      || rc=1

exit "$rc"
