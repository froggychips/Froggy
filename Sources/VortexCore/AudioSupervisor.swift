import AudioWorkerProtocol
import CoreAudio
import Darwin
import Foundation
import os

public enum AudioSupervisorError: Error, Sendable, CustomStringConvertible {
    case workerNotFound(String)
    case workerSpawnFailed(String)
    case workerCrashed
    case captureFailed(String)

    public var description: String {
        switch self {
        case .workerNotFound(let p):   return "Audio worker не найден: \(p)"
        case .workerSpawnFailed(let r): return "Не удалось spawn-нуть audio worker: \(r)"
        case .workerCrashed:           return "Audio worker упал во время захвата"
        case .captureFailed(let r):    return "Capture failed: \(r)"
        }
    }
}

/// Управляет жизненным циклом FroggyAudioWorker subprocess'а.
/// Паттерн — зеркало MLXSupervisor: spawn/kill через Process,
/// JSON-line stdin/stdout, crash isolation через subprocess boundary.
public actor AudioSupervisor {
    private static let log = Logger(subsystem: "com.froggychips.froggy", category: "audio-supervisor")

    public struct TranscriptEvent: Sendable {
        public var text: String
        public var isFinal: Bool
        public var speaker: String
    }

    private let workerURL: URL
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var pendingRequests: [String: CheckedContinuation<Void, any Error>] = [:]
    private var subscribers: [UUID: AsyncStream<TranscriptEvent>.Continuation] = [:]
    private var capturing = false
    private var sessionStore: SessionStore?
    private var lastSessionURL: URL?

    public init(workerExecutableURL: URL? = nil) {
        self.workerURL = workerExecutableURL ?? Self.defaultWorkerURL()
    }

    public static func defaultWorkerURL() -> URL {
        let execURL = Bundle.main.executableURL
            ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments.first ?? "/usr/local/libexec/FroggyDaemon")
        return execURL.deletingLastPathComponent().appendingPathComponent("FroggyAudioWorker")
    }

    // MARK: - Public API

    public func isCapturing() -> Bool { capturing }

    /// URL markdown-файла последней/текущей сессии. nil если сессий не было.
    public func sessionURL() -> URL? { lastSessionURL ?? sessionStore?.url }

    /// Подписывается на поток транскрипта. Возвращает AsyncStream и ID подписки.
    /// Вызови `unsubscribe(id:)` когда клиент отключился, иначе continuation утечёт.
    public func subscribeToTranscripts() -> (AsyncStream<TranscriptEvent>, UUID) {
        let id = UUID()
        let (stream, continuation) = AsyncStream<TranscriptEvent>.makeStream()
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.unsubscribe(id: id) }
        }
        subscribers[id] = continuation
        return (stream, id)
    }

    public func unsubscribe(id: UUID) {
        subscribers.removeValue(forKey: id)?.finish()
    }

    /// Запускает запись: spawn worker'а (если нет) + startCapture команда.
    public func startCapture(
        discordPid: Int32?,
        locale: String = "ru-RU",
        onDeviceRecognition: Bool = true,
        echoSuppression: Bool = true,
        echoSuppressionTailMs: Int = 400,
        vadEnabled: Bool = true,
        vadRmsThreshold: Double = 0.008
    ) async throws {
        try ensureWorkerSpawned()

        let id = UUID().uuidString
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            self.pendingRequests[id] = cont
            do {
                try self.sendCommand(.init(
                    cmd: AudioWorkerCommand.startCapture,
                    discordPid: discordPid,
                    requestId: id,
                    locale: locale,
                    onDeviceRecognition: onDeviceRecognition,
                    echoSuppression: echoSuppression,
                    echoSuppressionTailMs: echoSuppressionTailMs,
                    vadEnabled: vadEnabled,
                    vadRmsThreshold: vadRmsThreshold
                ))
            } catch {
                self.pendingRequests.removeValue(forKey: id)
                cont.resume(throwing: error)
            }
        }
        capturing = true
        let sessionURL = SessionStore.makeURL()
        if let store = try? SessionStore(at: sessionURL) {
            sessionStore = store
            lastSessionURL = sessionURL
        } else {
            Self.log.error("session store creation failed: \(sessionURL.path, privacy: .public)")
        }
        Self.log.notice("audio capture started discord_pid=\(discordPid.map(String.init) ?? "none") locale=\(locale) onDevice=\(onDeviceRecognition) echo=\(echoSuppression)")
    }

    /// Останавливает запись. Worker остаётся жить (готов к следующей сессии).
    public func stopCapture() async {
        guard capturing else { return }
        try? sendCommand(.init(cmd: AudioWorkerCommand.stopCapture, requestId: UUID().uuidString))
        capturing = false
        Self.log.notice("audio capture stopped")
    }

    /// Полное завершение: stopCapture + shutdown worker'а.
    public func shutdown() async {
        guard let p = process else { return }
        try? sendCommand(.init(cmd: AudioWorkerCommand.shutdown, requestId: UUID().uuidString))
        let exited = await Self.waitForExit(p, timeout: .seconds(3))
        if !exited { kill(p.processIdentifier, SIGKILL) }
        cleanup()
    }

    // MARK: - Worker spawn

    private func ensureWorkerSpawned() throws {
        if let p = process, p.isRunning { return }
        cleanup()

        guard FileManager.default.isExecutableFile(atPath: workerURL.path) else {
            throw AudioSupervisorError.workerNotFound(workerURL.path)
        }

        let proc = Process()
        proc.executableURL = workerURL
        proc.arguments = []
        let stdinPipe  = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput  = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError  = FileHandle.standardError

        let bridge = ReadBridge { [weak self] data in
            Task { await self?.feedStdout(data) }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { fh in
            bridge.receive(fh.availableData)
        }
        proc.terminationHandler = { p in
            let pid = p.processIdentifier
            let status = p.terminationStatus
            Task { [weak self] in await self?.handleWorkerExit(pid: pid, status: status) }
        }
        do {
            try proc.run()
        } catch {
            throw AudioSupervisorError.workerSpawnFailed(error.localizedDescription)
        }
        process = proc
        stdinHandle = stdinPipe.fileHandleForWriting
        Self.log.notice("audio worker spawned pid=\(proc.processIdentifier)")
    }

    // MARK: - stdin/stdout

    private func sendCommand(_ cmd: AudioWorkerCommand) throws {
        guard let stdin = stdinHandle else { throw AudioSupervisorError.workerCrashed }
        var data = try JSONEncoder().encode(cmd)
        data.append(0x0A)
        stdin.write(data)
    }

    private func feedStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        stdoutBuffer.append(data)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let endOffset = stdoutBuffer.distance(from: stdoutBuffer.startIndex, to: nl)
            let line = Data(stdoutBuffer.prefix(endOffset))
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            if let event = try? JSONDecoder().decode(AudioWorkerEvent.self, from: line) {
                deliverEvent(event)
            }
        }
    }

    private func deliverEvent(_ event: AudioWorkerEvent) {
        switch event.event {
        case AudioWorkerEvent.ready:
            if let id = event.requestId, let cont = pendingRequests.removeValue(forKey: id) {
                cont.resume()
            }

        case AudioWorkerEvent.transcript:
            let te = TranscriptEvent(
                text: event.text ?? "",
                isFinal: event.isFinal ?? false,
                speaker: event.speaker ?? "unknown"
            )
            if te.isFinal, let store = sessionStore {
                Task { await store.append(speaker: te.speaker, text: te.text) }
            }
            for cont in subscribers.values { cont.yield(te) }

        case AudioWorkerEvent.error:
            if let id = event.requestId, let cont = pendingRequests.removeValue(forKey: id) {
                cont.resume(throwing: AudioSupervisorError.captureFailed(event.message ?? "unknown"))
            } else {
                Self.log.error("audio worker error: \(event.message ?? "unknown", privacy: .public)")
            }

        case AudioWorkerEvent.pong:
            if let id = event.requestId, let cont = pendingRequests.removeValue(forKey: id) {
                cont.resume()
            }

        default:
            break
        }
    }

    // MARK: - Exit handling

    private func handleWorkerExit(pid: Int32, status: Int32) {
        guard process?.processIdentifier == pid else { return }
        Self.log.warning("audio worker exited pid=\(pid) status=\(status)")
        for (_, cont) in pendingRequests {
            cont.resume(throwing: AudioSupervisorError.workerCrashed)
        }
        cleanup()
    }

    private func cleanup() {
        pendingRequests.removeAll()
        for cont in subscribers.values { cont.finish() }
        subscribers.removeAll()
        stdoutBuffer.removeAll()
        try? stdinHandle?.close()
        stdinHandle = nil
        process = nil
        capturing = false
        if let store = sessionStore {
            Task { await store.close() }
            sessionStore = nil
        }
    }

    // MARK: - Utilities

    // MARK: - Audio device info (nonisolated, CoreAudio query)

    /// Имя текущего дефолтного output-устройства (AirPods, MacBook Speakers, …).
    /// nil если CoreAudio вернул ошибку.
    public nonisolated static func currentOutputDeviceName() -> String? {
        defaultDeviceName(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    /// Имя текущего дефолтного input-устройства (Built-in Microphone, AirPods, …).
    public nonisolated static func currentInputDeviceName() -> String? {
        defaultDeviceName(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    private nonisolated static func defaultDeviceName(selector: AudioObjectPropertySelector) -> String? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var prop = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &prop, 0, nil, &size, &deviceID
        ) == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }

        var nameProp = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioDevicePropertyDeviceNameCFString),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(deviceID, &nameProp, 0, nil, &nameSize, &name) == noErr else {
            return nil
        }
        return name as String
    }

    private static func waitForExit(_ proc: Process, timeout: Duration) async -> Bool {
        let pid = proc.processIdentifier
        guard pid > 0 else { return true }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let resolver = OneShotBoolResolver(continuation: cont)
            let queue = DispatchQueue.global(qos: .userInitiated)
            let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            src.setEventHandler { src.cancel(); resolver.resolve(true) }
            src.activate()
            if !proc.isRunning { src.cancel(); resolver.resolve(true); return }
            let nanos = UInt64(timeout.components.seconds) * 1_000_000_000
                + UInt64(timeout.components.attoseconds / 1_000_000_000)
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(nanos))) {
                src.cancel(); resolver.resolve(false)
            }
        }
    }
}

private final class ReadBridge: @unchecked Sendable {
    private let callback: @Sendable (Data) -> Void
    init(_ callback: @escaping @Sendable (Data) -> Void) { self.callback = callback }
    func receive(_ data: Data) { callback(data) }
}

private final class OneShotBoolResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false
    private let continuation: CheckedContinuation<Bool, Never>
    init(continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func resolve(_ value: Bool) {
        lock.lock(); let was = resolved; if !was { resolved = true }; lock.unlock()
        guard !was else { return }
        continuation.resume(returning: value)
    }
}
