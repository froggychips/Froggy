import Foundation
import os

/// Реактивный монитор уровня unified memory. Ловит события из источника
/// (`DispatchMemoryPressureSource` в проде, `FakeMemoryPressureSource` в тестах),
/// применяет debounce при понижении уровня и публикует в `events`.
///
/// Семантика debounce: повышение давления (`normal → warning → critical`) идёт
/// мгновенно. Понижение требует стабильности `cooldownSeconds` секунд — если
/// за это время пришло обратное повышение, downgrade отменяется.
public actor MemoryPressureMonitor {
    private static let log = Logger(subsystem: "com.froggychips.froggy", category: "pressure-monitor")

    /// Стрим публикуемых уровней — `nonisolated`, потому что
    /// `AsyncStream` уже `Sendable` и неизменяем.
    public nonisolated let events: AsyncStream<MemoryPressureLevel>
    private nonisolated let continuation: AsyncStream<MemoryPressureLevel>.Continuation

    private let source: any MemoryPressureSource
    private let cooldownSeconds: TimeInterval

    /// Что говорит ядро прямо сейчас. На него навешивается nudge от `loadModel`.
    private var observed: MemoryPressureLevel = .normal
    /// Что мы в последний раз опубликовали слушателям.
    private var current: MemoryPressureLevel = .normal
    private var stableSince: Date = Date()

    private var nudgeLevel: MemoryPressureLevel?
    private var nudgeUntil: Date?

    private var listenTask: Task<Void, Never>?
    private var pendingDowngradeTask: Task<Void, Never>?

    public init(source: any MemoryPressureSource, cooldownSeconds: TimeInterval = 60) {
        self.source = source
        self.cooldownSeconds = cooldownSeconds
        var cont: AsyncStream<MemoryPressureLevel>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    /// Запускает прослушивание источника и публикует начальный `.normal`.
    /// Идемпотентно.
    public func start() {
        guard listenTask == nil else { return }
        publishIfChanged(.normal, force: true)
        let stream = source.events()
        listenTask = Task { [weak self] in
            for await raw in stream {
                await self?.handleRaw(raw)
            }
        }
    }

    public func stop() {
        listenTask?.cancel()
        listenTask = nil
        pendingDowngradeTask?.cancel()
        pendingDowngradeTask = nil
    }

    /// Возвращает уровень, видимый снаружи (с учётом nudge).
    public func currentLevel() -> MemoryPressureLevel { current }

    /// Сколько секунд мы уже находимся в `current`.
    public func secondsInLevel() -> Int {
        max(0, Int(Date().timeIntervalSince(stableSince)))
    }

    /// Виртуальное «давление» от calling-кода (например, `Coordinator.loadModel`):
    /// поднимает уровень не ниже `level` до `expiry`. Естественные события из
    /// источника, более высокие чем nudge, перекрывают nudge как обычно.
    public func nudge(_ level: MemoryPressureLevel, durationSeconds: TimeInterval) {
        nudgeLevel = level
        nudgeUntil = Date().addingTimeInterval(durationSeconds)
        recompute()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(durationSeconds))
            await self?.expireNudge()
        }
    }

    private func expireNudge() {
        guard let until = nudgeUntil, Date() >= until else { return }
        nudgeLevel = nil
        nudgeUntil = nil
        recompute()
    }

    /// Источник эмитит «сырой» уровень. Считаем effective и публикуем
    /// либо мгновенно (upgrade), либо через cooldown (downgrade).
    private func handleRaw(_ raw: MemoryPressureLevel) {
        observed = raw
        recompute()
    }

    /// Перепосчитать `effectiveLevel` и опубликовать с учётом debounce.
    private func recompute() {
        let target = effectiveLevel()
        if target > current {
            // Эскалация — мгновенно. Любая pending-разморозка отменяется.
            pendingDowngradeTask?.cancel()
            pendingDowngradeTask = nil
            publishIfChanged(target)
        } else if target < current {
            // Деэскалация — через cooldown, повторно если уже запущено.
            schedulePendingDowngrade()
        }
        // target == current → ничего не делаем.
    }

    private func schedulePendingDowngrade() {
        pendingDowngradeTask?.cancel()
        let delay = cooldownSeconds
        pendingDowngradeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.tryDowngrade()
        }
    }

    private func tryDowngrade() {
        guard !Task.isCancelled else { return }
        let target = effectiveLevel()
        if target < current {
            publishIfChanged(target)
        }
        pendingDowngradeTask = nil
    }

    /// Активный уровень = max(observed, nudge?).
    private func effectiveLevel() -> MemoryPressureLevel {
        if let n = nudgeLevel { return max(n, observed) }
        return observed
    }

    private func publishIfChanged(_ level: MemoryPressureLevel, force: Bool = false) {
        guard force || level != current else { return }
        current = level
        stableSince = Date()
        Self.log.notice("pressure → \(level.rawValue, privacy: .public)")
        continuation.yield(level)
    }
}
