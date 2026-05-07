import Foundation
import os

/// Связывает `MLXSupervisor` и `VortexActor` через `MemoryPressureMonitor`.
/// Phase «Mem-1»: вместо однократного preflight-freeze перед `loadModel` —
/// постоянная подписка на стрим уровня unified memory. Tier-1 морозим
/// при `.warning`, Tier-2 — при `.critical`, оттепель — постепенно при
/// устойчивом `.normal`. `loadModel` теперь делает виртуальный nudge
/// в монитор: сам триггерит warning, реагируем общим путём.
public actor VortexCoordinator {
    private static let log = Logger(subsystem: "com.froggychips.froggy", category: "coordinator")
    private static let signposter = OSSignposter(subsystem: "com.froggychips.froggy", category: "coordinator")

    public let mlx: MLXSupervisor
    public let vortex: any VortexFreezing
    public let monitor: MemoryPressureMonitor

    private let finder: any ProcessFinder
    private let tier1BundleIds: [String]
    private let tier2BundleIds: [String]
    /// Через сколько секунд после оттепели tier-2 размораживать tier-1.
    private let gradualThawDelaySeconds: TimeInterval

    private var tier1Frozen: Set<Int32> = []
    private var tier2Frozen: Set<Int32> = []
    private var listenTask: Task<Void, Never>?
    private var thawTask: Task<Void, Never>?

    public init(
        mlx: MLXSupervisor,
        vortex: any VortexFreezing,
        monitor: MemoryPressureMonitor,
        tier1BundleIds: [String],
        tier2BundleIds: [String],
        finder: any ProcessFinder = NSWorkspaceProcessFinder(),
        gradualThawDelaySeconds: TimeInterval = 10
    ) {
        self.mlx = mlx
        self.vortex = vortex
        self.monitor = monitor
        self.tier1BundleIds = tier1BundleIds
        self.tier2BundleIds = tier2BundleIds
        self.finder = finder
        self.gradualThawDelaySeconds = gradualThawDelaySeconds
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
    }

    public func stopMonitoring() async {
        listenTask?.cancel()
        listenTask = nil
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

    // MARK: - Policy

    private func applyPolicy(_ level: MemoryPressureLevel) async {
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
