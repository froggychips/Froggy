# What Froggy is and isn't

Froggy is an opinionated personal project. This document exists so visitors
and would-be users can decide quickly whether it's relevant to them — and
so contributors don't open issues asking for things that are explicitly
out of scope.

## What Froggy is

- A **research-grade scaffold** for running local MLX models on
  memory-constrained Apple Silicon Macs — specifically targeting **8 GB
  unified memory**, the configuration most existing local-LLM tools
  ignore.
- A **working example of native macOS resource management**:
  `ScreenCaptureKit` capture, Vision OCR, reactive memory-pressure
  handling, `SIGSTOP` + forced pageout for background apps, MLX
  inference isolated in a child process, secret redaction before disk —
  all in Swift 6 with strict concurrency.
- A **plugin host** (`LushaAccessor`) so other tools can read normalized
  screen/system context over a Unix-socket JSON IPC, callable from any
  language.
- A **readable codebase** for people learning Swift 6, MLX integration,
  ScreenCaptureKit, low-level macOS APIs (mach, jetsam, dispatch
  pressure sources), and ADR-driven design.
- **Open source** for educational reference and contribution. (A
  formal `LICENSE` file is on the to-do list — until then, treat the
  code as source-available with all rights reserved by the author.)

## What Froggy is NOT

- **Not a consumer product.** No installer, no auto-updates, no support
  channel beyond GitHub Issues and Telegram.
- **Not a Rewind / Granola / Pi alternative.** Those are polished,
  funded products in adjacent categories. Froggy doesn't compete with
  them and won't try to.
- **Not cross-platform.** macOS 14+ on Apple Silicon only. Intel Macs,
  iOS, Linux, Windows are all out of scope by design — the whole memory
  story is unified-memory specific.
- **Not a frozen project, not a stable API.** The roadmap is exploratory
  and may shift. Don't depend on Froggy for critical workflows. IPC
  command shapes may change between releases.
- **Not yet hardened against malicious input.** Threat model assumes
  the local user is non-adversarial; do not expose the IPC socket or
  the daemon to untrusted networks or untrusted local users.

## Goals (in order of priority)

1. **Run a useful local-LLM workflow on 8 GB unified memory** without
   constant OOM and swap thrash.
2. **Stay fully on-device by default.** Nothing leaves the machine
   unless the user explicitly opts in. Secrets are redacted before
   disk, not just before display.
3. **Be a readable reference codebase** for Swift 6 + MLX + low-level
   macOS APIs. Architectural decisions are documented in
   [`docs/adr/`](adr/).
4. **Stay hackable.** Plugin API and JSON-line IPC mean you can build
   on top of Froggy without forking it.

## Non-goals

- Becoming a SaaS or paid product.
- Beating Rewind on memory of past activity, or Cursor / ChatGPT on
  coding help. Different categories, different budgets.
- Supporting non-Apple-Silicon platforms.
- Maintaining backward compatibility forever — pre-1.0 means breaking
  changes are allowed, with a note in the relevant PR.

## Who this is for

Roughly, in descending order of fit:

- People with **8 GB Apple Silicon Macs** who want to run small local
  LLMs without the machine grinding to a halt.
- **Privacy-conscious developers** who can't (or won't) send screen
  contents to cloud APIs — corporate code under NDA, legal/medical
  contexts, security research.
- **Swift / macOS developers** looking for a real-world example of
  Swift 6 strict concurrency, MLX integration, ScreenCaptureKit, or
  low-level memory management.
- **Hobbyists** who want a scriptable AI assistant they can drive from
  shell scripts, git hooks, or their own tools via the Unix-socket IPC.

## Who this is NOT for

- Someone looking for a polished, supported product. Use Rewind, Pi,
  or ChatGPT desktop instead.
- Anyone running on Intel Macs or non-Apple platforms.
- Production deployments. Treat Froggy as a personal tool, not
  infrastructure.

## Contact

- GitHub Issues for bugs, feature ideas, and PRs.
- Telegram: [@froggychips](https://t.me/froggychips) for direct contact.
