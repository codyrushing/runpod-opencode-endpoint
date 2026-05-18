#!/usr/bin/env bash
# Shared helpers for RunPod endpoint scripts.
# Source, don't execute.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$REPO_ROOT/.state"
ENDPOINTS_DIR="$REPO_ROOT/endpoints"

RUNPOD_API="https://rest.runpod.io/v1"

# Load .env if present without clobbering already-exported vars.
if [[ -f "$REPO_ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env"
  set +a
fi

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Error: $name is not set. Copy .env.example to .env and fill it in." >&2
    exit 1
  fi
}

require_cmd() {
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Error: required command '$cmd' not found in PATH." >&2
      exit 1
    fi
  done
}

# rp_curl METHOD PATH [JSON_BODY]
# Issues a request against the RunPod REST API and prints the response body to
# stdout. On HTTP >= 400, prints status + body to stderr and returns 1.
rp_curl() {
  local method="$1"
  local path="$2"
  local body="${3:-}"

  local tmp
  tmp="$(mktemp)"
  local args=(-sS -o "$tmp" -w '%{http_code}'
    -X "$method"
    -H "Authorization: Bearer $RUNPOD_API_KEY"
    -H "Content-Type: application/json"
    "$RUNPOD_API$path")
  if [[ -n "$body" ]]; then
    args+=(--data "$body")
  fi

  local code
  code="$(curl "${args[@]}")"
  if [[ "$code" -ge 400 ]]; then
    echo "HTTP $code from $method $path" >&2
    cat "$tmp" >&2
    echo >&2
    rm -f "$tmp"
    return 1
  fi
  cat "$tmp"
  rm -f "$tmp"
}

state_file_for() {
  echo "$STATE_DIR/$1.json"
}

# Replace ${REGISTRY} in an image name with the REGISTRY env var. Other env
# var references and shell metachars are left alone — this is targeted, not
# generic envsubst.
resolve_image_name() {
  local raw="$1"
  local reg="${REGISTRY:-}"
  # Escape sed special chars in REGISTRY (slashes appear in registry paths).
  local reg_escaped
  reg_escaped=$(printf '%s' "$reg" | sed 's|[\\/&]|\\&|g')
  printf '%s' "$raw" | sed "s|\${REGISTRY}|$reg_escaped|g"
}
