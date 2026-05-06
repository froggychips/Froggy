import XCTest
@testable import LushaBridge

final class RedactorTests: XCTestCase {
    private let r = Redactor(loadUserRules: false)

    func testRedactsAWSKey() {
        let s = "key=AKIAIOSFODNN7EXAMPLE end"
        XCTAssertEqual(r.redact(s), "key=[REDACTED-AWS-KEY] end")
    }

    func testRedactsGitHubLegacyToken() {
        let s = "token: ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ1234567890"
        let out = r.redact(s)
        XCTAssertTrue(out.contains("[REDACTED-GITHUB]"))
        XCTAssertFalse(out.contains("ghp_"))
    }

    func testRedactsAnthropicAndOpenAI() {
        let s1 = "auth=sk-ant-api03-abcdefghijklmnopqrstuvwxyz1234567890"
        let s2 = "auth=sk-proj-abcdefghijklmnopqrstuvwxyz1234567890"
        XCTAssertTrue(r.redact(s1).contains("[REDACTED-ANTHROPIC]"))
        XCTAssertTrue(r.redact(s2).contains("[REDACTED-OPENAI]"))
    }

    func testRedactsJWT() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIn0.ABC123"
        let out = r.redact("token: \(jwt)")
        XCTAssertTrue(out.contains("[REDACTED-JWT]"))
    }

    func testRedactsBearer() {
        let out = r.redact("Authorization: Bearer abcdef1234567890ghij")
        XCTAssertTrue(out.contains("[REDACTED-BEARER]"))
    }

    func testRedactsPasswordLabel() {
        let out = r.redact("password=Hunter2!secret")
        XCTAssertTrue(out.contains("[REDACTED]"))
        XCTAssertFalse(out.contains("Hunter2"))
    }

    func testRedactsValidCreditCard() {
        // 4242 4242 4242 4242 — Stripe canonical Luhn-valid test number.
        let out = r.redact("card 4242 4242 4242 4242 expires soon")
        XCTAssertTrue(out.contains("[REDACTED-CARD]"), "got: \(out)")
    }

    func testDoesNotRedactRandomLongNumber() {
        // Random 16-digit string that fails Luhn.
        let out = r.redact("order 1234567890123456 placed")
        XCTAssertFalse(out.contains("[REDACTED-CARD]"))
        XCTAssertTrue(out.contains("1234567890123456"))
    }

    func testRedactsPEMBlock() {
        let pem = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEpAIBAAKCAQEA2sgN
        -----END RSA PRIVATE KEY-----
        """
        XCTAssertTrue(r.redact(pem).contains("[REDACTED-PEM]"))
    }

    func testCleanTextUnchanged() {
        let s = "Hello world, this is fine — no secrets here."
        XCTAssertEqual(r.redact(s), s)
    }

    func testLineArrayVariant() {
        let lines = ["safe", "key=AKIAIOSFODNN7EXAMPLE"]
        let out = r.redact(lines)
        XCTAssertEqual(out[0], "safe")
        XCTAssertTrue(out[1].contains("[REDACTED-AWS-KEY]"))
    }

    func testCustomRulesAppliedAfterBuiltIn() {
        let rules = Redactor.builtInRules + [
            RedactionRule(name: "internal-id", pattern: "ACME-\\d{6}", replacement: "[REDACTED-CORP]")
        ]
        let custom = Redactor(rules: rules)
        let out = custom.redact("ticket ACME-123456 has aws=AKIAIOSFODNN7EXAMPLE")
        XCTAssertTrue(out.contains("[REDACTED-CORP]"))
        XCTAssertTrue(out.contains("[REDACTED-AWS-KEY]"))
    }

    func testLoadsUserRulesFromDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rules-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let payload = [
            RedactionRule(name: "test", pattern: "TOPSECRET-\\d+", replacement: "[REDACTED-TS]")
        ]
        let data = try JSONEncoder().encode(payload)
        try data.write(to: url)

        let loaded = Redactor.loadUserRules(from: url)
        XCTAssertEqual(loaded?.count, 1)
        XCTAssertEqual(loaded?.first?.name, "test")
    }

    func testCompiledOnceDoesNotRecompilePerCall() {
        // Smoke-тест: 1000 redact'ов на одной инстанции не падают и
        // отрабатывают за разумное время (<2 сек на M-чипе).
        let lines = (0..<1000).map { _ in "key=AKIAIOSFODNN7EXAMPLE end" }
        let start = Date()
        let out = r.redact(lines)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(out.count, 1000)
        XCTAssertTrue(out.allSatisfy { $0.contains("[REDACTED-AWS-KEY]") })
        XCTAssertLessThan(elapsed, 2.0, "1000 redactions took \(elapsed)s — slower than expected")
    }
}
