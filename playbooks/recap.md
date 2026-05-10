---
description: Quick summary of the last Froggy meeting transcript — no Jira, just the highlights
---

# /recap — Playbook

Lightweight companion to `/standup-recap`. Just reads the transcript and gives you a quick summary — no Jira writes, no ticket lookups.

## Installation

```sh
cp playbooks/recap.md ~/.claude/commands/recap.md
```

## Usage

```
/recap   # summary of last meeting, Jira ticket IDs flagged but not acted on
```

For full Jira integration, run `/standup-recap` afterward.

---

## Steps

1. Call `froggy_transcript` with `max_chars: 8000`.
   - If empty or error: "No transcript — is Froggy running and was `froggy_listen` active?"

2. Summarize in this format:

   **Meeting: [date/time from transcript]**
   **Duration:** [estimate from timestamps if available]

   **Key topics:**
   - [topic 1]
   - [topic 2]

   **Decisions made:**
   - [decision]

   **Action items:**
   - [ ] [person]: [action]

   **Jira tickets mentioned:** WO-XXXX, WO-YYYY ← run `/standup-recap` to post summaries

3. Keep the entire output under 400 words.
