# syntax=docker/dockerfile:1.6
#
# Bakes a Hugging Face model into a worker-v1-vllm image so RunPod cold starts
# don't have to download 30–60 GB of weights every time. Built by
# scripts/build.sh — see README "Phase 2: baked images" for the workflow.

ARG BASE_IMAGE=runpod/worker-v1-vllm:v2.18.1
FROM ${BASE_IMAGE}

ARG MODEL
RUN test -n "${MODEL}" || (echo "ERROR: MODEL build arg is required" >&2 && exit 1)

# Use hf_transfer for ~2–3× faster downloads during build (build-time only;
# runtime is offline anyway). huggingface_hub is already in the worker image
# as a vLLM dependency.
ENV HF_HUB_ENABLE_HF_TRANSFER=1

# Pre-populate the HF cache at /root/.cache/huggingface/hub. vLLM looks here
# first when loading by HF id, so MODEL_NAME stays as the natural HF model id
# in the manifest — no /models/... paths leaking into OpenCode requests.
#
# For gated models, supply HF_TOKEN as a Docker secret:
#   docker build --secret id=hf_token,env=HF_TOKEN ...
# then uncomment the --mount line below.
RUN \
    # --mount=type=secret,id=hf_token,target=/run/secrets/hf_token \
    huggingface-cli download "${MODEL}"

# Belt-and-suspenders offline mode. With these set, neither huggingface_hub
# nor transformers will attempt a network call at runtime — they use the
# baked-in cache directly. Removes the failure mode where a transient HF
# outage breaks model loading on cold start.
ENV HF_HUB_OFFLINE=1
ENV TRANSFORMERS_OFFLINE=1

LABEL org.opencontainers.image.title="runpod-opencode-baked"
LABEL model="${MODEL}"
LABEL base="${BASE_IMAGE}"
