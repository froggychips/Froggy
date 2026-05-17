import AudioWorkerProtocol
import Darwin
import Dispatch
import Foundation
import LushaBridge
import LushaExperimental
import MLXWorkerProtocol
import VortexCore
import os

private let log = Logger(subsystem: "com.froggychips.froggy", category: "daemon")

@main
struct FroggyDaemon {
    static func main() async {
        log.info("🐸 Froggy Daemon v0.4.0 starting")
        // Issue #57: явный лог wire-version constants. При расследовании
        // «почему daemon не понимает worker» — здесь сразу видно ожидаемые
        // числа, чтобы сравнить с тем что worker напишет в свой лог на старте.
        log.info(
            "wire api versions: mlx=\(MLXWireVersion.current, privacy: .public) audio=\(AudioWireVersion.current, privacy: .public) ipc=\(IPCWireVersion.current, privacy: .public)"
        )

        // SIGPIPE → SIG_IGN. IPC writes на закрытый client socket (клиент
        // crash'нулся посреди streaming response'а) иначе шлют SIGPIPE и
        // **убивают daemon с exit 141**. Один плохой client кладёт сервис.
        // Игнор SIGPIPE здесь означает: write возвращает EPIPE, IPC server
        // обрабатывает per-connection, daemon живёт. Bug-2.
        signal(SIGPIPE, SIG_IGN)

        let cli: CLIArgs
        do {
            cli = try CLIArgs.parse(arguments: CommandLine.arguments)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n\n\(CLIArgs.usage)\n".utf8))
            exit(2)
        }

        // Persisted config + CLI/env overrides.
        var config = (try? FroggyConfig.load()) ?? FroggyConfig()
        if let v = cli.modelPath { config.modelPath = v }
        if let v = cli.captureIntervalSeconds { config.captureIntervalSeconds = v }

        // Сначала восстанавливаемся: если предыдущий запуск умер с
        // зависшими SIGSTOP-pids — отпускаем их сейчас.
        let pidStore = FrozenPidsStore()
        let recovered = await pidStore.recover()
        if recovered > 0 {
            log.notice("recovered \(recovered) frozen pids from previous run")
        }

        let pageoutChain = PageoutChain(
            preferred: config.pageoutStrategy,
            machVM: MachVMPageoutImpl(),
            jetsam: JetsamPageoutImpl(),
            scratch: ScratchPageoutImpl(scratchMB: config.pageoutScratchMB)
        )
        // Mem-5: телеметрия freeze (этап 1 — только сбор; overlay позже).
        let freezeStats: FreezeStatsStore?
        let ranker: FreezeRanker?
        if config.freezeRankingEnabled {
            let store = FreezeStatsStore()
            do {
                try await store.openAndMigrate()
                freezeStats = store
                ranker = FreezeRanker(store: store)
                log.notice("freeze ranking telemetry enabled")
            } catch {
                log.warning("freeze ranking init failed: \(error.localizedDescription, privacy: .public)")
                freezeStats = nil
                ranker = nil
            }
        } else {
            freezeStats = nil
            ranker = nil
        }
        _ = freezeStats // ipc-handler ссылается отдельно
        let vortex = VortexActor(pidStore: pidStore, pageout: pageoutChain, ranker: ranker)
        let audioWorkerURL = config.audioWorkerPath.map { URL(fileURLWithPath: $0) }
        // Issue #58: audio worker тоже регистрируется в FrozenPidsStore под
        // `categoryWorker`, чтобы boot-recovery подбирал его сирот после
        // крах daemon'а (раньше boot-recovery работал только для MLX worker'а).
        let audioSupervisor = AudioSupervisor(workerExecutableURL: audioWorkerURL, pidStore: pidStore)

        let workerURL = config.mlxWorkerPath.map { URL(fileURLWithPath: $0) }
        let mlx = MLXSupervisor(
            memoryLimitBytes: config.gpuMemoryLimitBytes,
            workerExecutableURL: workerURL,
            pidStore: pidStore,
            kvCacheBits: config.kvCacheBits
        )
        let pressureSource: any MemoryPressureSource = DispatchMemoryPressureSource()
        let monitor = MemoryPressureMonitor(
            source: pressureSource,
            cooldownSeconds: TimeInterval(config.pressureCooldownSeconds)
        )
        // Reactive workspace events: один источник на координатор, finder и
        // termination-watcher — экономит подписки и держит state-карту в
        // одном месте.
        let workspaceSource: any WorkspaceEventSource = RealWorkspaceEventSource()
        let reactiveFinder = ReactiveProcessFinder(source: workspaceSource)
        await reactiveFinder.start()
        let coordinator = VortexCoordinator(
            mlx: mlx,
            vortex: vortex,
            monitor: monitor,
            tier1BundleIds: config.freezeTier1BundleIds,
            tier2BundleIds: config.freezeTier2BundleIds,
            finder: reactiveFinder,
            workspaceSource: workspaceSource,
            callModelPath: config.callModelPath,
            mainModelPath: config.modelPath,
            audioLocale: config.audioLocale,
            audioOnDeviceRecognition: config.audioOnDeviceRecognition,
            echoSuppressionEnabled: config.echoSuppressionEnabled,
            echoSuppressionTailMs: config.echoSuppressionTailMs,
            freezingEnabled: config.freezingEnabled
        )
        await coordinator.startMonitoring()
        // Termination-watcher: чистит FrozenPidsStore при внешнем kill'е.
        let terminationWatcher = WorkspaceTerminationWatcher(
            source: workspaceSource,
            pidStore: pidStore,
            sink: coordinator
        )
        await terminationWatcher.start()
        let scorer: any SimilarityScorer = config.contextDedupEnabled
            ? JaccardSimilarityScorer()
            : NoopSimilarityScorer()
        let contextStore = ContextStore(
            capacity: config.contextWindowSize,
            scorer: scorer,
            dedupThreshold: config.contextDedupThreshold
        )
        let vision = VisionActor(
            captureInterval: .seconds(config.captureIntervalSeconds),
            redactor: Redactor(),
            contextStore: contextStore,
            frameSimilarityThreshold: config.frameSimilarityThreshold
        )

        // Generic registration: main.swift не знает о конкретных
        // аксессорах, только о регистраторах. Добавление нового модуля
        // (experimental или core) — одна строка ниже, не правка инициализации
        // отдельных типов. См. ADR 0011 § EXP-1.
        let registry = AccessorRegistry()
        let registrars: [any AccessorRegistrar] = [
            LushaBridgeRegistrar(contextStore: contextStore),
            LushaExperimentalRegistrar(),
        ]
        for registrar in registrars {
            await registrar.register(into: registry)
        }

        installSignalHandlers(coordinator: coordinator, audioSupervisor: audioSupervisor)

        if config.freezingEnabled, let modelPath = config.modelPath {
            do {
                try await coordinator.loadModel(modelPath: modelPath)
                log.info("model loaded: \(modelPath, privacy: .public)")
            } catch {
                log.error("model load failed: \(error.localizedDescription, privacy: .public)")
            }
        } else if !config.freezingEnabled {
            // ADR 0017: при freezingEnabled=false автозагрузку модели на старте
            // тоже пропускаем — Off-state означает «daemon в idle ~50 MB».
            // User явно включит через MenuBar On + Load.
            log.notice("freezing disabled — model autoload skipped (idle mode)")
        } else {
            log.notice("no model path configured; daemon runs without LLM")
        }

        let handler = DaemonIPCHandler(
            coordinator: coordinator,
            vortex: vortex,
            vision: vision,
            contextStore: contextStore,
            registry: registry,
            augmenter: PromptAugmenter(maxContextChars: config.contextMaxChars),
            freezeStats: freezeStats,
            defaultContextChars: config.contextMaxChars,
            audioSupervisor: audioSupervisor,
            discordNotifyWebhookURL: config.discordNotifyWebhookURL
        )
        let ipc = IPCServer(socketPath: config.ipcSocketPath, handler: handler)
        do {
            try await ipc.start()
        } catch {
            log.error("IPC start failed: \(error.localizedDescription, privacy: .public)")
        }

        let captureTask = Task { await vision.startCapture() }

        // Screen sleep/wake gating для SCStream: пока экран спит, capture
        // тратит CPU на чёрные кадры. На screensDidSleep — vision.stopCapture()
        // (loop кооперативно завершится; ScreenStream остановится в defer'е),
        // на screensDidWake — перезапускаем capture loop.
        let screenGateStream = workspaceSource.events()
        let visionRef = vision
        let screenGateTask = Task {
            var captureLoop: Task<Void, Never>? = captureTask
            for await event in screenGateStream {
                switch event {
                case .screensDidSleep:
                    log.notice("screens did sleep — pausing capture")
                    await visionRef.stopCapture()
                    captureLoop?.cancel()
                    captureLoop = nil
                case .screensDidWake:
                    log.notice("screens did wake — resuming capture")
                    if captureLoop == nil {
                        captureLoop = Task { await visionRef.startCapture() }
                    }
                default:
                    break
                }
            }
        }
        log.info("🚀 systems online; ipc=\(config.ipcSocketPath, privacy: .public)")

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                break
            }
            let pressure = await vortex.getMemoryPressure()
            log.info("memory pressure=\(pressure)%")
        }

        captureTask.cancel()
        screenGateTask.cancel()
        await terminationWatcher.stop()
        await reactiveFinder.stop()
        await coordinator.emergencyThaw()
        await ipc.stop()
    }

    /// Перехватывает SIGINT/SIGTERM. Async-обработчик вызывает
    /// `coordinator.emergencyThaw`, но даже если процесс умрёт раньше — pids
    /// останутся в `frozen.pids` и будут разморожены на следующем старте
    /// через `FrozenPidsStore.recover()`.
    private static func installSignalHandlers(coordinator: VortexCoordinator, audioSupervisor: AudioSupervisor) {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                log.notice("signal \(sig) received — shutting down")
                Task {
                    // Сначала останавливаем audio worker — иначе остаётся orphan-процессом.
                    await audioSupervisor.shutdown()
                    // Bug-6: до exit'а **обязательно** kill'нуть MLX worker.
                    // Без этого worker остаётся orphan'ом (PPID=1, ~935 MB
                    // RAM висит до manual cleanup / reboot'а). MLXSupervisor
                    // владеет lifecycle'ом worker'а — `unloadModel` шлёт
                    // SIGTERM → SIGKILL fallback. Делается **до** thaw'а,
                    // чтобы worker не получил pressure-induced SIGSTOP в
                    // последний момент (race с unloadModel'ом).
                    await coordinator.unloadModel()
                    await coordinator.emergencyThaw()
                    exit(0)
                }
            }
            src.resume()
            SignalKeeper.shared.retain(src)
        }
    }
}

/// Хранит `DispatchSourceSignal`, чтобы они не сгорели по ARC.
private final class SignalKeeper: @unchecked Sendable {
    static let shared = SignalKeeper()
    private let lock = NSLock()
    private var sources: [any DispatchSourceSignal] = []

    func retain(_ source: any DispatchSourceSignal) {
        lock.lock(); defer { lock.unlock() }
        sources.append(source)
    }
}

// MARK: - IPC handler

/// Issue #57: глобальный once-flag для warning'а про IPC wire-version. Sendable
/// requires класс / actor; ставим class с lock. Простая видимость, не race-critical.
private final class IPCMismatchTracker: @unchecked Sendable {
    static let shared = IPCMismatchTracker()
    private let lock = NSLock()
    private var logged: Set<Int> = []
    func shouldLog(receivedVersion: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return logged.insert(receivedVersion).inserted
    }
}

struct DaemonIPCHandler: IPCRequestHandler, Sendable {
    let coordinator: VortexCoordinator
    let vortex: VortexActor
    let vision: VisionActor
    let contextStore: ContextStore
    let registry: AccessorRegistry
    let augmenter: PromptAugmenter
    let freezeStats: FreezeStatsStore?
    let defaultContextChars: Int
    let audioSupervisor: AudioSupervisor
    let discordNotifyWebhookURL: String?

    /// Fire-and-forget уведомление в Discord webhook. Не блокирует IPC.
    private func notifyDiscord(_ message: String) {
        guard let urlString = discordNotifyWebhookURL,
              let url = URL(string: urlString) else { return }
        Task {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["content": message])
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    /// Если useContext == true, оборачиваем prompt в шаблон с свежим контекстом.
    private func augmentedPrompt(_ prompt: String, useContext: Bool?) async -> String {
        guard useContext == true else { return prompt }
        let context = await contextStore.recentContext(maxChars: defaultContextChars)
        return augmenter.augment(prompt: prompt, context: context)
    }

    func handle(_ request: IPCRequest) async -> IPCResponse {
        // Issue #57: предупреждение об IPC wire-version mismatch. Не fatal —
        // request всё равно обработаем; пометим, что клиент возможно отстал.
        // Once-per-version (не per-request), иначе логи захлебнутся.
        if let v = request.apiVersion, v != IPCWireVersion.current,
           IPCMismatchTracker.shared.shouldLog(receivedVersion: v) {
            log.warning(
                "IPC wire version mismatch: client=\(v, privacy: .public) daemon=\(IPCWireVersion.current, privacy: .public) cmd=\(request.cmd, privacy: .public)"
            )
        }
        switch request.cmd {
        case "status":
            var r = IPCResponse()
            r.ok = true
            r.capturing = await vision.capturing()
            r.modelLoaded = await coordinator.mlx.isLoaded()
            r.modelPath = await coordinator.mlx.currentModelPath()
            r.memoryPressure = await vortex.getMemoryPressure()
            r.frozen = await vortex.suspendedCount()
            r.snapshots = await contextStore.count()
            r.lastCaptureError = await vision.lastCaptureError()
            r.kvCacheBits = await coordinator.mlx.currentKVCacheBits()
            r.listening = await audioSupervisor.isCapturing()
            r.audioOutputDevice = AudioSupervisor.currentOutputDeviceName()
            r.audioInputDevice = AudioSupervisor.currentInputDeviceName()
            r.freezingEnabled = await coordinator.isFreezingEnabled()
            r.coordinatorState = await coordinator.currentStateName()
            r.coordinatorStateReason = await coordinator.currentStateReason()
            r.final = true
            return r

        case "setFreezingEnabled":
            // ADR 0017. enabled=false — MenuBar Off: координатор перестаёт
            // морозить и сразу thaw-ит всё, что было заморожено. Persist в
            // config.json, чтобы переживать рестарт daemon-а.
            guard let enabled = request.enabled else {
                return .failure("missing 'enabled'")
            }
            await coordinator.setFreezingEnabled(enabled)
            do {
                var cfg = (try? FroggyConfig.load()) ?? FroggyConfig()
                cfg.freezingEnabled = enabled
                try cfg.save()
            } catch {
                log.warning("freezingEnabled persist failed: \(error.localizedDescription, privacy: .public)")
            }
            var r = IPCResponse()
            r.ok = true
            r.freezingEnabled = enabled
            r.final = true
            return r

        case "generate":
            // One-shot путь оставлен для совместимости. Streaming идёт
            // через handleStream и предпочтительнее для длинных ответов.
            guard let prompt = request.prompt else {
                return .failure("missing 'prompt'")
            }
            let finalPrompt = await augmentedPrompt(prompt, useContext: request.useContext)
            do {
                let text = try await coordinator.generate(
                    prompt: finalPrompt,
                    maxTokens: request.maxTokens ?? 200
                )
                var r = IPCResponse()
                r.ok = true
                r.text = text
                r.final = true
                return r
            } catch {
                return .failure(String(describing: error))
            }

        case "context":
            let maxChars = request.maxChars ?? defaultContextChars
            let text = await contextStore.recentContext(maxChars: maxChars)
            var r = IPCResponse()
            r.ok = true
            r.context = text
            r.snapshots = await contextStore.count()
            r.final = true
            return r

        case "loadModel":
            guard let path = request.path else {
                return .failure("missing 'path'")
            }
            if await audioSupervisor.isCapturing() {
                return .failure("cannot swap model during active listen session — call listen-stop first")
            }
            do {
                try await coordinator.loadModel(modelPath: path)
                var r = IPCResponse()
                r.ok = true
                r.modelPath = await coordinator.mlx.currentModelPath()
                r.final = true
                return r
            } catch {
                return .failure(String(describing: error))
            }

        case "unloadModel":
            await coordinator.unloadModel()
            return .success()

        case "accessors":
            // Фильтр по `experimental`: nil — вернуть все, true/false —
            // только опытные / только core. ADR 0011 § EXP-1.
            let descriptors = await registry.list(experimental: request.experimental)
            var r = IPCResponse()
            r.ok = true
            r.accessors = descriptors.map {
                IPCResponse.Accessor(id: $0.id, name: $0.name, experimental: $0.experimental)
            }
            r.final = true
            return r

        case "snapshot":
            guard let id = request.accessor else {
                return .failure("missing 'accessor'")
            }
            guard let lines = await registry.snapshot(id: id) else {
                return .failure("no accessor with id '\(id)'")
            }
            var r = IPCResponse()
            r.ok = true
            r.lines = lines
            r.final = true
            return r

        case "speak":
            guard let text = request.prompt, !text.isEmpty else {
                return .failure("missing text")
            }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            // request.path — опциональный голос, напр. "Milena" (ru) или "Samantha" (en)
            if let voice = request.path {
                proc.arguments = ["-v", voice, text]
            } else {
                proc.arguments = [text]
            }
            try? proc.run()
            await withCheckedContinuation { cont in
                proc.terminationHandler = { _ in cont.resume() }
            }
            return .success()

        case "freeze":
            let targetPid: Int32
            if let pid = request.pid {
                targetPid = pid
            } else if let bundleId = request.path {
                let pids = await NSWorkspaceProcessFinder().pids(forBundleIds: [bundleId])
                guard let found = pids.first else {
                    return .failure("app not running: \(bundleId)")
                }
                targetPid = found
            } else {
                return .failure("missing 'pid' or bundle_id (path)")
            }
            do {
                try await vortex.freezeProcess(pid: targetPid)
                return .success()
            } catch {
                return .failure(String(describing: error))
            }

        case "thawAll":
            await vortex.thawAll()
            return .success()

        case "listen":
            // Swap на маленькую модель если callModelPath задан
            let callPath = coordinator.callModelPath
            if let callPath, await coordinator.mlx.currentModelPath() != callPath {
                do {
                    try await coordinator.loadModel(modelPath: callPath)
                } catch {
                    return .failure("model swap to callModelPath failed: \(error)")
                }
            }
            do {
                try await audioSupervisor.startCapture(
                    discordPid: request.discordPid,
                    locale: coordinator.audioLocale,
                    onDeviceRecognition: coordinator.audioOnDeviceRecognition,
                    echoSuppression: coordinator.echoSuppressionEnabled,
                    echoSuppressionTailMs: coordinator.echoSuppressionTailMs,
                    vadEnabled: coordinator.vadEnabled,
                    vadRmsThreshold: coordinator.vadRmsThreshold
                )
                // Инжект произвольного контекста перед созвоном
                if let injectPath = request.path,
                   let text = try? String(contentsOfFile: injectPath, encoding: .utf8),
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await audioSupervisor.appendContext(text, title: "Pre-call Context")
                    log.notice("injected context from \(injectPath, privacy: .public)")
                }
                var r = IPCResponse()
                r.ok = true
                r.listening = true
                r.audioOutputDevice = AudioSupervisor.currentOutputDeviceName()
                r.audioInputDevice = AudioSupervisor.currentInputDeviceName()
                r.sessionURL = await audioSupervisor.sessionURL()?.path
                r.final = true
                notifyDiscord("🔴 Meeting recording started")
                return r
            } catch {
                return .failure("listen failed: \(error)")
            }

        case "injectContext":
            guard await audioSupervisor.isCapturing() else {
                return .failure("no active listen session — start with `froggy listen` first")
            }
            guard let text = request.prompt, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure("missing text — set prompt field")
            }
            let title = request.accessor ?? "Injected Context"
            await audioSupervisor.appendContext(text, title: title)
            return .success()

        case "listenStop":
            let sessionPath = await audioSupervisor.sessionURL()?.path
            await audioSupervisor.stopCapture()
            // Swap обратно на основную модель если callModelPath был другой
            let mainPath = coordinator.mainModelPath
            if let mainPath, await coordinator.mlx.currentModelPath() != mainPath {
                do {
                    try await coordinator.loadModel(modelPath: mainPath)
                } catch {
                    log.warning("model swap back failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            // Подсказка в лог — явный recap через отдельную команду
            if let p = sessionPath,
               let size = try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int,
               size > 500 {
                log.notice("session ready (\(size) bytes): run `froggy recap` to generate summary")
            }
            var r = IPCResponse()
            r.ok = true
            r.listening = false
            r.sessionURL = sessionPath
            r.final = true
            let stopMsg = sessionPath != nil ? "🟢 Meeting recording stopped — transcript saved" : "🟢 Meeting recording stopped"
            notifyDiscord(stopMsg)
            return r

        case "listenStatus":
            var r = IPCResponse()
            r.ok = true
            r.listening = await audioSupervisor.isCapturing()
            r.audioOutputDevice = AudioSupervisor.currentOutputDeviceName()
            r.audioInputDevice = AudioSupervisor.currentInputDeviceName()
            r.sessionURL = await audioSupervisor.sessionURL()?.path
            r.final = true
            return r

        case "pressure":
            let snap = await coordinator.pressureSnapshot()
            var r = IPCResponse()
            r.ok = true
            r.pressureLevel = snap.level.rawValue
            r.tier1Frozen = snap.tier1Frozen
            r.tier2Frozen = snap.tier2Frozen
            r.secondsInLevel = snap.secondsInLevel
            r.pageoutCounters = snap.pageoutCounters
            r.final = true
            return r

        case "freezeStats":
            guard let store = freezeStats else {
                return .failure("freeze ranking telemetry disabled (config.freezeRankingEnabled=false)")
            }
            do {
                let limit = request.maxTokens ?? 10 // переиспользуем поле как «top N»
                let stats = try await store.topByMedianFreed(limit: limit, daysBack: 7)
                var r = IPCResponse()
                r.ok = true
                r.freezeStats = stats
                r.final = true
                return r
            } catch {
                return .failure(String(describing: error))
            }

        default:
            return .failure("unknown cmd: \(request.cmd)")
        }
    }

    func handleStream(_ request: IPCRequest) -> AsyncThrowingStream<IPCResponse, any Error>? {
        switch request.cmd {
        case "generate":
            guard request.prompt != nil else { return nil }
            let userPrompt = request.prompt!
            let maxTokens = request.maxTokens ?? 200
            let coordinator = self.coordinator
            let useContext = request.useContext
            let handlerSelf = self
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let prompt = await handlerSelf.augmentedPrompt(userPrompt, useContext: useContext)
                        let mlxStream = await coordinator.mlx.generateStreamFull(
                            prompt: prompt, maxTokens: maxTokens
                        )
                        for try await fragment in mlxStream {
                            switch fragment {
                            case .text(let chunk):
                                var r = IPCResponse()
                                r.ok = true; r.text = chunk; r.final = false
                                continuation.yield(r)
                            case .done(let pTPS, let dTPS, let pTok, let gTok):
                                var done = IPCResponse()
                                done.ok = true; done.final = true
                                done.promptTPS = pTPS; done.decodeTPS = dTPS
                                done.promptTokens = pTok; done.generatedTokens = gTok
                                continuation.yield(done)
                            }
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }

        case "recap":
            let coordinator = self.coordinator
            let supervisor = self.audioSupervisor
            let reqPath = request.path
            return AsyncThrowingStream { continuation in
                let task = Task {
                    // Путь: явный аргумент или последняя сессия
                    let sessionPath: String
                    if let p = reqPath {
                        sessionPath = p
                    } else if let url = await supervisor.sessionURL() {
                        sessionPath = url.path
                    } else {
                        var r = IPCResponse()
                        r.ok = false; r.error = "no active session; use --path <file>"; r.final = true
                        continuation.yield(r); continuation.finish(); return
                    }
                    guard let transcript = try? String(contentsOfFile: sessionPath, encoding: .utf8),
                          transcript.count > 100 else {
                        var r = IPCResponse()
                        r.ok = false; r.error = "transcript too short or unreadable"; r.final = true
                        continuation.yield(r); continuation.finish(); return
                    }
                    guard await coordinator.mlx.isLoaded() else {
                        var r = IPCResponse()
                        r.ok = false; r.error = "model not loaded — run `froggy load <path>` first"; r.final = true
                        continuation.yield(r); continuation.finish(); return
                    }
                    let prompt = """
                    Ниже транскрипт встречи. Напиши краткое резюме на русском языке:
                    1. Что обсуждалось (3–5 пунктов).
                    2. Принятые решения.
                    3. Action items с владельцами (если упомянуты).
                    Пиши лаконично, без вводных фраз.

                    ---
                    \(transcript.prefix(12000))
                    """
                    let mlxStream = await coordinator.mlx.generateStreamFull(prompt: prompt, maxTokens: 600)
                    var fullSummary = ""
                    do {
                        for try await fragment in mlxStream {
                            switch fragment {
                            case .text(let chunk):
                                fullSummary += chunk
                                var r = IPCResponse()
                                r.ok = true; r.text = chunk; r.final = false
                                continuation.yield(r)
                            case .done(let pTPS, let dTPS, let pTok, let gTok):
                                // Записываем секцию в файл
                                if let fh = FileHandle(forUpdatingAtPath: sessionPath) {
                                    fh.seekToEndOfFile()
                                    fh.write(Data("\n## Summary\n\n\(fullSummary)\n".utf8))
                                    try? fh.close()
                                }
                                var done = IPCResponse()
                                done.ok = true; done.sessionURL = sessionPath; done.final = true
                                done.promptTPS = pTPS; done.decodeTPS = dTPS
                                done.promptTokens = pTok; done.generatedTokens = gTok
                                continuation.yield(done)
                            }
                        }
                    } catch {
                        continuation.finish(throwing: error); return
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }

        case "listenStream":
            let supervisor = self.audioSupervisor
            let store = self.contextStore
            return AsyncThrowingStream { continuation in
                let task = Task {
                    let (stream, subID) = await supervisor.subscribeToTranscripts()
                    continuation.onTermination = { @Sendable _ in
                        Task { await supervisor.unsubscribe(id: subID) }
                    }
                    for await event in stream {
                        // Финальные сегменты пушим в ContextStore — чтобы
                        // `froggy gen --context "подведи итог"` видел транскрипт.
                        if event.isFinal {
                            await store.push(lines: ["[\(event.speaker)] \(event.text)"])
                        }
                        var r = IPCResponse()
                        r.ok = true
                        r.text = event.text
                        r.speaker = event.speaker
                        r.final = event.isFinal
                        continuation.yield(r)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }

        default:
            return nil
        }
    }
}

// MARK: - CLI

struct CLIArgs: Sendable {
    var modelPath: String?
    var captureIntervalSeconds: Int?

    static let usage = """
    Usage: FroggyDaemon [--model-path <path>] [--capture-interval <seconds>]

    Configuration is loaded from ~/Library/Application Support/Froggy/config.json
    if present. CLI flags and env vars override fields in that file.

    Environment:
      FROGGY_MODEL_PATH        absolute path to local MLX model directory
      FROGGY_CAPTURE_INTERVAL  seconds between OCR cycles (default 2)
    """

    enum ParseError: Error, CustomStringConvertible {
        case missingValue(String)
        case unknownFlag(String)
        case invalidInt(String)

        var description: String {
            switch self {
            case let .missingValue(flag): return "Flag \(flag) requires a value"
            case let .unknownFlag(flag): return "Unknown flag: \(flag)"
            case let .invalidInt(value): return "Expected integer, got: \(value)"
            }
        }
    }

    static func parse(arguments: [String]) throws -> CLIArgs {
        var cli = CLIArgs()
        let env = ProcessInfo.processInfo.environment
        cli.modelPath = env["FROGGY_MODEL_PATH"]
        if let raw = env["FROGGY_CAPTURE_INTERVAL"], let v = Int(raw) {
            cli.captureIntervalSeconds = v
        }

        var i = 1
        while i < arguments.count {
            let arg = arguments[i]
            switch arg {
            case "--model-path":
                guard i + 1 < arguments.count else { throw ParseError.missingValue(arg) }
                cli.modelPath = arguments[i + 1]
                i += 2
            case "--capture-interval":
                guard i + 1 < arguments.count else { throw ParseError.missingValue(arg) }
                guard let v = Int(arguments[i + 1]) else {
                    throw ParseError.invalidInt(arguments[i + 1])
                }
                cli.captureIntervalSeconds = v
                i += 2
            case "--help", "-h":
                print(Self.usage)
                exit(0)
            default:
                throw ParseError.unknownFlag(arg)
            }
        }
        return cli
    }
}
