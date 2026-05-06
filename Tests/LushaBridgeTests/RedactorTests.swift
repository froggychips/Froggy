import XCTest
@testable import LushaBridge

final class RedactorTests: XCTestCase {
    private let r = Redactor()

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
}
