import Foundation

/// Команда от демона к FroggyAudioWorker. Одна JSON-строка на stdin.
public struct AudioWorkerCommand: Codable, Sendable {
    public var cmd: String
    /// PID процесса Discord для CATapDescription.
    public var discordPid: Int32?
    public var requestId: String?

    public init(cmd: String, discordPid: Int32? = nil, requestId: String? = nil) {
        self.cmd = cmd
        self.discordPid = discordPid
        self.requestId = requestId
    }

    public static let startCapture = "startCapture"
    public static let stopCapture  = "stopCapture"
    public static let shutdown     = "shutdown"
    public static let ping         = "ping"
}

/// Событие от FroggyAudioWorker к демону. Одна JSON-строка на stdout.
public struct AudioWorkerEvent: Codable, Sendable {
    public var event: String
    public var requestId: String?
    /// Текст транскрипта (для event = "transcript").
    public var text: String?
    /// true — финальный результат окна; false — промежуточный.
    public var isFinal: Bool?
    /// "mic" или "discord".
    public var speaker: String?
    /// Сообщение об ошибке (для event = "error").
    public var message: String?

    public init(
        event: String,
        requestId: String? = nil,
        text: String? = nil,
        isFinal: Bool? = nil,
        speaker: String? = nil,
        message: String? = nil
    ) {
        self.event = event
        self.requestId = requestId
        self.text = text
        self.isFinal = isFinal
        self.speaker = speaker
        self.message = message
    }

    public static let ready      = "ready"
    public static let transcript = "transcript"
    public static let error      = "error"
    public static let goodbye    = "goodbye"
    public static let pong       = "pong"
}
