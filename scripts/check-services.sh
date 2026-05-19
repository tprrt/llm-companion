#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Thomas Perrot <thomas.perrot@tupi.fr>
# SPDX-License-Identifier: GPL-3.0-only

# =============================================================================
# check-services.sh — Health checks for the llm-companion stack
#
# Probes each service on localhost and reports OK / FAIL.
# Exits 0 only if all checks pass.
#
# Services checked:
#   Ollama        localhost:11434  GET /          → HTTP 200
#   Open WebUI    localhost:3000   GET /health    → HTTP 200
#   Open Terminal localhost:8000   GET /          → any HTTP response (reachable)
#   SearXNG       localhost:8888   GET /          → HTTP 200
#   Caddy         localhost:8080   GET /health    → HTTP 200 (proxied to Open WebUI)
#   Caddy/SearXNG localhost:8080   GET /searxng/  → HTTP 200 (proxied to SearXNG)
#
# Installed by Ansible to ~/.local/bin/check-services.sh on the target host.
# Also callable via: ./test-vm.sh check
# =============================================================================

set -uo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

OLLAMA_API_KEY=$(grep -s OLLAMA_API_KEY ~/.config/ollama/api-key.env | cut -d= -f2- || true)

# http_check: pass only on HTTP 200; any other code (000 = no connection) is a failure.
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

# port_check: pass on any HTTP response; 000 (no connection) is the only failure.
port_check() {
    local name="$1" url="$2"
    local code
    code=$(curl --connect-timeout 5 -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || true)
    if [[ "$code" != "000" ]]; then
        printf '%b[OK]%b    %s\n' "${GREEN}" "${NC}" "${name} — reachable (HTTP ${code})"
        return 0
    else
        printf '%b[FAIL]%b  %s\n' "${RED}" "${NC}" "${name} — connection failed"
        return 1
    fi
}

rc=0
http_check "Ollama (localhost:11434)"       "http://localhost:11434/"      || rc=1
http_check "Open WebUI (localhost:3000)"    "http://localhost:3000/health" || rc=1
port_check "Open Terminal (localhost:8000)" "http://localhost:8000/"       || rc=1
http_check "SearXNG (localhost:8888)"       "http://localhost:8888/"          || rc=1
http_check "Caddy (localhost:8080)"         "http://localhost:8080/health"    || rc=1
http_check "Caddy/SearXNG (:8080/searxng)"  "http://localhost:8080/searxng/" \
    -H "Authorization: Bearer ${OLLAMA_API_KEY}"  || rc=1
exit "$rc"
