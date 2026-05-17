import Foundation
import XCTest
@testable import LushaBridge

/// Issue #60: semantic OCR-diff поверх pixel fingerprint'а.
/// Тесты гоняют post-OCR pipeline (`_testProcessOCRResult`) на готовых
/// массивах строк — без реального SCStream и Vision OCR.
final class SemanticOCRDiffTests: XCTestCase {

    private func makeActor() async -> (VisionActor, ContextStore) {
        let store = ContextStore(capacity: 30, scorer: NoopSimilarityScorer())
        let vision = VisionActor(
            captureInterval: .seconds(2),
            contextStore: store
        )
        return (vision, store)
    }

    /// Acceptance из issue: «два разных-по-пикселям-но-одинаковых-по-тексту
    /// кадра дают один snapshot в store». Pixel здесь не моделируем — но
    /// доказываем что одинаковые OCR-strings подряд пушатся один раз.
    func testIdenticalOCRPushesOnce() async {
        let (vision, store) = await makeActor()
        let pushed1 = await vision._testProcessOCRResult(["hello", "world"])
        let pushed2 = await vision._testProcessOCRResult(["hello", "world"])
        XCTAssertTrue(pushed1, "первый кадр всегда push'ится")
        XCTAssertFalse(pushed2, "тот же контент → semantic dup, не push'ится")
        let count = await store.count()
        XCTAssertEqual(count, 1, "в ContextStore должен попасть только один snapshot")
    }

    /// Разные strings — push'атся оба.
    func testDifferentOCRPushesBoth() async {
        let (vision, store) = await makeActor()
        let pushed1 = await vision._testProcessOCRResult(["first frame"])
        let pushed2 = await vision._testProcessOCRResult(["second frame"])
        XCTAssertTrue(pushed1)
        XCTAssertTrue(pushed2)
        let count = await store.count()
        XCTAssertEqual(count, 2)
    }

    /// Те же строки в разном порядке (Vision может re-layout'нуть OCR
    /// observations) — должны считаться equal через sort.
    func testReorderedLinesAreSemanticallyEqual() async {
        let (vision, store) = await makeActor()
        let pushed1 = await vision._testProcessOCRResult(["alpha", "beta", "gamma"])
        let pushed2 = await vision._testProcessOCRResult(["gamma", "alpha", "beta"])
        XCTAssertTrue(pushed1)
        XCTAssertFalse(pushed2, "reorder тех же строк = semantic equal")
        let count = await store.count()
        XCTAssertEqual(count, 1)
    }

    /// Whitespace вокруг строк не делает их semantically different.
    func testWhitespaceVariantsAreEqual() async {
        let (vision, store) = await makeActor()
        let pushed1 = await vision._testProcessOCRResult(["hello world"])
        let pushed2 = await vision._testProcessOCRResult(["  hello world  "])
        XCTAssertTrue(pushed1)
        XCTAssertFalse(pushed2, "trim'нутый whitespace → equal")
        let count = await store.count()
        XCTAssertEqual(count, 1)
    }

    /// Пустые строки внутри массива дропаются — массив [""] эквивалентен [].
    /// Cвидетельство: пустой массив → empty normalized → не сравнивается
    /// против lastOCRNormalized (защита от «два пустых кадра подряд → skip
    /// и потеря пушинга»). Первый push'ится; второй пустой — тоже push'ится
    /// (lastOCRNormalized = "" из первого → но мы не сравниваем пустые).
    func testEmptyResultsAlwaysPush() async {
        let (vision, store) = await makeActor()
        let pushed1 = await vision._testProcessOCRResult([])
        let pushed2 = await vision._testProcessOCRResult(["   ", ""])
        XCTAssertTrue(pushed1, "первый пустой кадр push'ится")
        XCTAssertTrue(pushed2, "второй пустой тоже push'ится (не сравниваем по empty normalized)")
        let count = await store.count()
        XCTAssertEqual(count, 2)
    }

    /// normalizeForSemanticDiff публичный — anchor-тест на стабильность
    /// формата. Если кто-то поменяет separator или удалит sort — здесь
    /// упадёт.
    func testNormalizationAnchor() {
        let input = ["  hello  ", "", "world", "hello"]
        let normalized = VisionActor.normalizeForSemanticDiff(input)
        XCTAssertEqual(normalized, "hello\nhello\nworld",
                       "trim → filter empty → sort → join по \\n")
    }
}
