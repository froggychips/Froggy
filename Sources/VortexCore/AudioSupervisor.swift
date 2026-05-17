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
/// Pipe-lifecycle (spawn/Process/stdin/stdout/waitForExit/terminationHandler
/// race-guard) делегирован `WorkerProcessHost` — общий с `MLXSupervisor`
/// (issue #58). Здесь — audio-специфика: декодинг событий, CheckedContinuation
/// pending-requests (вместо AsyncThrowingStream у MLX), subscribers
/// для streaming transcript'а, sessionStore.
public actor AudioSupervisor {
    private static let log = Logger(subsystem: "com.froggychips.froggy", category: "audio-supervisor")

    public struct TranscriptEvent: Sendable {
        public var text: String
        public var isFinal: Bool
        public var speaker: String
    }

    private let workerURL: URL
    private let pidStore: FrozenPidsStore?
    /// Pipe-lifecycle (issue #58). Lazy по той же причине что и в MLXSupervisor —
    /// Swift 6 запрещает `[weak self]` capture в actor init.
    private lazy var host: WorkerProcessHost = WorkerProcessHost(
        workerURL: workerURL,
        args: [],
        log: Self.log,
        pidStore: pidStore,
        onLine: { [weak self] line in
            guard let self else { return }
            Task { await self.handleLine(line) }
        },
        onExit: { [weak self] pid, status in
            guard let self else { return }
            Task { await self.handleWorkerExit(pid: pid, status: status) }
        }
    )
    private var pendingRequests: [String: CheckedContinuation<Void, any Error>] = [:]
    private var subscribers: [UUID: AsyncStream<TranscriptEvent>.Continuation] = [:]
    private var capturing = false
    private var sessionStore: SessionStore?
    private var lastSessionURL: URL?
    /// Issue #57: once-per-spawn wire-version warning (см. MLXSupervisor).
    private var wireVersionMismatchLogged = false

    /// Issue #58 acceptance: pidStore прокидывается в host, чтобы audio worker
    /// тоже регистрировался под `categoryWorker` и попадал в boot-recovery
    /// наравне с MLX worker'ом.
    public init(
        workerExecutableURL: URL? = nil,
        pidStore: FrozenPidsStore? = nil
    ) {
        self.workerURL = workerExecutableURL ?? Self.defaultWorkerURL()
        self.pidStore = pidStore
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

    /// Добавляет произвольный контекстный блок в текущую сессию.
    /// Возвращает false если сессия не активна.
    @discardableResult
    public func appendContext(_ text: String, title: String = "Injected Context") -> Bool {
        guard let store = sessionStore else { return false }
        Task { await store.appendSection(title: title, content: text) }
        return true
    }

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

    /// Полное завершение: shutdown worker'а + ожидание exit'а + SIGKILL fallback.
    /// Симметрично `MLXSupervisor.unloadModel`.
    public func shutdown() async {
        guard host.currentPid() != nil else { return }
        try? sendCommand(.init(cmd: AudioWorkerCommand.shutdown, requestId: UUID().uuidString))
        let exited = await host.waitForExit(timeout: .seconds(3))
        if !exited {
            await host.sigkill()
        }
        cleanup()
    }

    // MARK: - Worker spawn

    private func ensureWorkerSpawned() throws {
        do {
            try host.ensureSpawned()
        } catch WorkerProcessHost.WorkerProcessError.workerNotFound(let p) {
            throw AudioSupervisorError.workerNotFound(p)
        } catch WorkerProcessHost.WorkerProcessError.spawnFailed(let r) {
            throw AudioSupervisorError.workerSpawnFailed(r)
        } catch {
            throw AudioSupervisorError.workerSpawnFailed(error.localizedDescription)
        }
    }

    // MARK: - stdin/stdout

    private func sendCommand(_ cmd: AudioWorkerCommand) throws {
        let data = try JSONEncoder().encode(cmd)
        do {
            try host.write(data)
        } catch {
            throw AudioSupervisorError.workerCrashed
        }
    }

    private func handleLine(_ line: Data) {
        guard let event = try? JSONDecoder().decode(AudioWorkerEvent.self, from: line) else { return }
        deliverEvent(event)
    }

    private func deliverEvent(_ event: AudioWorkerEvent) {
        if let v = event.apiVersion, v != AudioWireVersion.current, !wireVersionMismatchLogged {
            Self.log.warning(
                "audio wire version mismatch: worker=\(v, privacy: .public) daemon=\(AudioWireVersion.current, privacy: .public) — продолжаем, но проверь audioWorkerPath"
            )
            wireVersionMismatchLogged = true
        }
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

    /// Race-guard: см. развёрнутый комментарий в `MLXSupervisor.handleWorkerExit`.
    private func handleWorkerExit(pid: Int32, status: Int32) {
        let currentPid = host.currentPid()
        guard currentPid == nil || currentPid == pid else {
            Self.log.notice("ignoring stale audio exit pid=\(pid) current=\(currentPid ?? 0)")
            return
        }
        if currentPid == nil {
            Self.log.info("audio worker exit post-cleanup pid=\(pid) status=\(status)")
            return
        }
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
        capturing = false
        // Issue #57: следующий spawn — другой бинарь, мог отстать.
        wireVersionMismatchLogged = false
        host.cleanup()
        if let store = sessionStore {
            Task { await store.close() }
            sessionStore = nil
        }
    }

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
        // CoreAudio для CFString properties отдаёт retained CF-object'ы
        // (см. AudioHardware.h: DeviceNameCFString → +1 retain). Передача
        // `&CFString` вместо `&Unmanaged<CFString>` ломает ARC bridging
        // (warning: «forming UnsafeMutableRawPointer to variable of type
        // CFString») — память overwrite'ит object reference без правильного
        // retain/release цикла. Канонический паттерн — Unmanaged + takeRetainedValue.
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &nameProp, 0, nil, &nameSize, &name) == noErr,
              let cfName = name?.takeRetainedValue() else {
            return nil
        }
        return cfName as String
    }
}
