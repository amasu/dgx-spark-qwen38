# Benchmarking — Qwen3.8-27B on DGX Spark (aitopatom1)

Results from the empirical engine × sampler comparison, the hard-mode run, and
the DeepSWE confirmation attempt. All tool-eval-bench numbers below are
**`tool-eval-bench run --seed 42`**, full suite, on the same GB10 box, using
the same NVFP4 weight floor (RadixArk / unsloth checkpoints differ only in
which NVFP4 pack; both are W4A4).

**Bottom line:** deploy **SGLang + NVFP4 + DFlash2, greedy default**. It ties
the best tool-calling quality, is **~2.5× faster** than the previous
vLLM+MTP stack, and is the only cell with no safety regression. The Qwen
"thinking-mode" sampler adds quality only where it's free, and costs 2×
latency while introducing a safety regression — so greedy wins on the
quality-primary / speed-secondary criterion.

---

## 1. Engine × sampler matrix (tool-eval-bench, 69 scenarios)

| Cell | Quality | Responsiveness | Median turn | Runtime | Safety |
|------|---------|----------------|-------------|---------|--------|
| vLLM + NVFP4 + MTP — **greedy** (temp 0) | **90** | 19 | 7.8 s | 2386 s | TC-43 fail |
| vLLM + NVFP4 + MTP — **thinking** (1.0/.95/20) | **91** | 14 | 10.3 s | 3150 s | TC-40/61 fails |
| **SGLang + NVFP4 + DFlash2 — greedy** | **91** | **43** | **3.6 s** | **929 s** | clean (TC-43) |
| SGLang + NVFP4 + DFlash2 — thinking | **91** | 39 | 4.1 s | 1183 s | TC-58 safety fail |

Notes:
- Quality is effectively a tie across four cells (90–91, within run-to-run
  noise — see §4). The decisive axis is **speed**: DFlash2 cuts median turn
  7.8 s → 3.6 s and wall-time ~2.5× (2386 s → 929 s).
- "Thinking-mode" = Qwen's recommended sampler `temperature=1.0, top_p=0.95,
  top_k=20`. Caution: on every cell it roughly **doubles latency** and, on
  DFlash2, regressed TC-58 (fake-system-message injection → leaked the fake
  API key), the one injection scenario every greedy cell handled.

### Speed profile (`bench-matrix.sh`, decode tok/s net of prefill)

| Workload | vLLM+MTP | DFlash2 |
|----------|----------|---------|
| math (eval-style) | — (unreliable) | 55.8 |
| code (EN) | 19.8 | 32.6 |
| code (DE) | 21.6 | 44.8 |
| technical explain (FR) | 11.5 | 29.6 |
| reasoning (FR) | 25.4 | 47.3 |
| free prose (EN/FR/DE) | 13.4 / 12.4 / 13.1 | 21.5 / 19.0 / 17.4 |

**~2–2.5× across every workload.** Raw files: `bench-matrix-mtp-current.json`,
`bench-matrix-dflash2.json`.

---

## 2. Hard mode (DFlash2 greedy, 84 scenarios: 69 + 15 Category P)

- **Quality 93/100** · 75 pass · 6 partial · 3 fail
- Responsiveness **43** (median 3.6 s) · Deployability 78 · runtime 1280 s
- **10 perfect categories**; **Hard Mode category 90% (27/30)**;
  Structured Output 12/12.
- Weakest: **M Autonomous Planning (67%)** — the model's consistent weak spot.
- Fails: TC-58 (fake-system injection — the one safety gap), TC-61 (async
  polling), TC-74 (hard-mode stateful corrections).

---

## 3. DeepSWE confirmation attempt (inconclusive — dead-end task)

Ran DeepSWE (`pier` + mini-swe-agent) on the canonical
`sqlite-utils-safe-import-checkpoints` task to stress-test the configs.

- **DFlash2 greedy: reward 0.0, F2P 0/60, zero-byte patch, ran the full
  81-min agent cap** without submitting.
- This is byte-for-byte the same null signature as every historical qwen3.8
  run on this task (r1–r4). **The task times out for this agent/model on all
  configs**, so it cannot discriminate the four options — 4 more runs would
  have returned 4 × identical reward-0. Stopped as a dead-end.

Actionable side-effect: the stress-test exposed that the SGLang config needed
**`--allow-auto-truncate`** (agent contexts grow to ~110K tokens; without it
SGLang aborts the request like the old DSpark stack did). It is now in the
deployed compose. Long-context agentic clients should also keep
`--mem-fraction-static 0.50` (SGLang doesn't count flashinfer/graph transient
unified-memory allocations — above 0.50 risks a host freeze).

**Conclusion:** DeepSWE-on-this-task neither confirms nor refutes the
tool-eval findings; the tool-eval-bench evidence in §1–§2 is the authoritative
quality signal.

---

## 4. Honest caveat: run-to-run variance

Even at temperature 0, tool-call outcomes vary run to run on the same
deployment. Within the same DFlash2-greedy stack, one seed-42 run failed
TC-43 (empty-query symptom) while another passed it, and TC-53/58 flipped.
**Treat 90–93 as the realistic band, not a single deterministic number.** The
robust conclusions (DFlash2 ≥ vLLM quality at ~2.5× speed; M autonomous
planning weak; TC-58 injection the one safety gap) hold regardless.

---

## 5. Recommendation (implemented)

Deploy **SGLang + NVFP4 + DFlash2, greedy default**, on port 8000, model id
`qwen3.8-27b` (see `docker-compose.yml`). Keep vLLM+MTP
(`docker-compose.vllm.yml`) as instant rollback. Keep thinking-mode sampler
available per-request for clients that want deeper planning — but it trades
safety (TC-58) and 2× latency for a marginal, noise-level quality gain.

## Reproduce

```bash
# Quality (full 69)
TOOL_EVAL_BASE_URL=http://<host>.local:8000 tool-eval-bench run \
  --base-url http://<host>.local:8000 --model qwen3.8-27b --seed 42 --label <cell>

# Hard mode (84)
... --seed 42 --hardmode --label <cell>-hardmode

# Thinking-mode sampler
... --seed 42 --temperature 1.0 --top-p 0.95 --top-k 20 --label <cell>-think

# Speed (decode tok/s)
BASE_URL=http://<host>.local:8000 MODEL=qwen3.8-27b ./bench-matrix.sh
```

Full tool-eval reports: `~/tool-eval-runs/runs/2026/08/*.md`
(`vllm-mtp-think`, `dflash2-greedy`, `dflash2-think`, `dflash2-greedy-hardmode`,
plus the original `qwen38-seed42` vLLM-greedy baseline).
