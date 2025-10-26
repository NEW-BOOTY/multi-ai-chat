#!/usr/bin/env bash
# Copyright © 2025, Devin B. Royal. All rights reserved
# multi-ai-chat — Query multiple AI agents concurrently and print labeled responses.
# Production-focused: robust error handling, retries, timeouts, logging, and safe credential handling.
# Requirements: bash >= 4, curl, jq
# Usage: ./multi-ai-chat "Your question here"
# Configuration: create a config file (see README section below) or set environment variables.

set -o errexit
set -o nounset
set -o pipefail

#### Basic runtime checks #####################################################
MIN_BASH_MAJOR=4
BASH_MAJOR="${BASH_VERSINFO[0]:-0}"
if (( BASH_MAJOR < MIN_BASH_MAJOR )); then
  echo "ERROR: Bash ${MIN_BASH_MAJOR}+ required. Installed bash version: ${BASH_VERSION}" >&2
  echo "On macOS: 'brew install bash' then run script with the new bash (usually /usr/local/bin/bash or /opt/homebrew/bin/bash)." >&2
  exit 2
fi

command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required."; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required."; exit 2; }

#### Configurable defaults ###################################################
# These may be overridden by environment variables or a config file.
LOG_DIR="${MULTIAI_LOG_DIR:-./multi-ai-chat-logs}"
LOG_FILE="${LOG_DIR}/multi-ai-chat.$(date +%Y%m%d%H%M%S).log"
RETRY_MAX="${MULTIAI_RETRY_MAX:-3}"
RETRY_BASE_SLEEP="${MULTIAI_RETRY_BASE_SLEEP:-1}"   # seconds
CURL_TIMEOUT="${MULTIAI_CURL_TIMEOUT:-20}"          # seconds per request
CONCURRENT_WAIT="${MULTIAI_CONCURRENT_WAIT:-0.1}"   # small sleep between starting jobs (throttle)
MASK_KEYS=true

# Per-provider endpoints and env var names (set these in your environment or config file)
# OpenAI (ChatGPT)
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
OPENAI_API_URL="${OPENAI_API_URL:-https://api.openai.com/v1/chat/completions}"

# Grok (placeholder)
GROK_API_KEY="${GROK_API_KEY:-}"
GROK_API_URL="${GROK_API_URL:-https://api.grok.example/v1/generate}"

# Microsoft Copilot (placeholder)
COPILOT_API_KEY="${COPILOT_API_KEY:-}"
COPILOT_API_URL="${COPILOT_API_URL:-https://api.microsoft.com/copilot/v1/generate}"

# Gemini (Google) — often requires OAuth; use a service endpoint you control or set GEMINI_API_URL
GEMINI_API_KEY="${GEMINI_API_KEY:-}"
GEMINI_API_URL="${GEMINI_API_URL:-https://api.gemini.example/v1/generate}"

# Meta AI (placeholder)
META_API_KEY="${META_API_KEY:-}"
META_API_URL="${META_API_URL:-https://api.meta.example/v1/generate}"

# Providers list (order controls output ordering if you want)
PROVIDERS=( "openai" "grok" "copilot" "gemini" "meta" )

#### Logging utilities #######################################################
mkdir -p "${LOG_DIR}"
# Mask potentially sensitive substrings (basic)
mask_sensitive() {
  local s="$1"
  if [ "${MASK_KEYS}" = true ]; then
    # crude masking: hide long token-like strings
    echo "${s}" | sed -E 's/([A-Za-z0-9_-]{20,})/<REDACTED>/g'
  else
    echo "${s}"
  fi
}

log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date --iso-8601=seconds 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "${ts} [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

#### Network helper: do request with retries #################################
do_request() {
  # $1 = provider name (for logging)
  # $2 = curl args (string)
  local provider="$1"; shift
  local curl_args=("$@")
  local attempt=0
  local response
  local http_code

  while (( attempt < RETRY_MAX )); do
    attempt=$(( attempt + 1 ))
    log "DEBUG" "Attempt ${attempt}/${RETRY_MAX} for provider=${provider}"
    # Using --silent to suppress progress, but show errors via -S
    response="$(curl --silent -S --show-error --fail --max-time "${CURL_TIMEOUT}" "${curl_args[@]}" 2>&1)" || {
      local rc=$?
      log "WARN" "curl failed for provider=${provider} (rc=${rc}): $(mask_sensitive "${response}")"
      if (( attempt < RETRY_MAX )); then
        local sleep_for=$(( RETRY_BASE_SLEEP * (2 ** (attempt - 1)) ))
        log "INFO" "Retrying in ${sleep_for}s..."
        sleep "${sleep_for}"
        continue
      else
        echo "{\"error\":\"curl_failed\",\"message\":\"$(mask_sensitive "${response}")\"}"
        return 0
      fi
    }
    # On success print response and exit loop
    echo "${response}"
    return 0
  done
  # If here, return final error object
  echo "{\"error\":\"max_retries_exhausted\",\"provider\":\"${provider}\"}"
  return 0
}

#### Adapter: parse question and format provider requests ####################
# NOTE: For providers that require OAuth flows or complex auth (Google/Gemini, Microsoft),
# you should create a simple proxy or provide a valid service endpoint in GEMINI_API_URL/COPILOT_API_URL.
# This script uses straightforward HTTP POST templates; you MUST configure correct URLs and keys.

send_openai() {
  local q="$1"
  local -n _out_ref="$2"  # name reference to a variable to write output into
  if [ -z "${OPENAI_API_KEY}" ]; then
    _out_ref="{\"error\":\"missing_api_key\",\"provider\":\"openai\"}"
    return
  fi
  # Build JSON payload (Chat Completions)
  local payload
  payload="$(jq -n --arg m "You are a helpful assistant." --arg q "${q}" \
    '{model:"gpt-4o-mini",messages:[{role:"system",content:$m},{role:"user",content:$q}],max_tokens:1200}')"

  local curl_args=( -X POST "${OPENAI_API_URL}" -H "Authorization: Bearer ${OPENAI_API_KEY}" -H "Content-Type: application/json" --data-binary "${payload}" )
  local raw
  raw="$(do_request "openai" "${curl_args[@]}")" || true

  # Attempt to parse known schema safely
  local content
  content="$(echo "${raw}" | jq -r '.choices[0].message.content // .error // empty' 2>/dev/null || echo "")"
  if [ -n "${content}" ]; then
    _out_ref="$(jq -n --arg p "openai" --arg r "${content}" '{provider:$p,response:$r}')";
  else
    # fallback: full raw
    _out_ref="$(jq -n --arg p "openai" --arg r "${raw}" '{provider:$p,response:$r}')";
  fi
}

send_grok() {
  local q="$1"
  local -n _out_ref="$2"
  if [ -z "${GROK_API_KEY}" ]; then
    _out_ref="{\"error\":\"missing_api_key\",\"provider\":\"grok\"}"
    return
  fi
  # Example generic POST template — adjust to provider specs.
  local payload
  payload="$(jq -n --arg q "${q}" '{input:$q,max_tokens:800}')"
  local curl_args=( -X POST "${GROK_API_URL}" -H "Authorization: Bearer ${GROK_API_KEY}" -H "Content-Type: application/json" --data-binary "${payload}" )
  local raw
  raw="$(do_request "grok" "${curl_args[@]}")" || true
  local content
  content="$(echo "${raw}" | jq -r '.output // .result // .text // .error // empty' 2>/dev/null || echo "")"
  if [ -n "${content}" ]; then
    _out_ref="$(jq -n --arg p "grok" --arg r "${content}" '{provider:$p,response:$r}')";
  else
    _out_ref="$(jq -n --arg p "grok" --arg r "${raw}" '{provider:$p,response:$r}')";
  fi
}

send_copilot() {
  local q="$1"
  local -n _out_ref="$2"
  if [ -z "${COPILOT_API_KEY}" ]; then
    _out_ref="{\"error\":\"missing_api_key\",\"provider\":\"copilot\"}"
    return
  fi
  # Microsoft Copilot often requires Azure AD/OAuth; this is a placeholder template.
  local payload
  payload="$(jq -n --arg q "${q}" '{prompt:$q}')"
  local curl_args=( -X POST "${COPILOT_API_URL}" -H "Authorization: Bearer ${COPILOT_API_KEY}" -H "Content-Type: application/json" --data-binary "${payload}" )
  local raw
  raw="$(do_request "copilot" "${curl_args[@]}")" || true
  local content
  content="$(echo "${raw}" | jq -r '.result // .text // .message // .error // empty' 2>/dev/null || echo "")"
  if [ -n "${content}" ]; then
    _out_ref="$(jq -n --arg p "copilot" --arg r "${content}" '{provider:$p,response:$r}')";
  else
    _out_ref="$(jq -n --arg p "copilot" --arg r "${raw}" '{provider:$p,response:$r}')";
  fi
}

send_gemini() {
  local q="$1"
  local -n _out_ref="$2"
  if [ -z "${GEMINI_API_KEY}" ]; then
    _out_ref="{\"error\":\"missing_api_key\",\"provider\":\"gemini\"}"
    return
  fi
  # Gemini/Google typically requires OAuth; please use a properly provisioned endpoint or service account proxy.
  local payload
  payload="$(jq -n --arg q "${q}" '{prompt:$q}')"
  local curl_args=( -X POST "${GEMINI_API_URL}" -H "Authorization: Bearer ${GEMINI_API_KEY}" -H "Content-Type: application/json" --data-binary "${payload}" )
  local raw
  raw="$(do_request "gemini" "${curl_args[@]}")" || true
  local content
  content="$(echo "${raw}" | jq -r '.candidates[0].content // .output // .text // .error // empty' 2>/dev/null || echo "")"
  if [ -n "${content}" ]; then
    _out_ref="$(jq -n --arg p "gemini" --arg r "${content}" '{provider:$p,response:$r}')";
  else
    _out_ref="$(jq -n --arg p "gemini" --arg r "${raw}" '{provider:$p,response:$r}')";
  fi
}

send_meta() {
  local q="$1"
  local -n _out_ref="$2"
  if [ -z "${META_API_KEY}" ]; then
    _out_ref="{\"error\":\"missing_api_key\",\"provider\":\"meta\"}"
    return
  fi
  local payload
  payload="$(jq -n --arg q "${q}" '{input:$q}')"
  local curl_args=( -X POST "${META_API_URL}" -H "Authorization: Bearer ${META_API_KEY}" -H "Content-Type: application/json" --data-binary "${payload}" )
  local raw
  raw="$(do_request "meta" "${curl_args[@]}")" || true
  local content
  content="$(echo "${raw}" | jq -r '.output // .response // .text // .error // empty' 2>/dev/null || echo "")"
  if [ -n "${content}" ]; then
    _out_ref="$(jq -n --arg p "meta" --arg r "${content}" '{provider:$p,response:$r}')";
  else
    _out_ref="$(jq -n --arg p "meta" --arg r "${raw}" '{provider:$p,response:$r}')";
  fi
}

#### Main orchestration ######################################################
main() {
  if [ $# -lt 1 ]; then
    echo "Usage: $0 \"Your question here\""
    exit 1
  fi
  local question="$*"
  log "INFO" "Starting multi-ai-chat for question: $(mask_sensitive "${question}")"

  # Optional: allow loading from a config file (export KEY=... lines)
  if [ -n "${MULTIAI_CONFIG_FILE:-}" ] && [ -f "${MULTIAI_CONFIG_FILE}" ]; then
    # shellcheck disable=SC1090
    source "${MULTIAI_CONFIG_FILE}"
    log "INFO" "Loaded config from ${MULTIAI_CONFIG_FILE}"
  fi

  # Prepare temporary directory for outputs
  local tmpdir
  tmpdir="$(mktemp -d -t multi-ai-chat.XXXXXX)"
  trap 'rm -rf "${tmpdir}"' EXIT

  # Launch provider jobs concurrently and capture PIDs and result files
  declare -a pids
  declare -a result_files
  local idx=0

  for provider in "${PROVIDERS[@]}"; do
    local outfile="${tmpdir}/${provider}.json"
    result_files[idx]="${outfile}"
    case "${provider}" in
      openai)
        (
          send_openai "${question}" response_json
          echo "${response_json}" >"${outfile}"
        ) &
        ;;
      grok)
        (
          send_grok "${question}" response_json
          echo "${response_json}" >"${outfile}"
        ) &
        ;;
      copilot)
        (
          send_copilot "${question}" response_json
          echo "${response_json}" >"${outfile}"
        ) &
        ;;
      gemini)
        (
          send_gemini "${question}" response_json
          echo "${response_json}" >"${outfile}"
        ) &
        ;;
      meta)
        (
          send_meta "${question}" response_json
          echo "${response_json}" >"${outfile}"
        ) &
        ;;
      *)
        echo "{\"error\":\"unknown_provider\",\"provider\":\"${provider}\"}" >"${outfile}" &
        ;;
    esac
    pids[idx]=$!
    idx=$(( idx + 1 ))
    sleep "${CONCURRENT_WAIT}"
  done

  # Wait for background jobs but enforce an overall graceful wait for each pid
  for i in "${!pids[@]}"; do
    local pid="${pids[i]}"
    if ! wait "${pid}"; then
      log "WARN" "Background job (pid=${pid}) exited non-zero"
    fi
  done

  # Aggregate and print labeled outputs in order of PROVIDERS array
  echo
  echo "=== Multi-AI Chat Results ==="
  echo "Question: ${question}"
  echo "Timestamp: $(date --iso-8601=seconds 2>/dev/null || date -u)"
  echo "-----------------------------"
  for provider in "${PROVIDERS[@]}"; do
    local f="${tmpdir}/${provider}.json"
    if [ -f "${f}" ]; then
      local raw
      raw="$(cat "${f}")"
      # Pretty print response field if exists
      local resp
      resp="$(echo "${raw}" | jq -r '.response // .message // .text // .error // empty' 2>/dev/null || echo "")"
      echo
      echo ">>> Provider: ${provider^^}"
      echo "-----------------------------"
      if [ -n "${resp}" ]; then
        echo "${resp}"
      else
        # Fallback: print raw JSON
        echo "${raw}" | jq -C .
      fi
      # Log masked
      log "INFO" "Provider ${provider} returned: $(mask_sensitive "${resp:-(raw output)"}")"
    else
      echo
      echo ">>> Provider: ${provider^^} (no result file)"
      log "ERROR" "Missing result for provider=${provider}"
    fi
  done

  echo
  log "INFO" "multi-ai-chat finished; detailed log: ${LOG_FILE}"
}

main "$@"

# Copyright © 2024, Devin B. Royal. All rights reserved
