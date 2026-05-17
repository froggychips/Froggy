# Security Policy

## Supported Versions

Security updates are only provided for the latest release of Froggy.

| Version | Supported |
|---|---|
| latest | ✅ |
| older | ❌ |

## Reporting a Vulnerability

**Do not open a public issue.** Please report security vulnerabilities privately:

- **Telegram:** [@froggychips](https://t.me/froggychips)
- **Email:** big@froggychips.xyz

Include: macOS version, Froggy build, reproduction steps, and what you expected vs. what happened.

## Threat Model

### In scope

- Local data leaks — screen frames or OCR text escaping the device (e.g. written to a world-readable path, sent to a network endpoint)
- `Redactor` bypass — a pattern that reliably fails to strip a well-known secret format (API key, JWT, OAuth token) from OCR output before disk write
- Entitlement abuse — `task_for_pid-allow` or other entitlements being exploitable to gain elevated access to another process's memory
- IPC socket exposure — the Unix socket used for inter-process communication being accessible to unprivileged processes outside the app bundle
- MLX inference output leaking confidential context into crash reports or system logs

### Out of scope

- Attacks requiring the device to already be compromised (root/jailbreak, malicious kernel extension)
- Safety or bias of the underlying MLX/LLM model outputs
- Network-based attacks (Froggy does not listen on any network interface by default)
- Supply-chain attacks on Apple's MLX framework or system frameworks
- Side-channel attacks on MLX inference (timing, power analysis)
- Physical access attacks

## Sensitive Attack Surfaces

### `Redactor.swift` — secret stripping

`Redactor` applies regex patterns to OCR output before writing transcripts or passing context to the inference layer. It is **regex-based**, not ML-based, which means:
- Novel or obfuscated secret formats may not be caught
- Context-dependent secrets (e.g. a UUID that happens to be a session token) are not detected
- Partial redaction (e.g. first 4 chars leaked) is possible if a pattern has an off-by-one error

If you find a pattern that reliably bypasses Redactor for a real-world secret format, please report it — that is a meaningful security issue.

### `VortexCore/IPC.swift` — inter-process socket

The Froggy daemon and the Claude Code bridge communicate over a Unix domain socket. The socket path defaults to a location under the user's home directory. If the socket permissions allow connections from other processes under the same UID, a local attacker could inject fake context or read responses.

Verify socket permissions are `0600` (owner only) after any IPC refactor.

### `Sources/FroggyMLXWorker/` — local inference

MLX inference runs in-process on the local GPU/Neural Engine. No data leaves the device during inference. Crash reporters and system logs should not receive inference inputs or outputs; verify this if adding new logging paths.

### `Froggy.entitlements` — `task_for_pid-allow`

This entitlement grants the app the ability to attach to other processes for memory inspection (used for the pageout/frozen-pids feature). It is a high-privilege capability. Any code path reachable from untrusted input (OCR text, IPC messages) must not be able to influence which PID is targeted.

### `frozen.pids` state

The list of frozen process IDs is a privileged resource. If this file or its in-memory equivalent can be written by an unprivileged process, an attacker could cause arbitrary processes to be frozen or unfrozen. Verify that write access is restricted to the Froggy daemon process.

## Privacy Notes

- **No raw frames to disk.** Screen capture frames are processed in-memory; only OCR-derived text (after Redactor) is persisted.
- **No cloud by default.** All inference runs locally via MLX. No screen content, OCR text, or audio is sent to any remote server unless the user explicitly configures a remote endpoint.
- **Transcripts are local-only.** Audio transcription output is stored under the user's home directory with standard macOS file permissions.

## Known Limitations

- **Redactor is incomplete.** Regex-based secret detection cannot cover every possible secret format. Do not rely on Redactor as the sole control for keeping secrets off disk — treat OCR output as potentially sensitive.
- **`task_for_pid-allow` is a broad entitlement.** It is required for the frozen-process feature but grants more privilege than strictly necessary. A future hardening goal is to scope this to a helper tool with a narrower entitlement set.
- **IPC authentication via peer UID (`getpeereid`) + `chmod 0600`.** After `accept()`, the daemon reads the peer's effective UID with `getpeereid(2)` and closes the connection if it does not match its own UID; the peer PID is read via `LOCAL_PEERPID` and logged with the first command for audit. This is defence in depth on top of the `0600` permissions on the socket file. Note that **any process running under the same UID is still inside the trust boundary** — a malicious helper launched in the user's session can still connect. If you need a tighter boundary (e.g. only allow `FroggyMenuBar` and `froggy` CLI bundles), see issue tracker for follow-up work on bundle-identifier checks via `LOCAL_PEERPID` → `proc_pidpath`.

## Response SLA

| Severity | Example | Target response |
|---|---|---|
| Critical | Screen data leaking to network / disk world-readable | Patch within 48 h |
| High | Redactor bypass for common secret format | Patch within 7 days |
| Medium | IPC socket permission issue | Patch within 14 days |
| Low | Docs / UX hardening | Best effort |
