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

    public init(
        modelPath: String? = nil,
        gpuMemoryLimitBytes: Int? = nil,
        captureIntervalSeconds: Int = 2,
        freezeBundleIds: [String] = FroggyConfig.defaultFreezeBundleIds,
        ipcSocketPath: String = FroggyConfig.defaultSocketPath
    ) {
        self.modelPath = modelPath
        self.gpuMemoryLimitBytes = gpuMemoryLimitBytes
        self.captureIntervalSeconds = captureIntervalSeconds
        self.freezeBundleIds = freezeBundleIds
        self.ipcSocketPath = ipcSocketPath
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
