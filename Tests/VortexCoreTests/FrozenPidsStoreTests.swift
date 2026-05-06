import Foundation
import XCTest
@testable import VortexCore

final class FrozenPidsStoreTests: XCTestCase {
    private func makeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("frozen-\(UUID()).pids")
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

    func testRecoverClearsFile() async {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FrozenPidsStore(fileURL: url)
        // Используем заведомо несуществующий pid — kill вернёт ESRCH, это OK.
        await store.add(.init(pid: 999_999, executablePath: "/Applications/Ghost.app"))
        let recovered = await store.recover()
        XCTAssertEqual(recovered, 1)
        let entries = await store.entries()
        XCTAssertEqual(entries, [])
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
}
