import AppKit
import Foundation
import os

/// Абстракция «получить pids приложений с такими bundle-id». Нужна, чтобы
/// Coordinator-а можно было тестировать без живого NSWorkspace.
public protocol ProcessFinder: Sendable {
    func pids(forBundleIds bundleIds: [String]) async -> [Int32]
}

/// Реальный finder поверх `NSWorkspace.runningApplications`. Polling-вариант:
/// каждый вызов `pids(...)` → новый прыжок на MainActor + сканирование всего
/// списка приложений. Сохранён для совместимости / fallback'а; в проде
/// рекомендуется `ReactiveProcessFinder` поверх `WorkspaceEventSource`.
public struct NSWorkspaceProcessFinder: ProcessFinder {
    public init() {}

    public func pids(forBundleIds bundleIds: [String]) async -> [Int32] {
        guard !bundleIds.isEmpty else { return [] }
        let set = Set(bundleIds)
        return await MainActor.run {
            NSWorkspace.shared.runningApplications
                .filter { app in
                    guard let bid = app.bundleIdentifier else { return false }
                    return set.contains(bid)
                }
                .map(\.processIdentifier)
        }
    }
}

/// Reactive-finder: держит in-memory-карту bundleId → Set<pid>, обновляемую
/// событиями `WorkspaceEventSource`. Cначала `start()` сидит карту через
/// `runningApplications()` (один раз), дальше карта живёт по событиям —
/// `appActivated` добавляет, `appTerminated` удаляет.
///
/// Зачем: polling `NSWorkspace.shared.runningApplications` на каждый
/// `applyPolicy` стоит несколько мс и хопает на main; reactive map'a отвечает
/// за O(1). Дополнительно — `appTerminated` событие можно использовать для
/// cleanup'а `FrozenPidsStore` (см. `WorkspaceTerminationWatcher`).
public actor ReactiveProcessFinder: ProcessFinder {
    private static let log = Logger(subsystem: "com.froggychips.froggy", category: "process-finder")

    private let source: any WorkspaceEventSource
    /// Прямая мапа `bundleId → pids` для O(1) lookup'a.
    private var byBundleId: [String: Set<Int32>] = [:]
    /// Обратная мапа `pid → bundleId`, чтобы при terminate-событии знать,
    /// из какого bucket'a удалять (NSRunningApplication по факту тогда уже
    /// невалиден, но pid и bundleId в notification.userInfo сохраняются).
    private var pidToBundleId: [Int32: String] = [:]
    private var listenTask: Task<Void, Never>?
    private var seeded = false

    public init(source: any WorkspaceEventSource) {
        self.source = source
    }

    /// Идемпотентный старт. Сидит карту, подписывается на события.
    public func start() async {
        guard listenTask == nil else { return }
        await seed()
        let stream = source.events()
        listenTask = Task { [weak self] in
            for await event in stream {
                await self?.apply(event)
            }
        }
    }

    public func stop() {
        listenTask?.cancel()
        listenTask = nil
    }

    public func pids(forBundleIds bundleIds: [String]) async -> [Int32] {
        // Если start() не дёрнули — деградируемся до one-shot seed'а, чтобы
        // вызывающий код не получил фантомный пустой список. start() — best
        // practice, но не обязателен (тесты часто работают без него).
        if !seeded { await seed() }
        var out: [Int32] = []
        for bid in bundleIds {
            if let set = byBundleId[bid] { out.append(contentsOf: set) }
        }
        return out
    }

    // MARK: - Internal

    private func seed() async {
        let apps = await source.runningApplications()
        byBundleId.removeAll(keepingCapacity: true)
        pidToBundleId.removeAll(keepingCapacity: true)
        for (pid, bid) in apps {
            guard let bid else { continue }
            byBundleId[bid, default: []].insert(pid)
            pidToBundleId[pid] = bid
        }
        seeded = true
        Self.log.info("reactive finder seeded: apps=\(apps.count) bundleIds=\(self.byBundleId.count)")
    }

    private func apply(_ event: WorkspaceEvent) async {
        switch event {
        case let .appActivated(pid, bundleId):
            guard let bid = bundleId else { return }
            byBundleId[bid, default: []].insert(pid)
            pidToBundleId[pid] = bid
        case .appDeactivated:
            // pid всё ещё бежит, просто потерял focus — карту не трогаем.
            break
        case let .appTerminated(pid, bundleId):
            // Bundle-id берём из события если есть, иначе из обратной мапы.
            let bid = bundleId ?? pidToBundleId[pid]
            if let bid {
                byBundleId[bid]?.remove(pid)
                if byBundleId[bid]?.isEmpty == true { byBundleId.removeValue(forKey: bid) }
            }
            pidToBundleId.removeValue(forKey: pid)
        case .frontmostChanged:
            // Frontmost-смена — не меняет «кто бежит», только кто в фокусе.
            // Это забота VortexCoordinator (frontmost-veto, ADR 0015).
            break
        case .willSleep, .didWake, .screensDidSleep, .screensDidWake:
            // Не наша забота — на другом слое gating'и.
            break
        }
    }
}
