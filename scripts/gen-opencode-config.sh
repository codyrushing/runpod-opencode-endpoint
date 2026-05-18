#!/usr/bin/env bash
# Generate opencode/opencode.json from the manifests + state of every deployed
# endpoint. Copy the result to ~/.config/opencode/opencode.json to use it.
# Usage: ./scripts/gen-opencode-config.sh [output-path]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd jq

out="${1:-$REPO_ROOT/opencode/opencode.json}"
mkdir -p "$(dirname "$out")"

providers="{}"
shopt -s nullglob
for state_file in "$STATE_DIR"/*.json; do
  name="$(jq -r '.name' "$state_file")"
  endpoint_id="$(jq -r '.endpointId' "$state_file")"
  manifest="$ENDPOINTS_DIR/$name.json"
  if [[ ! -f "$manifest" ]]; then
    echo "skip: no manifest for '$name'" >&2
    continue
  fi

  model_id="$(jq -r '.template.env.MODEL_NAME' "$manifest")"
  display="$(jq -r '.opencode.displayName // .name' "$manifest")"
  context="$(jq -r '.opencode.contextLimit // 131072' "$manifest")"
  output="$(jq -r '.opencode.maxOutputTokens // 8192' "$manifest")"

  providers="$(echo "$providers" | jq \
    --arg key "runpod-$name" \
    --arg display "$display" \
    --arg base "https://api.runpod.ai/v2/$endpoint_id/openai/v1" \
    --arg model "$model_id" \
    --argjson context "$context" \
    --argjson output "$output" \
    '. + { ($key): {
        npm: "@ai-sdk/openai-compatible",
        name: $display,
        options: { baseURL: $base, apiKey: "{env:RUNPOD_API_KEY}" },
        models: { ($model): { name: $display, limit: { context: $context, output: $output } } }
    } }')"
done

if [[ "$providers" == "{}" ]]; then
  echo "No deployments found in $STATE_DIR — deploy something first." >&2
  exit 1
fi

jq -n --argjson p "$providers" '{
  "$schema": "https://opencode.ai/config.json",
  "lsp": true,
  "permission": {
    "*": "ask",
    "read": "allow",
    "rm": "deny",
    "bash": "allow",
    "grep": "allow",
    "glob": {
      "*": "allow"
    },
    "edit": "ask"
  },
  "provider": $p
}' > "$out"

echo "Wrote $out"
echo
echo "To activate:"
echo "  mkdir -p ~/.config/opencode"
echo "  cp $out ~/.config/opencode/opencode.json"
echo "  export RUNPOD_API_KEY=<your key>   # or put it in your shell rc"
