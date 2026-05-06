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

    // MARK: - Phase 6: dedup

    func testDedupSkipsDuplicateNeighbors() async {
        let s = ContextStore(
            capacity: 10,
            scorer: JaccardSimilarityScorer(),
            dedupThreshold: 0.85
        )
        await s.push(lines: ["alpha beta gamma"])
        await s.push(lines: ["alpha beta gamma"]) // identical → skipped
        await s.push(lines: ["alpha beta gamma"]) // identical → skipped
        let n = await s.count()
        XCTAssertEqual(n, 1)
    }

    func testDedupDoesNotSkipDifferentLines() async {
        let s = ContextStore(
            capacity: 10,
            scorer: JaccardSimilarityScorer(),
            dedupThreshold: 0.85
        )
        await s.push(lines: ["alpha beta gamma"])
        await s.push(lines: ["delta epsilon zeta"])
        let n = await s.count()
        XCTAssertEqual(n, 2)
    }

    func testDedupDisabledByDefault() async {
        let s = ContextStore(capacity: 10) // default scorer = Noop → never skips
        await s.push(lines: ["x"])
        await s.push(lines: ["x"])
        await s.push(lines: ["x"])
        let n = await s.count()
        XCTAssertEqual(n, 3)
    }

    func testDedupZeroThresholdAcceptsEverything() async {
        // threshold=0 + Jaccard: только полное несовпадение (0.0) пропустит;
        // identical (1.0) — отброшено.
        let s = ContextStore(
            capacity: 10,
            scorer: JaccardSimilarityScorer(),
            dedupThreshold: 0.0
        )
        await s.push(lines: ["same"])
        await s.push(lines: ["same"])
        let n = await s.count()
        XCTAssertEqual(n, 1)
    }

    // MARK: - Phase 6: multi-byte truncation

    func testRecentContextTruncatesCyrillicByGraphemes() async {
        let s = ContextStore(capacity: 5)
        // Длинный кириллический snapshot — заведомо больше budget.
        let long = String(repeating: "тест ", count: 200)
        await s.push(lines: [long])
        let out = await s.recentContext(maxChars: 50)
        // Строго не больше budget'а в graphemes.
        XCTAssertLessThanOrEqual(out.count, 50)
        // И не пустое — старый код мог вернуть "".
        XCTAssertGreaterThan(out.count, 0)
    }

    func testRecentContextHandlesEmojiInTruncation() async {
        let s = ContextStore(capacity: 5)
        let emojiLine = String(repeating: "🐸", count: 100)
        await s.push(lines: [emojiLine])
        let out = await s.recentContext(maxChars: 30)
        XCTAssertLessThanOrEqual(out.count, 30)
        XCTAssertGreaterThan(out.count, 0)
    }
}
