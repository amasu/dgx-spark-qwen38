# DGX Spark — Qwen3.8-27B serving (docker compose)

Compose configs for serving **Qwen3.8-27B** on an NVIDIA DGX Spark (GB10) unit.
Developed and validated on `aitopatom1` (host alias via NVIDIA Sync ssh_config, user `amasu`).

## Quick start

Deploy the current production stack (vLLM + NVFP4 + MTP) on a fresh DGX Spark:

```bash
# Prerequisites: DGX Spark with Docker + Compose plugin (preinstalled),
# git, and ~24 GB free disk for the weights on first run.

git clone https://github.com/amasu/dgx-spark-qwen38
cd dgx-spark-qwen38

# Optional: host-specific settings (ports, model, cache path, memory — see example.env)
cp example.env .env

# 1. Start the current production stack (vLLM + NVFP4 + MTP)
docker compose -f docker-compose.vllm.yml up -d

# 2. Wait for boot (3–4 min with cached weights; longer on first run), then poll:
watch -n 10 'curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8000/health'
#    → 200 means ready. Do NOT send requests before this; first request includes
#      JIT warmup and will be slow anyway.

# 3. Smoke test (served model name = model arg)
curl http://localhost:8000/v1/chat/completions -H "Content-Type: application/json" -d '{
  "model": "unsloth/Qwen3.8-27B-NVFP4",
  "messages": [{"role": "user", "content": "Explain what a DGX Spark is in two sentences."}],
  "max_tokens": 256
}'

# 4. Verify MTP speculative decoding is active
docker compose -f docker-compose.vllm.yml logs | grep "Resolved architecture"
#    → expect: Resolved architecture: Qwen3_5MTP (fallback: Qwen3_5Text = no MTP)

# Switch to the SGLang rollback stack if needed:
docker compose -f docker-compose.vllm.yml down
docker compose -f docker-compose.sglang.yml up -d
```

**Troubleshooting:** if the container crash-loops, check fresh `docker ps`
start times and `docker logs <container>` for the root traceback before
changing config. `restart: unless-stopped` hides engine crashes behind restarts.

## Files

| File | Stack | Status |
|------|-------|--------|
| `docker-compose.vllm.yml` | vLLM + NVFP4 + embedded MTP (`vllm-node-b12x:latest`) | **current production** |
| `docker-compose.sglang.yml` | SGLang + NVFP4 + DSPARK draft (`lmsysorg/sglang:qwen38-27b`) | rollback |
| `docker-compose.yml` | vLLM + FP8 + DSPARK draft (`vllm/vllm-openai:v0.27.1`) | legacy |
| `Dockerfile` | Multi-stage DeepGemm build experiment (arm64) | experimental — see [Building the image](#building-the-experimental-image) |

Only one stack runs at a time; switch with `docker compose -f <file> up -d` after
`down` on the active one. All stacks expose the OpenAI-compatible endpoint on
port 8000.

## Building the experimental image

The `Dockerfile` is **only needed for the legacy FP8 stack** (`docker-compose.yml`).
It bakes a DeepGEMM wheel into `vllm/vllm-openai:v0.27.1` and patches
`should_auto_disable_deep_gemm` so the kernels can be forced via
`VLLM_USE_DEEP_GEMM=1`. The production NVFP4+MTP stack does **not** use it — this
is a rollback/learning artifact, not a dependency of the current setup.

```bash
# Build ON the DGX Spark (ARM64) — the wheel is compiled ARM64 to match the
# Ubuntu arm64 base image; from any other machine add --platform linux/arm64.
docker build -t vllm-openai:deepgemm .

# Then run the legacy stack (the only one that references this image):
docker compose -f docker-compose.yml up -d
```

Notes:
- `docker-compose.yml` has no `build:` directive — `docker compose up` alone
  pulls the image, it does not build it. Run `docker build` first, or
  `docker compose -f docker-compose.yml up -d --build` to build + start in one.
- Build takes several minutes (torch 2.13 cu130 wheel + DeepGEMM v2.1.1.post3
  compile); expect ~10 GB of build layers.
- Verify DeepGemm is active at runtime:
  `docker compose -f docker-compose.yml logs | grep -i deepgemm` — if the log
  instead shows the "auto-disables DeepGemm" note, `VLLM_USE_DEEP_GEMM=1`
  (already set in the compose file) isn't reaching the patched check.

## Current production stack

`vLLM + NVFP4 + embedded MTP`, no draft model download (the MTP head ships
inside the NVFP4 checkpoint as `model_mtp.safetensors`):

- Model: `unsloth/Qwen3.8-27B-NVFP4`
- Context: up to 262144 tokens at `--gpu-memory-utilization 0.45`
- Speculative decoding: MTP, 5 speculative tokens
- Expected: ~24 tok/s single-stream (forum-measured dual-Spark TP2: ~37 tok/s)

Boot ~3–4 min when weights are cached; 23.4 GB weights download on first run.

## NGC entrypoint trap

`vllm-node-*` images run `/opt/nvidia/nvidia_entrypoint.sh`, which routes the
literal `serve` command to Ray Serve's CLI. The compose overrides
`entrypoint: ["vllm"]`, then `command: serve ...`. Confirm MTP active via log
line `Resolved architecture: Qwen3_5MTP`.

## Why not FP8+DSpark (vLLM)

Measured 8.3 tok/s single-stream → 12.5 after DSpark; aggregate stuck at
13.3 tok/s even at 16 concurrent (recurrent-layer bottleneck + slow CUTLASS
FP8 fallback; vLLM auto-disables DeepGemm for qwen3_5_text on Blackwell).
SGLang+NVFP4+DSpark then measured 18.2 tok/s prose / 31.1 code single-stream,
but OOMs on ~130K-context agentic runs (spec KV budget). vLLM+MTP+0.45
mem-fraction is the current answer: full 262144 context, no KV wall, ~24 tok/s.

## Useful commands

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://<host>.local:8000/health
docker compose -f docker-compose.vllm.yml logs -f
docker ps   # check for crash-loop (restart: unless-stopped + engine crash = silent loop)
```

Per-request thinking toggle: `chat_template_kwargs: {"enable_thinking": false}`.

## Benchmarking

`bench-matrix.sh` runs a fixed workload battery (8 prompts × 3 languages)
against **any** OpenAI-compatible endpoint and reports tok/s. Decode is
measured net of prefill via a two-call delta (80 vs 680 max_tokens, same
prompt), so results stay comparable across engines, boxes and months —
commit the JSON as history.

```bash
# Defaults match the production stack (port 8000, model unsloth/…-NVFP4):
./bench-matrix.sh
# Custom endpoint / model / no auth:
BASE_URL=http://127.0.0.1:9000 MODEL=my-model API_KEY= ./bench-matrix.sh
# API key from file: $HOME/.config/qwen38/api-key (or set API_KEY_FILE=)
```

Output: human table + `bench-matrix-<label>.json`; `<label>` derives from
`BASE_URL` (override with `LABEL=`). Sample result:
[`bench-matrix-qe38f.json`](bench-matrix-qe38f.json) — aitopatom box, prod
stack, ~15–34 tok/s (~21 avg) depending on prompt.

## Credits

This repo's configs are based on community work in the NVIDIA DGX Spark /
GB10 User Forum. Special thanks to:

- **helge** — author of the vLLM+MTP measurement thread
  ([#380244](https://forums.developer.nvidia.com/t/qwen3-8-27b-nvfp4-on-a-single-dgx-spark-up-to-1m-context-vllm-mtp-measurements/380244))
  and the dual-Spark thread
  ([#380350](https://forums.developer.nvidia.com/t/qwen3-8-27b-on-dual-sparks/380350)).
  His MTP-on-NVFP4 recipe is the basis of our current production compose.
- **basbunarhasan** — author of the open-source one-command SGLang + NVFP4 +
  DSpark setup thread
  ([#380257](https://forums.developer.nvidia.com/t/qwen3-8-27b-at-34-38-tok-s-on-dgx-spark-open-source-one-command-setup-sglang-nvfp4-dspark/380257)),
  basis of the SGLang rollback stack.
- Thread participants who validated, benchmarked and debugged alongside them:
  **jomark, jwarner, seddonm1, tim318, voktolom, 1ou2, elsaco, vasimv,
  styles01, datltq, jbourny, mecworks_nvidia** (#380244); **emX0r, pontostroy,
  helge, phrogzy, clawDRude, jetspark** (#380257); **giles8, michaelhireitem,
  0rand, shawndo** (#380350).
- **RadixArk** — NVFP4 and DSpark draft model builds used by the SGLang stack
  (`RadixArk/Qwen3.8-27B-NVFP4`, `RadixArk/Qwen3.8-27B-DSpark`), and the
  target model for the one-command setup.
- **unsloth** — NVFP4 quantization of Qwen3.8-27B; the MTP head ships inside
  the checkpoint (`model_mtp.safetensors`), so no separate draft model is
  needed.
- **lmsysorg** — SGLang container image; **NVIDIA NGC** — the
  `vllm-node-b12x` image.

## Sources

NVIDIA Developer forums — DGX Spark / GB10 category:
- Qwen3.8-27B-NVFP4 on a single DGX Spark (vLLM+MTP): thread [#380244](https://forums.developer.nvidia.com/t/qwen3-8-27b-nvfp4-on-a-single-dgx-spark-up-to-1m-context-vllm-mtp-measurements/380244)
- Dual-Spark TP2 measurements: thread [#380350](https://forums.developer.nvidia.com/t/qwen3-8-27b-on-dual-sparks/380350)
- SGLang 34–38 tok/s setup: thread [#380257](https://forums.developer.nvidia.com/t/qwen3-8-27b-at-34-38-tok-s-on-dgx-spark-open-source-one-command-setup-sglang-nvfp4-dspark/380257)

## License

MIT — see [LICENSE](LICENSE).
