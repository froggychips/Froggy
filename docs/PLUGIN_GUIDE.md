# Plugin Guide — writing a `LushaAccessor`

🌐 **English** · [Русский](PLUGIN_GUIDE.ru.md)

Froggy treats *context sources* as plugins. Each one is called a
**`LushaAccessor`** and exposes one channel of data — current frontmost
app, last OCR'd screen, calendar entries, browser tabs, mailbox, anything
that can be sampled on demand. The agent (or any IPC client) asks the
daemon "give me the current snapshot of accessor X" and gets back a list
of strings.

This guide walks through writing a new accessor end-to-end. Target
audience: someone with a Swift checkout of Froggy, who wants to surface
one more signal to the local LLM without touching `main.swift` or the
IPC server.

## When to add an accessor

✅ Good fit:
- One concept, one channel (e.g. *Calendar — next 3 events*).
- Cheap snapshot (< 50 ms typical). Heavy CPU/IO work should be pre-computed
  elsewhere and the accessor just reads the cache.
- Doesn't require new TCC consent (or that consent is already requested
  by the daemon for an unrelated feature).

❌ Wrong tool:
- Mutating state, sending events into the world, kicking off long jobs —
  those are jobs for an *actor* in `VortexCore`, not a read-only accessor.
- Needs to capture screen / microphone / accessibility data directly.
  Reuse `LushaBridge`'s redacted streams (`ContextStore.snapshots()`)
  instead of plumbing a second capture session.

## Anatomy of an accessor

The protocol lives in [`Sources/LushaBridge/LushaAccessor.swift`](../Sources/LushaBridge/LushaAccessor.swift):

```swift
public protocol LushaAccessor: Sendable {
    var id: String { get }            // stable, kebab-case identifier shown in IPC
    var name: String { get }          // human-readable label
    var experimental: Bool { get }    // default false; see "Experimental" below
    func snapshot() async -> [String] // current value, one line per fact
}
```

Implementing one is ~30 lines. The two built-ins ([`OCRAccessor`](../Sources/LushaBridge/LushaAccessor.swift)
and [`FrontmostAppAccessor`](../Sources/LushaBridge/LushaAccessor.swift)) are good references.

## Worked example: `BatteryAccessor`

We'll surface the current charging state, battery percentage, and time-to-empty.
None of this requires entitlements — `IOKit` reads battery state without TCC.

### 1. Decide where it lives

| Maturity | Lives in | Marker |
|---|---|---|
| Stable, tested, public | `Sources/LushaBridge/` | `experimental: false` (default) |
| Prototype, rough edges OK | `Sources/LushaExperimental/` | `experimental: true` |

Battery is a stable concept, but if you're prototyping — start in
`LushaExperimental`, move to `LushaBridge` later. Cost of moving is one
file rename.

### 2. Write the struct

Create `Sources/LushaExperimental/BatteryAccessor.swift`:

```swift
import Foundation
import IOKit.ps
import LushaBridge

public struct BatteryAccessor: LushaAccessor {
    public let id = "battery"
    public let name = "Battery State"
    public let experimental = true

    public init() {}

    public func snapshot() async -> [String] {
        let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] ?? []
        guard let first = sources.first,
              let info = IOPSGetPowerSourceDescription(blob, first)?.takeUnretainedValue() as? [String: Any] else {
            return ["state=unknown"]
        }
        let percent = (info[kIOPSCurrentCapacityKey] as? Int) ?? -1
        let state   = (info[kIOPSPowerSourceStateKey] as? String) ?? "?"
        let ttE     = (info[kIOPSTimeToEmptyKey]     as? Int) ?? -1
        return [
            "percent=\(percent)",
            "state=\(state)",
            "minutesToEmpty=\(ttE)",
        ]
    }
}
```

Constraints to keep in mind:
- **`Sendable`**: all stored properties must be `Sendable`. Stateless structs
  pass for free; closures need `@Sendable`.
- **`snapshot()` is `async`**: hop to `MainActor.run { … }` if you need AppKit
  (see `FrontmostAppAccessor` for the pattern).
- **Return `[String]`**: one fact per line. The agent prompt-template
  joins them with `\n`; structured wire formats (JSON) are a separate
  concern handled by `IPCResponse`.

### 3. Hook it into the registrar

`main.swift` doesn't know about individual accessors. It only sees
`AccessorRegistrar` objects. For experimental accessors there's one shared
registrar — [`LushaExperimentalRegistrar`](../Sources/LushaExperimental/LushaExperimental.swift):

```swift
public struct LushaExperimentalRegistrar: AccessorRegistrar {
    public init() {}

    public func register(into registry: AccessorRegistry) async {
        await registry.register(ThermalStateAccessor())
        await registry.register(BatteryAccessor())   // ← add this line
    }
}
```

That's the only file you touch outside your new accessor. `main.swift`
stays unchanged — see ADR-0011 §EXP-1 for the rationale.

For a stable (`experimental: false`) accessor in `LushaBridge`, the
analogous registrar is `LushaBridgeRegistrar`.

### 4. Verify via CLI

After `make build`:

```bash
# List registered accessors. Without --experimental, only stable ones.
swift run froggy accessors --experimental
# id=battery       name="Battery State"        experimental=true
# id=thermal       name="Process Thermal State" experimental=true
# id=ocr           name="Screen OCR"            experimental=false
# id=frontmost     name="Frontmost Application" experimental=false

# Pull a snapshot.
swift run froggy snap battery
# percent=84
# state=AC Power
# minutesToEmpty=-1
```

### 5. Make it usable from the LLM

The `generate` command supports `useContext: true`, which folds the
sliding OCR window into the prompt. Accessors aren't auto-folded — that
would explode the prompt every call. Pull them explicitly:

```bash
swift run froggy snap battery | swift run froggy gen --prompt "Should I unplug the laptop and head to the meeting room?"
```

Or query directly through IPC:

```bash
echo '{"cmd":"snapshot","accessor":"battery"}' \
  | nc -U ~/Library/Application\ Support/Froggy/froggy.sock
# {"ok":true,"text":"percent=84\nstate=AC Power\nminutesToEmpty=-1","final":true}
```

### 6. Test it

Two paths depending on side effects.

**Pure / deterministic** (battery snapshot is non-deterministic but
reads via IOKit, which has no Swift mock): integration test under
`Tests/LushaExperimentalTests/`:

```swift
@Test func batteryAccessor_returnsAtLeastStateField() async {
    let snap = await BatteryAccessor().snapshot()
    #expect(snap.contains { $0.hasPrefix("state=") })
}
```

**Stateful** (e.g. an accessor that depends on a `ContextStore` or
external service): inject the dependency via init parameter and feed it
a fake in the test, the way `OCRAccessor(store:)` already does.

## Experimental vs stable

The `experimental: true` flag has two practical effects:

1. **Visibility filter.** `froggy accessors` shows only stable by default;
   pass `--experimental` to include them.
2. **No SemVer promise.** Stable accessors are part of FroggyDaemon's
   wire API: removing one or changing the `id` is a breaking change
   ([ADR-0003 forward-compat invariants](adr/0003-codable-json-config.md)).
   Experimental ones can be removed in a patch release.

When to promote experimental → stable:
- API has been used by an agent or tool for ≥ 2 weeks without churn.
- Failure modes are documented (what does `snapshot()` return if the
  underlying source is unavailable?).
- Either you have tests or you've decided the source is mockable enough
  that nobody will.

To promote, move the file from `LushaExperimental/` to `LushaBridge/`,
delete the `experimental` property (default is `false`), and move the
`registry.register(...)` call from `LushaExperimentalRegistrar` to
`LushaBridgeRegistrar`.

## Common pitfalls

- **Doing capture inside `snapshot()`**: don't. Capture lives in
  `ScreenStream` / `ContextStore`. Accessors read the latest cached frame.
- **Returning a single huge blob**: split into one fact per line so the
  agent can grep or summarise without parsing.
- **Forgetting `@MainActor`**: `NSWorkspace`, `NSRunningApplication`, and
  some `IOKit` APIs require main-thread access. Wrap with `await MainActor.run { … }`
  as `FrontmostAppAccessor` does.
- **Pulling in a new TCC permission**: if your accessor needs accessibility,
  screen recording, or microphone consent that the daemon doesn't already
  ask for, document the prompt in `packaging/README.md` and update
  `Froggy.entitlements`.

## See also

- [ADR-0011 — code-first design-second for level-2 features](adr/0011-code-first-design-second-for-level-2.md)
  (registrar pattern rationale).
- [ADR-0015 — frontmost-veto-minimal](adr/0015-frontmost-veto-minimal.md)
  (related: how the daemon already knows the frontmost app).
- [`LushaBridge/LushaAccessor.swift`](../Sources/LushaBridge/LushaAccessor.swift)
  — protocol + registry + built-in accessors.
- [`LushaExperimental/LushaExperimental.swift`](../Sources/LushaExperimental/LushaExperimental.swift)
  — current experimental registrar and a worked example
  (`ThermalStateAccessor`).
