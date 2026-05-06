# ADR 0002 — Unix domain socket for IPC, not XPC

* **Status:** Accepted (Phase 1)
* **Date:** 2026-05-06

## Context

The daemon needs an interface for in-process and out-of-process clients
(eventual MenuBar UI, CLI tools, scripts, third-party integrations).

Options:

1. **NSXPC / `xpc_main`.** Apple's recommended path for first-party macOS
   daemons. Requires a launchd-registered Mach service name, a code-signed
   bundle, an Info.plist, and (in practice) sandbox + entitlements wiring to
   make Apple's tooling happy.
2. **AF_UNIX SOCK_STREAM** at a known path under `~/Library/Application
   Support/Froggy/`. Permission control via filesystem mode bits.
3. **TCP/HTTP on localhost.** Simplest to talk to from any language, but
   exposes a port, requires firewall thinking, and doesn't carry peer creds.

## Decision

Unix domain socket. Path is configurable via `FroggyConfig.ipcSocketPath`,
default `~/Library/Application Support/Froggy/froggy.sock` with mode `0600`.
Protocol is one JSON object per line in each direction (`IPCRequest`,
`IPCResponse`).

## Consequences

* **Pro:** No bundle, no Mach service registration, no code-signing required
  to *develop*. `swift run FroggyDaemon` followed by
  `nc -U …/froggy.sock` works immediately.
* **Pro:** Trivial to script from any language (Python, Node, Bash via `socat`).
* **Pro:** Filesystem ACLs are enough to keep other users out — mode 0600 +
  the socket lives in the user's `~/Library`.
* **Con:** No ARC / Sendable type sharing across the boundary; the protocol
  is stringly-typed JSON. We mitigate with a single `IPCRequest`/`IPCResponse`
  Codable pair and a thin `IPCClient` actor in `VortexCore` that other Swift
  consumers can import.
* **Con:** No peer-credential check beyond filesystem permissions. If we ever
  expose Froggy to a multi-user system we'll need `SO_PEERCRED`-style checks.
* **Con:** No streaming responses (yet). Long-running generations land as a
  single response block. Phase 4 candidate: chunked responses with a streaming
  protocol marker.

## Alternatives considered

* **XPC via `NSXPCConnection`.** We may revisit when we ship a proper signed
  installer; the daemon and UI would each gain a small XPC stub on top of the
  same `IPCRequestHandler` protocol.
* **gRPC.** Overkill for a personal-use daemon and adds protobuf+codegen.
