#!/usr/bin/env bash
# Show RunPod's current view of one or all deployed endpoints.
# Usage: ./scripts/status.sh [endpoint-name]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd jq curl
require_env RUNPOD_API_KEY

name="${1:-}"

show_one() {
  local n="$1"
  local state
  state="$(state_file_for "$n")"
  if [[ ! -f "$state" ]]; then
    echo "No state for '$n'." >&2
    return 1
  fi
  local endpoint_id
  endpoint_id="$(jq -r '.endpointId' "$state")"
  echo "== $n ($endpoint_id) =="
  rp_curl GET "/endpoints/$endpoint_id" \
    | jq '{id, name, gpuTypeIds, workersMin, workersMax, idleTimeout, workersStandby, workers: (.workers | length)}'
}

if [[ -n "$name" ]]; then
  show_one "$name"
else
  shopt -s nullglob
  found=0
  for f in "$STATE_DIR"/*.json; do
    show_one "$(basename "$f" .json)"
    found=1
  done
  if [[ "$found" -eq 0 ]]; then
    echo "No deployments tracked in $STATE_DIR." >&2
    exit 1
  fi
fi
