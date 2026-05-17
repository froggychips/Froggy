import Foundation
import XCTest
@testable import VortexCore

/// Issue #63: тесты для `AuditLog`. Все используют tmp-директорию,
/// никаких побочных эффектов в реальном `~/Library/Application Support`.
final class AuditLogTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("froggy-audit-test-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        try await super.tearDown()
    }

    /// Write 3 записей → tail отдаёт их же. ts-поле сохраняется,
    /// outcome/tier/bundleId optional.
    func testWriteThenTailRoundtrip() async throws {
        let log = AuditLog(directory: tmpDir)
        await log.setUp()

        await log.record(op: "freeze", pid: 100, bundleId: "com.spotify.client",
                         tier: "1", reason: "pressure_warning", outcome: "ok")
        await log.record(op: "freeze", pid: 200, bundleId: "com.hnc.Discord",
                         tier: "1", reason: "pressure_warning", outcome: "ok")
        await log.record(op: "thawAll", reason: "emergency")
        await log.close()

        let records = await log.tail(limit: 50)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records[0].op, "freeze")
        XCTAssertEqual(records[0].pid, 100)
        XCTAssertEqual(records[0].bundleId, "com.spotify.client")
        XCTAssertEqual(records[2].op, "thawAll")
        XCTAssertNil(records[2].pid)
    }

    /// Limit обрезает с хвоста. Запишем 5 → tail(limit: 2) отдаст последние 2.
    func testTailLimitReturnsLastN() async throws {
        let log = AuditLog(directory: tmpDir)
        await log.setUp()
        for i in 1...5 {
            await log.record(op: "freeze", pid: Int32(i), reason: "test_\(i)")
        }
        await log.close()

        let records = await log.tail(limit: 2)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].pid, 4)
        XCTAssertEqual(records[1].pid, 5)
    }

    /// Daily rotation: записи с ts разных дней попадают в разные файлы.
    /// Симулируем через прямой `record(Record)` с заданным ts.
    func testDailyRotationCreatesSeparateFiles() async throws {
        let log = AuditLog(directory: tmpDir)
        await log.setUp()

        await log.record(AuditLog.Record(
            ts: "2026-05-15T10:00:00.000Z", op: "freeze", pid: 1, reason: "day_1"
        ))
        await log.record(AuditLog.Record(
            ts: "2026-05-15T11:00:00.000Z", op: "freeze", pid: 2, reason: "day_1"
        ))
        await log.record(AuditLog.Record(
            ts: "2026-05-16T10:00:00.000Z", op: "freeze", pid: 3, reason: "day_2"
        ))
        await log.close()

        let day1URL = tmpDir.appendingPathComponent("audit-2026-05-15.log")
        let day2URL = tmpDir.appendingPathComponent("audit-2026-05-16.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: day1URL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: day2URL.path))

        // Каждый файл содержит свои записи
        let day1Records = AuditLog.readTail(url: day1URL, limit: 100)
        let day2Records = AuditLog.readTail(url: day2URL, limit: 100)
        XCTAssertEqual(day1Records.count, 2)
        XCTAssertEqual(day2Records.count, 1)
        XCTAssertEqual(day2Records[0].pid, 3)
    }

    /// pruneOldLogs удаляет файлы старше maxAgeDays. Создаём 2 файла,
    /// одному ставим mtime далеко в прошлом — он должен исчезнуть.
    func testPruneOldLogsRemovesAgedFiles() async throws {
        let log = AuditLog(directory: tmpDir, maxAgeDays: 7)
        await log.setUp()

        // Создаём «старый» файл
        let oldURL = tmpDir.appendingPathComponent("audit-2026-01-01.log")
        FileManager.default.createFile(atPath: oldURL.path, contents: Data("{}\n".utf8))
        // Mtime на 30 дней назад — точно старше maxAgeDays=7
        let oldMtime = Date().addingTimeInterval(-30 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: oldMtime], ofItemAtPath: oldURL.path)

        // Создаём «свежий» файл (mtime по умолчанию = now)
        let newURL = tmpDir.appendingPathComponent("audit-2026-05-17.log")
        FileManager.default.createFile(atPath: newURL.path, contents: Data("{}\n".utf8))

        await log.pruneOldLogs()
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path),
                       "файл старше maxAgeDays=7 должен быть удалён")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path),
                      "свежий файл должен остаться")
    }

    /// Tail на пустой/несуществующей директории — пустой массив.
    func testTailOnEmptyDirectory() async throws {
        let log = AuditLog(directory: tmpDir)
        await log.setUp()
        let records = await log.tail(limit: 10)
        XCTAssertTrue(records.isEmpty)
    }

    /// Все записи на одной даче — один файл, не два.
    func testSameDayKeepsOneFile() async throws {
        let log = AuditLog(directory: tmpDir)
        await log.setUp()
        for i in 1...3 {
            await log.record(op: "freeze", pid: Int32(i), reason: "same_day")
        }
        await log.close()

        let files = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
        let auditFiles = files.filter { $0.hasPrefix("audit-") && $0.hasSuffix(".log") }
        XCTAssertEqual(auditFiles.count, 1, "все записи одного дня → один файл")
    }
}
