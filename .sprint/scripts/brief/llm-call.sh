#!/usr/bin/env bash
# toolkit/brief/llm-call.sh — LLM call with project-level override and fallback chain
#
# Fallback chain:
#   1. Project override (from .sprint/config/brief-config.sh)
#   2. Afterburner active provider (from llm-providers.json)
#   3. Ollama default (qwen3.5:latest)
#   4. Claude CLI haiku (final fallback)
#
# Usage:
#   ./llm-call.sh --prompt "..." --section "sprint-plan" [--max-tokens N]
#   Outputs generated text to stdout. Metrics to stderr.
#
# Exit codes:
#   0 — Success (text on stdout)
#   1 — All attempts failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
CONFIG_DIR="${CONFIG_DIR:-${ROOT}/.sprint/config}"

# ---------------------------------------------------------------------------
# Resolve LLM provider: project override → Afterburner active → defaults
# ---------------------------------------------------------------------------

# Layer 1: Project override
BRIEF_LLM_PROVIDER="${BRIEF_LLM_PROVIDER:-}"
BRIEF_LLM_MODEL="${BRIEF_LLM_MODEL:-}"
BRIEF_LLM_URL="${BRIEF_LLM_URL:-}"
BRIEF_LLM_API_KEY="${BRIEF_LLM_API_KEY:-}"
BRIEF_LLM_FORMAT="${BRIEF_LLM_FORMAT:-}"

if [ -f "${CONFIG_DIR}/brief-config.sh" ]; then
  source "${CONFIG_DIR}/brief-config.sh"
fi

# Layer 2: Afterburner active provider (llm-providers.json)
_AB_MODEL=""
_AB_URL=""
_AB_KEY=""
_AB_FORMAT=""
_AB_CONFIG=""

for _cfg_path in \
  "${SCRIPT_DIR}/../../dashboard/llm-providers.json" \
  "${ROOT}/dashboard/llm-providers.json"; do
  if [ -f "$_cfg_path" ]; then
    _AB_CONFIG="$_cfg_path"
    break
  fi
done

# Also check .sprint/.framework-root for installed projects
if [ -z "$_AB_CONFIG" ] && [ -f "${ROOT}/.sprint/.framework-root" ]; then
  _fw_root=$(cat "${ROOT}/.sprint/.framework-root" 2>/dev/null || echo "")
  if [ -f "${_fw_root}/dashboard/llm-providers.json" ]; then
    _AB_CONFIG="${_fw_root}/dashboard/llm-providers.json"
  fi
fi

if [ -n "$_AB_CONFIG" ] && command -v python3 >/dev/null 2>&1; then
  eval "$(python3 -c "
import json, sys
with open('$_AB_CONFIG') as f:
    data = json.load(f)
active = data.get('activeProvider', '')
cfg = data.get('configs', {}).get(active, {})
model = cfg.get('model', '')
url = cfg.get('baseUrl', '')
key = cfg.get('apiKey', '')
# Determine API format from provider name
fmt = 'openai'
if 'claude' in active or 'anthropic' in active:
    fmt = 'anthropic'
if model: print(f'_AB_MODEL=\"{model}\"')
if url: print(f'_AB_URL=\"{url}\"')
if key: print(f'_AB_KEY=\"{key}\"')
print(f'_AB_FORMAT=\"{fmt}\"')
" 2>/dev/null)" || true
fi

# Resolve final provider settings
# Priority: project override > Afterburner active > defaults
if [ -n "$BRIEF_LLM_MODEL" ]; then
  # Project override takes precedence
  LLM_MODEL="$BRIEF_LLM_MODEL"
  LLM_URL="${BRIEF_LLM_URL:-${_AB_URL:-http://localhost:11434}}"
  LLM_KEY="${BRIEF_LLM_API_KEY:-${_AB_KEY:-}}"
  LLM_FORMAT="${BRIEF_LLM_FORMAT:-${_AB_FORMAT:-openai}}"
  echo "[llm-call] Using project override: ${LLM_MODEL}" >&2
elif [ -n "$_AB_MODEL" ]; then
  # Afterburner active provider
  LLM_MODEL="$_AB_MODEL"
  LLM_URL="${_AB_URL:-http://localhost:11434}"
  LLM_KEY="${_AB_KEY:-}"
  LLM_FORMAT="${_AB_FORMAT:-openai}"
  echo "[llm-call] Using Afterburner active: ${LLM_MODEL}" >&2
else
  # Defaults
  LLM_MODEL="qwen3.5:latest"
  LLM_URL="http://localhost:11434"
  LLM_KEY=""
  LLM_FORMAT="openai"
  echo "[llm-call] Using default: ${LLM_MODEL}" >&2
fi

RETRY_MODEL="${RETRY_MODEL:-qwen3:8b}"
CLAUDE_MODEL="haiku"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
PROMPT=""
SECTION="unknown"
MAX_TOKENS=4096
TEMPERATURE=0.3

while [ $# -gt 0 ]; do
  case "$1" in
    --prompt)     shift; PROMPT="${1:-}"; shift ;;
    --section)    shift; SECTION="${1:-unknown}"; shift ;;
    --max-tokens) shift; MAX_TOKENS="${1:-4096}"; shift ;;
    --temperature) shift; TEMPERATURE="${1:-0.3}"; shift ;;
    *)            shift ;;
  esac
done

if [ -z "$PROMPT" ]; then
  echo "[llm-call] ERROR: No prompt provided" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Ollama call (local models via OpenAI-compatible API)
# ---------------------------------------------------------------------------
ollama_call() {
  local model="$1"
  local url="${2:-http://localhost:11434}"
  local start_s
  start_s=$(date +%s)

  # Check Ollama is running
  if ! curl -sf "${url}/api/tags" >/dev/null 2>&1; then
    echo "[llm-call] Ollama not available at ${url}" >&2
    return 3
  fi

  local tmpfile
  tmpfile=$(mktemp)

  local payload
  if command -v jq >/dev/null 2>&1; then
    payload=$(jq -n \
      --arg model "$model" \
      --arg prompt "$PROMPT" \
      --argjson max_tokens "$MAX_TOKENS" \
      --argjson temperature "$TEMPERATURE" \
      '{model: $model, prompt: $prompt, stream: false, think: false, options: {num_predict: $max_tokens, temperature: $temperature}}')
  else
    local escaped_prompt
    escaped_prompt=$(printf '%s' "$PROMPT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")
    payload="{\"model\":\"${model}\",\"prompt\":${escaped_prompt},\"stream\":false,\"think\":false,\"options\":{\"num_predict\":${MAX_TOKENS},\"temperature\":${TEMPERATURE}}}"
  fi

  local http_code
  http_code=$(curl -sf -w '%{http_code}' \
    -o "$tmpfile" \
    --max-time 300 \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "${url}/api/generate" 2>/dev/null) || {
    local elapsed=$(( $(date +%s) - start_s ))
    echo "[llm-call] ${model} request failed (${elapsed}s)" >&2
    rm -f "$tmpfile"
    return 2
  }

  if [ "$http_code" != "200" ]; then
    local elapsed=$(( $(date +%s) - start_s ))
    echo "[llm-call] ${model} returned HTTP ${http_code} (${elapsed}s)" >&2
    rm -f "$tmpfile"
    return 2
  fi

  local response
  if command -v jq >/dev/null 2>&1; then
    response=$(jq -r '.response // empty' "$tmpfile" 2>/dev/null)
  else
    response=$(python3 -c "import sys,json; print(json.load(sys.stdin).get('response',''))" < "$tmpfile" 2>/dev/null)
  fi
  rm -f "$tmpfile"

  # Strip <think>...</think> blocks
  response=$(printf '%s' "$response" | sed '/<think>/,/<\/think>/d')

  if [ -z "$response" ] || [ "${#response}" -lt 20 ]; then
    local elapsed=$(( $(date +%s) - start_s ))
    echo "[llm-call] ${model} returned empty/too-short response (${elapsed}s)" >&2
    return 2
  fi

  local elapsed=$(( $(date +%s) - start_s ))
  echo "[llm-call] ${model} OK for ${SECTION} (${elapsed}s, ${#response} chars)" >&2
  printf '%s' "$response"
  return 0
}

# ---------------------------------------------------------------------------
# Anthropic API call (Claude models)
# ---------------------------------------------------------------------------
anthropic_call() {
  local model="$1"
  local api_key="$2"
  local start_s
  start_s=$(date +%s)

  if [ -z "$api_key" ]; then
    echo "[llm-call] No API key for Anthropic" >&2
    return 2
  fi

  local tmpfile
  tmpfile=$(mktemp)

  local payload
  if command -v jq >/dev/null 2>&1; then
    payload=$(jq -n \
      --arg model "$model" \
      --arg prompt "$PROMPT" \
      --argjson max_tokens "$MAX_TOKENS" \
      --argjson temperature "$TEMPERATURE" \
      '{model: $model, max_tokens: $max_tokens, temperature: $temperature, messages: [{role: "user", content: $prompt}]}')
  else
    local escaped_prompt
    escaped_prompt=$(printf '%s' "$PROMPT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")
    payload="{\"model\":\"${model}\",\"max_tokens\":${MAX_TOKENS},\"temperature\":${TEMPERATURE},\"messages\":[{\"role\":\"user\",\"content\":${escaped_prompt}}]}"
  fi

  local http_code
  http_code=$(curl -sf -w '%{http_code}' \
    -o "$tmpfile" \
    --max-time 120 \
    -H "Content-Type: application/json" \
    -H "x-api-key: ${api_key}" \
    -H "anthropic-version: 2023-06-01" \
    -d "$payload" \
    "https://api.anthropic.com/v1/messages" 2>/dev/null) || {
    local elapsed=$(( $(date +%s) - start_s ))
    echo "[llm-call] Anthropic ${model} request failed (${elapsed}s)" >&2
    rm -f "$tmpfile"
    return 2
  }

  if [ "$http_code" != "200" ]; then
    local elapsed=$(( $(date +%s) - start_s ))
    echo "[llm-call] Anthropic ${model} returned HTTP ${http_code} (${elapsed}s)" >&2
    rm -f "$tmpfile"
    return 2
  fi

  local response
  if command -v jq >/dev/null 2>&1; then
    response=$(jq -r '.content[0].text // empty' "$tmpfile" 2>/dev/null)
  else
    response=$(python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('content',[{}])[0].get('text',''))" < "$tmpfile" 2>/dev/null)
  fi
  rm -f "$tmpfile"

  if [ -z "$response" ] || [ "${#response}" -lt 20 ]; then
    local elapsed=$(( $(date +%s) - start_s ))
    echo "[llm-call] Anthropic ${model} returned empty/too-short response (${elapsed}s)" >&2
    return 2
  fi

  local elapsed=$(( $(date +%s) - start_s ))
  echo "[llm-call] Anthropic ${model} OK for ${SECTION} (${elapsed}s, ${#response} chars)" >&2
  printf '%s' "$response"
  return 0
}

# ---------------------------------------------------------------------------
# Claude CLI fallback
# ---------------------------------------------------------------------------
claude_call() {
  local start_s
  start_s=$(date +%s)

  if ! command -v claude >/dev/null 2>&1; then
    echo "[llm-call] claude CLI not found" >&2
    return 2
  fi

  local response
  response=$(claude -m "$CLAUDE_MODEL" --dangerously-skip-permissions -p "$PROMPT" 2>/dev/null) || {
    local elapsed=$(( $(date +%s) - start_s ))
    echo "[llm-call] Claude ${CLAUDE_MODEL} failed (${elapsed}s)" >&2
    return 2
  }

  if [ -z "$response" ] || [ "${#response}" -lt 20 ]; then
    local elapsed=$(( $(date +%s) - start_s ))
    echo "[llm-call] Claude ${CLAUDE_MODEL} returned empty response (${elapsed}s)" >&2
    return 2
  fi

  local elapsed=$(( $(date +%s) - start_s ))
  echo "[llm-call] Claude ${CLAUDE_MODEL} OK for ${SECTION} (${elapsed}s, ${#response} chars)" >&2
  printf '%s' "$response"
  return 0
}

# ---------------------------------------------------------------------------
# Fallback chain
# ---------------------------------------------------------------------------

# Attempt 1: Resolved primary provider
if [ "$LLM_FORMAT" = "anthropic" ]; then
  if anthropic_call "$LLM_MODEL" "$LLM_KEY"; then
    exit 0
  fi
else
  if ollama_call "$LLM_MODEL" "$LLM_URL"; then
    exit 0
  fi
fi

# Attempt 2: Retry with alternate local model
echo "[llm-call] Retrying ${SECTION} with ${RETRY_MODEL}..." >&2
if ollama_call "$RETRY_MODEL" "http://localhost:11434"; then
  exit 0
fi

# Attempt 3: Claude haiku via CLI
echo "[llm-call] Falling back to Claude ${CLAUDE_MODEL} for ${SECTION}..." >&2
if claude_call; then
  exit 0
fi

echo "[llm-call] All attempts failed for ${SECTION}" >&2
exit 1
