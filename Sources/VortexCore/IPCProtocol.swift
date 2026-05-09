import Foundation

public struct IPCRequest: Codable, Sendable {
    public var cmd: String
    public var prompt: String?
    public var maxTokens: Int?
    public var pid: Int32?
    public var maxChars: Int?
    public var path: String?
    public var accessor: String?
    public var useContext: Bool?
    /// Фильтр для cmd `accessors`: если nil — вернуть все; true/false —
    /// только experimental или только core. См. ADR 0011 § EXP-1.
    public var experimental: Bool?
    /// Discord process PID для cmd `listen`.
    public var discordPid: Int32?

    public init(
        cmd: String,
        prompt: String? = nil,
        maxTokens: Int? = nil,
        pid: Int32? = nil,
        maxChars: Int? = nil,
        path: String? = nil,
        accessor: String? = nil,
        useContext: Bool? = nil,
        experimental: Bool? = nil,
        discordPid: Int32? = nil
    ) {
        self.cmd = cmd
        self.prompt = prompt
        self.maxTokens = maxTokens
        self.pid = pid
        self.maxChars = maxChars
        self.path = path
        self.accessor = accessor
        self.useContext = useContext
        self.experimental = experimental
        self.discordPid = discordPid
    }
}

public struct IPCResponse: Codable, Sendable {
    public var ok: Bool?
    public var error: String?
    public var text: String?
    public var capturing: Bool?
    public var modelLoaded: Bool?
    public var modelPath: String?
    public var memoryPressure: Int?
    public var frozen: Int?
    public var context: String?
    public var snapshots: Int?
    public var lines: [String]?
    public var accessors: [Accessor]?
    public var lastCaptureError: String?
    /// Mem-5 cmd `freezeStats`: топ-N bundle_id по медиане освобождения.
    public var freezeStats: [FreezeStatsStore.AggregatedStats]?
    /// Текущее значение KV-cache битности (16/8/4) — для cmd `status`.
    public var kvCacheBits: Int?
    /// Текущий уровень давления (`normal`/`warning`/`critical`) — для cmd `pressure`.
    public var pressureLevel: String?
    /// Pids, замороженные политикой tier-1 (warning).
    public var tier1Frozen: [Int32]?
    /// Pids, замороженные политикой tier-2 (critical).
    public var tier2Frozen: [Int32]?
    /// Сколько секунд держится текущий уровень.
    public var secondsInLevel: Int?
    /// Кумулятивные счётчики pageout (attempted/succeeded/failed по стратегиям) —
    /// observability для cmd `pressure`. Без них непонятно, реально ли работает
    /// jetsam/machVM на конкретной машине.
    public var pageoutCounters: PageoutCounters?
    /// Маркер «это последний chunk в стриме». Для one-shot ответов — true.
    /// Для streaming-промежуточных chunk'ов — false.
    public var final: Bool?
    /// Для cmd `listen`: идёт ли захват аудио прямо сейчас.
    public var listening: Bool?
    /// Для streaming транскрипта: спикер ("mic" | "discord").
    public var speaker: String?
    /// Имя дефолтного output-устройства (AirPods Pro, MacBook Speakers, …).
    /// Помогает клиенту определить нужен ли echo detection.
    public var audioOutputDevice: String?
    /// Имя дефолтного input-устройства (Built-in Microphone, AirPods, …).
    public var audioInputDevice: String?

    public init() {}

    public static func failure(_ message: String) -> IPCResponse {
        var r = IPCResponse()
        r.ok = false
        r.error = message
        r.final = true
        return r
    }

    public static func success() -> IPCResponse {
        var r = IPCResponse()
        r.ok = true
        r.final = true
        return r
    }

    /// Описание зарегистрированного Lusha-аксессора.
    /// `experimental == true` означает, что аксессор живёт в target'е
    /// `LushaExperimental` и помечен как опытный (ADR 0011 § EXP-1).
    /// Поле опциональное в wire-формате — старые клиенты, не знающие
    /// про experimental, продолжают работать.
    public struct Accessor: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var experimental: Bool?
        public init(id: String, name: String, experimental: Bool? = nil) {
            self.id = id
            self.name = name
            self.experimental = experimental
        }
    }
}

public protocol IPCRequestHandler: Sendable {
    func handle(_ request: IPCRequest) async -> IPCResponse

    /// Опциональный streaming путь: если возвращается non-nil, сервер
    /// будет писать каждый IPCResponse одной JSON-строкой и закроет
    /// соединение после chunk'a с `final == true`.
    /// Дефолтная реализация возвращает nil — handler one-shot.
    func handleStream(_ request: IPCRequest) -> AsyncThrowingStream<IPCResponse, any Error>?
}

extension IPCRequestHandler {
    public func handleStream(_ request: IPCRequest) -> AsyncThrowingStream<IPCResponse, any Error>? {
        nil
    }
}
