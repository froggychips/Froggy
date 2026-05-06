import XCTest
@testable import LushaBridge

final class ContextStoreTests: XCTestCase {
    func testStartsEmpty() async {
        let s = ContextStore(capacity: 5)
        let n = await s.count()
        XCTAssertEqual(n, 0)
        let text = await s.recentContext()
        XCTAssertEqual(text, "")
    }

    func testRingBufferEvicts() async {
        let s = ContextStore(capacity: 3)
        for i in 0..<5 {
            await s.push(lines: ["line \(i)"])
        }
        let count = await s.count()
        XCTAssertEqual(count, 3)
        let snaps = await s.snapshots()
        XCTAssertEqual(snaps.first?.lines, ["line 2"])
        XCTAssertEqual(snaps.last?.lines, ["line 4"])
    }

    func testRecentContextRespectsMaxChars() async {
        let s = ContextStore(capacity: 10)
        for i in 0..<5 {
            await s.push(lines: ["payload \(i) " + String(repeating: "x", count: 100)])
        }
        let short = await s.recentContext(maxChars: 200)
        let long = await s.recentContext(maxChars: 10_000)
        XCTAssertLessThan(short.count, long.count)
        XCTAssertLessThanOrEqual(short.count, 400) // header + body, looser bound
        XCTAssertTrue(long.contains("payload 4"), "newest snapshot must be present in long")
    }

    func testClearEmptiesStore() async {
        let s = ContextStore(capacity: 5)
        await s.push(lines: ["a"])
        await s.push(lines: ["b"])
        await s.clear()
        let n = await s.count()
        XCTAssertEqual(n, 0)
    }
}
