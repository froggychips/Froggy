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
    /// Echo suppression: гейтим mic пока Discord-тап активен.
    public nonisolated let echoSuppressionEnabled: Bool
    /// Хвост mic-gate после последнего Discord-аудио (мс).
    public nonisolated let echoSuppressionTailMs: Int
    /// VAD: пропускать mic-буферы тише vadRmsThreshold.
    public nonisolated let vadEnabled: Bool
    public nonisolated let vadRmsThreshold: Double

    private let finder: any ProcessFinder
    private let workspaceSource: (any WorkspaceEventSource)?
    private let tier1BundleIds: [String]
    private let tier2BundleIds: [String]
    /// Через сколько секунд после оттепели tier-2 размораживать tier-1.
    private let gradualThawDelaySeconds: TimeInterval
    /// Issue #63: optional audit-trail для freeze/thaw операций.
    /// nil — записи не пишутся (используется в юнит-тестах).
    private let auditLog: AuditLog?

    /// Issue #59: adaptive frame pacer hook. Coordinator при каждом
    /// pressure level change'е дёргает `adjustPacerForPressure`,
    /// растягивая OCR-interval на .warning/.critical и сжимая обратно
    /// на .normal. Optional — для тестов / headless-режима без vision.
    /// Тип `(any Sendable)?` чтобы не таскать `VisionActor` import в
    /// VortexCore (LushaBridge зависит от VortexCore, не наоборот) —
    /// coordinator зовёт через closure.
    private let pacerAdjuster: (@Sendable (String) async -> Void)?

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

    /// Master switch (ADR 0017). false → `applyPolicy` и `applyWorkspaceEvent`
    /// игнорят pressure-сигналы и app-activations. Daemon продолжает крутиться
    /// (ContextStore, vision, IPC), но не SIGSTOP-ит ничего самостоятельно.
    /// Меняется только через `setFreezingEnabled`. MenuBar Off → false + unload
    /// + thawAll, чтобы daemon уехал в idle ~50 MB без замороженных pid'ов.
    private var freezingEnabled: Bool

    /// Issue #64: lifecycle-состояние. См. `CoordinatorState`.
    private var state: CoordinatorState = .idle

    /// Поколение политики. Инкрементируется на каждое событие, которое
    /// делает уже начатый обход `freezeTier` неактуальным: `thawAll`
    /// (в т.ч. emergencyThaw на Off/ADR 0017 и на willSleep) и
    /// `stopMonitoring`. `freezeTier` фиксирует значение на входе и
    /// перепроверяет после каждого `await`: между `finder.pids` и
    /// `freezeProcess` проходят actor-hop'ы, за которые пользователь мог
    /// выключить freeze, а система — уйти в sleep. Без этого обход,
    /// начатый до Off, доморозит остаток tier'а уже после emergencyThaw.
    private var policyGeneration: UInt64 = 0

    /// Pid'ы, для которых `freezeProcess` сейчас висит на await. Пока pid
    /// здесь, новый обход его не трогает (он ещё не в tier-set'е, поэтому
    /// «skip already-frozen» его не поймал бы), а откат старого обхода не
    /// разморозит то, что успел заморозить новый.
    private var inFlightFreezes: Set<Int32> = []

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
        audioOnDeviceRecognition: Bool = true,
        echoSuppressionEnabled: Bool = true,
        echoSuppressionTailMs: Int = 400,
        vadEnabled: Bool = true,
        vadRmsThreshold: Double = 0.008,
        freezingEnabled: Bool = true,
        auditLog: AuditLog? = nil,
        pacerAdjuster: (@Sendable (String) async -> Void)? = nil
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
        self.echoSuppressionEnabled = echoSuppressionEnabled
        self.echoSuppressionTailMs = echoSuppressionTailMs
        self.vadEnabled = vadEnabled
        self.vadRmsThreshold = vadRmsThreshold
        self.freezingEnabled = freezingEnabled
        self.auditLog = auditLog
        self.pacerAdjuster = pacerAdjuster
    }

    // MARK: - Lifecycle

    public func startMonitoring() async {
        guard listenTask == nil else { return }
        transition(to: .starting)
        // Issue #64: crash observer на MLX. Worker умирает неожиданно
        // (внешний kill, OOM, jetsam) → coordinator уходит в degraded.
        // Возврат в ready — только через успешный loadModel (вручную).
        await mlx.addCrashObserver { [weak self] pid, status in
            Task { await self?.handleMLXCrash(pid: pid, status: status) }
        }
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
        transition(to: .ready)
    }

    public func stopMonitoring() async {
        transition(to: .stopping)
        policyGeneration &+= 1
        listenTask?.cancel()
        listenTask = nil
        workspaceTask?.cancel()
        workspaceTask = nil
        thawTask?.cancel()
        thawTask = nil
        await monitor.stop()
        transition(to: .idle)
    }

    // MARK: - Public API

    /// Загружает модель, предварительно подняв виртуальное давление
    /// на `nudgeDurationSeconds` (по умолчанию 60 c) — так монитор сам
    /// дёрнет нашу политику и заморозит tier-1.
    public func loadModel(modelPath: String, nudgeDurationSeconds: TimeInterval = 60) async throws {
        let interval = Self.signposter.beginInterval("coordinator.loadModel")
        defer { Self.signposter.endInterval("coordinator.loadModel", interval) }

        // Issue #64: если были в degraded — это попытка recovery.
        // Промежуточный recovering, конечный — ready при успехе или
        // обратно degraded при неудаче (stuck recovery).
        let recoveringFromDegraded: Bool
        if case .degraded = state {
            recoveringFromDegraded = true
            transition(to: .recovering)
        } else {
            recoveringFromDegraded = false
        }

        await monitor.nudge(.warning, durationSeconds: nudgeDurationSeconds)
        // Дать монитору цикл, чтобы политика прокатилась до возврата.
        await Task.yield()

        do {
            try await mlx.loadModel(modelPath: modelPath)
        } catch {
            await emergencyThaw()
            if recoveringFromDegraded {
                transition(to: .degraded(reason: "load_failed: \(String(describing: error))"))
            }
            throw error
        }
        if recoveringFromDegraded {
            transition(to: .ready)
        }
    }

    public func unloadModel() async {
        await mlx.unloadModel()
        // Оттепель сделает монитор, когда увидит, что давления больше нет.
    }

    /// Текущее состояние master switch — для IPC `status`.
    public func isFreezingEnabled() -> Bool { freezingEnabled }

    /// Issue #64: текущее состояние lifecycle. Для IPC `status` и тестов.
    public func currentState() -> CoordinatorState { state }
    public func currentStateName() -> String { state.name }
    public func currentStateReason() -> String? { state.reason }

    /// Issue #64 test-hook: установить degraded извне без реального MLX crash'а.
    /// Используется юнит-тестами state machine, чтобы не таскать настоящий
    /// MLXSupervisor с fake worker'ом. Не для прод-использования —
    /// production-path идёт через crashObserver.
    internal func _testSetDegraded(reason: String) {
        transition(to: .degraded(reason: reason))
    }

    /// Test-hook: текущий закешированный frontmost pid. Нужен тестам, которые
    /// меняют frontmost ВО ВРЕМЯ `await freezeProcess` и должны дождаться
    /// обработки события, не полагаясь на sleep.
    internal func _testFrontmostPid() -> Int32? { frontmostPid }

    /// Переключатель master switch (ADR 0017).
    /// false → cancel pending thawTask, emergencyThaw всех замороженных,
    /// дальнейшие pressure-эвенты игнорятся в `applyPolicy`.
    /// true → ничего не делаем сразу; политика оживёт на следующем
    /// `.warning`/`.critical`-эвенте от монитора.
    public func setFreezingEnabled(_ enabled: Bool) async {
        guard freezingEnabled != enabled else { return }
        freezingEnabled = enabled
        Self.log.notice("freezingEnabled → \(enabled, privacy: .public)")
        if !enabled {
            await emergencyThaw()
        }
    }

    /// Жёсткая моментальная оттепель — для SIGINT/SIGTERM-обработчика.
    public func emergencyThaw() async {
        await thawAll(reason: "emergency")
    }

    /// Полная оттепель через coordinator, чтобы in-memory tier-set'ы,
    /// VortexActor и audit trail оставались синхронными.
    public func thawAll(reason: String = "manual") async {
        // Любой обход freezeTier, который сейчас висит на await, после
        // возврата увидит смену поколения и не доморозит остаток tier'а.
        policyGeneration &+= 1
        thawTask?.cancel()
        thawTask = nil
        await thawTier(.tier2, reason: reason)
        await thawTier(.tier1, reason: reason)
        await vortex.thawAll()
        await auditLog?.record(op: "thawAll", reason: reason)
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

    // MARK: - MLX crash handling (issue #64)

    private func handleMLXCrash(pid: Int32, status: Int32) {
        Self.log.warning("mlx worker crash detected pid=\(pid, privacy: .public) status=\(status, privacy: .public) — coordinator → degraded")
        transition(to: .degraded(reason: "mlx_crash_pid=\(pid)_status=\(status)"))
    }

    // MARK: - State transitions (issue #64)

    private func transition(to new: CoordinatorState) {
        let old = state
        guard old != new else { return }
        state = new
        Self.log.info(
            "coordinator state: \(old.name, privacy: .public) → \(new.name, privacy: .public)\(new.reason.map { " reason=\($0)" } ?? "")"
        )
        // Дискретный event в POI track — Instruments видит каждый transition
        // как точечный маркер на coordinator timeline.
        Self.poi.emitEvent(
            "coordinator_state_change",
            "from=\(old.name) to=\(new.name)"
        )
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
            guard !sleeping, freezingEnabled, let bundleId else { break }
            // Поколение фиксируем ДО await — см. `policyGeneration`.
            let generation = policyGeneration
            let level = await monitor.currentLevel()
            if tier1BundleIds.contains(bundleId), level >= .warning {
                await freezeTier(.tier1, generation: generation)
            } else if tier2BundleIds.contains(bundleId), level >= .critical {
                await freezeTier(.tier2, generation: generation)
            }
        default:
            // Deactivate/terminate/screen-events — не наша забота
            // на этом слое (terminate ловит WorkspaceTerminationWatcher,
            // screen-события — VisionActor).
            break
        }
    }

    private func applyPolicy(_ level: MemoryPressureLevel) async {
        // Master switch (ADR 0017): когда user явно выключил freeze через
        // MenuBar Off, daemon продолжает крутить ContextStore/vision/IPC,
        // но не SIGSTOP-ит ничего. emergencyThaw уже был вызван в момент
        // переключения; здесь просто дропаем pressure-event.
        if !freezingEnabled {
            Self.log.info("policy event ignored: freezing disabled (level=\(level.rawValue, privacy: .public))")
            return
        }
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
        // Одно поколение на весь обработчик, снятое ДО первого await:
        // thawAll во время обхода tier-1 должен прервать и tier-2, а не
        // только текущий tier (иначе tier-2 взял бы уже новое поколение и
        // доморозил после Off/willSleep). `pacerAdjuster` ниже — тоже await:
        // пока он висит, thawAll()/stopMonitoring() успевают инкрементить
        // поколение, и обработчик, читающий его после, сравнивал бы новое
        // значение с самим собой — все stale-проверки проходили бы, а обход
        // морозил процессы уже после Off/sleep. Отмена задачи async-обработчик
        // сама по себе не останавливает, поэтому защита — именно поколение.
        let generation = policyGeneration
        // Issue #59: vision pacer узнаёт о новом уровне до freeze-логики.
        // На .warning/.critical OCR растягивается ДО того как мы начнём
        // SIGSTOP'ить процессы — даёт системе шанс «выдохнуть» раньше.
        if let pacerAdjuster {
            await pacerAdjuster(level.rawValue)
        }

        let pressureReason = "pressure_\(level.rawValue)"
        switch level {
        case .warning:
            thawTask?.cancel(); thawTask = nil
            await freezeTier(.tier1, generation: generation, reason: pressureReason)
        case .critical:
            thawTask?.cancel(); thawTask = nil
            await freezeTier(.tier1, generation: generation, reason: pressureReason)
            await freezeTier(.tier2, generation: generation, reason: pressureReason)
        case .normal:
            // Tier-2 отпускаем сразу, tier-1 — через задержку, чтобы дать
            // системе ещё чуть-чуть «выдохнуть» перед возвращением фоновых
            // процессов к жизни. Если до конца задержки прилетит warning —
            // pendingThaw отменится и оттепели tier-1 не будет.
            thawTask?.cancel()
            let delay = gradualThawDelaySeconds
            thawTask = Task { [weak self] in
                await self?.thawTier(.tier2, reason: pressureReason)
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await self?.thawTier(.tier1, reason: pressureReason)
            }
        }
    }

    private enum Tier {
        case tier1
        case tier2
    }

    /// `generation` — поколение политики, зафиксированное вызывающим ДО его
    /// первого await (см. `policyGeneration`); один обработчик передаёт одно
    /// и то же значение во все свои обходы.
    private func freezeTier(_ tier: Tier, generation: UInt64, reason: String = "manual") async {
        let bundleIds = tier == .tier1 ? tier1BundleIds : tier2BundleIds
        // Issue #63: ходим per-bundleId чтобы знать соответствие pid→bundleId
        // для audit-записи. ProcessFinder.pids(forBundleIds:) уплощает массив
        // и теряет это соответствие. Стоимость 2-3 NSWorkspace-вызова на tier —
        // дешёво по сравнению с самим SIGSTOP.
        let tierName = tier == .tier1 ? "1" : "2"
        // Signpost-interval на весь обход tier'а: в Instruments видно, сколько
        // заняло решение и сколько pid'ов из кандидатов реально замёрзло
        // (остальные — veto, уже замороженные, откаты).
        let signpostId = Self.signposter.makeSignpostID()
        let signpostState = Self.signposter.beginInterval(
            "freeze-tier", id: signpostId,
            "tier=\(tierName, privacy: .public) reason=\(reason, privacy: .public)"
        )
        var candidateCount = 0
        var frozenCount = 0
        defer {
            Self.signposter.endInterval(
                "freeze-tier", signpostState,
                "candidates=\(candidateCount, privacy: .public) frozen=\(frozenCount, privacy: .public)"
            )
        }
        // Обход, который уже неактуален (Off/sleep за время предыдущего
        // tier'а или pacerAdjuster), не начинаем вовсе.
        if let stale = policyStaleReason(generation: generation) {
            Self.log.info("freeze tier=\(tierName, privacy: .public) not started: \(stale, privacy: .public)")
            return
        }
        for bundleId in bundleIds {
            let pids = await finder.pids(forBundleIds: [bundleId])
            candidateCount += pids.count
            for pid in pids {
                // За `await finder.pids` или за предыдущий freezeProcess
                // условия могли измениться — перепроверяем перед КАЖДЫМ SIGSTOP.
                if let stale = policyStaleReason(generation: generation) {
                    Self.log.info("freeze tier=\(tierName, privacy: .public) traversal aborted: \(stale, privacy: .public)")
                    return
                }
                // Skip уже-замороженные в любом из tier'ов и те, чей freeze
                // прямо сейчас выполняет другой обход.
                if tier1Frozen.contains(pid) || tier2Frozen.contains(pid) { continue }
                if inFlightFreezes.contains(pid) { continue }
                // Frontmost-veto (ADR 0015): pid frontmost-app никогда не морозим.
                if let frontmostPid, pid == frontmostPid {
                    Self.log.info("freeze pid=\(pid, privacy: .public) tier=\(tierName, privacy: .public) vetoed: frontmost")
                    await auditLog?.record(
                        op: "freeze", pid: pid, bundleId: bundleId,
                        tier: tierName, reason: reason, outcome: "skipped:frontmost"
                    )
                    continue
                }
                inFlightFreezes.insert(pid)
                do {
                    try await vortex.freezeProcess(pid: pid)
                } catch {
                    inFlightFreezes.remove(pid)
                    Self.log.warning("freeze pid=\(pid) tier=\(tierName, privacy: .public) skipped: \(error.localizedDescription, privacy: .public)")
                    await auditLog?.record(
                        op: "freeze", pid: pid, bundleId: bundleId,
                        tier: tierName, reason: reason,
                        outcome: "failed:\(error.localizedDescription)"
                    )
                    continue
                }
                // За время `await freezeProcess` (SIGSTOP + journal + pageout)
                // пользователь мог активировать это приложение, выключить
                // freeze, а система — уйти в sleep. Обработчик `frontmostChanged`
                // этот pid ещё не видит (он не в tier-set'е), поэтому откат
                // делаем здесь: SIGCONT сразу, в tier-set не вставляем.
                if let revert = revertReason(pid: pid, generation: generation) {
                    // pid остаётся in-flight до конца SIGCONT: новый обход не
                    // должен успеть заморозить его между решением и откатом.
                    await vortex.thawProcess(pid: pid)
                    inFlightFreezes.remove(pid)
                    Self.log.notice("freeze pid=\(pid, privacy: .public) tier=\(tierName, privacy: .public) reverted: \(revert, privacy: .public)")
                    await auditLog?.record(
                        op: "freeze", pid: pid, bundleId: bundleId,
                        tier: tierName, reason: reason, outcome: "reverted:\(revert)"
                    )
                    // Frontmost-откат локален для одного pid; остальное —
                    // признак того, что весь обход больше не нужен.
                    if revert == "frontmost" { continue }
                    return
                }
                inFlightFreezes.remove(pid)
                switch tier {
                case .tier1: tier1Frozen.insert(pid)
                case .tier2: tier2Frozen.insert(pid)
                }
                frozenCount += 1
                await auditLog?.record(
                    op: "freeze", pid: pid, bundleId: bundleId,
                    tier: tierName, reason: reason, outcome: "ok"
                )
            }
        }
    }

    /// nil — обход `freezeTier` ещё актуален; иначе причина прервать его.
    private func policyStaleReason(generation: UInt64) -> String? {
        if generation != policyGeneration { return "generation_changed" }
        if !freezingEnabled { return "freezing_disabled" }
        if sleeping { return "sleeping" }
        return nil
    }

    /// Причина откатить только что выполненный freeze: обход устарел
    /// (см. `policyStaleReason`) или pid за время await стал frontmost.
    private func revertReason(pid: Int32, generation: UInt64) -> String? {
        if let stale = policyStaleReason(generation: generation) { return stale }
        if let frontmostPid, pid == frontmostPid { return "frontmost" }
        return nil
    }

    private func thawTier(_ tier: Tier, reason: String = "manual") async {
        let pids = tier == .tier1 ? tier1Frozen : tier2Frozen
        let tierName = tier == .tier1 ? "1" : "2"
        for pid in pids {
            await vortex.thawProcess(pid: pid)
            await auditLog?.record(
                op: "thaw", pid: pid, tier: tierName, reason: reason, outcome: "ok"
            )
        }
        switch tier {
        case .tier1: tier1Frozen.removeAll()
        case .tier2: tier2Frozen.removeAll()
        }
    }
}
