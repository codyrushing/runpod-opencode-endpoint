#!/usr/bin/env bash
# Send a minimal OpenAI-compatible chat request straight to the endpoint,
# bypassing OpenCode. Helps isolate "is the endpoint broken or is OpenCode
# misconfigured" when something hangs.
#
# Usage: ./scripts/ping.sh <endpoint-name> [prompt]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd jq curl
require_env RUNPOD_API_KEY

name="${1:-}"
prompt="${2:-Say hello in exactly five words.}"

if [[ -z "$name" ]]; then
  echo "Usage: $0 <endpoint-name> [prompt]" >&2
  exit 1
fi

state="$(state_file_for "$name")"
manifest="$ENDPOINTS_DIR/$name.json"
[[ -f "$state" ]] || { echo "No state for '$name'." >&2; exit 1; }
[[ -f "$manifest" ]] || { echo "No manifest for '$name'." >&2; exit 1; }

endpoint_id="$(jq -r '.endpointId' "$state")"
model_name="$(jq -r '.template.env.MODEL_NAME' "$manifest")"
base_url="https://api.runpod.ai/v2/$endpoint_id/openai/v1"

echo "Endpoint: $base_url"
echo "Model:    $model_name"
echo

# --- 1. /models — cheap, doesn't require warm worker on every implementation,
# but on worker-v1-vllm it does invoke the worker. Useful smoke test.
echo "--- GET /models ---"
curl -sS --max-time 30 \
  -H "Authorization: Bearer $RUNPOD_API_KEY" \
  "$base_url/models" \
  | jq . || echo "(no JSON / timed out)"

echo
echo "--- POST /chat/completions (non-stream, 5min timeout for cold start) ---"
body="$(jq -n --arg model "$model_name" --arg prompt "$prompt" '{
  model: $model,
  messages: [{role: "user", content: $prompt}],
  max_tokens: 64,
  temperature: 0.2,
  stream: false
}')"

curl -sS --max-time 600 \
  -X POST \
  -H "Authorization: Bearer $RUNPOD_API_KEY" \
  -H "Content-Type: application/json" \
  "$base_url/chat/completions" \
  --data "$body" \
  | jq . || echo "(no JSON / timed out)"
