# runpod-opencode-endpoint

A thin config-and-deploy repo that runs an open coding model on a private RunPod
serverless endpoint and points [OpenCode](https://opencode.ai) at it as a
drop-in alternative to Claude Code.



## What's here

- `endpoints/*.json` — declarative manifests describing each model + GPU + scaling config
- `docker/Dockerfile` — extends `worker-v1-vllm` and bakes a model into the image
- `scripts/build.sh` — builds & pushes a baked image from a manifest's `build` block
- `scripts/deploy.sh` — idempotent create-or-update against the RunPod REST API
- `scripts/destroy.sh` — tear down endpoint + template, scaled to zero first
- `scripts/status.sh` — show RunPod's current view of a deployment
- `scripts/ping.sh` — hit the endpoint's `/models` and `/chat/completions` directly to isolate endpoint vs. OpenCode issues
- `scripts/gen-opencode-config.sh` — emit `opencode.json` from local state
- `.state/<name>.json` — generated, git-ignored; tracks template/endpoint IDs

## Prerequisites

- `curl`, `jq`, `bash`
- A RunPod account + API key (`rpa_...`)
- [OpenCode](https://opencode.ai) installed locally

## First run

```sh
cp .env.example .env
$EDITOR .env                                 # set RUNPOD_API_KEY and REGISTRY

docker login ghcr.io                         # or your chosen registry

# Build & push the baked image (one-time per model — ~30–70 GB push).
./scripts/build.sh endpoints/qwen2.5-coder-14b.json

# Create the endpoint pointing at your image.
./scripts/deploy.sh endpoints/qwen2.5-coder-14b.json
./scripts/gen-opencode-config.sh
mkdir -p ~/.config/opencode
cp opencode/opencode.json ~/.config/opencode/opencode.json
export RUNPOD_API_KEY=rpa_...                # OpenCode reads this at runtime

opencode models                              # confirm provider appears
opencode                                     # Ctrl+P to pick the RunPod model
```

With weights baked into the image, cold starts are ~30 s (image pull from
registry → load weights from local disk → GPU), not the several-minute HF
download you'd pay with the stock image. That's what makes a tight 5 s
`idleTimeout` economical: re-warming is cheap enough that you stop caring.

## Included manifests

Two manifests ship with the repo so you can A/B them in OpenCode (Ctrl+P to
switch). Both scale to zero and use a tight 5 s idle timeout.

| Manifest | Model | GPU tier | Context | Approx. $/hr active | Use for |
|---|---|---|---|---|---|
| `qwen3-coder-30b.json` | Qwen3-Coder-30B-A3B-Instruct (bf16, MoE 3B active) | H100/A100 80GB | 32 K | ~$2.05–2.74 | Hard problems, multi-file reasoning |
| `qwen2.5-coder-14b.json` | Qwen2.5-Coder-14B-Instruct (bf16, dense) | L40S 48GB | 32 K | ~$1.12 | Daily-driver coding, edits, refactors |

Qwen3-Coder-30B-A3B at bf16 needs ~60 GB of VRAM (MoE loads all experts), which
is why that manifest targets an H100/A100 80GB tier. The 14B fits comfortably
on an L40S — ~2.5× cheaper per active second.

The 14B uses `TOOL_CALL_PARSER: hermes` because Qwen2.5-Coder emits
Hermes/ChatML-style `<tool_call>` blocks. The 30B uses `qwen3_coder` because
Qwen3-Coder emits its native `<function=...><parameter=...>` format. Don't
swap them — the wrong parser causes raw tool-call text to leak into chat
content.

## Adding a new model

1. Copy `endpoints/qwen3-coder-30b.json` to `endpoints/<new-name>.json`
2. Edit `name`, `template.env.MODEL_NAME`, `template.imageName` (the repo slug part), `build.model`, `endpoint.gpuTypeIds`, etc.
3. `./scripts/build.sh endpoints/<new-name>.json` — bakes a new image and pushes it
4. `./scripts/deploy.sh endpoints/<new-name>.json` — creates the endpoint
5. `./scripts/gen-opencode-config.sh && cp opencode/opencode.json ~/.config/opencode/opencode.json`

Each model gets its own baked image, so this is a once-per-model cost.

## Updating an existing deployment

What you're changing dictates what you need to run:

| Change | Build? | Deploy? | Destroy first? |
|---|---|---|---|
| GPU tier, scaling, idle timeout | no | yes (PATCH) | no |
| Runtime env var (`MAX_MODEL_LEN`, parser, etc.) | no | yes (PATCH) | no |
| Model (`build.model`) | yes | yes | yes — image change |
| Worker image tag bump | yes | yes | yes — image change |
| Container disk size | maybe | yes | yes — disk lives on template |

`deploy.sh` refuses to PATCH when `imageName` changes — it'll tell you to
`destroy.sh` first. That avoids a silent-no-op trap.

## Manifest field reference

```jsonc
{
  "name": "qwen3-coder-30b",                 // local key; prefixes RunPod names
  "template": {
    "imageName": "${REGISTRY}/runpod-opencode-qwen3-coder-30b:v1",
    "containerDiskInGb": 120,                // baked image is ~70GB; leave headroom
    "env": {                                 // runtime env, merged on top of image ENV
      "MODEL_NAME": "Qwen/Qwen3-Coder-30B-A3B-Instruct",
      "MAX_MODEL_LEN": "32768",
      "GPU_MEMORY_UTILIZATION": "0.95",
      "TRUST_REMOTE_CODE": "true",           // booleans are "true"/"false", NOT "1"/"0"
      "DTYPE": "bfloat16",
      "ENABLE_AUTO_TOOL_CHOICE": "true",
      "TOOL_CALL_PARSER": "qwen3_coder",     // see note below
      "MAX_CONCURRENCY": "4"                 // single-user; more = wasted KV cache
    }
  },
  "build": {                                 // consumed only by scripts/build.sh
    "baseImage": "runpod/worker-v1-vllm:v2.18.1",
    "model": "Qwen/Qwen3-Coder-30B-A3B-Instruct"
  },
  "endpoint": {
    "gpuTypeIds": ["NVIDIA H100 80GB HBM3"], // ordered preference; RunPod falls through
    "gpuCount": 1,
    "workersMin": 0,                         // scale-to-zero between requests
    "workersMax": 1,                         // cap concurrent worker cost
    "idleTimeout": 5,                        // seconds of idle before worker dies
    "scalerType": "QUEUE_DELAY",
    "scalerValue": 4,
    "flashboot": true,
    "executionTimeoutMs": 180000             // 3 min ceiling per request
  },
  "opencode": {                              // consumed only by gen-opencode-config.sh
    "displayName": "Qwen3 Coder 30B (RunPod)",
    "contextLimit": 32768,
    "maxOutputTokens": 8192
  }
}
```

`TOOL_CALL_PARSER: qwen3_coder` is the model-native parser and the only one
that correctly handles Qwen3-Coder's `<function=...><parameter=...>` emit
format. Available in vLLM ~0.10+ (bundled with worker-v1-vllm v2.18.x). On
older worker images, `hermes` is a fallback but you'll see raw tool-call text
leaking into the chat content because it can't decode the native syntax.

## Useful RunPod GPU IDs

```
NVIDIA L4
NVIDIA L40
NVIDIA L40S
NVIDIA A100 80GB PCIe
NVIDIA A100-SXM4-80GB
NVIDIA H100 PCIe
NVIDIA H100 80GB HBM3
NVIDIA H100 NVL
NVIDIA H200
NVIDIA RTX A6000
NVIDIA RTX 6000 Ada Generation
```

(Full list: <https://docs.runpod.io/references/gpu-types>.)

## Phase 2: baked images

The `scripts/build.sh` + `docker/Dockerfile` path is the answer to "the HF
download is killing my cold starts." It extends `runpod/worker-v1-vllm:v2.18.1`
and runs `huggingface-cli download` at build time, then sets `HF_HUB_OFFLINE=1`
so runtime never touches the HF API. Net effect:

| | Stock image | Baked image |
|---|---|---|
| First cold start | 5–15 min (60 GB HF download) | ~30–60 s (registry pull, then warm) |
| Subsequent cold starts | ~30–60 s (RunPod caches blobs) | ~30 s |
| Tight idle timeout viable | not really | yes |
| Reproducibility | depends on HF + worker tag | pinned in image |

Requirements:

- Docker with BuildKit (modern Docker has it on by default).
- ~150–200 GB of free disk during build (image layers + push cache).
- A registry you can `docker login` to: GHCR (recommended; free for public images), Docker Hub, or RunPod's own registry.
- Set `REGISTRY` in `.env` to e.g. `ghcr.io/your-github-user`.

Build cost is amortized — you only rebuild when changing the underlying
model or bumping the worker image tag. Routine config tweaks (env vars,
GPU tier, scaling) PATCH the endpoint in place and don't require a rebuild.

For gated HF models (none of the shipped manifests use one), uncomment the
`--mount=type=secret,id=hf_token` line in `docker/Dockerfile` and pass
`--secret id=hf_token,env=HF_TOKEN` to `docker build`.

## Roadmap

- [ ] Try an FP8/AWQ quant of Qwen3-Coder-30B on L40S to get the big model at L40S prices.
- [ ] GitHub Actions workflow for building images, so the laptop doesn't have to push 70 GB.
- [x] Move to a custom Docker image with the model baked in for faster cold starts — see Phase 2 section above.
- [x] Add a second manifest (smaller model on L40S) for cheap experimentation — `qwen2.5-coder-14b.json`.
- [x] Pin a specific `worker-v1-vllm` tag — `runpod/worker-v1-vllm` does **not** publish `:latest`; only versioned tags from <https://github.com/runpod-workers/worker-vllm/releases>. Manifest pins `v2.18.1`.
