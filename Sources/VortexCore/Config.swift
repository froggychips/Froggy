import Foundation

/// Persisted Froggy configuration. Loaded from
/// `~/Library/Application Support/Froggy/config.json`.
/// CLI flags and env vars override these values at the daemon level.
public struct FroggyConfig: Codable, Sendable, Equatable {
    public var modelPath: String?
    public var gpuMemoryLimitBytes: Int?
    public var captureIntervalSeconds: Int
    public var freezeBundleIds: [String]
    public var ipcSocketPath: String
    public var frameSimilarityThreshold: Double
    public var contextWindowSize: Int
    public var contextMaxChars: Int
    public var contextDedupEnabled: Bool
    public var contextDedupThreshold: Double

    public init(
        modelPath: String? = nil,
        gpuMemoryLimitBytes: Int? = nil,
        captureIntervalSeconds: Int = 2,
        freezeBundleIds: [String] = FroggyConfig.defaultFreezeBundleIds,
        ipcSocketPath: String = FroggyConfig.defaultSocketPath,
        frameSimilarityThreshold: Double = 0.98,
        contextWindowSize: Int = 30,
        contextMaxChars: Int = 4096,
        contextDedupEnabled: Bool = true,
        contextDedupThreshold: Double = 0.85
    ) {
        self.modelPath = modelPath
        self.gpuMemoryLimitBytes = gpuMemoryLimitBytes
        self.captureIntervalSeconds = captureIntervalSeconds
        self.freezeBundleIds = freezeBundleIds
        self.ipcSocketPath = ipcSocketPath
        self.frameSimilarityThreshold = frameSimilarityThreshold
        self.contextWindowSize = contextWindowSize
        self.contextMaxChars = contextMaxChars
        self.contextDedupEnabled = contextDedupEnabled
        self.contextDedupThreshold = contextDedupThreshold
    }

    public static let defaultFreezeBundleIds: [String] = [
        "com.tinyspeck.slackmacgap",      // Slack
        "com.hnc.Discord",                // Discord
        "com.spotify.client",             // Spotify
        "com.microsoft.teams2",           // Teams
        "com.electron.dropbox",           // Dropbox
    ]

    /// `~/Library/Application Support/Froggy/`.
    public static var supportDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Froggy", isDirectory: true)
    }

    public static var defaultURL: URL {
        supportDirectory.appendingPathComponent("config.json")
    }

    public static var defaultSocketPath: String {
        supportDirectory.appendingPathComponent("froggy.sock").path
    }

    // Custom decoder so older config.json files without the new fields still
    // load — they'll just get the current defaults.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FroggyConfig()
        self.modelPath = try c.decodeIfPresent(String.self, forKey: .modelPath)
        self.gpuMemoryLimitBytes = try c.decodeIfPresent(Int.self, forKey: .gpuMemoryLimitBytes)
        self.captureIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .captureIntervalSeconds) ?? d.captureIntervalSeconds
        self.freezeBundleIds = try c.decodeIfPresent([String].self, forKey: .freezeBundleIds) ?? d.freezeBundleIds
        self.ipcSocketPath = try c.decodeIfPresent(String.self, forKey: .ipcSocketPath) ?? d.ipcSocketPath
        self.frameSimilarityThreshold = try c.decodeIfPresent(Double.self, forKey: .frameSimilarityThreshold) ?? d.frameSimilarityThreshold
        self.contextWindowSize = try c.decodeIfPresent(Int.self, forKey: .contextWindowSize) ?? d.contextWindowSize
        self.contextMaxChars = try c.decodeIfPresent(Int.self, forKey: .contextMaxChars) ?? d.contextMaxChars
        self.contextDedupEnabled = try c.decodeIfPresent(Bool.self, forKey: .contextDedupEnabled) ?? d.contextDedupEnabled
        self.contextDedupThreshold = try c.decodeIfPresent(Double.self, forKey: .contextDedupThreshold) ?? d.contextDedupThreshold
    }

    /// Loads config from `url`, returning defaults if the file is missing.
    /// Throws only on malformed JSON / IO errors other than not-found.
    public static func load(from url: URL = defaultURL) throws -> FroggyConfig {
        let fm = FileManager.default
        try fm.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard fm.fileExists(atPath: url.path) else {
            return FroggyConfig()
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(FroggyConfig.self, from: data)
    }

    /// Persists config as pretty-printed JSON with mode 0600.
    public func save(to url: URL = defaultURL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }
}
