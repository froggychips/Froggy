import Foundation
import XCTest
@testable import VortexCore

final class FrozenPidsStoreTests: XCTestCase {
    private func makeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("frozen-\(UUID()).pids")
    }

    /// pid и путь бинаря текущего тест-раннера — единственный процесс, которому
    /// в тестах можно безопасно послать SIGCONT (он и так не остановлен).
    private var selfPid: Int32 { ProcessInfo.processInfo.processIdentifier }
    private var selfPath: String {
        ProcessClassifier.executablePath(pid: selfPid) ?? "/unknown"
    }

    func testStartsEmpty() async {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FrozenPidsStore(fileURL: url)
        let entries = await store.entries()
        XCTAssertEqual(entries, [])
    }

    func testAddAndRemove() async {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FrozenPidsStore(fileURL: url)
        await store.add(.init(pid: 42, executablePath: "/Applications/Foo.app/Contents/MacOS/Foo"))
        await store.add(.init(pid: 43, executablePath: "/Applications/Bar.app/Contents/MacOS/Bar"))
        let after = await store.entries()
        XCTAssertEqual(after.map(\.pid).sorted(), [42, 43])

        await store.remove(pid: 42)
        let trimmed = await store.entries()
        XCTAssertEqual(trimmed.map(\.pid), [43])
    }

    func testAddReplacesDuplicate() async {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FrozenPidsStore(fileURL: url)
        await store.add(.init(pid: 42, executablePath: "/old/path"))
        await store.add(.init(pid: 42, executablePath: "/new/path"))
        let entries = await store.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.executablePath, "/new/path")
    }

    func testPersistAcrossInstances() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let s1 = FrozenPidsStore(fileURL: url)
        await s1.add(.init(pid: 7, executablePath: "/Applications/Seven.app/X"))

        let s2 = FrozenPidsStore(fileURL: url)
        let entries = await s2.entries()
        XCTAssertEqual(entries.map(\.pid), [7])

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attrs[.posixPermissions] as? NSNumber, 0o600)
    }

    /// Несуществующий pid: запись обрабатывается (счётчик = 1), но как
    /// пропущенная — сигнал никому не уходит; файл очищен.
    func testRecoverClearsFile() async {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FrozenPidsStore(fileURL: url)
        await store.add(.init(pid: 999_999, executablePath: "/Applications/Ghost.app"))
        let recovered = await store.recover()
        XCTAssertEqual(recovered, 1)
        let entries = await store.entries()
        XCTAssertEqual(entries, [])
    }

    func testRecoverDetailedSkipsDeadPid() async {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FrozenPidsStore(fileURL: url)
        await store.add(.init(pid: 999_999, executablePath: "/Applications/Ghost.app"))
        let report = await store.recoverDetailed()
        XCTAssertEqual(report, .init(thawed: 0, killed: 0, skipped: 1))
    }

    func testClear() async {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FrozenPidsStore(fileURL: url)
        await store.add(.init(pid: 100, executablePath: "/Applications/X.app"))
        await store.clear()
        let entries = await store.entries()
        XCTAssertEqual(entries, [])
    }

    /// `thawAll` чистит только записи приложений — запись воркера переживает.
    func testClearFrozenKeepsWorkerEntries() async {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FrozenPidsStore(fileURL: url)
        await store.add(.init(pid: 100, executablePath: "/Applications/X.app"))
        await store.add(.init(pid: 200, executablePath: "/usr/local/libexec/FroggyMLXWorker",
                              category: FrozenPidsStore.categoryWorker))
        await store.clearFrozen()
        let entries = await store.entries()
        XCTAssertEqual(entries.map(\.pid), [200])
        XCTAssertEqual(entries.first?.category, FrozenPidsStore.categoryWorker)
    }

    // MARK: - Идентичность процесса

    func testProcessStartTimeOfSelfIsKnown() {
        let t = FrozenPidsStore.processStartTime(pid: selfPid)
        XCTAssertNotNil(t)
        XCTAssertGreaterThan(t ?? 0, 0)
    }

    func testProcessStartTimeOfDeadPidIsNil() {
        XCTAssertNil(FrozenPidsStore.processStartTime(pid: 999_999))
    }

    /// Entry заполняет startTime автоматически.
    func testEntryCapturesStartTimeOfLivePid() {
        let entry = FrozenPidsStore.Entry(pid: selfPid, executablePath: selfPath)
        XCTAssertEqual(entry.startTime, FrozenPidsStore.processStartTime(pid: selfPid))
    }

    /// Файл старого формата (без `startTime`) читается; поле = nil.
    func testEntryDecodesLegacyJSONWithoutStartTime() throws {
        let json = """
        [{"pid":4242,"executablePath":"/Applications/Legacy.app/Contents/MacOS/Legacy",
          "frozenAt":"2026-05-10T12:00:00Z","category":null}]
        """
        let entries = try JSONDecoder.iso.decode([FrozenPidsStore.Entry].self, from: Data(json.utf8))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.pid, 4242)
        XCTAssertNil(entries.first?.startTime)
    }

    /// Живой pid, но записанное время старта чужое → это переиспользованный
    /// pid, сигнал не посылаем.
    func testRecoverSkipsEntryWithForeignStartTime() async {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FrozenPidsStore(fileURL: url)
        await store.add(.init(pid: selfPid, executablePath: selfPath, startTime: 1))
        let report = await store.recoverDetailed()
        XCTAssertEqual(report, .init(thawed: 0, killed: 0, skipped: 1))
        let entries = await store.entries()
        XCTAssertEqual(entries, [])
    }

    /// Живой pid и верное время, но путь бинаря другой → пропуск.
    func testRecoverSkipsEntryWithForeignPath() async {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FrozenPidsStore(fileURL: url)
        await store.add(.init(
            pid: selfPid,
            executablePath: "/Applications/NotTheTestRunner.app/Contents/MacOS/NotMe",
            startTime: FrozenPidsStore.processStartTime(pid: selfPid)
        ))
        let report = await store.recoverDetailed()
        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(report.thawed, 0)
    }

    /// Полное совпадение (pid + время старта + путь) → SIGCONT уходит.
    /// SIGCONT самому себе безвреден: процесс не остановлен.
    func testRecoverSignalsMatchingProcess() async {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FrozenPidsStore(fileURL: url)
        await store.add(.init(pid: selfPid, executablePath: selfPath))
        let report = await store.recoverDetailed()
        XCTAssertEqual(report, .init(thawed: 1, killed: 0, skipped: 0))
    }

    /// Запись старого формата (без startTime) с верным путём — recovery
    /// по-прежнему работает, идентичность подтверждается путём.
    func testRecoverAcceptsLegacyEntryByPath() async {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FrozenPidsStore(fileURL: url)
        let legacy = """
        [{"pid":\(selfPid),"executablePath":"\(selfPath)","frozenAt":"2026-05-10T12:00:00Z","category":null}]
        """
        try? Data(legacy.utf8).write(to: url)
        let report = await store.recoverDetailed()
        XCTAssertEqual(report, .init(thawed: 1, killed: 0, skipped: 0))
    }
}
