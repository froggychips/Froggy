import XCTest
@testable import LushaBridge

final class SimilarityScorerTests: XCTestCase {
    func testJaccardIdentical() async {
        let s = JaccardSimilarityScorer()
        let v = await s.similarity(["hello world foo"], ["hello world foo"])
        XCTAssertEqual(v, 1.0, accuracy: 1e-9)
    }

    func testJaccardDisjoint() async {
        let s = JaccardSimilarityScorer()
        let v = await s.similarity(["alpha beta"], ["gamma delta"])
        XCTAssertEqual(v, 0.0, accuracy: 1e-9)
    }

    func testJaccardPartialOverlap() async {
        let s = JaccardSimilarityScorer()
        // {hello, world, foo} vs {hello, world, bar}: |∩|=2, |∪|=4 → 0.5
        let v = await s.similarity(["hello world foo"], ["hello world bar"])
        XCTAssertEqual(v, 0.5, accuracy: 1e-9)
    }

    func testJaccardCaseInsensitive() async {
        let s = JaccardSimilarityScorer()
        let v = await s.similarity(["Hello World"], ["hello WORLD"])
        XCTAssertEqual(v, 1.0, accuracy: 1e-9)
    }

    func testJaccardIgnoresPunctuation() async {
        let s = JaccardSimilarityScorer()
        let v = await s.similarity(["hello, world!"], ["hello world"])
        XCTAssertEqual(v, 1.0, accuracy: 1e-9)
    }

    func testJaccardBothEmptyIsOne() async {
        // Документированное поведение: «оба пустые» считаем идентичными,
        // чтобы пустые snapshots'ы не накапливались.
        let s = JaccardSimilarityScorer()
        let v = await s.similarity([], [])
        XCTAssertEqual(v, 1.0)
    }

    func testJaccardMinTokenLengthFiltersShortTokens() async {
        let s = JaccardSimilarityScorer(minTokenLength: 3)
        // "a b c" — все токены короче 3, отфильтрованы → пустые множества → 1.0
        let v = await s.similarity(["a b c"], ["x y z"])
        XCTAssertEqual(v, 1.0)
    }

    func testNoopAlwaysZero() async {
        let s = NoopSimilarityScorer()
        let v = await s.similarity(["same"], ["same"])
        XCTAssertEqual(v, 0.0)
    }
}
