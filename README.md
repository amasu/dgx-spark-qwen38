# DGX Spark — Qwen3.8-27B serving (docker compose)

Compose configs for serving **Qwen3.8-27B** on an NVIDIA DGX Spark (GB10) unit.
Developed and validated on `aitopatom1` (host alias via NVIDIA Sync ssh_config, user `amasu`).

## Files

| File | Stack | Status |
|------|-------|--------|
| `docker-compose.vllm.yml` | vLLM + NVFP4 + embedded MTP (`vllm-node-b12x:latest`) | **current production** |
| `docker-compose.sglang.yml` | SGLang + NVFP4 + DSPARK draft (`lmsysorg/sglang:qwen38-27b`) | rollback |
| `docker-compose.yml` | vLLM + FP8 + DSPARK draft (`vllm/vllm-openai:v0.27.1`) | legacy |
| `Dockerfile` | Multi-stage DeepGemm build experiment (arm64) | experimental |

Only one stack runs at a time; switch with `docker compose -f <file> up -d` after
`down` on the active one. All stacks expose the OpenAI-compatible endpoint on
port 8000.

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

## Sources

NVIDIA Developer forums — DGX Spark / GB10 category:
- Qwen3.8-27B-NVFP4 on a single DGX Spark (vLLM+MTP): thread #380244
- Dual-Spark TP2 measurements: thread #380350
- SGLang 34–38 tok/s thread: #380257
