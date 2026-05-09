# Froggy — FAQ

Quick answers for people who don't have time to read THESIS and the ADRs.

---

## What does Froggy actually do?

Two things working together:

**1. Memory management.** Froggy monitors unified memory pressure in real time. When pressure rises, it freezes background apps (Spotify, Discord, Telegram) via `SIGSTOP`, forces their pages out to swap, and frees up RAM for the LLM. When pressure drops, it thaws them. The apps never know it happened.

**2. Screen context.** Every 2 seconds Froggy captures a screenshot via ScreenCaptureKit, runs Vision OCR on-device, strips secrets (passwords, tokens, API keys), and keeps the last 30 snapshots in memory. Ask the model "what's on my screen?" and it sees.

---

## What Froggy does NOT do

- **No history.** No database, no search over past activity. 30 snapshots in memory — that's it, cleared on restart. If you want a screen history, check out [Rewind](https://www.rewind.ai/) — they do that well.
- **Not a replacement for ChatGPT/Claude.** Froggy runs small models (3–4B) that fit in 8 GB. They handle local tasks well but don't compete with large cloud models on hard questions.
- **Not useful if you have 16+ GB RAM.** The whole point is aggressive memory management for memory-constrained machines. If you have an M3 Max with 36 GB, just use Ollama directly.
- **Doesn't run on Intel Macs.** Unified memory is an Apple Silicon architecture. Intel is out of scope by design.
- **Not a packaged product.** You build from source (`make build`). No `.dmg`, no auto-updates.

---

## My Mac slows down when I run Ollama. Will Froggy help?

Depends on why.

**If the problem is RAM contention** — browser + Slack + Spotify + Ollama all running at once — yes, that's exactly what Froggy solves. It will freeze background apps while Ollama infers and thaw them when RAM is freed.

**If the model simply doesn't fit in 8 GB**, no tool will fix that. Use a smaller model: Qwen3-4B-4bit, Gemma-3B-4bit, Phi-3.5-mini-4bit — all run in 8 GB.

---

## Is my screen being recorded continuously?

Screenshots are taken every 2 seconds (configurable), but **nothing is written to disk**. The data path is:

```
Screenshot → OCR (text) → Redactor (strips secrets) → memory (30 snapshots)
```

When the daemon stops, the buffer is gone. No video, no SQLite with screen history.

The redactor strips: AWS keys, GitHub PATs, Anthropic/OpenAI/Slack tokens, JWTs, bearer headers, `password=`/`api_key=`/`secret=` values, and credit card numbers (Luhn-validated).

---

## Does this send my screen to the cloud?

No. Everything is local: OCR via Apple Vision, inference via MLX. Nothing leaves the machine unless you explicitly configure otherwise.

---

## Can I use Froggy with Ollama?

Yes. Run the daemon without a model — it will operate as a memory manager only:

```sh
.build/release/FroggyDaemon
# No --model-path. ~50 MB footprint, full freeze/thaw logic active.
```

Ollama benefits: when RAM gets tight, Froggy freezes Slack and Discord to make room for Ollama. You can load an MLX model later via `froggy load <path>` if you need one.

---

## Which models are supported?

Any MLX model from HuggingFace that fits in RAM. For 8 GB:

| Model | RAM footprint | Link |
|---|---|---|
| Qwen3-4B-4bit | ~2.5 GB | mlx-community/Qwen3-4B-4bit |
| Gemma-3-4B-4bit | ~2.5 GB | mlx-community/gemma-3-4b-it-4bit |
| Phi-3.5-mini-4bit | ~2.2 GB | mlx-community/Phi-3.5-mini-instruct-4bit |
| Llama-3.2-3B-4bit | ~1.8 GB | mlx-community/Llama-3.2-3B-Instruct-4bit |

Froggy uses an 8-bit KV cache by default (ADR-0009), which roughly halves KV cache memory on long prompts.

---

## Do I need to know Swift to use it?

**To use it — no.** Build once (`make build`), configure `config.json`, run. From there it's CLI (`froggy gen`, `froggy status`) or any language over the Unix-socket JSON IPC.

**To read the code — yes**, it's Swift 6 with strict concurrency. The codebase is designed as a readable reference — every non-obvious decision is documented in an ADR.

---

## How is this different from Rewind / Granola / Pi?

Froggy is not a competitor to those products. Quick comparison:

| | Rewind / Granola | Pi | Froggy |
|---|---|---|---|
| Inference | Cloud (OpenAI/Anthropic) | Cloud | Local, on-device |
| History | Months, searchable | None | 30 snapshots in memory |
| RAM | Unconstrained | Unconstrained | Designed for 8 GB |
| Product | Yes, with installer | Yes | No, personal scaffold |
| Privacy | Screen goes to cloud | Conversation goes to cloud | Nothing leaves the machine |

If you want searchable screen history, use Rewind. If you want a local LLM on 8 GB without OOM, use Froggy.

---

## How stable is it?

The author uses Froggy daily for real tasks — that's success criterion #1 per [THESIS](THESIS.md). But this is a personal project, not a product with an SLA. The IPC protocol may change between versions. Don't use it in production infrastructure.

---

## Where do I report a bug?

[GitHub Issues](https://github.com/froggychips/Froggy/issues) or Telegram [@froggychips](https://t.me/froggychips).
