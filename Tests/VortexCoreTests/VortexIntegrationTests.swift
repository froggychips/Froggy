import Foundation
import XCTest
@testable import VortexCore

/// Round-trip headline-фичи: spawn child, freeze, проверить через `ps` что
/// он реально SIGSTOP-нут, thaw, проверить что снова бежит. По пути
/// проверяем, что pid попадает в FrozenPidsStore и удаляется оттуда.
///
/// Default-deny классификатор не пускает `/bin/sleep`, поэтому подсовываем
/// расширенный allowlist именно для теста.
final class VortexIntegrationTests: XCTestCase {
    private var child: Process!
    private var classifier: ProcessClassifier!
    private var storeURL: URL!
    private var store: FrozenPidsStore!
    private var vortex: VortexActor!

    override func setUp() async throws {
        try await super.setUp()
        classifier = ProcessClassifier(extraAllowedPrefixes: ["/bin/", "/usr/bin/"])
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vortex-int-\(UUID()).pids")
        store = FrozenPidsStore(fileURL: storeURL)
        vortex = VortexActor(classifier: classifier, pidStore: store)

        child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        // Подождать, пока ядро запишет процесс в таблицу.
        try await Task.sleep(for: .milliseconds(150))
    }

    override func tearDown() async throws {
        if child.isRunning { child.terminate() }
        try? FileManager.default.removeItem(at: storeURL)
        try await super.tearDown()
    }

    func testFreezeStopsProcessAndPersistsThawResumesAndClears() async throws {
        let pid = child.processIdentifier
        XCTAssertTrue(pid > 100, "child pid suspiciously low: \(pid)")

        // Initially process is running (S = sleeping, R = runnable, оба — "running" в ps-смысле).
        let initialStat = try Self.psStat(pid: pid)
        XCTAssertNotEqual(initialStat.first, "T", "process started already stopped: \(initialStat)")

        // Freeze.
        _ = try await vortex.freezeProcess(pid: pid)

        // ps -o stat должен показать 'T' (stopped). Даём ядру 50ms на отметку.
        try await Task.sleep(for: .milliseconds(100))
        let frozenStat = try Self.psStat(pid: pid)
        XCTAssertEqual(frozenStat.first, "T",
                       "expected SIGSTOP-ed pid \(pid) to have stat starting with T, got '\(frozenStat)'")

        // Persistent store должен видеть запись.
        let entriesAfterFreeze = await store.entries()
        XCTAssertEqual(entriesAfterFreeze.count, 1)
        XCTAssertEqual(entriesAfterFreeze.first?.pid, pid)
        XCTAssertEqual(entriesAfterFreeze.first?.executablePath, "/bin/sleep")

        // Thaw.
        await vortex.thawProcess(pid: pid)
        try await Task.sleep(for: .milliseconds(100))
        let thawedStat = try Self.psStat(pid: pid)
        XCTAssertNotEqual(thawedStat.first, "T",
                          "expected SIGCONT-ed pid \(pid) to no longer be stopped, got '\(thawedStat)'")

        // Persistent store должен очиститься.
        let entriesAfterThaw = await store.entries()
        XCTAssertEqual(entriesAfterThaw, [])
    }

    func testThawAllRestoresAllAndEmptiesStore() async throws {
        let pid = child.processIdentifier
        _ = try await vortex.freezeProcess(pid: pid)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try Self.psStat(pid: pid).first, "T")

        await vortex.thawAll()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotEqual(try Self.psStat(pid: pid).first, "T")
        let entries = await store.entries()
        XCTAssertEqual(entries, [])
        let count = await vortex.suspendedCount()
        XCTAssertEqual(count, 0)
    }

    func testRecoverThawsLeftoverPidsAtStartup() async throws {
        let pid = child.processIdentifier
        // Имитируем «демон умер с замороженным процессом»: пишем в store
        // запись и шлём SIGSTOP вручную (минуя VortexActor — чтобы
        // suspendedPids у actor оставался пустым).
        await store.add(.init(pid: pid, executablePath: "/bin/sleep"))
        XCTAssertEqual(kill(pid, SIGSTOP), 0)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try Self.psStat(pid: pid).first, "T")

        // recover() должен SIGCONT и очистить файл.
        let recovered = await store.recover()
        XCTAssertEqual(recovered, 1)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotEqual(try Self.psStat(pid: pid).first, "T")
        let entries = await store.entries()
        XCTAssertEqual(entries, [])
    }

    // MARK: - Helpers

    /// Возвращает значение колонки `stat` для pid через `/bin/ps`. Бросает,
    /// если процесс не найден.
    private static func psStat(pid: Int32) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-o", "stat=", "-p", String(pid)]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: data, encoding: .utf8) ?? ""
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw NSError(domain: "ps", code: 0, userInfo: [NSLocalizedDescriptionKey: "no row for pid \(pid)"])
        }
        return trimmed
    }
}
