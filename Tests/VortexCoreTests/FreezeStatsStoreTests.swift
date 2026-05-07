import Foundation
import XCTest
@testable import VortexCore

final class FreezeStatsStoreTests: XCTestCase {
    private func makeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("freeze-\(UUID()).sqlite")
    }

    func testOpenAndMigrateOnFreshDB() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FreezeStatsStore(fileURL: url)
        try await store.openAndMigrate()
        let n = try await store.count()
        XCTAssertEqual(n, 0)
        await store.close()
    }

    func testRecordAndCount() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FreezeStatsStore(fileURL: url)
        try await store.openAndMigrate()

        for i in 0..<5 {
            let event = FreezeStatsStore.Event(
                bundleId: "Test.app",
                pid: Int32(1000 + i),
                rssBefore: 100_000_000 + i * 1_000_000,
                rssAfter: 50_000_000,
                pageoutStrategy: "jetsam",
                recoveryMs: 200 + i * 10
            )
            try await store.record(event)
        }
        let n = try await store.count()
        XCTAssertEqual(n, 5)
        await store.close()
    }

    func testTopByMedianFreed() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FreezeStatsStore(fileURL: url)
        try await store.openAndMigrate()

        // App A: освобождает 100 MB каждый раз (4 события).
        for _ in 0..<4 {
            try await store.record(.init(
                bundleId: "Heavy.app", pid: 1, rssBefore: 200_000_000, rssAfter: 100_000_000,
                pageoutStrategy: "jetsam", recoveryMs: 300
            ))
        }
        // App B: освобождает 10 MB (3 события).
        for _ in 0..<3 {
            try await store.record(.init(
                bundleId: "Light.app", pid: 2, rssBefore: 50_000_000, rssAfter: 40_000_000,
                pageoutStrategy: "jetsam", recoveryMs: 100
            ))
        }

        let top = try await store.topByMedianFreed(limit: 10, daysBack: 7)
        XCTAssertEqual(top.count, 2)
        XCTAssertEqual(top[0].bundleId, "Heavy.app")
        XCTAssertEqual(top[0].medianFreedBytes, 100_000_000)
        XCTAssertEqual(top[0].sampleCount, 4)
        XCTAssertEqual(top[1].bundleId, "Light.app")
        XCTAssertEqual(top[1].medianFreedBytes, 10_000_000)
        await store.close()
    }

    func testPersistsAcrossReopens() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let store = FreezeStatsStore(fileURL: url)
            try await store.openAndMigrate()
            try await store.record(.init(
                bundleId: "X.app", pid: 1, rssBefore: 100, rssAfter: 50,
                pageoutStrategy: nil, recoveryMs: nil
            ))
            await store.close()
        }
        do {
            let store = FreezeStatsStore(fileURL: url)
            try await store.openAndMigrate()
            let n = try await store.count()
            XCTAssertEqual(n, 1)
            await store.close()
        }
    }

    func testClearEmpties() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FreezeStatsStore(fileURL: url)
        try await store.openAndMigrate()
        try await store.record(.init(
            bundleId: "X.app", pid: 1, rssBefore: 100, rssAfter: 50,
            pageoutStrategy: nil, recoveryMs: nil
        ))
        try await store.clear()
        let n = try await store.count()
        XCTAssertEqual(n, 0)
        await store.close()
    }

    /// Только события за последние `daysBack` дней попадают в выборку.
    func testCutoffByDaysBack() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FreezeStatsStore(fileURL: url)
        try await store.openAndMigrate()

        // Старое событие 30 дней назад.
        let old = FreezeStatsStore.Event(
            timestamp: Date().addingTimeInterval(-30 * 86_400),
            bundleId: "Stale.app", pid: 1, rssBefore: 1_000_000_000, rssAfter: 0,
            pageoutStrategy: "jetsam", recoveryMs: 100
        )
        try await store.record(old)
        // Свежее событие.
        try await store.record(.init(
            bundleId: "Fresh.app", pid: 2, rssBefore: 10_000_000, rssAfter: 5_000_000,
            pageoutStrategy: "jetsam", recoveryMs: 100
        ))

        let top = try await store.topByMedianFreed(limit: 10, daysBack: 7)
        XCTAssertEqual(top.count, 1)
        XCTAssertEqual(top[0].bundleId, "Fresh.app")
        await store.close()
    }
}
