---
description: Summarize the last standup transcript and post summaries to mentioned Jira tickets
---

# /standup-recap — Playbook

**Claude Code slash command** that turns a Froggy meeting transcript into Jira ticket updates.
No copy-paste. No manual notes.

## Requirements

- [Froggy daemon](https://github.com/froggychips/froggy) running with `froggy-mcp` registered in Claude Code
- [Atlassian MCP](https://github.com/anthropics/anthropic-tools-atlassian) configured for your Jira workspace
- Active or recently ended Froggy audio session (transcript must exist)

## Installation

```sh
# Global — available in any Claude Code session
cp playbooks/standup-recap.md ~/.claude/commands/standup-recap.md

# Or project-local
mkdir -p .claude/commands
cp playbooks/standup-recap.md .claude/commands/standup-recap.md
```

Then in Claude Code: `/standup-recap`

## Usage

```
/standup-recap              # full run: summarize + post to Jira
/standup-recap --dry-run    # show what would be posted, no Jira writes
/standup-recap --no-jira    # summarize only, skip comment posting
```

---

## Steps

### 1. Get transcript

Call `froggy_transcript` with `max_chars: 12000`. If it returns an error or empty content, stop and tell the user: "No transcript found — is Froggy listening? (`froggy_status`)"

### 2. Extract ticket references

Scan the transcript for all Jira ticket IDs matching the pattern `[A-Z]+-\d+` (e.g. `WO-11193`, `INFRA-42`). Deduplicate. If none found, say so and offer to post a general meeting note.

### 3. Fetch ticket context from Jira

For each unique ticket ID, call `getJiraIssue` to get: `summary`, `status`, `assignee`, `issuetype`. Use this to confirm the ticket exists and get its current state. Skip tickets that return 404/error (log them as "not found").

### 4. Build per-ticket discussion summary

For each ticket, extract from the transcript: what was said about it, any decisions made, blockers mentioned, action items, next steps. Keep it to 3–5 bullet points max. Be factual — quote speaker labels if present.

### 5. Compose Jira comment

Format each comment as:

```
*Standup recap [DATE]*

Discussion notes:
• [bullet 1]
• [bullet 2]
...

Status at time of meeting: [current status from Jira]
_Posted automatically via Froggy + Claude Code_
```

### 6. Preview and approval

**Always required before posting — even without --dry-run.**

Show a preview block for each ticket:

```
--- WO-XXXX: [Jira summary] ---
[full comment text that will be posted]

--- WO-YYYY: [Jira summary] ---
[full comment text that will be posted]
```

Then ask: **"Post these N comments to Jira? Reply `yes` to post all, `no` to cancel, or list ticket IDs to post selectively (e.g. `WO-11193 WO-11205`)."**

Wait for the user's reply. If the reply is `no` or anything other than `yes` / a list of IDs — stop, do not call `addCommentToJiraIssue`.

If `--dry-run` or `--no-jira` flag is set, skip to step 7 without asking.

### 7. Post to Jira

Post only to tickets approved in step 6. For each, call `addCommentToJiraIssue`. Record success/failure.

### 8. Output summary table

Return a markdown table:

| Ticket | Summary | Discussed | Comment posted |
|--------|---------|-----------|----------------|
| WO-XXXX | [Jira summary] | [1-line what was said] | ✓ / ✗ / dry-run |

End with total: "N tickets found, M comments posted."

## Error handling

- If `froggy_transcript` times out: retry once, then fail with message.
- If Jira returns 403: remind user to check Atlassian MCP auth.
- If a ticket ID appears in transcript but doesn't exist in Jira: skip silently, list at bottom as "Unrecognized: [ids]".
- If `--dry-run` anywhere in arguments: never call `addCommentToJiraIssue`.

## What it does NOT do

- Does not store the transcript anywhere beyond this session
- Does not create new Jira tickets
- Does not modify ticket status or assignee
- Does not process video or raw audio — only the text transcript Froggy already produced
