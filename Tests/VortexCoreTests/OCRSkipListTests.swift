import Foundation
import XCTest
@testable import LushaBridge

/// Issue #61: regex skip-list для шумных OCR-строк.
final class OCRSkipListTests: XCTestCase {

    /// Default-патчи матчат «10:30», «10:30:45», «75%», «1.2 GB», «1.2.3».
    func testDefaultPatternsMatchNoisyStrings() {
        let list = OCRSkipList(patterns: OCRSkipList.defaultPatterns)
        XCTAssertTrue(list.shouldSkip("10:30"))
        XCTAssertTrue(list.shouldSkip("10:30:45"))
        XCTAssertTrue(list.shouldSkip("75%"))
        XCTAssertTrue(list.shouldSkip("100%"))
        XCTAssertTrue(list.shouldSkip("1.2 GB"))
        XCTAssertTrue(list.shouldSkip("512KB"))
        XCTAssertTrue(list.shouldSkip("3 MB"))
        XCTAssertTrue(list.shouldSkip("1.2.3"))
        XCTAssertTrue(list.shouldSkip("1.2.3.4"))
        XCTAssertTrue(list.shouldSkip("42"))
    }

    /// Default-патчи anchored на целую строку: «meeting at 10:30» не
    /// матчится, потому что у нас anchored ^...$.
    func testDefaultPatternsDoNotMatchSubstrings() {
        let list = OCRSkipList(patterns: OCRSkipList.defaultPatterns)
        XCTAssertFalse(list.shouldSkip("meeting at 10:30"))
        XCTAssertFalse(list.shouldSkip("Battery: 75%"))
        XCTAssertFalse(list.shouldSkip("File size: 1.2 GB free"))
        XCTAssertFalse(list.shouldSkip("Version 1.2.3 released"))
        XCTAssertFalse(list.shouldSkip("hello world"))
    }

    /// Whitespace вокруг строки тоже trim'ится перед матчем.
    func testWhitespaceIsTrimmedBeforeMatch() {
        let list = OCRSkipList(patterns: OCRSkipList.defaultPatterns)
        XCTAssertTrue(list.shouldSkip("  10:30  "))
        XCTAssertTrue(list.shouldSkip("\t75%\n"))
    }

    /// Пустая строка → не skip. Дедуп/empty семантика — забота #60.
    func testEmptyLineIsNotSkipped() {
        let list = OCRSkipList(patterns: OCRSkipList.defaultPatterns)
        XCTAssertFalse(list.shouldSkip(""))
        XCTAssertFalse(list.shouldSkip("   "))
    }

    /// filter() — convenience: возвращает массив без skip'нутых.
    func testFilterRemovesSkippedLines() {
        let list = OCRSkipList(patterns: OCRSkipList.defaultPatterns)
        let input = ["Hello", "10:30", "World", "75%", "File: report.pdf"]
        let output = list.filter(input)
        XCTAssertEqual(output, ["Hello", "World", "File: report.pdf"])
    }

    /// User-добавленный pattern — допустим к defaults.
    func testUserPatternIsApplied() {
        let userPattern = #"^debug:"#
        let list = OCRSkipList(patterns: OCRSkipList.defaultPatterns + [userPattern])
        XCTAssertTrue(list.shouldSkip("debug: connection refused"))
        XCTAssertTrue(list.shouldSkip("10:30"), "default тоже работает")
        XCTAssertFalse(list.shouldSkip("normal log line"))
    }

    /// Невалидный regex логируется warning'ом и пропускается, init не падает.
    func testInvalidRegexIsSkippedGracefully() {
        let list = OCRSkipList(patterns: ["[broken"]) // незакрытая скобка
        XCTAssertEqual(list.patternCount, 0, "невалидные паттерны не должны попасть в compiled list")
        XCTAssertFalse(list.shouldSkip("anything"))
    }

    /// loadDefaults() склеивает три источника. Тест: configPatterns +
    /// userPatternsFile добавляются к defaults.
    func testLoadDefaultsMergesSources() throws {
        // Создаём временный файл с user patterns.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("froggy-skip-test-\(UUID().uuidString).json")
        let userPatterns = [#"^FPS:\s*\d+"#]
        try JSONEncoder().encode(userPatterns).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let list = OCRSkipList.loadDefaults(
            configPatterns: [#"^DEBUG:"#],
            userPatternsFile: tmp
        )
        XCTAssertTrue(list.shouldSkip("10:30"), "default")
        XCTAssertTrue(list.shouldSkip("DEBUG: hello"), "config-added")
        XCTAssertTrue(list.shouldSkip("FPS: 60"), "user-file-added")
        XCTAssertFalse(list.shouldSkip("regular line"))
    }

    /// Integration через VisionActor._testProcessOCRResult: skip-list
    /// фильтрует ДО semantic-diff, в ContextStore попадает только полезное.
    func testVisionActorAppliesSkipListBeforePush() async {
        let store = ContextStore(capacity: 30, scorer: NoopSimilarityScorer())
        let skipList = OCRSkipList(patterns: OCRSkipList.defaultPatterns)
        let vision = VisionActor(
            contextStore: store,
            skipList: skipList
        )

        let pushed = await vision._testProcessOCRResult([
            "Reading email", "10:30", "75%", "Subject: Meeting"
        ])
        XCTAssertTrue(pushed)

        let snapshots = await store.snapshots()
        XCTAssertEqual(snapshots.count, 1)
        // Сохранилось только то что НЕ skip'нуто.
        let lines = snapshots[0].lines
        XCTAssertEqual(Set(lines), Set(["Reading email", "Subject: Meeting"]))
    }
}
