import Foundation
import os

/// Подписан на `WorkspaceEvent.appTerminated`. На каждый terminate шлёт
/// `coordinator.handleTermination(pid:)` (если он есть) и чистит запись
/// в `FrozenPidsStore`.
///
/// **Зачем cleanup `FrozenPidsStore`**: store — это persisted-fallback на
/// случай краха демона (boot-recovery шлёт SIGCONT накопленным pid'ам).
/// Если frozen pid убили извне (Activity Monitor, OOM-kill, jetsam), и мы
/// не удалили его из store, то на следующем запуске `recover()` будет
/// слать SIGCONT мёртвому pid'у — это ESRCH, безвредно, но мусор копится
/// и при долгой uptime превращается в десятки записей.
///
/// Также вызывается hook на координаторе — он может убрать pid из своих
/// in-memory tier-set'ов (`tier1Frozen`/`tier2Frozen`) чтобы snapshot не
/// показывал zombie-pid'ы.
public actor WorkspaceTerminationWatcher {
    private static let log = Logger(subsystem: "com.froggychips.froggy", category: "termination-watcher")

    /// Узкий callback-интерфейс: координатор подписывает себя и убирает pid
    /// из своих in-memory tier-set'ов. Опционально, чтобы watcher мог жить
    /// и без координатора (например, в integration-тестах).
    public protocol Sink: Sendable {
        func handleExternalTermination(pid: Int32) async
    }

    private let source: any WorkspaceEventSource
    private let pidStore: FrozenPidsStore?
    private let sink: (any Sink)?
    private var listenTask: Task<Void, Never>?

    public init(
        source: any WorkspaceEventSource,
        pidStore: FrozenPidsStore?,
        sink: (any Sink)? = nil
    ) {
        self.source = source
        self.pidStore = pidStore
        self.sink = sink
    }

    public func start() {
        guard listenTask == nil else { return }
        let stream = source.events()
        listenTask = Task { [weak self] in
            for await event in stream {
                guard case let .appTerminated(pid, _) = event else { continue }
                await self?.handleTerminate(pid: pid)
            }
        }
    }

    public func stop() {
        listenTask?.cancel()
        listenTask = nil
    }

    private func handleTerminate(pid: Int32) async {
        // 1) убираем из persisted store — главное.
        if let pidStore {
            let entries = await pidStore.entries()
            if entries.contains(where: { $0.pid == pid }) {
                Self.log.notice("frozen pid=\(pid, privacy: .public) terminated externally — cleaning persisted store")
                await pidStore.remove(pid: pid)
            }
        }
        // 2) hook координатора, если подписан.
        await sink?.handleExternalTermination(pid: pid)
    }
}
