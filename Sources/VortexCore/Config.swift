import Foundation

/// Persisted Froggy configuration. Loaded from
/// `~/Library/Application Support/Froggy/config.json`.
/// CLI flags and env vars override these values at the daemon level.
public struct FroggyConfig: Codable, Sendable, Equatable {
    public var modelPath: String?
    public var gpuMemoryLimitBytes: Int?
    public var captureIntervalSeconds: Int

    /// Tier-1: морозим при `.warning`. По умолчанию — лёгкие фоновые
    /// приложения, которые редко бьют по UX (плеер, чат с pull-моделью,
    /// IM, который не критичен в момент тяжёлой работы).
    public var freezeTier1BundleIds: [String]

    /// Tier-2: дополнительно морозим при `.critical`. По умолчанию —
    /// корпоративные коммуникации/доки. Их «оживить» дороже, поэтому
    /// трогаем только когда unified memory реально под прессом.
    public var freezeTier2BundleIds: [String]

    /// Сколько секунд уровень должен продержаться в стабильно более низком
    /// состоянии, прежде чем мы начнём оттепель.
    public var pressureCooldownSeconds: Int

    /// Стратегия принудительного pageout после SIGSTOP. По умолчанию `jetsam`
    /// (не требует `task_for_pid-allow` entitlement'а). См. ADR 0007.
    public var pageoutStrategy: PageoutStrategy
    /// Размер scratch-буфера для `.scratch` стратегии и для fallback-цепочки.
    public var pageoutScratchMB: Int

    /// Путь к executable'у `FroggyMLXWorker`. По умолчанию — рядом с демоном.
    /// См. ADR 0008.
    public var mlxWorkerPath: String?

    /// Путь к маленькой модели (1-2B) для ответов во время созвона.
    /// Если nil — используется основная модель без смены.
    public var callModelPath: String?

    /// Путь к executable'у `FroggyAudioWorker`. По умолчанию — рядом с демоном.
    public var audioWorkerPath: String?

    /// BCP-47 locale для SFSpeechRecognizer. По умолчанию "ru-RU".
    public var audioLocale: String

    /// Только on-device распознавание (не отправлять аудио в Apple cloud).
    /// По умолчанию true — приватность важнее accuracy на рабочих созвонах.
    public var audioOnDeviceRecognition: Bool

    /// Подавлять микрофон пока Discord-тап слышит аудио (echo suppression).
    /// Актуально при встроенных динамиках — без этого mic транскрибирует
    /// и голос собеседника из колонок тоже.
    public var echoSuppressionEnabled: Bool

    /// Сколько мс держать mic-gate после последнего Discord-аудио.
    /// 400ms покрывает комнатный реверб + задержку микрофона.
    public var echoSuppressionTailMs: Int

    /// Voice Activity Detection: пропускать mic-буферы тише этого RMS.
    /// ~0.008 (-42 dBFS) — отсекает фоновый шум без потери тихой речи.
    public var vadEnabled: Bool
    public var vadRmsThreshold: Double

    /// Mem-5 этап 1: собирать ли телеметрию freeze/thaw в SQLite.
    /// На этапе 1 мы только пишем; ranking-overlay пойдёт отдельным PR'ом.
    /// См. ADR 0010.
    public var freezeRankingEnabled: Bool

    /// Биты KV-cache в worker'е: 16 (без квантизации), 8 (default), 4.
    /// Значение `8` экономит ~50% RAM на KV-cache на больших prompt'ах.
    /// См. ADR 0009.
    public var kvCacheBits: Int

    /// Master switch для freeze-логики (ADR 0017).
    /// false → coordinator игнорит pressure events и не морозит ничего.
    /// MenuBar при Off-нажатии ставит false + unload model + thawAll.
    /// Default true — backwards-compat с существующими config.json.
    public var freezingEnabled: Bool

    /// Issue #59: на `.warning` от MemoryPressureMonitor — растягиваем
    /// `captureInterval` в N раз. Default 2.0. Никогда не падает ниже
    /// base interval (multiplier ≥ 1.0 по дизайну).
    public var framePacerWarningMultiplier: Double
    /// Issue #59: на `.critical` — растягиваем в N раз. Default 4.0.
    /// Не отключает OCR полностью (multiplier=∞) — это тратит pressure
    /// без observability; используйте `.critical` × 4 как «почти пауза»,
    /// которая всё ещё иногда даёт snapshot.
    public var framePacerCriticalMultiplier: Double

    /// Issue #61: regex-список для skip'а шумных OCR-строк (часы, проценты,
    /// file sizes). Применяется per-line поверх `defaultPatterns`. nil →
    /// только defaults; пустой массив — тоже только defaults (если хочется
    /// явно «не добавлять кастом», просто пропусти поле). Невалидные regex'ы
    /// логируются warning'ом и игнорятся, daemon не падает.
    /// User-specific list — отдельным файлом `ocr-skip-patterns.json` в
    /// support directory; см. `OCRSkipList.defaultUserPatternsURL`.
    public var ocrSkipPatterns: [String]?

    public var ipcSocketPath: String
    public var frameSimilarityThreshold: Double
    public var contextWindowSize: Int
    public var contextMaxChars: Int
    public var contextDedupEnabled: Bool
    public var contextDedupThreshold: Double

    /// Discord Incoming Webhook URL для уведомлений о начале/конце записи созвона.
    /// nil — уведомления отключены. Env: DISCORD_NOTIFY_WEBHOOK.
    public var discordNotifyWebhookURL: String?

    /// **DEPRECATED.** Алиас на `freezeTier1BundleIds` для обратной совместимости
    /// со старыми `config.json`. Если в файле указано и старое, и новое поле —
    /// побеждает новое. Удалить в одной из следующих фаз.
    public var freezeBundleIds: [String]?

    public init(
        modelPath: String? = nil,
        gpuMemoryLimitBytes: Int? = nil,
        captureIntervalSeconds: Int = 2,
        freezeTier1BundleIds: [String] = FroggyConfig.defaultFreezeTier1BundleIds,
        freezeTier2BundleIds: [String] = FroggyConfig.defaultFreezeTier2BundleIds,
        pressureCooldownSeconds: Int = 60,
        pageoutStrategy: PageoutStrategy = .jetsam,
        pageoutScratchMB: Int = 256,
        mlxWorkerPath: String? = nil,
        callModelPath: String? = nil,
        audioWorkerPath: String? = nil,
        audioLocale: String = "ru-RU",
        audioOnDeviceRecognition: Bool = true,
        echoSuppressionEnabled: Bool = true,
        echoSuppressionTailMs: Int = 400,
        vadEnabled: Bool = true,
        vadRmsThreshold: Double = 0.008,
        freezeRankingEnabled: Bool = true,
        kvCacheBits: Int = 8,
        freezingEnabled: Bool = true,
        framePacerWarningMultiplier: Double = 2.0,
        framePacerCriticalMultiplier: Double = 4.0,
        ocrSkipPatterns: [String]? = nil,
        ipcSocketPath: String = FroggyConfig.defaultSocketPath,
        frameSimilarityThreshold: Double = 0.98,
        contextWindowSize: Int = 30,
        contextMaxChars: Int = 4096,
        contextDedupEnabled: Bool = true,
        contextDedupThreshold: Double = 0.85,
        discordNotifyWebhookURL: String? = nil,
        freezeBundleIds: [String]? = nil
    ) {
        self.modelPath = modelPath
        self.gpuMemoryLimitBytes = gpuMemoryLimitBytes
        self.captureIntervalSeconds = captureIntervalSeconds
        self.freezeTier1BundleIds = freezeTier1BundleIds
        self.freezeTier2BundleIds = freezeTier2BundleIds
        self.pressureCooldownSeconds = pressureCooldownSeconds
        self.pageoutStrategy = pageoutStrategy
        self.pageoutScratchMB = pageoutScratchMB
        self.mlxWorkerPath = mlxWorkerPath
        self.callModelPath = callModelPath
        self.audioWorkerPath = audioWorkerPath
        self.audioLocale = audioLocale
        self.audioOnDeviceRecognition = audioOnDeviceRecognition
        self.echoSuppressionEnabled = echoSuppressionEnabled
        self.echoSuppressionTailMs = echoSuppressionTailMs
        self.vadEnabled = vadEnabled
        self.vadRmsThreshold = vadRmsThreshold
        self.freezeRankingEnabled = freezeRankingEnabled
        self.kvCacheBits = kvCacheBits
        self.freezingEnabled = freezingEnabled
        self.framePacerWarningMultiplier = framePacerWarningMultiplier
        self.framePacerCriticalMultiplier = framePacerCriticalMultiplier
        self.ocrSkipPatterns = ocrSkipPatterns
        self.ipcSocketPath = ipcSocketPath
        self.frameSimilarityThreshold = frameSimilarityThreshold
        self.contextWindowSize = contextWindowSize
        self.contextMaxChars = contextMaxChars
        self.contextDedupEnabled = contextDedupEnabled
        self.contextDedupThreshold = contextDedupThreshold
        self.discordNotifyWebhookURL = discordNotifyWebhookURL
        self.freezeBundleIds = freezeBundleIds
    }

    public static let defaultFreezeTier1BundleIds: [String] = [
        "com.spotify.client",
        "com.hnc.Discord",
        "ru.keepcoder.Telegram",
        "com.electron.dropbox",
    ]

    public static let defaultFreezeTier2BundleIds: [String] = [
        "com.tinyspeck.slackmacgap",   // Slack
        "notion.id",                   // Notion
        "com.microsoft.teams2",        // Teams
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
    // load — they'll just get the current defaults. Старое поле
    // `freezeBundleIds` маппится на tier-1, если новое поле отсутствует.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FroggyConfig()

        self.modelPath = try c.decodeIfPresent(String.self, forKey: .modelPath)
        self.gpuMemoryLimitBytes = try c.decodeIfPresent(Int.self, forKey: .gpuMemoryLimitBytes)
        self.captureIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .captureIntervalSeconds) ?? d.captureIntervalSeconds

        let legacy = try c.decodeIfPresent([String].self, forKey: .freezeBundleIds)
        let newTier1 = try c.decodeIfPresent([String].self, forKey: .freezeTier1BundleIds)
        self.freezeTier1BundleIds = newTier1 ?? legacy ?? d.freezeTier1BundleIds
        self.freezeBundleIds = legacy

        self.freezeTier2BundleIds = try c.decodeIfPresent([String].self, forKey: .freezeTier2BundleIds) ?? d.freezeTier2BundleIds
        self.pressureCooldownSeconds = try c.decodeIfPresent(Int.self, forKey: .pressureCooldownSeconds) ?? d.pressureCooldownSeconds
        self.pageoutStrategy = try c.decodeIfPresent(PageoutStrategy.self, forKey: .pageoutStrategy) ?? d.pageoutStrategy
        self.pageoutScratchMB = try c.decodeIfPresent(Int.self, forKey: .pageoutScratchMB) ?? d.pageoutScratchMB
        self.freezeRankingEnabled = try c.decodeIfPresent(Bool.self, forKey: .freezeRankingEnabled) ?? d.freezeRankingEnabled
        self.mlxWorkerPath = try c.decodeIfPresent(String.self, forKey: .mlxWorkerPath)
        self.callModelPath = try c.decodeIfPresent(String.self, forKey: .callModelPath)
        self.audioWorkerPath = try c.decodeIfPresent(String.self, forKey: .audioWorkerPath)
        self.audioLocale = try c.decodeIfPresent(String.self, forKey: .audioLocale) ?? d.audioLocale
        self.audioOnDeviceRecognition = try c.decodeIfPresent(Bool.self, forKey: .audioOnDeviceRecognition) ?? d.audioOnDeviceRecognition
        self.echoSuppressionEnabled = try c.decodeIfPresent(Bool.self, forKey: .echoSuppressionEnabled) ?? d.echoSuppressionEnabled
        self.echoSuppressionTailMs = try c.decodeIfPresent(Int.self, forKey: .echoSuppressionTailMs) ?? d.echoSuppressionTailMs
        self.vadEnabled = try c.decodeIfPresent(Bool.self, forKey: .vadEnabled) ?? d.vadEnabled
        self.vadRmsThreshold = try c.decodeIfPresent(Double.self, forKey: .vadRmsThreshold) ?? d.vadRmsThreshold
        self.kvCacheBits = try c.decodeIfPresent(Int.self, forKey: .kvCacheBits) ?? d.kvCacheBits
        self.freezingEnabled = try c.decodeIfPresent(Bool.self, forKey: .freezingEnabled) ?? d.freezingEnabled
        self.framePacerWarningMultiplier = try c.decodeIfPresent(Double.self, forKey: .framePacerWarningMultiplier) ?? d.framePacerWarningMultiplier
        self.framePacerCriticalMultiplier = try c.decodeIfPresent(Double.self, forKey: .framePacerCriticalMultiplier) ?? d.framePacerCriticalMultiplier
        self.ocrSkipPatterns = try c.decodeIfPresent([String].self, forKey: .ocrSkipPatterns)

        self.ipcSocketPath = try c.decodeIfPresent(String.self, forKey: .ipcSocketPath) ?? d.ipcSocketPath
        self.frameSimilarityThreshold = try c.decodeIfPresent(Double.self, forKey: .frameSimilarityThreshold) ?? d.frameSimilarityThreshold
        self.contextWindowSize = try c.decodeIfPresent(Int.self, forKey: .contextWindowSize) ?? d.contextWindowSize
        self.contextMaxChars = try c.decodeIfPresent(Int.self, forKey: .contextMaxChars) ?? d.contextMaxChars
        self.contextDedupEnabled = try c.decodeIfPresent(Bool.self, forKey: .contextDedupEnabled) ?? d.contextDedupEnabled
        self.contextDedupThreshold = try c.decodeIfPresent(Double.self, forKey: .contextDedupThreshold) ?? d.contextDedupThreshold
        let webhookFromConfig = try c.decodeIfPresent(String.self, forKey: .discordNotifyWebhookURL)
        self.discordNotifyWebhookURL = ProcessInfo.processInfo.environment["DISCORD_NOTIFY_WEBHOOK"] ?? webhookFromConfig
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
