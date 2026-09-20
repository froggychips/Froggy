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
    /// Второй `startCapture`, пока первый ждёт `ready`. Два pending старта
    /// делили бы одни флаги отмены — отказываем сразу, без второго ожидания.
    case startInProgress

    public var description: String {
        switch self {
        case .workerNotFound(let p):   return "Audio worker не найден: \(p)"
        case .workerSpawnFailed(let r): return "Не удалось spawn-нуть audio worker: \(r)"
        case .workerCrashed:           return "Audio worker упал во время захвата"
        case .captureFailed(let r):    return "Capture failed: \(r)"
        case .startInProgress:         return "startCapture уже выполняется"
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
    /// Каталог markdown-сессий. Дефолт — `~/Documents/Froggy/Meetings`;
    /// тесты передают временный каталог, чтобы не писать в реальные документы.
    private let sessionDirectory: URL
    /// Pipe-lifecycle (issue #58). Lazy по той же причине что и в MLXSupervisor —
    /// stored properties из closure в actor init недоступны. Callback'и host'а
    /// только кладут события в `pipeContinuation`; в actor они попадают через
    /// один последовательный `pipePump` (см. `WorkerPipeEvent`).
    private lazy var host: WorkerProcessHost = WorkerProcessHost(
        workerURL: workerURL,
        args: [],
        log: Self.log,
        pidStore: pidStore,
        onLine: { [pipeContinuation] line, gen in
            pipeContinuation.yield(.line(line, generation: gen))
        },
        onExit: { [pipeContinuation] pid, status, gen in
            pipeContinuation.yield(.exit(pid: pid, status: status, generation: gen))
        }
    )
    private let pipeEvents: AsyncStream<WorkerPipeEvent>
    private let pipeContinuation: AsyncStream<WorkerPipeEvent>.Continuation
    private var pipePump: Task<Void, Never>?
    /// Страховка на случай, если worker не пришлёт `goodbye` на стоп
    /// (старая версия, крэш между командой и ответом). См. `awaitGoodbye`.
    private var transcriptFinishTask: Task<Void, Never>?
    private var pendingRequests: [String: CheckedContinuation<Void, any Error>] = [:]
    /// Подписчик и сессия, чей транскрипт он ждёт: текущая, если запись идёт,
    /// иначе следующая — подписаться до `startCapture` разрешено (так делает
    /// заранее запущенный `froggy listen-stream`). Номер нужен, чтобы стоп
    /// одной сессии не закрывал стрим, открытый для другой.
    private struct TranscriptSubscription {
        let continuation: AsyncStream<TranscriptEvent>.Continuation
        let session: UInt64
    }
    private var subscribers: [UUID: TranscriptSubscription] = [:]
    /// Номер текущей (или последней) записи; растёт на каждом старте.
    private var captureSession: UInt64 = 0
    /// Сессия, по которой стоп уже отправлен и ждём `goodbye`.
    private var sessionAwaitingGoodbye: UInt64?
    /// Стоп-команды, ожидающие `goodbye`: requestId → сессия. Поздний
    /// `goodbye` закрывает свою сессию, а не ту, что успела начаться после.
    private var pendingStops: [String: UInt64] = [:]
    /// Сессия, чей вывод сейчас идёт от worker'а: транскрипт адресуется
    /// только её подписчикам, иначе хвост прошлой записи попал бы в стрим
    /// (и в `ContextStore`) следующей.
    private var emittingSession: UInt64?
    private var capturing = false
    /// `startCapture` ждёт `ready` от worker'а через continuation; в это окно
    /// `capturing == false`, и `stopCapture` раньше был no-op — микрофон
    /// оставался включённым вопреки явной остановке. Флаги закрывают окно.
    private var startInFlight = false
    private var stopRequestedDuringStart = false
    private var sessionStore: SessionStore?
    private var lastSessionURL: URL?
    /// Issue #57: once-per-spawn wire-version warning (см. MLXSupervisor).
    private var wireVersionMismatchLogged = false

    /// Issue #58 acceptance: pidStore прокидывается в host, чтобы audio worker
    /// тоже регистрировался под `categoryWorker` и попадал в boot-recovery
    /// наравне с MLX worker'ом.
    public init(
        workerExecutableURL: URL? = nil,
        pidStore: FrozenPidsStore? = nil,
        sessionDirectory: URL = SessionStore.defaultDirectory
    ) {
        self.workerURL = workerExecutableURL ?? Self.defaultWorkerURL()
        self.pidStore = pidStore
        self.sessionDirectory = sessionDirectory
        let (events, continuation) = AsyncStream<WorkerPipeEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.pipeEvents = events
        self.pipeContinuation = continuation
    }

    deinit {
        pipePump?.cancel()
        pipeContinuation.finish()
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
        subscribers[id] = TranscriptSubscription(
            continuation: continuation,
            session: (capturing || startInFlight) ? captureSession : captureSession &+ 1
        )
        return (stream, id)
    }

    public func unsubscribe(id: UUID) {
        subscribers.removeValue(forKey: id)?.continuation.finish()
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
        guard !startInFlight else { throw AudioSupervisorError.startInProgress }
        resolvePendingGoodbyeFallback()
        try ensureWorkerSpawned()

        // Номер выделяется на КАЖДУЮ попытку, в том числе отменённую: иначе
        // подписчик, пришедший после отмены, получил бы уже похороненный
        // номер и был бы закрыт хвостом той попытки.
        let restarting = capturing
        if restarting {
            // Worker перезапускает захват сам, но подписчики прошлой сессии
            // иначе остались бы открытыми и без событий до следующего стопа.
            Self.log.notice("start during active capture — retiring session \(self.captureSession, privacy: .public)")
            capturing = false
            finishTranscriptSubscribers(upTo: captureSession)
        }
        captureSession &+= 1
        // При рестарте в трубе ещё может стоять хвост прошлой записи, а в
        // событиях транскрипта нет номера сессии — до `ready` новой записи
        // не помечаем ничего, иначе старые строки уедут новым подписчикам.
        emittingSession = restarting ? nil : captureSession
        startInFlight = true
        stopRequestedDuringStart = false
        defer { startInFlight = false }

        let id = UUID().uuidString
        do {
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
        } catch {
            stopRequestedDuringStart = false
            // Попытка съела номер сессии: подписчики, ждавшие именно её,
            // иначе молчали бы до следующего стопа — ретрай уедет на
            // следующий номер, и транскрипт до них не дойдёт.
            finishTranscriptSubscribers(upTo: captureSession)
            throw error
        }

        if stopRequestedDuringStart {
            // `stopCapture` пришёл, пока ждали `ready`: worker уже пишет —
            // гасим его сразу, сессию не открываем, `capturing` не выставляем.
            stopRequestedDuringStart = false
            try? sendCommand(.init(cmd: AudioWorkerCommand.stopCapture, requestId: stopRequestId(for: captureSession)))
            awaitGoodbyeThenFinishTranscripts(upTo: captureSession)
            Self.log.notice("audio capture cancelled: stop requested during start")
            return
        }

        capturing = true
        emittingSession = captureSession
        let requestedURL = SessionStore.makeURL(in: sessionDirectory)
        do {
            let store = try SessionStore(at: requestedURL)
            sessionStore = store
            // `store.url` может отличаться суффиксом `-N`, если имя было занято.
            lastSessionURL = store.url
        } catch {
            Self.log.error("session store creation failed: \(requestedURL.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        Self.log.notice("audio capture started discord_pid=\(discordPid.map(String.init) ?? "none") locale=\(locale) onDevice=\(onDeviceRecognition) echo=\(echoSuppression)")
    }

    /// Останавливает запись. Worker остаётся жить (готов к следующей сессии).
    /// Если `startCapture` ещё ждёт `ready` — остановка откладывается до его
    /// возвращения и выполняется там (см. `stopRequestedDuringStart`).
    public func stopCapture() async {
        if startInFlight {
            stopRequestedDuringStart = true
            Self.log.notice("audio stop requested during start — deferred")
            return
        }
        guard capturing else { return }
        try? sendCommand(.init(cmd: AudioWorkerCommand.stopCapture, requestId: stopRequestId(for: captureSession)))
        capturing = false
        awaitGoodbyeThenFinishTranscripts(upTo: captureSession)
        Self.log.notice("audio capture stopped")
    }

    /// Полное завершение: shutdown worker'а + ожидание exit'а + SIGKILL fallback.
    /// Симметрично `MLXSupervisor.unloadModel`: shutdown-команда пишется с
    /// таймаутом, чтобы зависший worker (полный pipe) не блокировал SIGKILL.
    public func shutdown() async {
        guard let workerPid = host.currentPid() else { return }
        if let data = try? JSONEncoder().encode(
            AudioWorkerCommand(cmd: AudioWorkerCommand.shutdown, requestId: UUID().uuidString)
        ) {
            let sent = await host.writeWithTimeout(data, timeout: .seconds(1))
            if !sent {
                Self.log.warning("shutdown command write stalled for pid=\(workerPid, privacy: .public) — falling back to exit wait + SIGKILL")
            }
        }
        let exited = await host.waitForExit(timeout: .seconds(3))
        if !exited {
            await host.sigkill()
        }
        cleanup()
    }

    // MARK: - Worker spawn

    private func ensureWorkerSpawned() throws {
        ensurePipePump()
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

    /// Единственный потребитель `pipeEvents` — строки и exit доставляются в
    /// actor в порядке pipe'а. Живёт всю жизнь supervisor'а, отменяется в deinit.
    private func ensurePipePump() {
        guard pipePump == nil else { return }
        let events = pipeEvents
        pipePump = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case .line(let line, let gen):
                    guard await self.isCurrentGeneration(gen) else { continue }
                    await self.handleLine(line)
                case .exit(let pid, let status, let gen):
                    guard await self.isCurrentGeneration(gen) else {
                        Self.log.notice("dropping exit of stale audio worker gen=\(gen) pid=\(pid)")
                        continue
                    }
                    await self.handleWorkerExit(pid: pid, status: status)
                }
            }
        }
    }

    private func isCurrentGeneration(_ gen: UInt64) -> Bool {
        host.currentGeneration() == gen
    }

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
            guard let emitting = emittingSession else { break }
            for sub in subscribers.values where sub.session == emitting {
                sub.continuation.yield(te)
            }

        case AudioWorkerEvent.error:
            if let id = event.requestId, let cont = pendingRequests.removeValue(forKey: id) {
                cont.resume(throwing: AudioSupervisorError.captureFailed(event.message ?? "unknown"))
            } else {
                Self.log.error("audio worker error: \(event.message ?? "unknown", privacy: .public)")
            }

        case AudioWorkerEvent.goodbye:
            // Worker подтвердил конец записи (ответ на stopCapture/shutdown)
            // и, по порядку протокола, уже отдал весь транскрипт до него.
            // Здесь и закрываем подписки: иначе клиент ждёт вечно даже после
            // остановки с другого соединения. Сессию берём по requestId той
            // стоп-команды — опоздавший `goodbye` не должен обрывать запись,
            // начатую после него. Без совпадения (shutdown, старый worker)
            // закрываем текущую.
            if let rid = event.requestId, let stopped = pendingStops.removeValue(forKey: rid) {
                // Запись могли уже перезапустить: гасим флаг только если
                // остановлена именно текущая сессия, иначе `stopCapture`
                // следующей вернулся бы на `guard capturing`, пока worker
                // продолжает писать.
                if stopped >= captureSession { capturing = false }
                finishTranscriptSubscribers(upTo: stopped)
            } else if event.requestId == nil || pendingStops.isEmpty {
                // shutdown или worker без requestId — закрываем текущую.
                capturing = false
                finishTranscriptSubscribers(upTo: emittingSession ?? captureSession)
            } else {
                Self.log.notice("goodbye with unknown requestId — ignored")
            }

        case AudioWorkerEvent.pong:
            if let id = event.requestId, let cont = pendingRequests.removeValue(forKey: id) {
                cont.resume()
            }

        default:
            break
        }
    }

    /// Конец потока транскрипта = `continuation.finish()`. Финальность
    /// отдельного сегмента этим не является: остановка записи приходит не из
    /// потока событий, а от `stopCapture`/`goodbye`, и без явного закрытия
    /// подписчик (`froggy listen-stream`, MCP-консьюмер) висит после конца
    /// записи — в том числе когда остановку инициировал другой клиент.
    private func finishTranscriptSubscribers(upTo session: UInt64) {
        transcriptFinishTask?.cancel()
        transcriptFinishTask = nil
        if sessionAwaitingGoodbye.map({ $0 <= session }) ?? false { sessionAwaitingGoodbye = nil }
        if emittingSession.map({ $0 <= session }) ?? false { emittingSession = nil }
        for (id, sub) in subscribers where sub.session <= session {
            sub.continuation.finish()
            subscribers.removeValue(forKey: id)
        }
    }

    /// Все подписки разом — worker умер, следующей сессии у этих стримов нет.
    private func finishAllTranscriptSubscribers() {
        finishTranscriptSubscribers(upTo: .max)
    }

    /// Закрываем подписки не на самой команде стопа, а на `goodbye`: в
    /// `pipeEvents` может стоять уже записанная worker'ом, но ещё не
    /// доставленная строка транскрипта, а протокол упорядочен — `goodbye`
    /// приходит после всего предыдущего вывода. Таймер — страховка: без
    /// `goodbye` (старый worker, крэш между командой и ответом) подписчик
    /// иначе висел бы снова.
    private func awaitGoodbyeThenFinishTranscripts(upTo session: UInt64) {
        sessionAwaitingGoodbye = session
        guard subscribers.values.contains(where: { $0.session <= session }) else { return }
        transcriptFinishTask?.cancel()
        transcriptFinishTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return  // отменены `goodbye`-веткой: подписки уже закрыты
            }
            guard !Task.isCancelled else { return }
            await self?.finishTranscriptsAfterGoodbyeTimeout(session: session)
        }
    }

    /// requestId стоп-команды, по которому потом опознаётся её `goodbye`.
    private func stopRequestId(for session: UInt64) -> String {
        let id = UUID().uuidString
        pendingStops[id] = session
        return id
    }

    /// Незакрытая прошлая сессия разрешается на входе в новую запись: иначе
    /// её таймер сработал бы уже во время новой. Закрываем только подписки
    /// остановленной сессии — те, кто подписался на следующую, продолжают
    /// ждать её транскрипт.
    private func resolvePendingGoodbyeFallback() {
        guard let pending = sessionAwaitingGoodbye else { return }
        Self.log.notice("new capture before goodbye — closing subscriptions of session \(pending, privacy: .public)")
        finishTranscriptSubscribers(upTo: pending)
    }

    private func finishTranscriptsAfterGoodbyeTimeout(session: UInt64) {
        pendingStops = pendingStops.filter { $0.value != session }
        guard subscribers.values.contains(where: { $0.session <= session }) else { return }
        Self.log.warning("no goodbye within 2s after stop — closing transcript subscriptions")
        finishTranscriptSubscribers(upTo: session)
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
        pendingStops.removeAll()
        finishAllTranscriptSubscribers()
        capturing = false
        stopRequestedDuringStart = false
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
