# Competitor Analysis — Froggy vs Nearest Alternatives

* **Status:** Living document
* **Date:** 2026-05-09
* **Sources:** GitHub MCP (search + README), local Froggy source reading
* **Scope:** snapshot for orientation at the next design phase; not marketing

## Why this note exists

Level 1.5 (trust governance) is not yet closed — it is too early to open
Level 2 per ADR-0014. But **understanding where the space is unclaimed** is
useful before design begins, not after. This note records what was found during
a GitHub sweep so it does not need to be re-verified at the start of each
subsequent layer.

---

## Three significant projects

### 1. [owgit/memento-native](https://github.com/owgit/memento-native)

**What it does:** local-first macOS screen memory — capture, OCR, semantic
search, timeline browsing. Swift 6 + ScreenCaptureKit + Vision + SQLite FTS5
+ on-device embeddings + H.264 video segments for the timeline. Active project
(v2.1.3 at analysis date). PolyForm NC license.

**Key differences from Froggy:**

| Aspect | Memento | Froggy |
|---|---|---|
| LLM | None. OCR → search, no generation | Yes. MLX inference in subprocess |
| Storage | SQLite FTS5 + H.264 to disk | In-memory ring buffer, 30 snapshots |
| Semantic search | On-device embeddings, works | No |
| Memory management | None (no LLM, no pressure needed) | Reactive SIGSTOP + pageout |
| Redaction | None | AWS/GitHub/JWT/CC before disk write |
| URL context | Yes (Apple Events, browsers) | No |
| Incognito auto-pause | Yes | No |
| IPC / scriptability | None | Unix socket, JSON-line |
| RAM target | Not constrained by LLM | 8 GB — primary design audience |

**Where Froggy is better:** the entire memory-orchestration layer (SIGSTOP,
pageout, subprocess isolation), secret redaction, scriptability, LLM inference
instead of search-only.

**Where Froggy is worse:** history disappears on restart (Memento retains it
for months); no URL context; no incognito pause; no timeline.

**Important boundary:** POSITIONING explicitly states "Not a Rewind / Granola /
Pi alternative" and lists as a non-goal "Beating Memento on memory of past
activity." We are not competing. The in-memory sliding window is a design
decision, not an unfinished feature.

---

### 2. [signerlabs/Klee](https://github.com/signerlabs/Klee)

**What it does:** native macOS AI agent, MLX, 100% local. Tool calling
(file_read, shell_exec, web_search), vision models (VLM), inline thinking,
streaming. Signed DMG, macOS 15+. Active, polished. MIT.

**Key differences from Froggy:**

| Aspect | Klee | Froggy |
|---|---|---|
| RAM target | **16 GB minimum** stated explicitly | 8 GB primary |
| Screen context | None | ScreenCaptureKit + OCR |
| Memory management | None (in-process MLX, unload is cosmetic) | Reactive, subprocess kill = real RAM return |
| Tool calling | Yes (mlx-swift-lm ToolCall API) | No |
| VLM | Yes | No (roadmap) |
| Model download | One-click HuggingFace | Manual path |
| Scriptability | UI-only | Unix socket IPC |
| Audio/transcription | None | In development |

**Where Froggy is better:** the only player in the 8 GB niche; real RAM return
on unload; screen context awareness; scriptable.

**Where Froggy is worse:** no tool calling; no VLM; no one-click model
download; no Klee-equivalent "agent who acts."

**Cherry-pick candidate:** mlx-swift-lm ToolCall API — Klee demonstrated that
it works natively. First reference for Level 2 tool-calling design. Separate
ID: **COMPETITOR-KLEE-TOOLCALL** — read `LLMService.swift` in Klee before the
tool-calling design-doc.

**Klee MLX optimizations:** already documented in
[`docs/peer-research/klee-mlx-optimizations.md`](klee-mlx-optimizations.md)
(KLEE-A..KLEE-F).

---

### 3. [johnmai-dev/ChatMLX](https://github.com/johnmai-dev/ChatMLX)

**What it does:** MLX chat app, multi-model, open source. Last push — March
2025, stagnating. Unsigned (xattr workaround), no screen context, no memory
management.

**Conclusion:** not relevant as a reference. Recorded for completeness —
do not revisit.

---

## What nobody does (Level 2+ opportunities)

These points **do not violate POSITIONING** — they come from the thesis
("voice, VLM, persona memory, and chat coexisting on 8 GB"), not from
competing with Memento:

**1. Persistent screen context + LLM generation on 8 GB**
Memento stores and searches but has no LLM. Froggy generates with context but
has no storage. "Summarize what I was doing yesterday" — nobody does this. This
is our qualitative gap IF we ever open up storage (but see POSITIONING
non-goal — do not compete with Rewind).

**2. Audio + screen context → LLM on 8 GB**
Klee cannot see the screen and cannot hear. Memento cannot hear and does not
generate. Froggy is building both channels. "I hear what you are doing now +
I see the screen → answer" — unique. Implemented via meeting transcription
(audio) + existing screen context.

**3. Tool calling over screen context**
The LLM sees an error on screen → reads a file → proposes a fix. Klee does
tool calling but is blind (cannot see the screen). Froggy sees the screen but
has no action loop. Combining them is a qualitatively new class.

**4. Memory management for VLM + LLM + audio on 8 GB**
Klee has VLM but on 16 GB+ with no real RAM release. Our subprocess isolation
(ADR-0008) solves this architecturally — the VLM worker is killed and RAM
returns. This is exactly the thesis: "voice + VLM + chat coexisting on 8 GB."

---

## Quick wins from the analysis (do not violate POSITIONING, not Level 2)

Both are small LushaAccessors, not architectural decisions:

**QW-1: URL accessor (Apple Events)**
Memento does it — Froggy does not. A new `BrowserURLAccessor` in
`LushaExperimental`: Apple Events → active tab in Safari/Chrome/Arc → URL +
title. Requires entitlement `com.apple.security.automation.apple-events`.
30 lines of accessor + `NSAppleEventsUsageDescription` in the plist.

**QW-2: Incognito auto-pause**
Memento does it — Froggy does not. Privacy is non-negotiable per THESIS.
In `VisionActor` before each capture cycle — Apple Events → `AXIsPrivate`.
If true — skip the snapshot. Same entitlement as QW-1, logical to ship in
one PR.

Both — after the freeze on `Sources/**` is lifted.

---

## Explicit non-goals (record and do not revisit)

Derived from POSITIONING + thesis-compliance check 2026-05-09:

* **Persistent history / SQLite + FTS5** — POSITIONING: "Non-goal: Beating
  Rewind on memory of past activity." In-memory window is the design. Do not
  touch.
* **Signed DMG + auto-update as a user-facing feature** — POSITIONING: "Not
  a consumer product. No installer, no auto-updates." Signing is needed for
  entitlements in prod; auto-update as a feature — no.
* **Semantic search (VecturaKit)** — same non-goal as persistent history.
* **Frame diff improvement** — quantitative substrate, gravity trap. THESIS
  deprioritizes. Exception: `VNGenerateImageFeaturePrintRequest` is already
  documented in TODO as "consider at the next FrameDigest touch."

---

## Sources and dates

* [signerlabs/Klee README](https://github.com/signerlabs/Klee/blob/main/README.md) — read 2026-05-09
* [owgit/memento-native README](https://github.com/owgit/memento-native/blob/main/README.md) — read 2026-05-09
* [johnmai-dev/ChatMLX README](https://github.com/johnmai-dev/ChatMLX/blob/main/README.md) — read 2026-05-09
* GitHub MCP topic search: `mlx+swift`, `screencapturekit`, `apple-silicon+llm` — 2026-05-09
