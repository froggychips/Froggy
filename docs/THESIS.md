# Thesis

This document captures the central argument behind Froggy and the
operational principles that follow from it. It is a compass — not a
roadmap. When in doubt about an architectural decision, return here
first. When this document and a feature request disagree, the feature
request loses by default.

## The thesis

> Froggy is a **memory-orchestration runtime with a trust-governance
> layer** for local AI on constrained Apple Silicon. Its differentiator
> is not inference speed but *enabling capability classes that don't
> fit without it* — voice, VLM, persona memory, and chat coexisting on
> 8 GB unified memory, with screen-context awareness.

Two inseparable layers, neither sufficient alone:

1. **Memory orchestration.** Reactive pressure handling, tiered
   freezing, forced pageout, MLX subprocess isolation. Makes the
   capabilities *possible*.
2. **Trust governance.** Freeze confidence scoring, activity
   detection, freeze budgets, explainability, per-app capture
   policy. Makes the capabilities *acceptable* to a real user.

Without (1), Froggy is another OCR-equipped LLM wrapper — Ollama
already does that, with less code and fewer risks. Without (2), it is
technically brilliant but psychologically hostile — one frozen Zoom
call away from being uninstalled.

## Anti-compromise design

Most local-LLM tooling accepts the 8 GB constraint by **shrinking the
model**: harder quantization, smaller architectures, trimmed KV-cache,
swapped-out layers. Froggy takes the opposite approach — **keep the
model useful, shrink everything else**. The model stays the size it
needs to be; the OS around it gets re-managed under pressure.

This is not a stylistic choice. It is the entire reason the project
exists. Removing the freeze layer to make Froggy "less invasive"
collapses the thesis: at that point Ollama already does what Froggy
does, with less code and fewer risks.

## Qualitative substrate, not quantitative

Substrate work falls into two categories with very different survival
profiles:

- **Quantitative substrate** makes existing capabilities *N% faster or
  cheaper*. It rarely survives without active maintenance, because the
  gain is rarely large enough to switch stacks.
- **Qualitative substrate** makes capabilities *possible at all* that
  were infeasible before. It tends to outlive any single application
  built on top of it.

Froggy's design target is **qualitative**. The test for any new
substrate-layer work is:

> *Does this enable a class of capability that is impossible without
> it?*

If the answer is "it makes the existing thing N% better," the work is
deprioritized. If the answer is "without this, voice + VLM + chat
cannot coexist on 8 GB," the work is core.

## Success criteria

Three signals, in order of immediacy and trustworthiness:

1. **The author uses Froggy daily for non-development tasks** within
   6 months of any major capability landing. If Froggy is only useful
   while *working on Froggy*, the project is already dead — even if no
   one has noticed yet. This signal cannot be falsified to oneself for
   long.
2. **A capability exists that cannot be reasonably achieved without
   Froggy's architecture.** Voice + VLM + persona memory + chat, all
   coexisting on 8 GB unified memory, with screen context and trust
   governance. If this capability works, the substrate is justified by
   its own output.
3. **External developers build atop the runtime.** Plugins,
   downstream tools, alternative front-ends. This is a *bonus*
   outcome, not the primary success measure. Substrate that only the
   author uses is still a win if (1) and (2) hold.

Notably absent from this list: stars, "production readiness," total
user count, enterprise adoption, hiring on the strength of the repo.
These are not the project's target. They may happen; they are not
evidence of success against the thesis.

## Primary failure mode

**Infrastructure gravity trap.** The pattern in which substrate keeps
refining itself — cleaner abstractions, deeper test coverage, more
elegant ADRs — without ever producing a user-facing capability above
it. Each refinement looks justified in isolation; the cumulative
effect is a project that never ships anything its users (including
the author) actually use.

The trap is dangerous specifically because each step is *defensible*.
"This refactor makes future work easier" is true and also a death
spiral if "future work" never comes.

Mitigations are structural, not motivational:

- **Time-boxed substrate phases.** *N* weeks on substrate, then *N*
  weeks on capability, regardless of whether substrate feels
  "complete." Substrate is never complete. Capability proves whether
  substrate was sufficient.
- **The trust governance layer is itself a capability.** It is not
  "Level 1.5 substrate before the real work begins." A menubar that
  explains *"Slack frozen — memory pressure critical, no active call
  detected, background 18 min, will resume in 4 min"* is a user-visible
  feature that no other tool offers. Treat it that way.
- **Capability precedes platform.** Do not announce a "platform"
  before a working application demonstrates value. Successful
  platforms are *discovered* under shipped applications (SQLite,
  Redis, Sentry), not declared in advance.
- **Design docs do not run ahead of implementation.** Forward-looking
  specification beyond the layer currently being built is its own
  flavour of gravity trap — see
  [`docs/adr/0009-design-docs-after-implementation.md`](adr/0009-design-docs-after-implementation.md).
  After a layer's design-docs are written, the next design-doc for a
  subsequent layer is gated on at least one implementation PR for the
  current layer landing in main.

## Operating principles

Decisions that follow directly from the thesis:

- **Aggression in the memory layer is non-negotiable.** `SIGSTOP` +
  forced pageout is the load-bearing technique. Critiques that say
  "remove freeze to be less invasive" misunderstand the project.
- **UX trust is non-negotiable.** Every freeze must be explainable,
  time-bounded, and subject to confidence scoring. A trust failure
  (frozen Zoom call, broken Slack reconnect during work) is a
  *thesis-level* failure, not a bug — it falsifies layer (2).
- **Privacy is non-negotiable.** Screen content does not leave the
  machine without explicit per-source opt-in. Redaction happens before
  disk, not before display. Cloud routing, when added, is per-tier and
  audited.
- **Hardware target is constrained Apple Silicon.** 16+ GB Macs are
  out of scope *as the design audience* — they don't have the problem
  Froggy solves. They may use Froggy and benefit from the trust and
  capability layers, but the architecture is not tuned for them and
  optimization decisions break ties in favor of 8 GB.
- **The author is the first user.** When in doubt about UX or scope,
  prioritize what the author actually uses daily over what would scale
  to imagined other users. Imagined users do not exist yet; the author
  does.
- **Qualitative > quantitative for any roadmap decision.** When choosing
  between two pieces of work, the one that *enables a previously
  impossible class of capability* wins over the one that makes existing
  capability faster.

## Living document

This thesis can change. When it does, the change is recorded as an
ADR with explicit reasoning, not silently. If a future PR implies a
thesis change without saying so, the PR is wrong: either the change
shouldn't happen, or the thesis should be updated first, in a separate
PR, with the new wording defended on its own.
