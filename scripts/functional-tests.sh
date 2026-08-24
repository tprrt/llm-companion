#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Thomas Perrot <thomas.perrot@tupi.fr>
# SPDX-License-Identifier: GPL-3.0-only

# =============================================================================
# functional-tests.sh — Behavioral checks for a deployed llm-companion stack
#
# check-services.sh only proves each service is *up* (container health +
# HTTP 200 through Caddy). This script proves each service actually works:
# real inference through Ollama, a real search through SearXNG, real auth
# enforcement at the Caddy layer, and real Ollama connectivity from inside
# the Open WebUI container.
#
# Self-contained: no sourcing, no sibling-file dependency, so it can run
# directly on a deployed host or be piped over ssh to one that doesn't have
# the repo checked out:
#   ssh myhost 'bash -s' < scripts/functional-tests.sh
#
# Run this on demand after any change to confirm nothing broke. It is
# heavier and slower than check-services.sh (a real inference call, a real
# web search), so it is not installed by Ansible and not run in CI, which
# has no live deployment to test against.
#
# Requires: a pulled Ollama model (run scripts/pull-models.sh first), and
# OLLAMA_API_KEY in $HOME/.config/ollama/api-key.env (same as check-services.sh).
#
# Caveat: the SearXNG check can report no results if the host has no
# outbound internet access to reach upstream search engines — that is not
# necessarily a regression.
#
# Exits 0 only if all checks pass.
# =============================================================================

set -uo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'

OLLAMA_API_KEY=$(grep -s OLLAMA_API_KEY "$HOME/.config/ollama/api-key.env" | cut -d= -f2- || true)
BASE_URL="http://localhost:8080"

rc=0

ok() {
    printf '%b[OK]%b    %s\n' "${GREEN}" "${NC}" "$1"
}

fail() {
    local name="$1" detail="${2:-}"
    printf '%b[FAIL]%b  %s\n' "${RED}" "${NC}" "${name}"
    if [[ -n "${detail}" ]]; then
        printf '%s\n' "${detail}" | sed 's/^/         /'
    fi
    rc=1
}

# Prints "<body>\n<http_code>" for a Bearer-authenticated GET. Caller splits
# on the last newline. The token is fed to curl via -K - (config from
# stdin), not -H, so it never appears in ps/`/proc/*/cmdline`.
# shellcheck disable=SC2329 # Interface for Tasks 2-4
get_bearer() {
    local url="$1" maxtime="$2"
    printf 'header = "Authorization: Bearer %s"\n' "${OLLAMA_API_KEY}" \
        | curl -s --connect-timeout 5 --max-time "${maxtime}" -K - \
            -w '\n%{http_code}' "${url}" 2>/dev/null
}

step_auth() {
    printf '%b── Auth enforcement ────────────────────────────────%b\n' "${CYAN}" "${NC}"

    local code
    code=$(curl -s --connect-timeout 5 --max-time 10 -o /dev/null -w '%{http_code}' \
        "${BASE_URL}/ollama/api/tags" 2>/dev/null)
    if [[ "${code}" == "401" ]]; then
        ok "Auth — no Authorization header rejected (HTTP ${code})"
    else
        fail "Auth — no Authorization header rejected" "Expected HTTP 401, got HTTP ${code:-<no response>}"
    fi

    code=$(printf 'header = "Authorization: Bearer wrong-token"\n' \
        | curl -s --connect-timeout 5 --max-time 10 -o /dev/null -w '%{http_code}' -K - \
            "${BASE_URL}/ollama/api/tags" 2>/dev/null)
    if [[ "${code}" == "401" ]]; then
        ok "Auth — wrong Bearer token rejected (HTTP ${code})"
    else
        fail "Auth — wrong Bearer token rejected" "Expected HTTP 401, got HTTP ${code:-<no response>}"
    fi
}

step_auth

exit "${rc}"
