import Darwin
import Foundation
import os
import XCTest
@testable import VortexCore

/// Issue #58: unit-тесты для `WorkerProcessHost`. Не используем
/// `FroggyMLXWorkerFake` чтобы не зависеть от его сборки — берём
/// /bin/cat, /usr/bin/yes, /usr/bin/true в качестве «worker'а».
final class WorkerProcessHostTests: XCTestCase {

    private let log = Logger(subsystem: "com.froggychips.froggy.test", category: "host-test")

    /// `/usr/bin/true` exit'ится мгновенно с status=0. waitForExit должен
    /// вернуть true в пределах short timeout'а.
    func testWaitForExitOnAlreadyExitedProcess() async throws {
        let exitReceived = expectation(description: "onExit fired")
        let host = WorkerProcessHost(
            workerURL: URL(fileURLWithPath: "/usr/bin/true"),
            args: [],
            log: log,
            onLine: { _ in },
            onExit: { _, status in
                XCTAssertEqual(status, 0)
                exitReceived.fulfill()
            }
        )
        try host.ensureSpawned()
        // Pid должен быть валидным сразу после spawn.
        XCTAssertNotNil(host.currentPid())
        let exited = await host.waitForExit(timeout: .seconds(2))
        XCTAssertTrue(exited, "/usr/bin/true должен exit'нуться сразу")
        await fulfillment(of: [exitReceived], timeout: 2)
        host.cleanup()
        XCTAssertNil(host.currentPid())
    }

    /// `/bin/cat` без stdin-input'а живёт. sigkill+cleanup → host в чистом
    /// состоянии (currentPid==nil, isRunning==false). Foundation `Process`
    /// может с задержкой обновить `isRunning` после kernel reap'а, поэтому
    /// окончательный assert идёт после явного cleanup'а.
    func testSigkillTerminatesRunningProcess() async throws {
        let host = WorkerProcessHost(
            workerURL: URL(fileURLWithPath: "/bin/cat"),
            args: [],
            log: log,
            onLine: { _ in },
            onExit: { _, _ in }
        )
        try host.ensureSpawned()
        XCTAssertTrue(host.isRunning())
        await host.sigkill()
        host.cleanup()
        XCTAssertNil(host.currentPid())
        XCTAssertFalse(host.isRunning())
    }

    /// `ensureSpawned` идемпотентен: повторный вызов на живом процессе — no-op.
    func testEnsureSpawnedIsIdempotent() async throws {
        let host = WorkerProcessHost(
            workerURL: URL(fileURLWithPath: "/bin/cat"),
            args: [],
            log: log,
            onLine: { _ in },
            onExit: { _, _ in }
        )
        try host.ensureSpawned()
        let firstPid = host.currentPid()
        try host.ensureSpawned()
        let secondPid = host.currentPid()
        XCTAssertEqual(firstPid, secondPid, "повторный spawn на живом процессе должен сохранить тот же pid")
        await host.sigkill()
        host.cleanup()
    }

    /// Не-существующий путь → workerNotFound error.
    func testEnsureSpawnedThrowsOnMissingExecutable() throws {
        let host = WorkerProcessHost(
            workerURL: URL(fileURLWithPath: "/nonexistent/path/froggy-worker-fake"),
            args: [],
            log: log,
            onLine: { _ in },
            onExit: { _, _ in }
        )
        XCTAssertThrowsError(try host.ensureSpawned()) { error in
            guard case WorkerProcessHost.WorkerProcessError.workerNotFound = error else {
                XCTFail("ожидали workerNotFound, получили \(error)")
                return
            }
        }
    }

    /// `cat` эхо'ит stdin в stdout. Проверяем line-splitter:
    /// * полная строка с `\n` → один line
    /// * строка без `\n` — host сам дописывает (удобный API), тоже один line
    /// * чанк, который сам по себе разрезается на несколько `\n` границ
    func testStdoutLineSplitterDeliversLines() async throws {
        let received = LineCollector()
        let host = WorkerProcessHost(
            workerURL: URL(fileURLWithPath: "/bin/cat"),
            args: [],
            log: log,
            onLine: { data in
                received.append(data)
            },
            onExit: { _, _ in }
        )
        try host.ensureSpawned()
        try host.write(Data("hello\n".utf8))
        try host.write(Data("world\n".utf8))
        // Без `\n` — host.write сам дописывает (см. WorkerProcessHost.write).
        try host.write(Data("partial".utf8))
        // Дать pipe'у время прокачать.
        try await Task.sleep(for: .milliseconds(200))
        let lines = received.snapshot()
        XCTAssertEqual(lines.count, 3, "host.write авто-добавляет \\n → все 3 пишутся как полные строки")
        XCTAssertEqual(lines[safe: 0], Data("hello".utf8))
        XCTAssertEqual(lines[safe: 1], Data("world".utf8))
        XCTAssertEqual(lines[safe: 2], Data("partial".utf8))
        await host.sigkill()
        host.cleanup()
    }
}

/// Thread-safe collector для onLine callback'ов.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [Data] = []
    func append(_ d: Data) {
        lock.lock(); lines.append(d); lock.unlock()
    }
    func snapshot() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { i < count ? self[i] : nil }
}
