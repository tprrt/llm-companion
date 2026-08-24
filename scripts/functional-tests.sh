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
get_bearer() {
    local url="$1" maxtime="$2"
    printf 'header = "Authorization: Bearer %s"\n' "${OLLAMA_API_KEY}" \
        | curl -s --connect-timeout 5 --max-time "${maxtime}" -K - \
            -w '\n%{http_code}' "${url}" 2>/dev/null
}

# Prints "<body>\n<http_code>". Returns curl's own exit status (non-zero on
# timeout/connection failure — distinct from a non-200 HTTP response, which
# is reflected in the printed http_code instead).
post_json() {
    local url="$1" json="$2" maxtime="$3"
    local tmp
    tmp=$(mktemp)
    printf '%s' "${json}" > "${tmp}"
    printf 'header = "Authorization: Bearer %s"\n' "${OLLAMA_API_KEY}" \
        | curl -s --connect-timeout 5 --max-time "${maxtime}" -K - \
            -H "Content-Type: application/json" --data-binary "@${tmp}" \
            -w '\n%{http_code}' "${url}" 2>/dev/null
    local curl_rc=$?
    rm -f "${tmp}"
    return "${curl_rc}"
}

step_ollama() {
    printf '%b── Ollama (inference) ──────────────────────────────%b\n' "${CYAN}" "${NC}"

    local raw tags_code tags_json
    raw=$(get_bearer "${BASE_URL}/ollama/api/tags" 10)
    tags_code="${raw##*$'\n'}"
    tags_json="${raw%$'\n'*}"

    if [[ "${tags_code}" != "200" ]]; then
        fail "Ollama — no model pulled" "GET /ollama/api/tags returned HTTP ${tags_code:-<no response>}. Raw reply: ${tags_json}"
        return
    fi

    local model
    model=$(printf '%s' "${tags_json}" | python3 -c '
import json, sys
try:
    models = json.load(sys.stdin).get("models", [])
    print(models[0]["name"] if models else "")
except Exception:
    print("")
')

    if [[ -z "${model}" ]]; then
        fail "Ollama — no model pulled" "Run './scripts/pull-models.sh' first, then re-run this check."
        return
    fi

    local gen_body
    gen_body=$(python3 -c '
import json, sys
print(json.dumps({"model": sys.argv[1], "prompt": "Say OK.", "stream": False}))
' "${model}")

    local gen_raw curl_rc
    gen_raw=$(post_json "${BASE_URL}/ollama/api/generate" "${gen_body}" 180)
    curl_rc=$?

    if [[ ${curl_rc} -ne 0 ]]; then
        fail "Ollama — generate (${model})" "curl failed (exit ${curl_rc}) — request may have timed out during cold model load."
        return
    fi

    local gen_code gen_json
    gen_code="${gen_raw##*$'\n'}"
    gen_json="${gen_raw%$'\n'*}"

    if [[ "${gen_code}" != "200" ]]; then
        fail "Ollama — generate (${model})" "HTTP ${gen_code}. Raw reply: ${gen_json}"
        return
    fi

    local error response
    error=$(printf '%s' "${gen_json}" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("error", ""))
except Exception:
    print("")
')
    response=$(printf '%s' "${gen_json}" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("response", ""))
except Exception:
    print("")
')

    if [[ -n "${error}" ]]; then
        fail "Ollama — generate (${model})" "Ollama returned an error: ${error}"
        return
    fi

    if [[ -z "${response}" ]]; then
        fail "Ollama — generate (${model})" "Empty .response field. Raw reply: ${gen_json}"
        return
    fi

    ok "Ollama — generate (${model}) — got a non-empty response"

    # Unload the model so running this check doesn't leave VRAM/RAM state
    # changed on a constrained host that wasn't already running it.
    local unload_body
    unload_body=$(python3 -c '
import json, sys
print(json.dumps({"model": sys.argv[1], "keep_alive": 0}))
' "${model}")
    post_json "${BASE_URL}/ollama/api/generate" "${unload_body}" 15 >/dev/null 2>&1 || true
}

step_searxng() {
    printf '%b── SearXNG (search) ────────────────────────────────%b\n' "${CYAN}" "${NC}"

    local raw code json count
    raw=$(get_bearer "${BASE_URL}/searxng/search?q=test&format=json" 20)
    code="${raw##*$'\n'}"
    json="${raw%$'\n'*}"

    if [[ "${code}" != "200" ]]; then
        fail "SearXNG — search" "HTTP ${code:-<no response>}. Raw reply: ${json}"
        return
    fi

    count=$(printf '%s' "${json}" | python3 -c '
import json, sys
try:
    print(len(json.load(sys.stdin).get("results", [])))
except Exception:
    print(0)
')

    if [[ "${count}" -gt 0 ]]; then
        ok "SearXNG — search returned ${count} result(s)"
    else
        fail "SearXNG — search returned no results" "This can also mean the host lacks outbound internet access to reach upstream search engines, not necessarily a regression."
    fi
}

step_open_webui() {
    printf '%b── Open WebUI ──────────────────────────────────────%b\n' "${CYAN}" "${NC}"

    local raw code body
    raw=$(curl -s --connect-timeout 5 --max-time 10 -w '\n%{http_code}' "${BASE_URL}/" 2>/dev/null)
    code="${raw##*$'\n'}"
    body="${raw%$'\n'*}"

    if [[ "${code}" == "200" ]] && printf '%s' "${body}" | grep -qi '<html'; then
        ok "Open WebUI — frontend served (HTTP ${code})"
    else
        fail "Open WebUI — frontend served" "HTTP ${code:-<no response>}. First 200 bytes: $(printf '%s' "${body}" | head -c 200)"
    fi

    local exec_out
    exec_out=$(podman exec llm-companion-open-webui python3 -c '
import os, urllib.request
url = os.environ.get("OLLAMA_BASE_URL", "").rstrip("/") + "/api/tags"
try:
    with urllib.request.urlopen(url, timeout=10) as r:
        print(r.status)
except Exception as e:
    print("ERROR: " + str(e))
' 2>&1)

    if [[ "${exec_out}" == "200" ]]; then
        ok "Open WebUI — reaches Ollama internally (OLLAMA_BASE_URL)"
    else
        fail "Open WebUI — reaches Ollama internally (OLLAMA_BASE_URL)" "${exec_out}"
    fi
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

step_ollama
step_searxng
step_open_webui
step_auth

exit "${rc}"
