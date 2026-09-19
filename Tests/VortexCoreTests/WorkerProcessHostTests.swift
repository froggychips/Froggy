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

    override func setUp() {
        super.setUp()
        // Демон делает то же самое в main.swift: запись в pipe мёртвого
        // worker'а должна давать EPIPE → Swift-ошибку, а не убивать процесс.
        signal(SIGPIPE, SIG_IGN)
    }

    /// `/usr/bin/true` exit'ится мгновенно с status=0. waitForExit должен
    /// вернуть true в пределах short timeout'а.
    func testWaitForExitOnAlreadyExitedProcess() async throws {
        let exitReceived = expectation(description: "onExit fired")
        let host = WorkerProcessHost(
            workerURL: URL(fileURLWithPath: "/usr/bin/true"),
            args: [],
            log: log,
            onLine: { _, _ in },
            onExit: { _, status, _ in
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
            onLine: { _, _ in },
            onExit: { _, _, _ in }
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
            onLine: { _, _ in },
            onExit: { _, _, _ in }
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
            onLine: { _, _ in },
            onExit: { _, _, _ in }
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
            onLine: { data, _ in
                received.append(data)
            },
            onExit: { _, _, _ in }
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

    /// EOF без завершающего `\n`: остаток буфера должен прийти как последняя
    /// строка. Раньше EOF игнорировался — хвост терялся, а readabilityHandler
    /// крутился с пустыми данными до cleanup'а.
    func testStdoutTailWithoutNewlineDeliveredOnEOF() async throws {
        let received = LineCollector()
        // Handshake: `onExit` host эмитит только после EOF на stdout, а
        // хвост доставляется до отметки EOF — к моменту onExit все строки
        // уже в коллекторе. Никаких sleep'ов.
        let exitReceived = expectation(description: "onExit after EOF")
        let host = WorkerProcessHost(
            workerURL: URL(fileURLWithPath: "/bin/sh"),
            args: ["-c", "printf 'first\\nsecond'"],
            log: log,
            onLine: { data, _ in received.append(data) },
            onExit: { _, _, _ in exitReceived.fulfill() }
        )
        try host.ensureSpawned()
        await fulfillment(of: [exitReceived], timeout: 3)
        let lines = received.snapshot()
        XCTAssertEqual(lines.count, 2, "хвост без \\n должен быть доставлен как строка")
        XCTAssertEqual(lines[safe: 0], Data("first".utf8))
        XCTAssertEqual(lines[safe: 1], Data("second".utf8))
        host.cleanup()
    }

    /// Порядок строк на выходе host'а совпадает с порядком в pipe'е —
    /// на этом стоит последовательный pump в supervisor'ах.
    func testStdoutLinesPreserveOrder() async throws {
        let received = LineCollector()
        let exitReceived = expectation(description: "onExit after EOF")
        let host = WorkerProcessHost(
            workerURL: URL(fileURLWithPath: "/bin/sh"),
            args: ["-c", "i=1; while [ $i -le 200 ]; do echo $i; i=$((i+1)); done"],
            log: log,
            onLine: { data, _ in received.append(data) },
            onExit: { _, _, _ in exitReceived.fulfill() }
        )
        try host.ensureSpawned()
        await fulfillment(of: [exitReceived], timeout: 5)
        let lines = received.snapshot().map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(lines, (1...200).map(String.init))
        host.cleanup()
    }

    /// Запись в stdin exit'нувшегося worker'а — ошибка, а не падение процесса.
    /// Legacy `FileHandle.write(_:)` здесь поднимал ObjC-exception.
    func testWriteToExitedWorkerThrows() async throws {
        let host = WorkerProcessHost(
            workerURL: URL(fileURLWithPath: "/usr/bin/true"),
            args: [],
            log: log,
            onLine: { _, _ in },
            onExit: { _, _, _ in }
        )
        try host.ensureSpawned()
        let exited = await host.waitForExit(timeout: .seconds(2))
        XCTAssertTrue(exited)
        // Первая запись может успеть в буфер pipe'а до того, как ядро заметит
        // отсутствие читателя; вторая — точно EPIPE. Проверяем, что ни одна
        // не убивает процесс, и хотя бы одна из них бросает.
        var threw = false
        for _ in 0..<2 {
            do {
                try host.write(Data("{\"cmd\":\"ping\"}".utf8))
            } catch {
                threw = true
            }
        }
        XCTAssertTrue(threw, "запись в pipe без читателя должна бросать writeFailed/notRunning")
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
