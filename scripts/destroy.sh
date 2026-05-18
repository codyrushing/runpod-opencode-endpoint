#!/usr/bin/env bash
# Tear down a deployed endpoint + its template, and clear local state.
# Usage: ./scripts/destroy.sh <endpoint-name>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd jq curl
require_env RUNPOD_API_KEY

name="${1:-}"
if [[ -z "$name" ]]; then
  echo "Usage: $0 <endpoint-name>" >&2
  exit 1
fi

state="$(state_file_for "$name")"
if [[ ! -f "$state" ]]; then
  echo "No state file at $state — nothing to delete." >&2
  exit 1
fi

endpoint_id="$(jq -r '.endpointId' "$state")"
template_id="$(jq -r '.templateId' "$state")"

# Endpoints must be scaled to zero before delete or RunPod refuses.
echo "Scaling endpoint $endpoint_id to zero workers..."
rp_curl PATCH "/endpoints/$endpoint_id" '{"workersMin":0,"workersMax":0}' >/dev/null

echo "Deleting endpoint $endpoint_id..."
rp_curl DELETE "/endpoints/$endpoint_id" >/dev/null

echo "Deleting template $template_id..."
rp_curl DELETE "/templates/$template_id" >/dev/null

rm -f "$state"
echo "Done."
