# ADR-0016: Cloud routing via froggy-mcp — data flow and privacy boundaries

| Field | Value |
|---|---|
| Status | Accepted |
| Date | 2026-05-10 |
| Ref | THESIS § "Privacy is non-negotiable" |

## Context

`froggy-mcp` is a companion MCP server that bridges Claude Code (cloud model) to the Froggy
daemon over its existing Unix-socket IPC. THESIS says: *"Cloud routing, when added, is
per-tier and audited."* This ADR is that audit.

The daemon's Redactor runs before any snapshot is stored in `ContextStore`. The question
is what exactly passes through froggy-mcp to the cloud model, and what the Redactor
does and does not guarantee.

## What leaves the machine when froggy-mcp is active

froggy-mcp exposes four tools to Claude Code. Each tool call causes the following data
to transit to Anthropic's servers:

| Tool | What leaves the Mac |
|---|---|
| `froggy_context` | Redacted OCR text from the last N snapshots (up to `contextMaxChars`). This is screen content — filenames, editor text, terminal output, Jira ticket bodies, Slack messages, browser page content — with credentials stripped. |
| `froggy_generate` | The `prompt` string the cloud model passes in, plus the local model's generated response text. The response may include information derived from OCR context. |
| `froggy_transcripts` | Raw transcript text from the current or last audio session: everything spoken and recognized during a meeting. Speaker labels and timestamps included. |
| `froggy_status` | Daemon status: `modelLoaded`, `modelPath`, `capturing`, `memoryPressure`, snapshot count, `listening`. No content. |

All four are **explicit per-call opt-ins** — Claude Code must call a tool; the MCP server
does not push data proactively.

## What the Redactor guarantees

Before any snapshot enters `ContextStore` (and therefore before it can reach froggy-mcp),
`Redactor` strips:

- AWS access keys and secret keys (`AKIA…`, `aws_secret_access_key=…`)
- GitHub personal access tokens (`ghp_…`, `github_pat_…`)
- Anthropic, OpenAI, Slack API tokens (prefix-matched)
- JWTs (`ey…` in three-part dot-separated form)
- Bearer header values (`Authorization: Bearer …`)
- `password=`, `api_key=`, `secret=`, `token=` key-value pairs
- Credit card numbers passing Luhn validation (13–19 digits)

These are replaced with `[REDACTED]` before the text is stored. The cloud model never
sees them.

## What the Redactor does NOT guarantee

The Redactor is a **credential filter**, not a content filter. It does not:

- Strip business-sensitive text (ticket descriptions, code, error messages, meeting dialogue)
- Redact personal names, email addresses, or internal URLs that don't match credential patterns
- Filter transcript content — speech recognition output passes through unmodified except for
  credential patterns that happen to be spoken
- Protect data that was never captured: raw video frames and raw audio are never stored or
  transmitted anywhere

**Practical implication:** when you call `froggy_context`, the cloud model receives your
actual screen content — code you're editing, Jira tickets open in the browser, Slack threads
visible on screen — minus credentials. If that content is sensitive beyond credentials
(proprietary code under NDA, patient data, internal financial figures), you are routing it
to a cloud model. This is the same risk as pasting a screenshot into a chat window, with
the Redactor providing an automated first pass at credential removal.

## Opt-in model

Three gates must be open for any data to reach the cloud:

1. **froggy-mcp registered in Claude Code settings** — user action, not default.
2. **Claude Code session active** — data is not streamed; it is fetched on demand by tool calls.
3. **Tool call issued** — the cloud model must ask; froggy-mcp does not push.

Froggy does not know or store which queries Claude Code makes. No telemetry is sent from
the daemon to froggy-mcp beyond the response to each IPC command.

## Audio transcripts: elevated sensitivity

`froggy_transcripts` carries meeting speech. Spoken content is categorically more sensitive
than screen OCR: people say things in meetings they would not type. The Redactor runs on
transcript text with the same credential patterns, but spoken credentials are rare — the
more realistic risk is business-confidential discussion reaching the cloud.

Mitigation: `froggy_transcripts` is a separate tool from `froggy_context`. A user can
register froggy-mcp for screen context only and instruct Claude Code not to call
`froggy_transcripts`. The daemon has no per-tool ACL today; this is a known gap.

## Relation to THESIS

THESIS states: *"Screen content does not leave the machine without explicit per-source
opt-in. Cloud routing, when added, is per-tier and audited."*

- **Explicit opt-in:** satisfied — froggy-mcp registration + per-call tool invocation.
- **Per-tier:** partially satisfied — all four tools share one opt-in (froggy-mcp
  registration). Separate enable/disable per tool is the stated gap.
- **Audited:** this ADR is the audit record.

## Decision

Accept the current data-flow as documented. The "sensitive data never leaves the Mac"
shorthand used in README is **inaccurate** and must be replaced with a precise statement:
credentials are stripped before any data leaves the Mac; screen and transcript content
does leave the Mac when froggy-mcp tools are called, by explicit user opt-in.

## Consequences

- README Ecosystem section updated with accurate privacy summary.
- Per-tool ACL (enable/disable individual froggy-mcp tools) recorded as a known gap
  in TODO.md, not a blocker for current use.
- Any future cloud-routing addition (e.g., Jira context enrichment sending data to
  Jira cloud) must produce its own ADR update before landing.
