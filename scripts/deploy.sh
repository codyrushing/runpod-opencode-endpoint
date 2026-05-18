#!/usr/bin/env bash
# Deploy (create-or-update) a RunPod serverless endpoint from a manifest.
# Usage: ./scripts/deploy.sh endpoints/<name>.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd jq curl
require_env RUNPOD_API_KEY

manifest="${1:-}"
if [[ -z "$manifest" || ! -f "$manifest" ]]; then
  echo "Usage: $0 path/to/manifest.json" >&2
  exit 1
fi

name="$(jq -r '.name' "$manifest")"
if [[ -z "$name" || "$name" == "null" ]]; then
  echo "Manifest is missing required '.name'." >&2
  exit 1
fi

mkdir -p "$STATE_DIR"
state="$(state_file_for "$name")"

# --- Template ---
# imageName + env vars + disk size live on the template. The endpoint references
# it by ID. Updating env vars therefore means PATCHing the template, not the
# endpoint.
raw_image="$(jq -r '.template.imageName' "$manifest")"
resolved_image="$(resolve_image_name "$raw_image")"
if [[ "$resolved_image" == *'${REGISTRY}'* ]]; then
  echo "Error: template.imageName contains \${REGISTRY} but REGISTRY env is unset." >&2
  echo "Set REGISTRY in .env (e.g. REGISTRY=ghcr.io/your-user)." >&2
  exit 1
fi

template_body="$(jq --arg img "$resolved_image" '{
  name: ("opencode-" + .name),
  imageName: $img,
  isServerless: true,
  containerDiskInGb: (.template.containerDiskInGb // 50),
  volumeInGb: (.template.volumeInGb // 0),
  env: .template.env
}' "$manifest")"

if [[ -f "$state" ]] && jq -e '.templateId' "$state" >/dev/null; then
  template_id="$(jq -r '.templateId' "$state")"

  # imageName is treated as immutable on PATCH. If the manifest changed it,
  # warn loudly and stop — silent no-op was actually our first bug here.
  current_image="$(rp_curl GET "/templates/$template_id" | jq -r '.imageName')"
  if [[ "$current_image" != "$resolved_image" ]]; then
    echo "Refusing to PATCH: template imageName changed." >&2
    echo "  current: $current_image" >&2
    echo "  wanted:  $resolved_image" >&2
    echo "Run ./scripts/destroy.sh $name then rerun this command." >&2
    exit 2
  fi

  echo "Updating template $template_id..."
  patch_template="$(echo "$template_body" | jq 'del(.imageName, .isServerless)')"
  rp_curl PATCH "/templates/$template_id" "$patch_template" >/dev/null
else
  echo "Creating template..."
  template_response="$(rp_curl POST "/templates" "$template_body")"
  template_id="$(echo "$template_response" | jq -r '.id')"
  echo "  templateId: $template_id"
fi

# --- Endpoint ---
endpoint_body="$(jq --arg templateId "$template_id" '{
  templateId: $templateId,
  name: ("opencode-" + .name),
  computeType: "GPU",
  gpuTypeIds: .endpoint.gpuTypeIds,
  gpuCount: (.endpoint.gpuCount // 1),
  workersMin: (.endpoint.workersMin // 0),
  workersMax: (.endpoint.workersMax // 3),
  idleTimeout: (.endpoint.idleTimeout // 30),
  scalerType: (.endpoint.scalerType // "QUEUE_DELAY"),
  scalerValue: (.endpoint.scalerValue // 4),
  flashboot: (.endpoint.flashboot // true),
  executionTimeoutMs: (.endpoint.executionTimeoutMs // 600000)
}' "$manifest")"

if [[ -f "$state" ]] && jq -e '.endpointId' "$state" >/dev/null; then
  endpoint_id="$(jq -r '.endpointId' "$state")"
  echo "Updating endpoint $endpoint_id..."
  # PATCH rejects templateId / computeType / name on existing endpoints.
  patch_endpoint="$(echo "$endpoint_body" | jq 'del(.templateId, .computeType, .name)')"
  rp_curl PATCH "/endpoints/$endpoint_id" "$patch_endpoint" >/dev/null
else
  echo "Creating endpoint..."
  endpoint_response="$(rp_curl POST "/endpoints" "$endpoint_body")"
  endpoint_id="$(echo "$endpoint_response" | jq -r '.id')"
  echo "  endpointId: $endpoint_id"
fi

# --- Persist state for idempotent reruns. ---
jq -n \
  --arg name "$name" \
  --arg templateId "$template_id" \
  --arg endpointId "$endpoint_id" \
  --arg updatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{name: $name, templateId: $templateId, endpointId: $endpointId, updatedAt: $updatedAt}' \
  > "$state"

echo
echo "Done."
echo "  Base URL: https://api.runpod.ai/v2/$endpoint_id/openai/v1"
echo "  Console:  https://console.runpod.io/serverless/$endpoint_id"
echo
echo "Regenerate the OpenCode config with:"
echo "  ./scripts/gen-opencode-config.sh"
