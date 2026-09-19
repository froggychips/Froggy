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

    /// `load(from:)` создаёт каталог самого файла (раньше — глобальный
    /// support directory независимо от `url`).
    func testLoadCreatesParentDirectoryOfURL() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("froggy-test-\(UUID())", isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let url = dir.appendingPathComponent("config.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        let c = try FroggyConfig.load(from: url)
        XCTAssertEqual(c, FroggyConfig())
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }

    // MARK: - Defaults (ADR 0018)

    /// Дефолт стратегии — `scratch`: jetsam требует root/entitlement,
    /// machVM — development-ядро. См. ADR 0018.
    func testDefaultPageoutStrategyIsScratch() {
        XCTAssertEqual(FroggyConfig().pageoutStrategy, .scratch)
    }

    /// Старый файл, где стратегия не указана, тоже получает `scratch`.
    func testDecodeWithoutPageoutStrategyGetsScratch() throws {
        let cfg = try JSONDecoder().decode(FroggyConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(cfg.pageoutStrategy, .scratch)
    }

    // MARK: - validate()

    func testValidateAcceptsDefaults() throws {
        XCTAssertNoThrow(try FroggyConfig().validate())
    }

    /// `contextWindowSize: 0` раньше доезжал до `precondition(capacity > 0)`
    /// в ContextStore и валил демон в crash-loop.
    func testValidateRejectsZeroContextWindow() {
        var c = FroggyConfig()
        c.contextWindowSize = 0
        XCTAssertThrowsError(try c.validate()) { error in
            XCTAssertEqual((error as? ConfigValidationError)?.field, "contextWindowSize")
        }
    }

    func testValidateRejectsNonPositiveCaptureInterval() {
        var c = FroggyConfig()
        c.captureIntervalSeconds = 0
        XCTAssertThrowsError(try c.validate()) { error in
            XCTAssertEqual((error as? ConfigValidationError)?.field, "captureIntervalSeconds")
        }
    }

    func testValidateRejectsMultiplierBelowOneOrNonFinite() {
        var c = FroggyConfig()
        c.framePacerWarningMultiplier = 0.5
        XCTAssertThrowsError(try c.validate())
        c.framePacerWarningMultiplier = 2.0
        c.framePacerCriticalMultiplier = .infinity
        XCTAssertThrowsError(try c.validate()) { error in
            XCTAssertEqual((error as? ConfigValidationError)?.field, "framePacerCriticalMultiplier")
        }
    }

    /// `pageoutScratchMB` ниже 16 нормализуется в ScratchPageoutImpl, а не
    /// отвергается — иначе ранее валидный конфиг (8) перестал бы грузиться.
    func testValidateAcceptsSmallScratchButRejectsNonPositive() {
        var c = FroggyConfig()
        c.pageoutScratchMB = 8
        XCTAssertNoThrow(try c.validate())
        c.pageoutScratchMB = 0
        XCTAssertThrowsError(try c.validate()) { error in
            XCTAssertEqual((error as? ConfigValidationError)?.field, "pageoutScratchMB")
        }
    }

    func testValidateRejectsThresholdOutsideUnitRange() {
        var c = FroggyConfig()
        c.frameSimilarityThreshold = 1.5
        XCTAssertThrowsError(try c.validate())
        c.frameSimilarityThreshold = 0.98
        c.contextDedupThreshold = -0.1
        XCTAssertThrowsError(try c.validate()) { error in
            XCTAssertEqual((error as? ConfigValidationError)?.field, "contextDedupThreshold")
        }
    }

    /// ADR 0009: допустимы только 16 / 8 / 4.
    func testValidateRejectsUnsupportedKVCacheBits() {
        var c = FroggyConfig()
        for bits in [16, 8, 4] {
            c.kvCacheBits = bits
            XCTAssertNoThrow(try c.validate(), "kvCacheBits=\(bits) must be accepted")
        }
        c.kvCacheBits = 6
        XCTAssertThrowsError(try c.validate()) { error in
            XCTAssertEqual((error as? ConfigValidationError)?.field, "kvCacheBits")
        }
    }

    func testValidateRejectsEmptyOrOverlongSocketPath() {
        var c = FroggyConfig()
        c.ipcSocketPath = ""
        XCTAssertThrowsError(try c.validate())
        c.ipcSocketPath = "/tmp/" + String(repeating: "x", count: 120) + ".sock"
        XCTAssertThrowsError(try c.validate()) { error in
            XCTAssertEqual((error as? ConfigValidationError)?.field, "ipcSocketPath")
        }
    }

    func testValidationErrorDescriptionNamesField() {
        let e = ConfigValidationError(field: "contextWindowSize", reason: "must be >= 1 (got 0)")
        XCTAssertEqual(String(describing: e), "config.contextWindowSize: must be >= 1 (got 0)")
    }
}
