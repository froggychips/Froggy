import XCTest
@testable import VortexCore

final class KVCacheConfigTests: XCTestCase {
    func testDefaultIs8() {
        let c = FroggyConfig()
        XCTAssertEqual(c.kvCacheBits, 8)
    }

    func testRoundTrip() throws {
        for bits in [16, 8, 4] {
            var c = FroggyConfig()
            c.kvCacheBits = bits
            let data = try JSONEncoder().encode(c)
            let decoded = try JSONDecoder().decode(FroggyConfig.self, from: data)
            XCTAssertEqual(decoded.kvCacheBits, bits, "bits=\(bits) round-trip failed")
        }
    }

    func testLegacyConfigGetsDefault() throws {
        // Старый config.json без kvCacheBits — должен получить default=8.
        let json = #"""
        {"captureIntervalSeconds": 5}
        """#
        let cfg = try JSONDecoder().decode(FroggyConfig.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.kvCacheBits, 8)
    }

    /// Supervisor использует config.kvCacheBits → передаётся в worker через
    /// `--kv-bits N` argument (проверяется визуально в Mem-3 интеграции).
    /// Здесь — что getter совпадает с тем, что положили.
    func testSupervisorReadsConfiguredBits() async {
        let supervisor = MLXSupervisor(kvCacheBits: 4)
        let actual = await supervisor.currentKVCacheBits()
        XCTAssertEqual(actual, 4)
    }
}
