#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Thomas Perrot <thomas.perrot@tupi.fr>
# SPDX-License-Identifier: GPL-3.0-only

# =============================================================================
# generate-api-key.sh — Create a Bearer token for the Ollama Caddy proxy
#
# Generates a cryptographically random API key and writes it to the env file
# that the llm-companion service reads at startup.
#
# Usage:
#   chmod +x generate-api-key.sh
#   ./generate-api-key.sh
#
# The key is written to ~/.config/ollama/api-key.env in the format:
#   OLLAMA_API_KEY=sk-ollama-<random>
#
# Use this key in opencode.json and anywhere else you call the Ollama API:
#   "baseURL": "http://<server-ip>:8080/v1"
#   Authorization: Bearer sk-ollama-<your-key>
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

ENV_FILE="${HOME}/.config/ollama/api-key.env"

# ── Check if a key already exists ─────────────────────────────────────────
if [[ -f "${ENV_FILE}" ]]; then
    EXISTING=$(grep '^OLLAMA_API_KEY=' "${ENV_FILE}" | cut -d= -f2-)
    warn "A key already exists: ${EXISTING}"
    echo -n "Generate a new key and overwrite? [y/N] "
    read -r confirm
    [[ "${confirm,,}" == "y" ]] || { info "Keeping existing key."; exit 0; }
fi

# ── Generate the key ───────────────────────────────────────────────────────
KEY="sk-ollama-$(openssl rand -hex 24)"

# ── Write the env file ─────────────────────────────────────────────────────
mkdir -p "$(dirname "${ENV_FILE}")"
# 0600 — readable only by the owner (never world-readable)
install -m 0600 /dev/null "${ENV_FILE}"
echo "OLLAMA_API_KEY=${KEY}" > "${ENV_FILE}"

info "Key written to: ${ENV_FILE}"
info "Key value:      ${KEY}"

# ── Reminder ───────────────────────────────────────────────────────────────
echo ""
echo "  Add this to your opencode.json:"
echo ""
echo '  "provider": {'
echo '    "ollama": {'
echo '      "npm": "@ai-sdk/openai-compatible",'
echo '      "options": {'
echo '        "baseURL": "http://<server-ip>:8080/v1",'
echo '        "headers": {'
echo '          "Authorization": "Bearer '"${KEY}"'"'
echo '        }'
echo '      }'
echo '    }'
echo '  }'
echo ""
echo "  Restart the stack to pick up the new key:"
echo "    systemctl --user restart llm-companion"
echo ""
warn "Keep this key secret — it grants full access to all Ollama models."
