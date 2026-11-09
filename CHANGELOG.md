# Changelog

## 2026-11-09 — fp8 KV cache, per-token SSE streaming, mem-fraction 0.70

Applied to the production DFlash2 stack on the prod host (`qwen38-dflash2`,
image `v1.2.2`, host-network port 8000). Sources: NVIDIA forum Qwen3.8-27B
NVFP4+SGLang+DFlash2 recipe (thread 380732), OpenZeka 48 tok/s recipe,
Kubesimplify engine-comparison notes.

### Changes (docker-compose.yml, all env-parameterized)

| Flag | Default | Purpose |
|---|---|---|
| `--kv-cache-dtype` | `fp8_e4m3` (`KV_CACHE_DTYPE`) | Halves KV bytes; with the mem-fraction raise below, grows the KV pool 2.4x |
| `--stream-interval` | `1` (`STREAM_INTERVAL`) | One token per SSE event — DFlash2 otherwise batches 2–4 accepted tokens per event (lumpy agent streaming) |
| `MEM_FRACTION_STATIC` | `0.50` → `0.70` | At 0.50 the pool was NOT memory-bound (fp8 KV alone changed nothing); pool scales with the fraction |

### Measured on the host (before → after)

- KV pool: **406,630 → 990,064 tokens** (~3.8 full 262K contexts)
- Decode (256-tok prose, greedy, median of 3): 23.8 → 22.5 tok/s — within
  noise, no regression
- Coherence (17×23 → 391), tool-call JSON shape, SSE streaming + TTFT 209 ms:
  all verified after each restart
- Stress (the README's documented >0.50 failure vector): 8 concurrent
  ~12K-token prompts, 96K tokens prefill in flight — completed cleanly,
  50 s wall, ~15–17 tok/s per stream, no OOM/restart, host 29 GB available
- Boot: ~7–8 min warm (cached kernels)

### Constraint history

README previously pinned `--mem-fraction-static 0.50` ("do not raise —
SGLang under-counts GB10 unified-memory transients; >0.50 risks a host
freeze"). That guidance predates fp8 KV: the 0.70-fp8 combination leaves
31 GB free at idle and survived the concurrent-prefill stress above.
**Revert to `KV_CACHE_DTYPE=auto` + `MEM_FRACTION_STATIC=0.50` if any
host-freeze or OOM symptom reappears.**

### Rollback

```bash
cd ~/qwen38-compose
cp docker-compose.yml.bak-20261109 docker-compose.yml   # + .env.bak-20261109
docker compose up -d
```
(or without a file restore: set `KV_CACHE_DTYPE=auto`, `STREAM_INTERVAL=2`,
`MEM_FRACTION_STATIC=0.50` in `.env` and `docker compose up -d`.)

### Not applied (deliberate)

- `--schedule-policy lpm` / `--radix-eviction-policy lfu` — multi-agent
  scheduling tweak; single-coder profile doesn't need it yet
- TP=2 pairing — costs the second node (ComfyUI), rejected for now
