import XCTest
@testable import VortexCore

final class ConfigTests: XCTestCase {
    func testDefaults() {
        let c = FroggyConfig()
        XCTAssertNil(c.modelPath)
        XCTAssertNil(c.gpuMemoryLimitBytes)
        XCTAssertEqual(c.captureIntervalSeconds, 2)
        XCTAssertFalse(c.freezeTier1BundleIds.isEmpty)
        XCTAssertFalse(c.freezeTier2BundleIds.isEmpty)
        XCTAssertEqual(c.pressureCooldownSeconds, 60)
        XCTAssertNil(c.freezeBundleIds, "deprecated alias must default to nil")
        XCTAssertTrue(c.ipcSocketPath.hasSuffix("froggy.sock"))
    }

    /// Старый формат конфига с `freezeBundleIds` маппится в `freezeTier1BundleIds`.
    func testLegacyFreezeBundleIdsMapsToTier1() throws {
        let json = #"""
        {"freezeBundleIds": ["legacy.app.one", "legacy.app.two"]}
        """#
        let cfg = try JSONDecoder().decode(FroggyConfig.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.freezeTier1BundleIds, ["legacy.app.one", "legacy.app.two"])
        XCTAssertEqual(cfg.freezeBundleIds, ["legacy.app.one", "legacy.app.two"])
        XCTAssertFalse(cfg.freezeTier2BundleIds.isEmpty)
    }

    /// Если в файле есть и старое, и новое поле — побеждает новое.
    func testNewTier1WinsOverLegacy() throws {
        let json = #"""
        {
          "freezeBundleIds": ["legacy.app"],
          "freezeTier1BundleIds": ["new.app"]
        }
        """#
        let cfg = try JSONDecoder().decode(FroggyConfig.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.freezeTier1BundleIds, ["new.app"])
    }

    func testRoundTripJSON() throws {
        var c = FroggyConfig()
        c.modelPath = "/tmp/model"
        c.gpuMemoryLimitBytes = 8_000_000_000
        c.captureIntervalSeconds = 5
        c.freezeBundleIds = ["com.foo.bar"]
        c.ipcSocketPath = "/tmp/test.sock"

        let data = try JSONEncoder().encode(c)
        let decoded = try JSONDecoder().decode(FroggyConfig.self, from: data)
        XCTAssertEqual(c, decoded)
    }

    func testLoadReturnsDefaultsWhenMissing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("froggy-test-\(UUID()).json")
        let c = try FroggyConfig.load(from: url)
        XCTAssertEqual(c, FroggyConfig())
    }

    func testSaveAndLoadRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("froggy-test-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }

        var c = FroggyConfig()
        c.modelPath = "/x"
        c.captureIntervalSeconds = 7
        try c.save(to: url)

        let loaded = try FroggyConfig.load(from: url)
        XCTAssertEqual(loaded, c)

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attrs[.posixPermissions] as? NSNumber, 0o600)
    }

    func testLoadThrowsOnMalformedJSON() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("froggy-test-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        XCTAssertThrowsError(try FroggyConfig.load(from: url))
    }
}
