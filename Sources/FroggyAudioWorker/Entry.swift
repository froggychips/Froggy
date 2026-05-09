import AudioToolbox
import AudioWorkerProtocol
import AVFoundation
import CoreAudio
import Foundation
import Speech
import os

/// FroggyAudioWorker — отдельный процесс, захватывающий аудио Discord через
/// CATapDescription (macOS 14.2+) и микрофон через AVAudioEngine.
/// Транскрипция — SFSpeechRecognizer. Демон управляет им через AudioSupervisor
/// по тому же stdin/stdout JSON-line протоколу, что и FroggyMLXWorker.

@main
struct FroggyAudioWorker {
    static func main() {
        let log = Logger(subsystem: "com.froggychips.froggy.audio", category: "worker")
        log.notice("audio worker started pid=\(getpid())")

        let cli = CLIFlags.parse(CommandLine.arguments)
        let runtime = AudioRuntime(log: log, defaultDiscordPid: cli.discordPid)
        runtime.start()

        // CoreAudio и SFSpeechRecognizer требуют живого RunLoop на main thread.
        RunLoop.main.run()
    }
}

struct CLIFlags {
    var discordPid: Int32?

    static func parse(_ argv: [String]) -> CLIFlags {
        var out = CLIFlags()
        var i = 1
        while i < argv.count {
            if argv[i] == "--discord-pid", i + 1 < argv.count, let pid = Int32(argv[i + 1]) {
                out.discordPid = pid
                i += 2
            } else {
                i += 1
            }
        }
        return out
    }
}

// MARK: - Runtime

final class AudioRuntime: @unchecked Sendable {
    private let log: Logger
    private let defaultDiscordPid: Int32?
    private let stdout = FileHandle.standardOutput
    private var buffer = Data()

    // Audio state (доступ только из main thread через RunLoop callbacks)
    private var discordEngine: AVAudioEngine?
    private var micEngine: AVAudioEngine?
    private var tapDeviceID: AudioDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioDeviceID = AudioObjectID(kAudioObjectUnknown)

    // Speech recognition
    private var recognizer: SFSpeechRecognizer?
    private var discordRequest: SFSpeechAudioBufferRecognitionRequest?
    private var discordTask: SFSpeechRecognitionTask?
    private var micRequest: SFSpeechAudioBufferRecognitionRequest?
    private var micTask: SFSpeechRecognitionTask?

    init(log: Logger, defaultDiscordPid: Int32?) {
        self.log = log
        self.defaultDiscordPid = defaultDiscordPid
    }

    func start() {
        // Читаем stdin в фоновой очереди чтобы не блокировать main RunLoop.
        let stdinHandle = FileHandle.standardInput
        stdinHandle.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            if data.isEmpty {
                self?.shutdown()
                return
            }
            self?.feedStdin(data)
        }

        // Запрашиваем permission на speech recognition заранее.
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            self?.log.notice("speech auth: \(String(describing: status).lowercased())")
        }

        write(.init(event: AudioWorkerEvent.ready))
        log.notice("audio worker ready")
    }

    // MARK: - Stdin parsing

    private func feedStdin(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let endOffset = buffer.distance(from: buffer.startIndex, to: nl)
            let line = Data(buffer.prefix(endOffset))
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let cmd = try? JSONDecoder().decode(AudioWorkerCommand.self, from: line) else {
                write(.init(event: AudioWorkerEvent.error, message: "malformed command"))
                continue
            }
            dispatch(cmd)
        }
    }

    private func dispatch(_ cmd: AudioWorkerCommand) {
        switch cmd.cmd {
        case AudioWorkerCommand.ping:
            write(.init(event: AudioWorkerEvent.pong, requestId: cmd.requestId))

        case AudioWorkerCommand.startCapture:
            let pid = cmd.discordPid ?? defaultDiscordPid
            let locale = cmd.locale ?? "ru-RU"
            let onDevice = cmd.onDeviceRecognition ?? true
            DispatchQueue.main.async { [weak self] in
                self?.startCapture(discordPid: pid, requestId: cmd.requestId,
                                   locale: locale, onDeviceRecognition: onDevice)
            }

        case AudioWorkerCommand.stopCapture:
            DispatchQueue.main.async { [weak self] in
                self?.stopCapture()
                self?.write(.init(event: AudioWorkerEvent.goodbye, requestId: cmd.requestId))
            }

        case AudioWorkerCommand.shutdown:
            DispatchQueue.main.async { [weak self] in
                self?.stopCapture()
                self?.write(.init(event: AudioWorkerEvent.goodbye, requestId: cmd.requestId))
                exit(0)
            }

        default:
            write(.init(event: AudioWorkerEvent.error, requestId: cmd.requestId,
                        message: "unknown cmd: \(cmd.cmd)"))
        }
    }

    // MARK: - Capture lifecycle (main thread)

    private func startCapture(discordPid: Int32?, requestId: String?, locale: String, onDeviceRecognition: Bool) {
        stopCapture() // clean slate

        recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
        recognizer?.defaultTaskHint = .dictation

        guard let recognizer, recognizer.isAvailable else {
            write(.init(event: AudioWorkerEvent.error, requestId: requestId,
                        message: "SFSpeechRecognizer unavailable"))
            return
        }

        // --- Discord tap ---
        if let pid = discordPid, #available(macOS 14.2, *) {
            do {
                let (tapAggDeviceID, tapAggTapID) = try createDiscordTap(pid: pid)
                self.tapID = tapAggTapID
                self.aggregateDeviceID = tapAggDeviceID
                startDiscordEngine(aggregateDeviceID: tapAggDeviceID, recognizer: recognizer,
                                   onDeviceRecognition: onDeviceRecognition)
            } catch {
                log.error("discord tap failed: \(error.localizedDescription, privacy: .public)")
                write(.init(event: AudioWorkerEvent.error, requestId: requestId,
                            message: "tap failed: \(error.localizedDescription)"))
                // fallback: только mic
            }
        } else if discordPid != nil {
            write(.init(event: AudioWorkerEvent.error, requestId: requestId,
                        message: "CATapDescription requires macOS 14.2+"))
        }

        // --- Mic ---
        startMicEngine(recognizer: recognizer, onDeviceRecognition: onDeviceRecognition)

        write(.init(event: AudioWorkerEvent.ready, requestId: requestId))
        log.notice("capture started discord_pid=\(discordPid.map(String.init) ?? "none")")
    }

    private func stopCapture() {
        discordTask?.cancel()
        discordTask = nil
        discordRequest?.endAudio()
        discordRequest = nil

        micTask?.cancel()
        micTask = nil
        micRequest?.endAudio()
        micRequest = nil

        discordEngine?.stop()
        discordEngine?.inputNode.removeTap(onBus: 0)
        discordEngine = nil

        micEngine?.stop()
        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine = nil

        destroyTapResources()
        log.notice("capture stopped")
    }

    private func shutdown() {
        stopCapture()
        exit(0)
    }

    // MARK: - Discord tap engine (main thread)

    @available(macOS 14.2, *)
    private func startDiscordEngine(aggregateDeviceID: AudioDeviceID, recognizer: SFSpeechRecognizer, onDeviceRecognition: Bool) {
        let discordEngine = AVAudioEngine()
        self.discordEngine = discordEngine

        // Переключаем input на aggregate device (содержит tap).
        let inputNode = discordEngine.inputNode
        let inputUnit = inputNode.audioUnit!
        var devID = aggregateDeviceID
        AudioUnitSetProperty(
            inputUnit,
            AudioUnitPropertyID(kAudioOutputUnitProperty_CurrentDevice),
            AudioUnitScope(kAudioUnitScope_Global),
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = onDeviceRecognition
        self.discordRequest = req

        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak req] buffer, _ in
            req?.append(buffer)
        }

        do {
            try discordEngine.start()
        } catch {
            log.error("discord engine start failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        self.discordTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                self?.write(.init(
                    event: AudioWorkerEvent.transcript,
                    text: text,
                    isFinal: result.isFinal,
                    speaker: "discord"
                ))
            }
            if let error {
                self?.log.warning("discord recognition error: \(error.localizedDescription, privacy: .public)")
                // Перезапускаем задачу (1-минутный лимит SFSpeechRecognizer)
                if let eng = self?.discordEngine, eng.isRunning {
                    self?.restartDiscordTask(recognizer: recognizer)
                }
            }
        }
    }

    private func restartDiscordTask(recognizer: SFSpeechRecognizer) {
        discordTask?.cancel()
        discordRequest?.endAudio()

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        self.discordRequest = req

        self.discordTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                self?.write(.init(
                    event: AudioWorkerEvent.transcript,
                    text: text,
                    isFinal: result.isFinal,
                    speaker: "discord"
                ))
            }
            if let error, let eng = self?.discordEngine, eng.isRunning {
                self?.log.warning("discord task restart error: \(error.localizedDescription, privacy: .public)")
                self?.restartDiscordTask(recognizer: recognizer)
            }
        }
    }

    // MARK: - Mic engine (main thread)

    private func startMicEngine(recognizer: SFSpeechRecognizer, onDeviceRecognition: Bool) {
        let micEngine = AVAudioEngine()
        let inputNode = micEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = onDeviceRecognition
        self.micRequest = req

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak req] buffer, _ in
            req?.append(buffer)
        }

        do {
            try micEngine.start()
        } catch {
            log.error("mic engine start failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        self.micTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                self?.write(.init(
                    event: AudioWorkerEvent.transcript,
                    text: text,
                    isFinal: result.isFinal,
                    speaker: "mic"
                ))
            }
            if let error, let eng = self?.micEngine, eng.isRunning {
                self?.log.warning("mic task error: \(error.localizedDescription, privacy: .public)")
            }
        }

        self.micEngine = micEngine
    }

    // MARK: - CATapDescription + aggregate device

    @available(macOS 14.2, *)
    private func createDiscordTap(pid: Int32) throws -> (AudioDeviceID, AudioObjectID) {
        // Resolve pid → AudioObjectID
        var processObjID = AudioObjectID(kAudioObjectUnknown)
        var inputPid = pid
        var prop = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyTranslatePIDToProcessObject),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let lookupStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &prop,
            UInt32(MemoryLayout<Int32>.size), &inputPid,
            &size, &processObjID
        )
        guard lookupStatus == noErr, processObjID != AudioObjectID(kAudioObjectUnknown) else {
            throw TapError.processNotFound(pid, lookupStatus)
        }

        // Создаём tap
        let tapDesc = CATapDescription(stereoMixdownOfProcesses: [processObjID])
        tapDesc.muteBehavior = .unmuted
        var createdTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDesc, &createdTapID)
        guard tapStatus == noErr else {
            throw TapError.tapCreationFailed(tapStatus)
        }
        let tapUID = tapDesc.uuid.uuidString.lowercased()

        // Aggregate device: tap as input + system output as clock
        let clockUID = systemOutputDeviceUID() ?? ""
        let aggUID = "com.froggychips.froggy.agg.\(UUID().uuidString)"

        let aggDict: NSDictionary = [
            kAudioAggregateDeviceNameKey:          "FroggyDiscordCapture",
            kAudioAggregateDeviceUIDKey:           aggUID,
            kAudioAggregateDeviceIsPrivateKey:     true,
            kAudioAggregateDeviceIsStackedKey:     false,
            kAudioAggregateDeviceTapListKey:       [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey:               tapUID,
            ]],
            kAudioAggregateDeviceSubDeviceListKey: clockUID.isEmpty ? [] : [[
                kAudioSubDeviceUIDKey: clockUID,
            ]],
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
        ]

        var aggDeviceID = AudioDeviceID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDict, &aggDeviceID)
        guard aggStatus == noErr, aggDeviceID != AudioObjectID(kAudioObjectUnknown) else {
            AudioHardwareDestroyProcessTap(createdTapID)
            throw TapError.aggregateCreationFailed(aggStatus)
        }

        log.notice("tap created tapID=\(createdTapID) aggDeviceID=\(aggDeviceID)")
        return (aggDeviceID, createdTapID)
    }

    private func destroyTapResources() {
        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            if #available(macOS 14.2, *) {
                AudioHardwareDestroyProcessTap(tapID)
            }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func systemOutputDeviceUID() -> String? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var prop = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyDefaultOutputDevice),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &prop, 0, nil, &size, &deviceID
        ) == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }

        var uidProp = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioDevicePropertyDeviceUID),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(deviceID, &uidProp, 0, nil, &uidSize, &uid) == noErr else {
            return nil
        }
        return uid as String
    }

    // MARK: - Output

    private func write(_ event: AudioWorkerEvent) {
        guard var data = try? JSONEncoder().encode(event) else { return }
        data.append(0x0A)
        stdout.write(data)
    }
}

// MARK: - Errors

enum TapError: Error, CustomStringConvertible {
    case processNotFound(Int32, OSStatus)
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)

    var description: String {
        switch self {
        case let .processNotFound(pid, s): return "process \(pid) not found (status=\(s))"
        case let .tapCreationFailed(s):   return "AudioHardwareCreateProcessTap failed (status=\(s))"
        case let .aggregateCreationFailed(s): return "aggregate device creation failed (status=\(s))"
        }
    }
}
