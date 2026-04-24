#!/usr/bin/env bash
# /etc/profile.d/opencode-caii.sh
#
# Sourced on every interactive JupyterLab terminal. Configures OpenCode to use
# Cloudera AI Inference (CAII) OpenAI-compatible endpoints via env vars:
#   CAII_OPENAI_BASE_URL — base URL including /v1 (see your CAII deployment docs)
#   CAII_API_TOKEN       — bearer token for the endpoint
#   CAII_MODEL           — model id string your CAII route expects (often matches
#                          the Hugging Face repo id or registry name)
#   CAII_MODEL_SUPPORTS_TOOLS — set to true/1/yes only if your CAII endpoint has
#                          vLLM tool flags enabled; otherwise generated config sets
#                          tool_call: false so OpenCode does not send tool_choice:auto
#
# Commands:
#   opencode-sync-config  — write ~/.config/opencode/opencode.json from env
#   opencode-caii         — sync config then run `opencode` (pass extra args)

[[ $- != *i* ]] && return

_OPENCODE_CONFIG="$HOME/.config/opencode/opencode.json"

_opencode_sync_config() {
    if [[ -z "${CAII_OPENAI_BASE_URL}" || -z "${CAII_API_TOKEN}" || -z "${CAII_MODEL}" ]]; then
        echo "opencode-sync-config: set CAII_OPENAI_BASE_URL, CAII_API_TOKEN, and CAII_MODEL first." >&2
        return 1
    fi

    mkdir -p "$(dirname "$_OPENCODE_CONFIG")"

    local _tools_flag="${CAII_MODEL_SUPPORTS_TOOLS:-}"
    # vLLM without --enable-auto-tool-choice rejects tool_choice:auto; OpenCode honors
    # provider model "tool_call": false to avoid sending tool-calling to the API.
    # https://opencode.ai/config.json — models.*.tool_call

    # apiKey/baseURL use OpenCode env indirection so secrets are not written to disk.
    jq -n \
        --arg mid "$CAII_MODEL" \
        --arg schema "https://opencode.ai/config.json" \
        --arg tools "$_tools_flag" \
        '(
            ($tools == "true" or $tools == "1" or $tools == "yes" or $tools == "TRUE")
        ) as $server_tools |
        {
            "$schema": $schema,
            "model": ("caii/" + $mid),
            "small_model": ("caii/" + $mid),
            "enabled_providers": ["caii"],
            "provider": {
                "caii": {
                    "npm": "@ai-sdk/openai-compatible",
                    "name": "Cloudera AI Inference",
                    "options": {
                        "baseURL": "{env:CAII_OPENAI_BASE_URL}",
                        "apiKey": "{env:CAII_API_TOKEN}"
                    },
                    "models": {
                        ($mid): (
                            if $server_tools then
                                { "name": ("CAII: " + $mid) }
                            else
                                { "name": ("CAII: " + $mid), "tool_call": false }
                            end
                        )
                    }
                }
            }
        }' > "$_OPENCODE_CONFIG"

    if [[ "${_tools_flag}" == "true" || "${_tools_flag}" == "1" || "${_tools_flag}" == "yes" || "${_tools_flag}" == "TRUE" ]]; then
        echo "Wrote $_OPENCODE_CONFIG (provider caii, model caii/${CAII_MODEL}, tool_call per server)."
    else
        echo "Wrote $_OPENCODE_CONFIG (provider caii, model caii/${CAII_MODEL}, tool_call:false — chat-style; set CAII_MODEL_SUPPORTS_TOOLS=true if CAII has vLLM tool args)."
    fi
}

opencode-sync-config() {
    _opencode_sync_config
}

# Sync OpenCode config from env, then launch the TUI (or forward to `opencode run`, etc.)
opencode-caii() {
    _opencode_sync_config || return 1
    command opencode "$@"
}

_opencode_banner() {
    echo ""
    echo "┌─ OpenCode + Cloudera AI Inference ─────────────────────────────────────┐"
    if command -v opencode &>/dev/null; then
        echo "│  ✓ opencode: $(command -v opencode)"
    else
        echo "│  ✗ opencode CLI not found"
    fi
    if [[ -n "${CAII_OPENAI_BASE_URL}" && -n "${CAII_API_TOKEN}" && -n "${CAII_MODEL}" ]]; then
        echo "│  ✓ CAII env set (model id: ${CAII_MODEL})"
        echo "│  → Run: opencode-sync-config && opencode"
        echo "│     or: opencode-caii"
    else
        echo "│  ○ Set CAII_OPENAI_BASE_URL, CAII_API_TOKEN, CAII_MODEL (CML env / secrets)"
        echo "│    then: opencode-caii"
    fi
    echo "└──────────────────────────────────────────────────────────────────────────┘"
    echo ""
}

_opencode_banner
