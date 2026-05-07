import Foundation
import XCTest
@testable import VortexCore

/// Sink-стаб: запоминает, кого ему сообщили о terminate.
private actor StubSink: WorkspaceTerminationWatcher.Sink {
    private(set) var seen: [Int32] = []
    func handleExternalTermination(pid: Int32) async {
        seen.append(pid)
    }
}

final class WorkspaceTerminationWatcherTests: XCTestCase {
    private func makeStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("frozen-watcher-\(UUID()).pids")
    }

    /// Главный сценарий: frozen pid убили извне → watcher должен убрать
    /// запись из `FrozenPidsStore`. Иначе boot-recovery будет слать SIGCONT
    /// мёртвому pid'у на каждом перезапуске, и накопится мусор.
    func testTerminationRemovesPidFromStore() async throws {
        let url = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FrozenPidsStore(fileURL: url)
        await store.add(.init(pid: 777, executablePath: "/Applications/Foo.app"))

        let source = FakeWorkspaceEventSource()
        let sink = StubSink()
        let watcher = WorkspaceTerminationWatcher(
            source: source, pidStore: store, sink: sink
        )
        await watcher.start()

        source.emit(.appTerminated(pid: 777, bundleId: "com.foo"))
        try await Task.sleep(for: .milliseconds(100))

        let entries = await store.entries()
        XCTAssertEqual(entries, [], "frozen pid не удалён из store после terminate'a")
        let seen = await sink.seen
        XCTAssertEqual(seen, [777], "sink не получил уведомление")

        await watcher.stop()
    }

    /// Не-frozen pid тоже приходит через тот же стрим (мы подписаны на ВСЕ
    /// terminate'ы). Watcher не должен трогать store, но обязан вызвать sink
    /// — координатор сам решает, что делать.
    func testTerminationOfUnrelatedPidIsNoOpForStore() async throws {
        let url = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FrozenPidsStore(fileURL: url)
        await store.add(.init(pid: 100, executablePath: "/Applications/Frozen.app"))

        let source = FakeWorkspaceEventSource()
        let sink = StubSink()
        let watcher = WorkspaceTerminationWatcher(
            source: source, pidStore: store, sink: sink
        )
        await watcher.start()

        source.emit(.appTerminated(pid: 200, bundleId: "com.other"))
        try await Task.sleep(for: .milliseconds(100))

        let entries = await store.entries()
        XCTAssertEqual(entries.map(\.pid), [100],
                       "запись unrelated pid'а не должна была удалиться")
        let seen = await sink.seen
        XCTAssertEqual(seen, [200])

        await watcher.stop()
    }

    /// Без store вотчер всё равно зовёт sink — координатор хочет знать.
    func testWorksWithoutPidStore() async throws {
        let source = FakeWorkspaceEventSource()
        let sink = StubSink()
        let watcher = WorkspaceTerminationWatcher(
            source: source, pidStore: nil, sink: sink
        )
        await watcher.start()

        source.emit(.appTerminated(pid: 5, bundleId: nil))
        try await Task.sleep(for: .milliseconds(100))

        let seen = await sink.seen
        XCTAssertEqual(seen, [5])

        await watcher.stop()
    }

    /// Activate / deactivate / sleep / wake watcher игнорирует.
    func testIgnoresUnrelatedEvents() async throws {
        let url = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FrozenPidsStore(fileURL: url)
        await store.add(.init(pid: 1, executablePath: "/x"))

        let source = FakeWorkspaceEventSource()
        let sink = StubSink()
        let watcher = WorkspaceTerminationWatcher(
            source: source, pidStore: store, sink: sink
        )
        await watcher.start()

        source.emit(.appActivated(pid: 1, bundleId: "com.x"))
        source.emit(.appDeactivated(pid: 1, bundleId: "com.x"))
        source.emit(.willSleep)
        source.emit(.didWake)
        source.emit(.screensDidSleep)
        source.emit(.screensDidWake)
        try await Task.sleep(for: .milliseconds(100))

        let entries = await store.entries()
        XCTAssertEqual(entries.map(\.pid), [1])
        let seen = await sink.seen
        XCTAssertEqual(seen, [])

        await watcher.stop()
    }
}
