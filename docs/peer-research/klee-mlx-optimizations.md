# Klee — MLX Performance Optimizations, Candidates for FroggyMLXWorker

* **Source:** [signerlabs/Klee](https://github.com/signerlabs/Klee). Primary file —
  [`Klee/Service/LLMService.swift`](https://github.com/signerlabs/Klee/blob/main/Klee/Service/LLMService.swift)
  ("Phase C optimizations applied based on oMLX engine_core.py analysis"),
  plus [`Klee/Service/TokenizerPatcher.swift`](https://github.com/signerlabs/Klee/blob/main/Klee/Service/TokenizerPatcher.swift)
  for item KLEE-E. Links point to the `main` branch; when reading in the
  future, verify that the code has not drifted and that the rationale still
  holds.
* **Status:** backlog. At the time this file was created, a freeze on
  `Sources/**` changes is in effect; apply after it is lifted.
* **Date:** 2026-05-09

## Why this note exists

Klee is a direct architectural peer (Swift + mlx-swift on macOS), but it runs
MLX **in-process** without a supervisor/worker split. Architecturally that is
worse than Froggy (MLX cannot be killed without quitting the app, unified
memory cannot be returned). However, **inside** generation Klee has applied a
series of targeted performance tweaks that we have not set. Below are
cherry-pick candidates with rationale, so the next time we work on
`FroggyMLXWorker` we do not need to re-examine Klee from scratch.

Split into items with fixed IDs (`KLEE-A`..`KLEE-E`) so they can be
referenced from commits / PRs / issues.

---

## KLEE-A — Metal pipeline warmup after `loadModel`

Source: `LLMService.swift` → `warmupMetalPipeline(_:)`
([blob](https://github.com/signerlabs/Klee/blob/main/Klee/Service/LLMService.swift)).

After `loadModel`, run a background 2-token generation:

```swift
let params = GenerateParameters(maxTokens: 2, temperature: 0.0, prefillStepSize: 512)
let stream = try await container.generate(input: warmupInput, parameters: params)
for await _ in stream {}  // drain so Metal kernels have time to compile
```

**What it does:** compiles Metal shader pipelines and warms up memory
allocators. Without this, the first real user request pays shader-cache
compile time.

**Applicability to Froggy:** `FroggyMLXWorker` does not do this today. The
first generation after `loadModel` IPC is therefore colder. We already have a
pre-built metallib (ADR 0013) — that covers the existence of the library, but
the pipeline cache still warms up on the first generation.

**Cost / benefit:** ~10–30 ms CPU + minimal allocation, one-time cost per
worker lifetime. Gain — deterministic TTFT on the first user request.

**Failure mode:** non-fatal. If warmup fails, the next generation is simply
colder, as it is today. Log it, do not crash.

**Application point:** `FroggyMLXWorker/Entry.swift`, after a successful
`loadModel`, before sending `ready` over IPC. Can be a background `Task` —
then `ready` goes out sooner and warmup catches up in the background.

---

## KLEE-B — `Memory.cacheLimit` tuned to the system

Source: `LLMService.swift` → `configureGPUMemoryLimit()`
([blob](https://github.com/signerlabs/Klee/blob/main/Klee/Service/LLMService.swift)).

```swift
if let recommended = GPU.maxRecommendedWorkingSetBytes() {
    Memory.cacheLimit = Int(Double(recommended) * 0.75)
}
```

**What it does:** caps the MLX memory cache at 75% of
`GPU.maxRecommendedWorkingSetBytes()`. Without this, MLX is greedy with
unified memory.

**Why this matters especially for us:** the Vortex daemon already monitors
memory pressure (`MemoryPressureMonitor`, `FreezeStatsStore`). If a worker
without a limit has consumed everything, the supervisor will learn through
pressure → freeze, but that is a patch over the root cause. Better to limit
upfront.

**Applicability:** `FroggyMLXWorker/Entry.swift`, immediately after
`import MLX`, before the first `loadModel`. Can be made tunable via a CLI
flag `--mlx-cache-mb` analogous to `--kv-bits` (see ADR 0009) or an
environment variable. The 75% default is sane, but on older 8 GB Macs it
may be tight — worth measuring.

**Relation to other ADRs:** does not conflict with ADR 0008 (subprocess
isolation — the worker still dies on unloadModel and unified memory returns
to the kernel); complements ADR 0009 (kvBits limits the KV cache,
cacheLimit limits the overall MLX cache).

---

## KLEE-C — `GenerateParameters`: prefillStepSize + sampler nuances

Source: `LLMService.swift` → `makeGenerateParameters(kvBits:)`
([blob](https://github.com/signerlabs/Klee/blob/main/Klee/Service/LLMService.swift)).

From Klee's comment on `makeGenerateParameters`:

```
- prefillStepSize 512: matches oMLX scheduler default, processes prompt in chunks
- temperature 0.6: uses CategoricalSampler (efficient)
- topP 1.0 (default): avoids TopPSampler overhead (softmax+cumsum+sort per token).
                       CategoricalSampler is already selected by temperature > 0 alone.
- repetitionPenalty nil: no LogitProcessor created → zero per-token processing overhead
```

Two non-obvious nuances of mlx-swift-lm:

1. **`topP: 1.0` (explicitly passed) ≠ `topP: nil`.** Setting `1.0` runs
   `softmax + cumsum + sort` around every token. For top-p sampling, 1.0 means
   "no effect," but the overhead remains. **Pass `nil` / omit it** if top-p
   is not needed.
2. **`repetitionPenalty: 0` or any non-nil value is also bad.** Any non-nil
   value creates a `LogitProcessor` attached to the decode loop. nil →
   zero overhead.

**What to check in Froggy:** every place that constructs `GenerateParameters`.
Specifically:
- `FroggyMLXWorker/Entry.swift::handleGenerate` (or wherever parameter
  construction lives after ADR 0009).
- IPC inputs `MLXWorkerCommand` — if `topP`/`repetitionPenalty` are forwarded
  with a default of "1.0"/"0", replace with an optional defaulting to nil.

`prefillStepSize: 512` is most likely not set today — if so, adding it is a
one-field change in `GenerateParameters`.

---

## KLEE-D — `ModelConfiguration(directory:)` for already-cached models

Source: `LLMService.swift` → `loadModel(id:)` (the `configuration` selection
block, [blob](https://github.com/signerlabs/Klee/blob/main/Klee/Service/LLMService.swift)).

```swift
let isCachedLocally = FileManager.default.fileExists(atPath: localURL.path)
let configuration = isCachedLocally
    ? ModelConfiguration(directory: localURL)
    : ModelConfiguration(id: id)
```

**Klee comment:** *Hub normally fetches remote hashes even for cached models.*

In other words: `ModelConfiguration(id:)` hits HuggingFace Hub to verify the
ETag even when the files are already local. This means:
- an extra network round-trip on every load,
- a failure when there is no internet connection (even if the model is already
  downloaded),
- unnecessary waiting on slow networks.

**Applicability to Froggy:** if there was ever a bug "worker does not load an
already-downloaded model when offline" — this is most likely the cause. Also
relevant for CI: `make full` in bench/ under ipv6-only, a corporate proxy,
DNS issues — any scenario where the HF hub is flaky.

**Application point:** wherever the worker resolves the model path. Need to
check how Froggy currently passes the model to the worker — via `--model-path`
with a local path or via an HF id. If it is already via a local path, KLEE-D
does not apply.

---

## KLEE-E — TokenizerPatcher: chat_template missing fallback

Source: [`Klee/Service/TokenizerPatcher.swift`](https://github.com/signerlabs/Klee/blob/main/Klee/Service/TokenizerPatcher.swift),
function `patchTokenizerConfigIfNeeded(modelId:localURL:)`.

> Some mlx-community models omit chat_template, causing inference to fail.

On load, Klee checks `tokenizer_config.json` for the loaded model; if the
`chat_template` field is absent:

1. Attempts to fetch the original `tokenizer_config.json` from HF (the
   template may be present there but lost during mlx-community quantization).
2. Falls back to a bundled `QwenChatTemplate` / family.
3. Writes the patched JSON back to disk.

**Failure mode:** silent log, does not block the main download flow.

**Applicability to Froggy:** a real road bump on mlx-community quantized
models — occurs, for example, on some `Qwen3.5-*-4bit` distributions. If
Froggy users have ever experienced a worker crash on first generation after
a successful model download, check `tokenizer_config.json` in the model
directory — `chat_template` is likely missing.

**Cost:** ~60 lines of Swift + bundled template resources. Klee carries one
template (`QwenChatTemplate`); we can include only those for the model
families we actually support.

---

## KLEE-F (bonus) — accurate metrics via `GenerateCompletionInfo`

Source: `LLMService.swift`, fields `lastPrefillTimeMs` /
`lastDecodeTokensPerSec` / `lastTotalTokens` / `lastTotalTimeMs`
([blob](https://github.com/signerlabs/Klee/blob/main/Klee/Service/LLMService.swift)).
`GenerateCompletionInfo` itself comes from mlx-swift-lm.

mlx-swift-lm natively provides `GenerateCompletionInfo` with separate fields:

* `lastPrefillTimeMs` — TTFT / prefill, milliseconds
* `lastDecodeTokensPerSec` — decode-only TPS, **without** prefill bias
* `lastTotalTokens`, `lastTotalTimeMs`

**Applicability:** if `bench/run.sh` currently computes
`tokens_per_sec = total_tokens / total_time` — that mixes prefill and decode.
For short prompts this is fine; for long prompts TTFT dominates and the metric
drifts. Using the built-in API gives honest, separate numbers in
`baseline.json`.

**Application point:** somewhere near ADR 0011 "code-first-design-second for
Level 2" — that is precisely where the validation gate through bench is
discussed. If the baseline is written before this change, either rewrite it
with honest metrics or add a separate column.

---

## What we deliberately do not take from Klee

* **In-process architecture** — subprocess is better for us (ADR 0008).
* **HuggingFace mirror via env (`HF_ENDPOINT`)** — that is for Chinese CDN,
  not our scenario.
* **IntentRouter / shell_exec / web_search** — Klee is a chat agent; we are
  a process supervisor; different domains.
* **CI / Klee tests** — Klee has **none at all** (no workflows, no test
  targets). We are ahead.

---

## ml-aim, mlx-tune — why not relevant

Reviewed alongside Klee; leaving one line each to avoid revisiting.

* **[apple/ml-aim](https://github.com/apple/ml-aim)** — vision encoder
  pretraining (AIMv1/v2, CVPR 2025 / ICML 2024). Python research code,
  not infra. Zero applicability to Froggy — we do not do vision pretraining.
* **[ARahim3/mlx-tune](https://github.com/ARahim3/mlx-tune)** — Python
  fine-tuning toolkit on MLX (SFT/DPO/GRPO/Vision/TTS/STT/OCR). Training,
  not inference + process management. Could become interesting if at some
  distant roadmap point on-device LoRA for Vortex policy around user habits
  is desired — but that is years away, not now.

---

## When to apply

After the freeze on `Sources/**` is explicitly lifted. Doing all five items
in one PR is **not recommended** — each has independent value and an
independent testing surface. Minimum breakdown:

1. **PR 1: KLEE-A + KLEE-B + KLEE-C** — all in `FroggyMLXWorker/Entry.swift`,
   closely related (init/teardown/params). One regression test via bench.
2. **PR 2: KLEE-D** — separate, because it changes the model loading flow
   and needs a scenario test (offline/cached vs online/fresh).
3. **PR 3: KLEE-E** — separate PR with TokenizerPatcher + bundled templates;
   involves a resource story (see ADR 0013 on bundled resources and mlx-swift
   search paths) and needs individual verification against specific
   mlx-community models.
4. **PR 4 (optional): KLEE-F** — migration to `GenerateCompletionInfo`.
   Will affect `bench/baseline.json` — must be paired with a rebaseline and
   coordinated with ADR 0011.
