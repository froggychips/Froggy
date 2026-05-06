import XCTest
@testable import VortexCore

final class PromptAugmenterTests: XCTestCase {
    func testEmptyContextReturnsBarePrompt() {
        let a = PromptAugmenter()
        let out = a.augment(prompt: "hi", context: "")
        XCTAssertEqual(out, "hi")
    }

    func testWhitespaceOnlyContextReturnsBarePrompt() {
        let a = PromptAugmenter()
        let out = a.augment(prompt: "hi", context: "   \n\t  ")
        XCTAssertEqual(out, "hi")
    }

    func testNonEmptyContextWrapsPrompt() {
        let a = PromptAugmenter()
        let out = a.augment(prompt: "what app am I in?", context: "Slack channel: #general")
        XCTAssertTrue(out.contains("--- CONTEXT ---"))
        XCTAssertTrue(out.contains("Slack channel: #general"))
        XCTAssertTrue(out.contains("--- END CONTEXT ---"))
        XCTAssertTrue(out.contains("User: what app am I in?"))
        XCTAssertTrue(out.contains("Assistant:"))
    }

    func testMaxContextCharsTruncatesContext() {
        // Используем «маркерный» символ, которого в default template нет,
        // чтобы посчитать ровно сколько контекста дошло до prompt'a.
        // Юникод U+2603 SNOWMAN.
        let a = PromptAugmenter(maxContextChars: 50)
        let marker: Character = "☃"
        let huge = String(repeating: marker, count: 500)
        let out = a.augment(prompt: "p", context: huge)
        let count = out.filter { $0 == marker }.count
        XCTAssertEqual(count, 50)
    }

    func testCustomTemplateApplied() {
        let a = PromptAugmenter(template: "CTX={context}|Q={prompt}")
        let out = a.augment(prompt: "ask", context: "ctx")
        XCTAssertEqual(out, "CTX=ctx|Q=ask")
    }
}
