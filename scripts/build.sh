#!/usr/bin/env bash
# Build & push a custom worker image with a model baked in.
# Usage: ./scripts/build.sh endpoints/<name>.json [--no-push]
#
# Requires:
#   - docker (with buildkit; modern docker has it by default)
#   - REGISTRY env var set in .env (e.g. REGISTRY=ghcr.io/your-user)
#   - You're already logged in: `docker login ghcr.io` etc.
#
# Heads-up: builds are 30–70 GB. Expect 100–200 GB of free disk during build,
# and bandwidth for the HF download (build-time) + registry push.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd jq docker
require_env REGISTRY

manifest="${1:-}"
push="true"
if [[ "${2:-}" == "--no-push" ]]; then
  push="false"
fi

if [[ -z "$manifest" || ! -f "$manifest" ]]; then
  echo "Usage: $0 path/to/manifest.json [--no-push]" >&2
  exit 1
fi

base_image="$(jq -r '.build.baseImage // empty' "$manifest")"
model="$(jq -r '.build.model // empty' "$manifest")"
image_template="$(jq -r '.template.imageName // empty' "$manifest")"

if [[ -z "$base_image" || -z "$model" || -z "$image_template" ]]; then
  echo "Manifest is missing build.baseImage, build.model, or template.imageName." >&2
  exit 1
fi

image_name="$(resolve_image_name "$image_template")"
if [[ "$image_name" == *'${REGISTRY}'* ]]; then
  echo "Image name still contains \${REGISTRY} placeholder after substitution." >&2
  echo "Check that REGISTRY is set in your .env (e.g. REGISTRY=ghcr.io/your-user)." >&2
  exit 1
fi

echo "==> Building $image_name"
echo "    base:  $base_image"
echo "    model: $model"
echo

DOCKER_BUILDKIT=1 docker build \
  --build-arg "BASE_IMAGE=$base_image" \
  --build-arg "MODEL=$model" \
  -t "$image_name" \
  -f "$REPO_ROOT/docker/Dockerfile" \
  "$REPO_ROOT/docker"

if [[ "$push" == "false" ]]; then
  echo
  echo "Skipped push (--no-push). Local image: $image_name"
  exit 0
fi

echo
echo "==> Pushing $image_name"
docker push "$image_name"

echo
echo "Done. Next steps:"
echo "  # If this is the first deploy with this image, or imageName changed:"
echo "  ./scripts/destroy.sh $(jq -r .name "$manifest") 2>/dev/null || true"
echo "  ./scripts/deploy.sh $manifest"
echo "  ./scripts/gen-opencode-config.sh"
echo "  cp opencode/opencode.json ~/.config/opencode/opencode.json"
