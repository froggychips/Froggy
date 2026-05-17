import Darwin
import Foundation
import VortexCore

@main
struct FroggyCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let cmd = args.first else {
            stderr(Self.usage)
            exit(2)
        }
        let rest = Array(args.dropFirst())
        let socket = ProcessInfo.processInfo.environment["FROGGY_IPC_SOCKET"]
            ?? FroggyConfig.defaultSocketPath
        let client = IPCClient(socketPath: socket)

        do {
            switch cmd {
            case "status": try await Self.runStatus(client)
            case "gen", "generate": try await Self.runGenerate(client, rest)
            case "ctx", "context": try await Self.runContext(client, rest)
            case "load": try await Self.runLoad(client, rest)
            case "unload": try await Self.runUnload(client)
            case "accessors": try await Self.runAccessors(client, rest)
            case "snap", "snapshot": try await Self.runSnapshot(client, rest)
            case "thaw": try await Self.runThaw(client)
            case "listen": try await Self.runListen(client, rest)
            case "listen-stop": try await Self.runListenStop(client)
            case "listen-status": try await Self.runListenStatus(client)
            case "listen-stream": try await Self.runListenStream(client)
            case "recap": try await Self.runRecap(client, rest)
            case "audit": try await Self.runAudit(rest)
            case "-h", "--help", "help":
                print(Self.usage)
                exit(0)
            default:
                stderr("unknown command: \(cmd)\n\n\(Self.usage)")
                exit(2)
            }
        } catch let e as IPCClientError {
            stderr("IPC error: \(e)")
            exit(1)
        } catch {
            stderr("error: \(error)")
            exit(1)
        }
    }

    // MARK: - Commands

    private static func runStatus(_ client: IPCClient) async throws {
        let r = try await client.status()
        if r.ok != true {
            stderr(r.error ?? "status failed")
            exit(1)
        }
        // Разбито на одиночные append'ы — type-checker не вытягивает
        // массив-literal с 10+ tuples + ?? + map + String.init за разумное
        // время и кидает «unable to type-check this expression».
        var pairs: [(String, String)] = []
        pairs.append(("coord_state",     r.coordinatorState ?? "—"))
        if r.coordinatorState == "degraded", let reason = r.coordinatorStateReason {
            pairs.append(("degraded_reason", reason))
        }
        pairs.append(("capturing",       fmt(r.capturing)))
        pairs.append(("listening",       fmt(r.listening)))
        pairs.append(("model_loaded",    fmt(r.modelLoaded)))
        pairs.append(("model_path",      r.modelPath ?? "—"))
        pairs.append(("memory_pressure", r.memoryPressure.map { "\($0)%" } ?? "—"))
        pairs.append(("frozen_procs",    r.frozen.map(String.init) ?? "—"))
        pairs.append(("snapshots",       r.snapshots.map(String.init) ?? "—"))
        pairs.append(("capture_error",   r.lastCaptureError ?? "—"))
        pairs.append(("audio_output",    r.audioOutputDevice ?? "—"))
        pairs.append(("audio_input",     r.audioInputDevice ?? "—"))
        let width = pairs.map(\.0.count).max() ?? 0
        for (k, v) in pairs {
            print("\(k.padding(toLength: width, withPad: " ", startingAt: 0))  \(v)")
        }
    }

    private static func runGenerate(_ client: IPCClient, _ args: [String]) async throws {
        var prompt: String?
        var maxTokens: Int?
        var useContext = false
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--max-tokens", "-n":
                guard i + 1 < args.count, let v = Int(args[i + 1]) else {
                    stderr("--max-tokens needs an integer"); exit(2)
                }
                maxTokens = v; i += 2
            case "--context", "-c":
                useContext = true; i += 1
            default:
                if prompt == nil { prompt = a } else { prompt! += " " + a }
                i += 1
            }
        }
        guard let p = prompt else {
            stderr("usage: froggy gen [--context] [--max-tokens N] <prompt...>")
            exit(2)
        }
        let stream = client.generateStream(prompt: p, maxTokens: maxTokens, useContext: useContext)
        for try await chunk in stream {
            print(chunk, terminator: "")
            // `fflush(stdout)` для немедленной выдачи токенов в streaming
            // режиме. Раньше тут был `FileHandle.standardOutput.synchronizeFile()`
            // (= fsync), который **не определён** для non-tty FileHandle'ов
            // (pipe, redirect, /dev/null) — кидал `NSFileHandleOperationException`
            // и крашил CLI при любом запуске не из interactive shell'а
            // (`echo x | froggy gen "..."`, CI скрипты, через harness'ы).
            // `fflush` работает на любом FILE*, в т.ч. pipe. Bug-1.
            fflush(stdout)
        }
        print() // trailing newline
    }

    private static func runContext(_ client: IPCClient, _ args: [String]) async throws {
        var maxChars: Int?
        var i = 0
        while i < args.count {
            if (args[i] == "--max" || args[i] == "-m"), i + 1 < args.count, let v = Int(args[i + 1]) {
                maxChars = v; i += 2
            } else {
                stderr("usage: froggy ctx [--max N]"); exit(2)
            }
        }
        let r = try await client.context(maxChars: maxChars)
        if r.ok == true {
            print(r.context ?? "")
        } else {
            stderr(r.error ?? "context failed"); exit(1)
        }
    }

    private static func runLoad(_ client: IPCClient, _ args: [String]) async throws {
        guard let path = args.first else {
            stderr("usage: froggy load <model-path>"); exit(2)
        }
        let r = try await client.loadModel(path: path)
        if r.ok == true {
            print("loaded: \(r.modelPath ?? path)")
        } else {
            stderr(r.error ?? "load failed"); exit(1)
        }
    }

    private static func runUnload(_ client: IPCClient) async throws {
        let r = try await client.unloadModel()
        if r.ok == true { print("unloaded") }
        else { stderr(r.error ?? "unload failed"); exit(1) }
    }

    private static func runAccessors(_ client: IPCClient, _ args: [String]) async throws {
        // `--experimental` / `--core` фильтруют список на стороне
        // демона. Без флага — все аксессоры. См. ADR 0011 § EXP-1.
        var filter: Bool?
        for a in args {
            switch a {
            case "--experimental": filter = true
            case "--core": filter = false
            default:
                stderr("unknown flag: \(a)\nusage: froggy accessors [--experimental|--core]")
                exit(2)
            }
        }
        let r = try await client.accessors(experimental: filter)
        guard r.ok == true, let list = r.accessors else {
            stderr(r.error ?? "accessors failed"); exit(1)
        }
        for a in list {
            let tag = (a.experimental == true) ? "  [experimental]" : ""
            print("\(a.id)\t\(a.name)\(tag)")
        }
    }

    private static func runSnapshot(_ client: IPCClient, _ args: [String]) async throws {
        guard let id = args.first else {
            stderr("usage: froggy snap <accessor-id>"); exit(2)
        }
        let r = try await client.snapshot(accessorId: id)
        guard r.ok == true, let lines = r.lines else {
            stderr(r.error ?? "snapshot failed"); exit(1)
        }
        for line in lines { print(line) }
    }

    private static func runThaw(_ client: IPCClient) async throws {
        let r = try await client.thawAll()
        if r.ok == true { print("thawed") }
        else { stderr(r.error ?? "thaw failed"); exit(1) }
    }

    private static func runListen(_ client: IPCClient, _ args: [String]) async throws {
        var discordPid: Int32?
        var injectFile: String?
        var i = 0
        while i < args.count {
            if (args[i] == "--discord-pid" || args[i] == "-d"), i + 1 < args.count {
                guard let v = Int32(args[i + 1]) else {
                    stderr("--discord-pid needs an integer"); exit(2)
                }
                discordPid = v; i += 2
            } else if args[i] == "--inject", i + 1 < args.count {
                injectFile = args[i + 1]; i += 2
            } else {
                stderr("usage: froggy listen [--discord-pid PID] [--inject FILE]"); exit(2)
            }
        }
        let r = try await client.listen(discordPid: discordPid, injectFile: injectFile)
        if r.ok == true {
            print("listening: \(r.listening == true ? "yes" : "no")")
        } else {
            stderr(r.error ?? "listen failed"); exit(1)
        }
    }

    private static func runListenStop(_ client: IPCClient) async throws {
        let r = try await client.listenStop()
        if r.ok == true {
            print("stopped")
            if let path = r.sessionURL {
                print("session:  \(path)")
                print("hint:     froggy recap  (or  froggy recap --path <file>)")
            }
        } else { stderr(r.error ?? "listen-stop failed"); exit(1) }
    }

    private static func runListenStatus(_ client: IPCClient) async throws {
        let r = try await client.listenStatus()
        if r.ok == true {
            print("listening:     \(r.listening == true ? "yes" : "no")")
            print("audio_output:  \(r.audioOutputDevice ?? "—")")
            print("audio_input:   \(r.audioInputDevice ?? "—")")
            if let path = r.sessionURL { print("session:       \(path)") }
        } else {
            stderr(r.error ?? "listen-status failed"); exit(1)
        }
    }

    private static func runListenStream(_ client: IPCClient) async throws {
        let stream = client.listenStream()
        for try await chunk in stream {
            guard chunk.ok == true else {
                stderr(chunk.error ?? "stream error"); exit(1)
            }
            let speaker = chunk.speaker ?? "?"
            let marker = chunk.final == true ? "" : "…"
            print("[\(speaker)]\(marker) \(chunk.text ?? "")")
            fflush(stdout)
        }
    }

    /// Issue #63: `froggy audit` — pretty-print последних N записей из
    /// audit-лога. Без IPC — читает файл напрямую. Это нарочно: если daemon
    /// упал, audit-trail остаётся читаемым.
    private static func runAudit(_ args: [String]) async throws {
        var limit = 50
        var day: String?
        var i = 0
        while i < args.count {
            if args[i] == "--limit", i + 1 < args.count, let v = Int(args[i + 1]) {
                limit = v; i += 2
            } else if args[i] == "--day", i + 1 < args.count {
                day = args[i + 1]; i += 2
            } else {
                stderr("usage: froggy audit [--limit N] [--day YYYY-MM-DD]"); exit(2)
            }
        }
        let auditLog = AuditLog()
        let records = await auditLog.tail(limit: limit, day: day)
        if records.isEmpty {
            print("(no audit records)")
            return
        }
        for r in records {
            // Компактная строка для tail-style чтения. Полный JSON всё
            // равно лежит в audit-YYYY-MM-DD.log если нужны все поля.
            var line = "\(r.ts)  \(r.op.padding(toLength: 7, withPad: " ", startingAt: 0))"
            if let pid = r.pid { line += "  pid=\(pid)" }
            if let bundleId = r.bundleId { line += "  app=\(bundleId)" }
            if let tier = r.tier { line += "  tier=\(tier)" }
            line += "  reason=\(r.reason)"
            if let outcome = r.outcome, outcome != "ok" { line += "  outcome=\(outcome)" }
            print(line)
        }
    }

    private static func runRecap(_ client: IPCClient, _ args: [String]) async throws {
        var path: String? = nil
        var i = 0
        while i < args.count {
            if args[i] == "--path", i + 1 < args.count {
                path = args[i + 1]; i += 2
            } else { i += 1 }
        }
        let stream = client.recapStream(path: path)
        for try await chunk in stream {
            print(chunk, terminator: "")
            fflush(stdout)
        }
        print() // финальный перевод строки
    }

    // MARK: - Helpers

    private static func fmt(_ v: Bool?) -> String {
        switch v {
        case .some(true): return "yes"
        case .some(false): return "no"
        case .none: return "—"
        }
    }

    private static func stderr(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    static let usage = """
    Usage: froggy <command> [options]

    Commands:
      status                              show daemon status
      gen [--context] [-n N] <prompt>     stream a generation; --context augments with OCR
      ctx [--max N]                       print recent context window
      load <model-path>                   hot-swap MLX model
      unload                              unload current model
      accessors [--experimental|--core]   list registered LushaAccessors
      snap <accessor-id>                  run one accessor and print its lines
      thaw                                SIGCONT all frozen processes
      listen [--discord-pid PID] [--inject FILE]  start meeting transcription; optionally inject pre-call context from FILE
      listen-stop                         stop transcription (swap back to main model)
      listen-status                       show whether transcription is active
      listen-stream                       stream transcript chunks to stdout (blocking)
      recap [--path <file>]               generate LLM summary of last session (streams tokens)
      audit [--limit N] [--day YYYY-MM-DD] pretty-print recent freeze/thaw audit records
      help                                this message

    Environment:
      FROGGY_IPC_SOCKET                   override socket path
                                          (default ~/Library/Application Support/Froggy/froggy.sock)
    """
}
