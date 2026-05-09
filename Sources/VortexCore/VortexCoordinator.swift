import Foundation
import os

/// Связывает `MLXSupervisor` и `VortexActor` через `MemoryPressureMonitor`.
/// Phase «Mem-1»: вместо однократного preflight-freeze перед `loadModel` —
/// постоянная подписка на стрим уровня unified memory. Tier-1 морозим
/// при `.warning`, Tier-2 — при `.critical`, оттепель — постепенно при
/// устойчивом `.normal`. `loadModel` теперь делает виртуальный nudge
/// в монитор: сам триггерит warning, реагируем общим путём.
///
/// Workspace-events: опционально подписывается на `WorkspaceEventSource`,
/// чтобы (а) gating'ить freeze-loop вокруг sleep/wake (см. `applyPolicy`),
/// (б) обрабатывать `appTerminated` через `WorkspaceTerminationWatcher.Sink`
/// — убирать pid из in-memory tier-set'ов когда процесс убили извне.
public actor VortexCoordinator: WorkspaceTerminationWatcher.Sink {
    private static let log = Logger(subsystem: "com.froggychips.froggy", category: "coordinator")
    private static let signposter = OSSignposter(subsystem: "com.froggychips.froggy", category: "coordinator")
    /// POI-канал — Instruments автоматически рендерит это в track
    /// «Points of Interest». Используется для freeze-cycle overlay'я.
    private static let poi = OSSignposter(subsystem: "com.froggychips.froggy", category: "PointsOfInterest")

    public let mlx: MLXSupervisor
    public let vortex: any VortexFreezing
    public let monitor: MemoryPressureMonitor

    /// Маленькая модель для режима созвона (callModelPath из конфига).
    /// nonisolated — доступ без await из IPC-хэндлеров.
    public nonisolated let callModelPath: String?
    /// Основная модель (config.modelPath) — для swap-back после listenStop.
    public nonisolated let mainModelPath: String?
    /// BCP-47 locale для SFSpeechRecognizer.
    public nonisolated let audioLocale: String
    /// Только on-device SR (не отправлять аудио в Apple cloud).
    public nonisolated let audioOnDeviceRecognition: Bool

    private let finder: any ProcessFinder
    private let workspaceSource: (any WorkspaceEventSource)?
    private let tier1BundleIds: [String]
    private let tier2BundleIds: [String]
    /// Через сколько секунд после оттепели tier-2 размораживать tier-1.
    private let gradualThawDelaySeconds: TimeInterval

    private var tier1Frozen: Set<Int32> = []
    private var tier2Frozen: Set<Int32> = []
    private var listenTask: Task<Void, Never>?
    private var workspaceTask: Task<Void, Never>?
    private var thawTask: Task<Void, Never>?

    /// Sleep-gate: пока true, `applyPolicy` не делает новых freeze'ов.
    /// На `willSleep` мы ещё успеваем выполнить emergencyThaw — на wake
    /// MemoryPressureMonitor сам пере-эмитит свой текущий уровень при
    /// первом изменении, поэтому ничего форсировать не нужно.
    private var sleeping: Bool = false

    /// Pid frontmost-app — закешированный через `WorkspaceEvent.frontmostChanged`.
    /// **Никогда не морозим** этот pid, даже если его bundleId в tier-1/tier-2
    /// allowlist. Закрывает failure mode «freeze посередине набора текста»
    /// — пользователь активно работает с этой app, замораживать её = баг
    /// для пользователя. См. ADR 0015.
    /// `nil` означает «frontmost не определён» (login window, lock screen);
    /// в этом состоянии veto не применяется (и так морозим что хотим).
    private var frontmostPid: Int32?

    public init(
        mlx: MLXSupervisor,
        vortex: any VortexFreezing,
        monitor: MemoryPressureMonitor,
        tier1BundleIds: [String],
        tier2BundleIds: [String],
        finder: any ProcessFinder = NSWorkspaceProcessFinder(),
        workspaceSource: (any WorkspaceEventSource)? = nil,
        gradualThawDelaySeconds: TimeInterval = 10,
        callModelPath: String? = nil,
        mainModelPath: String? = nil,
        audioLocale: String = "ru-RU",
        audioOnDeviceRecognition: Bool = true
    ) {
        self.mlx = mlx
        self.vortex = vortex
        self.monitor = monitor
        self.tier1BundleIds = tier1BundleIds
        self.tier2BundleIds = tier2BundleIds
        self.finder = finder
        self.workspaceSource = workspaceSource
        self.gradualThawDelaySeconds = gradualThawDelaySeconds
        self.callModelPath = callModelPath
        self.mainModelPath = mainModelPath
        self.audioLocale = audioLocale
        self.audioOnDeviceRecognition = audioOnDeviceRecognition
    }

    // MARK: - Lifecycle

    public func startMonitoring() async {
        guard listenTask == nil else { return }
        await monitor.start()
        let stream = monitor.events // nonisolated, доступ без await
        listenTask = Task { [weak self] in
            for await level in stream {
                await self?.applyPolicy(level)
            }
        }
        // Sleep/wake gating + frontmost-veto — отдельный task, чтобы не
        // путать с pressure-loop'ом.
        if let workspaceSource {
            // Seed frontmost ДО подписки на стрим: иначе первое окно
            // между `startMonitoring` и первым `.frontmostChanged` event'ом
            // мы морозили бы frontmost-app по bundleId-allowlist'у.
            let initial = await workspaceSource.initialFrontmostPid()
            self.frontmostPid = initial
            if let initial {
                Self.log.info("frontmost seed: pid=\(initial, privacy: .public)")
            }

            let wsStream = workspaceSource.events()
            workspaceTask = Task { [weak self] in
                for await event in wsStream {
                    await self?.applyWorkspaceEvent(event)
                }
            }
        }
    }

    public func stopMonitoring() async {
        listenTask?.cancel()
        listenTask = nil
        workspaceTask?.cancel()
        workspaceTask = nil
        thawTask?.cancel()
        thawTask = nil
        await monitor.stop()
    }

    // MARK: - Public API

    /// Загружает модель, предварительно подняв виртуальное давление
    /// на `nudgeDurationSeconds` (по умолчанию 60 c) — так монитор сам
    /// дёрнет нашу политику и заморозит tier-1.
    public func loadModel(modelPath: String, nudgeDurationSeconds: TimeInterval = 60) async throws {
        let interval = Self.signposter.beginInterval("coordinator.loadModel")
        defer { Self.signposter.endInterval("coordinator.loadModel", interval) }

        await monitor.nudge(.warning, durationSeconds: nudgeDurationSeconds)
        // Дать монитору цикл, чтобы политика прокатилась до возврата.
        await Task.yield()

        do {
            try await mlx.loadModel(modelPath: modelPath)
        } catch {
            await emergencyThaw()
            throw error
        }
    }

    public func unloadModel() async {
        await mlx.unloadModel()
        // Оттепель сделает монитор, когда увидит, что давления больше нет.
    }

    /// Жёсткая моментальная оттепель — для SIGINT/SIGTERM-обработчика.
    public func emergencyThaw() async {
        thawTask?.cancel()
        thawTask = nil
        await thawTier(.tier2)
        await thawTier(.tier1)
        await vortex.thawAll()
    }

    public func generate(prompt: String, maxTokens: Int = 200) async throws -> String {
        try await mlx.generate(prompt: prompt, maxTokens: maxTokens)
    }

    /// Снимок для IPC `pressure` команды.
    public func pressureSnapshot() async -> PressureSnapshot {
        let level = await monitor.currentLevel()
        let secs = await monitor.secondsInLevel()
        let counters = await vortex.pageoutCounters()
        return PressureSnapshot(
            level: level,
            tier1Frozen: Array(tier1Frozen).sorted(),
            tier2Frozen: Array(tier2Frozen).sorted(),
            secondsInLevel: secs,
            pageoutCounters: counters
        )
    }

    public struct PressureSnapshot: Sendable, Equatable {
        public let level: MemoryPressureLevel
        public let tier1Frozen: [Int32]
        public let tier2Frozen: [Int32]
        public let secondsInLevel: Int
        public let pageoutCounters: PageoutCounters?
    }

    // MARK: - WorkspaceTerminationWatcher.Sink

    /// Pid убили извне (Activity Monitor, OOM-kill, ручной `kill -9`,
    /// jetsam). Watcher уже почистил `FrozenPidsStore`; нам остаётся
    /// убрать pid из in-memory tier-set'ов, чтобы snapshot не показывал
    /// zombie-pid'ы и `thawTier` не звала `kill(SIGCONT)` мёртвому pid'у
    /// (это ESRCH — безвредно, но шумит в логах).
    public func handleExternalTermination(pid: Int32) async {
        let inT1 = tier1Frozen.remove(pid) != nil
        let inT2 = tier2Frozen.remove(pid) != nil
        if inT1 || inT2 {
            Self.log.notice("frozen pid=\(pid, privacy: .public) terminated externally — removed from tier-set")
        }
    }

    // MARK: - Policy

    private func applyWorkspaceEvent(_ event: WorkspaceEvent) async {
        switch event {
        case .willSleep:
            // Перед sleep'ом — мгновенно отпустить всё. После wake watchdog'и
            // не любят полу-мёртвых SIGSTOP-нутых процессов: они могут
            // получить SIGKILL от ApplePersistence и прочих, что превратит
            // нашу backstop-cleanup'у в гонку.
            Self.log.notice("system will sleep — emergency thaw")
            sleeping = true
            await emergencyThaw()
        case .didWake:
            // На wake пресс-monitor сам пере-эмитит уровень при следующем
            // изменении ядра. Просто снимаем gate.
            Self.log.notice("system did wake — freeze loop ungated")
            sleeping = false
        case let .frontmostChanged(pid, _):
            // Кешируем pid frontmost-app для frontmost-veto в `freezeTier`.
            // Если в момент смены фокуса этот pid уже заморожен в одном
            // из tier'ов (race: пользователь активировал app, которая
            // только что попала под freeze), — сразу его отпустить, чтобы
            // не оставлять frontmost в SIGSTOP. Это редкий corner-case,
            // но он закрывает race-window между applyPolicy и
            // frontmostChanged.
            frontmostPid = pid
            if let pid {
                let inT1 = tier1Frozen.contains(pid)
                let inT2 = tier2Frozen.contains(pid)
                if inT1 || inT2 {
                    Self.log.notice("frontmost activated mid-freeze: thawing pid=\(pid, privacy: .public)")
                    await vortex.thawProcess(pid: pid)
                    tier1Frozen.remove(pid)
                    tier2Frozen.remove(pid)
                }
            }
        case let .appActivated(_, bundleId):
            // Re-evaluate freeze под sustained pressure'ом, когда
            // tier-1/tier-2 app запускается ИЛИ активируется. `applyPolicy`
            // event-driven на pressure level changes — без этого pathа,
            // когда давление держится на `.warning`/`.critical` и
            // пользователь открывает новый tier-1 app (Telegram под
            // Discord-frontmost'ом, например), он бы никогда не попал
            // под freeze. `freezeTier` идемпотентен (skip already-frozen
            // + frontmost-veto), безопасно вызывать повторно.
            guard !sleeping, let bundleId else { break }
            let level = await monitor.currentLevel()
            if tier1BundleIds.contains(bundleId), level >= .warning {
                await freezeTier(.tier1)
            } else if tier2BundleIds.contains(bundleId), level >= .critical {
                await freezeTier(.tier2)
            }
        default:
            // Deactivate/terminate/screen-events — не наша забота
            // на этом слое (terminate ловит WorkspaceTerminationWatcher,
            // screen-события — VisionActor).
            break
        }
    }

    private func applyPolicy(_ level: MemoryPressureLevel) async {
        // Sleep-gate: во время sleep'а ничего не морозим. Pressure-эвенты
        // в это время не должны прилетать (CPU всё равно спит), но на
        // всякий случай явно дропаем — в момент willSleep мы уже сделали
        // emergencyThaw, восстанавливать состояние сейчас бессмысленно.
        if sleeping {
            Self.log.info("policy event ignored: system is sleeping (level=\(level.rawValue, privacy: .public))")
            return
        }
        // POI: один interval на весь freeze-cycle от pressure-event'а до
        // окончания SIGSTOP+pageout chain. В Instruments видно длительность
        // реакции на каждый level-change. На `.normal` interval короткий —
        // только cancel'ит thawTask и возвращается, основная работа в детач'е.
        let poiId = Self.poi.makeSignpostID()
        let poiState = Self.poi.beginInterval(
            "freeze_cycle", id: poiId, "pressure_level=\(level.rawValue)"
        )
        defer {
            Self.poi.endInterval(
                "freeze_cycle",
                poiState,
                "pressure_level=\(level.rawValue) tier1=\(self.tier1Frozen.count) tier2=\(self.tier2Frozen.count)"
            )
        }
        switch level {
        case .warning:
            thawTask?.cancel(); thawTask = nil
            await freezeTier(.tier1)
        case .critical:
            thawTask?.cancel(); thawTask = nil
            await freezeTier(.tier1)
            await freezeTier(.tier2)
        case .normal:
            // Tier-2 отпускаем сразу, tier-1 — через задержку, чтобы дать
            // системе ещё чуть-чуть «выдохнуть» перед возвращением фоновых
            // процессов к жизни. Если до конца задержки прилетит warning —
            // pendingThaw отменится и оттепели tier-1 не будет.
            thawTask?.cancel()
            let delay = gradualThawDelaySeconds
            thawTask = Task { [weak self] in
                await self?.thawTier(.tier2)
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await self?.thawTier(.tier1)
            }
        }
    }

    private enum Tier {
        case tier1
        case tier2
    }

    private func freezeTier(_ tier: Tier) async {
        let bundleIds = tier == .tier1 ? tier1BundleIds : tier2BundleIds
        let pids = await finder.pids(forBundleIds: bundleIds)
        for pid in pids {
            // Skip уже-замороженные в любом из tier'ов.
            if tier1Frozen.contains(pid) || tier2Frozen.contains(pid) { continue }
            // Frontmost-veto (ADR 0015): pid frontmost-app никогда не морозим,
            // даже если его bundleId в allowlist'е. Закрывает «freeze
            // посередине набора текста». NSWorkspace-only уровень — typing
            // через Accessibility API явно вне scope'а.
            if let frontmostPid, pid == frontmostPid {
                Self.log.info("freeze pid=\(pid, privacy: .public) tier=\(String(describing: tier), privacy: .public) vetoed: frontmost")
                continue
            }
            do {
                try await vortex.freezeProcess(pid: pid)
                switch tier {
                case .tier1: tier1Frozen.insert(pid)
                case .tier2: tier2Frozen.insert(pid)
                }
            } catch {
                Self.log.warning("freeze pid=\(pid) tier=\(String(describing: tier), privacy: .public) skipped: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func thawTier(_ tier: Tier) async {
        let pids = tier == .tier1 ? tier1Frozen : tier2Frozen
        for pid in pids {
            await vortex.thawProcess(pid: pid)
        }
        switch tier {
        case .tier1: tier1Frozen.removeAll()
        case .tier2: tier2Frozen.removeAll()
        }
    }
}
