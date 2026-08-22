# DGX Spark — Qwen3.8-27B serving (docker compose)

Compose configs for serving **Qwen3.8-27B** on an NVIDIA DGX Spark (GB10) unit.
Developed and validated on `aitopatom1` (host alias via NVIDIA Sync ssh_config,
user `amasu`, LAN IP `192.168.50.201`).

**Current setup: SGLang + NVFP4 + DFlash2, greedy default.** Selected as the
quality-primary / speed-secondary winner of an engine × sampler A/B — see
[`benchmarking.md`](benchmarking.md) for the full evidence.

## Quick start

Deploy the current production stack (SGLang + NVFP4 + DFlash2) on a fresh DGX Spark:

```bash
# Prerequisites: DGX Spark with Docker + Compose plugin, git, ~30 GB free
# disk (weights + draft), and network for a one-time HF download.

git clone https://github.com/amasu/dgx-spark-qwen38
cd dgx-spark-qwen38

# 0. Build the serving image qwen38-dflash2:v1.2.2 — a LOCAL tag. It is NOT
#    published to any registry, so there is no `docker pull` for this tag.
#    The image = the public base `lmsysorg/sglang:qwen38-27b` (Docker Hub,
#    pinned digest) + 5 sha256-verified DFlash2 overlay files from the SGLang
#    commit-1cf2b8c tree (PR #35496). Build it locally once per host (do this
#    in a scratch dir, not this repo):
#    git clone https://github.com/hasso5703/dgx-spark-qwen38 && cd dgx-spark-qwen38
#    ./install.sh --no-service   # pulls base, downloads RadixArk NVFP4 + z-lab
#                                # DFlash2 draft checkpoints, builds & tags
#                                # qwen38-dflash2:v1.2.2, writes the patched
#                                # chat template + API key. No systemd.
#    cd <back to this repo>
#    On aitopatom1 the image already exists (built 2026-08-22).

# 1. Start the current production stack
docker compose up -d

# 2. First boot ~9 min (torch.compile + CUDA graph capture). Wait for health:
watch -n 15 'docker compose ps --format "{{.Status}}" | grep -i healthy'
#    → "healthy" means ready.

# 3. Smoke test (served model id = qwen3.8-27b)
curl http://localhost:8000/v1/chat/completions -H "Content-Type: application/json" -d '{
  "model": "qwen3.8-27b",
  "messages": [{"role": "user", "content": "Explain what a DGX Spark is in two sentences."}],
  "max_tokens": 256
}'
```

**Rollback:** the previous production (vLLM + NVFP4 + MTP) is kept as an
instant fallback:

```bash
docker compose down
docker compose -f docker-compose.vllm.yml up -d   # vLLM+MTP rollback
# ...or the older SGLang+DSpark rollback:
docker compose -f docker-compose.sglang.yml up -d
```

**Troubleshooting:** if the container crash-loops, check fresh `docker ps`
start times and `docker logs <container>` for the root traceback before
changing config. `restart: unless-stopped` hides engine crashes behind
restarts.

## Files

| File | Stack | Status |
|------|-------|--------|
| `docker-compose.yml` | **SGLang + NVFP4 + DFlash2** (`qwen38-dflash2:v1.2.2`) | **current production** |
| `docker-compose.vllm.yml` | vLLM + NVFP4 + embedded MTP (`vllm-node-b12x:latest`) | rollback |
| `docker-compose.sglang.yml` | SGLang + NVFP4 + DSPARK draft (`lmsysorg/sglang:qwen38-27b`) | rollback |
| `docker-compose.fp8-legacy.yml` | vLLM + FP8 + DSPARK draft (`vllm-openai:deepgemm`) | legacy (needs `Dockerfile` build) |
| `benchmarking.md` | engine × sampler A/B + hard-mode + DeepSWE results | evidence |
| `Dockerfile` | Multi-stage DeepGemm build experiment (arm64) | experimental — legacy FP8 only |

Only one stack runs at a time; switch with `docker compose -f <file> up -d`
after `docker compose down`. All stacks expose the OpenAI-compatible endpoint
on port 8000.

## Current production stack

`SGLang + NVFP4 + DFlash2`, block-diffusion speculative decoding:

- Target: `RadixArk/Qwen3.8-27B-NVFP4`; draft: `z-lab/Qwen3.8-27B-DFlash2`
  (block size 8, lossless)
- Served model id: `qwen3.8-27b`; context 262144 tokens
- `--mem-fraction-static 0.50` (do **not** raise — SGLang under-counts GB10
  unified-memory transients; >0.50 risks a host freeze), plus
  `--allow-auto-truncate` (agentic/DeepSWE contexts grow to ~110K tokens)
- OpenAPI/no-auth on port 8000 (drop-in parity with the previous stack)
- Boot ~9 min with cached weights (torch.compile + graph capture); later boots
  faster, cached
- Expected: **~24→53 tok/s** decode depending on workload (see benchmarking.md)

**Sampler default: greedy** (temp 0), the winning cell. The Qwen "thinking
mode" set (`temperature=1.0, top_p=0.95, top_k=20`) is available per-request
but costs ~2× latency and regressed the TC-58 injection scenario in our
testing — prefer greedy for tool-calling; reserve thinking mode for tasks
that genuinely need deeper planning. `reasoning_effort` (xhigh/medium/low) is
the better latency knob for a 27B tool-agent.

## Obtaining the serving image (`qwen38-dflash2:v1.2.2`)

`qwen38-dflash2:v1.2.2` is a **local build tag — it is not published to any
registry, so `docker pull qwen38-dflash2:v1.2.2` will fail**. Build it once on
each host. What it contains and where it comes from:

- **Base (the only network pull):** `lmsysorg/sglang:qwen38-27b` on Docker
  Hub, pinned to digest
  `sha256:febfb971c7352570fc445c466ebd6ffc9d896024958e544a60f2137fd85856b1`
  (a 2026-08-15 SGLang build). This is the one pullable artifact.
- **Overlay (local files):** 5 DFlash2 source files from the SGLang
  commit-`1cf2b8c` tree (PR #35496 — the quantized-`lm_head` selector path that
  the NVFP4 checkpoint requires), sha256-verified against
  `dflash2/MANIFEST.sha256` in `hasso5703/dgx-spark-qwen38`.

**Reproduce (recommended — full prep):**
```bash
git clone https://github.com/hasso5703/dgx-spark-qwen38 && cd dgx-spark-qwen38
./install.sh --no-service   # pulls base image; downloads RadixArk/Qwen3.8-27B-NVFP4
                            # + z-lab/Qwen3.8-27B-DFlash2 checkpoints (~30 GB);
                            # builds & tags qwen38-dflash2:v1.2.2; writes the
                            # patched chat template + API key + Claude Code env.
                            # --no-service = foreground, no systemd.
docker images | grep qwen38-dflash2   # → localhost tag v1.2.2 now exists
```

**Minimal (image only):** once the base image is pulled and you have the
`dflash2/` overlay directory:
```bash
BASE_IMAGE=lmsysorg/sglang@sha256:febfb971c7352570fc445c466ebd6ffc9d896024958e544a60f2137fd85856b1 \
TAG=qwen38-dflash2:v1.2.2 \
  ./dflash2/build-image.sh      # offline, ~1 min, verifies MANIFEST.sha256
```

Boot is ~9 min (torch.compile + CUDA graph capture); the container needs no
network once the image + checkpoints are cached.

## Benchmarking

See [`benchmarking.md`](benchmarking.md) — engine × sampler tool-eval-bench
matrix, bench-matrix decode profiles, the 84-scenario hard-mode run (93/100),
and the (inconclusive) DeepSWE attempt.

`bench-matrix.sh` runs a fixed workload battery (8 prompts × 3 languages)
against **any** OpenAI-compatible endpoint and reports tok/s. Decode is
measured net of prefill via a two-call delta (80 vs 680 max_tokens, same
prompt), so results stay comparable across engines, boxes and months — commit
the JSON as history.

```bash
# Defaults match the current stack (port 8000, model qwen3.8-27b, no auth):
BASE_URL=http://127.0.0.1:8000 MODEL=qwen3.8-27b ./bench-matrix.sh
# Auth (if the server has an API key, e.g. the hasso5703 run.sh variant):
# API key from file: $HOME/.config/qwen38/api-key (or set API_KEY=)
```

Output: human table + `bench-matrix-<label>.json`. Sample results:
[`bench-matrix-dflash2.json`](bench-matrix-dflash2.json) (DFlash2,
~32–56 tok/s on code/math) and
[`bench-matrix-mtp-current.json`](bench-matrix-mtp-current.json) (vLLM+MTP,
~12–25 tok/s).

## Useful commands

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8000/health   # → 200
docker compose logs -f
docker ps   # check for crash-loop (restart: unless-stopped + crash = silent loop)
```

## Why DFlash2 (not the older stacks)

The community-fastest Qwen3.8-27B config on GB10 is SGLang + NVFP4 + DFlash2
(50 tok/s greedy median on the reference harness, fully OpenAI-compatible).
DFlash2 block-diffusion speculative decoding beats the embedded-MTP (vLLM,
~24 tok/s) and DSpark (SGLang, ~34–38 tok/s) approaches. Our own A/B
confirmed it: ~2–2.5× faster than vLLM+MTP at **tied or better** tool-calling
quality (91 standard / 93 hard-mode), with no safety regression. DFlash2 is
not compatible with YaRN context extension.

DFlash2 needs an SGLang build at/after commit `1cf2b8c` (PR #35496) — the
release tag `lmsysorg/sglang:qwen38-27b` predates the quantized-`lm_head`
selector path, so on NVFP4 a build without #35496 fails at boot with
`requires a dense FP16/BF16/FP32 target lm_head`. The `qwen38-dflash2:v1.2.2`
image bundles the fix.

## Credits

Community work from the NVIDIA DGX Spark / GB10 forum and related repos:

- **hasso5703 / basbunarhasan** — the one-command SGLang + NVFP4 + DSpark/DFlash2
  setup ([#380257](https://forums.developer.nvidia.com/t/qwen3-8-27b-at-34-38-tok-s-on-dgx-spark-open-source-one-command-setup-sglang-nvfp4-dspark/380257),
  [dgx-spark-qwen38](https://github.com/hasso5703/dgx-spark-qwen38)) — basis of
  the current production compose.
- **kosta** — DFlash2 recipe + dual-Spark TP2
  ([#380732](https://forums.developer.nvidia.com/t/qwen3-8-27b-nvfp4-on-single-dual-dgx-spark-sglang-dflash2-fully-openai-compatible/380732)),
  including the tool-eval-bench 92.3±0.6/100 validation.
- **MiaAI-Lab** — the quantized-lm_head fix that makes DFlash2 safe on the
  NVFP4 checkpoint.
- **RadixArk** — NVFP4 + DSpark checkpoints; **z-lab / Inco AI** — the
  DFlash2 drafter; **SGLang (lmsysorg)** — engine + DFlash2 implementation;
  **unsloth** — NVFP4 quantization (embedded MTP in the checkpoint).
- **helge** — vLLM+MTP measurements
  ([#380244](https://forums.developer.nvidia.com/t/qwen3-8-27b-nvfp4-on-a-single-dgx-spark-up-to-1m-context-vllm-mtp-measurements/380244)).

## Sources

- SGLang cookbook — [Qwen3.8-27B](https://lmsysorg.mintlify.app/cookbook/autoregressive/Qwen/Qwen3.8-27B)
  (DFlash2 official recipe)
- NVIDIA forums — [#380732](https://forums.developer.nvidia.com/t/qwen3-8-27b-nvfp4-on-single-dual-dgx-spark-sglang-dflash2-fully-openai-compatible/380732),
  [#380257](https://forums.developer.nvidia.com/t/qwen3-8-27b-at-34-38-tok-s-on-dgx-spark-open-source-one-command-setup-sglang-nvfp4-dspark/380257),
  [#380244](https://forums.developer.nvidia.com/t/qwen3-8-27b-nvfp4-on-a-single-dgx-spark-up-to-1m-context-vllm-mtp-measurements/380244)
- hasso5703/dgx-spark-qwen38 — [BENCHMARKS.md](https://github.com/hasso5703/dgx-spark-qwen38)

## License

MIT — see [LICENSE](LICENSE).
