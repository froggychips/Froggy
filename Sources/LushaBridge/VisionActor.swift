import CoreGraphics
import Foundation
import os
import Vision

/// Снимки экрана + OCR. Все мутации состояния — через actor.
/// Phase 4: захват кадров делегирован persistent `ScreenStream` (Phase 2
/// делал `SCScreenshotManager.captureImage` на каждом цикле — это тратило
/// 100–200 мс на discovery).
public actor VisionActor {
    private static let log = Logger(subsystem: "com.froggychips.froggy", category: "vision")
    private static let signposter = OSSignposter(subsystem: "com.froggychips.froggy", category: "vision")
    private static let isoStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private var isCapturing = false
    private var lastDigest: FrameDigest?
    private let stateFilePath: URL
    private let captureInterval: Duration
    private let redactor: Redactor
    private let contextStore: ContextStore?
    private let frameSimilarityThreshold: Double
    private let screenStream: ScreenStream

    public init(
        captureInterval: Duration = .seconds(2),
        redactor: Redactor = Redactor(),
        contextStore: ContextStore? = nil,
        frameSimilarityThreshold: Double = 0.98,
        screenStream: ScreenStream = ScreenStream()
    ) {
        self.captureInterval = captureInterval
        self.redactor = redactor
        self.contextStore = contextStore
        self.frameSimilarityThreshold = frameSimilarityThreshold
        self.screenStream = screenStream
        let supportDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Froggy", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: supportDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        self.stateFilePath = supportDir.appendingPathComponent("state.json")
    }

    public func stateFileURL() -> URL { stateFilePath }

    /// Запускает persistent stream + цикл OCR. Кооперативно прерывается
    /// по `Task.isCancelled`.
    public func startCapture() async {
        guard !isCapturing else { return }
        isCapturing = true
        Self.log.info("capture loop started")

        // Стартуем stream один раз. Frame rate берём из captureInterval —
        // мы всё равно опрашиваем latestFrame() в этом темпе.
        let intervalSec = max(0.1, captureInterval.toSeconds)
        let frameRateHz = max(0.5, 1.0 / intervalSec)
        do {
            try await screenStream.start(frameRateHz: frameRateHz)
        } catch {
            Self.log.error("screen stream failed to start: \(error.localizedDescription)")
            isCapturing = false
            return
        }

        defer {
            Task { [screenStream] in await screenStream.stop() }
            isCapturing = false
            Self.log.info("capture loop stopped")
        }

        while isCapturing && !Task.isCancelled {
            await runCycle()
            do {
                try await Task.sleep(for: captureInterval)
            } catch {
                break
            }
        }
    }

    public func stopCapture() {
        isCapturing = false
    }

    public func capturing() -> Bool { isCapturing }

    /// Текстовое описание последней ошибки stream'a — для статус-IPC.
    /// nil если всё хорошо.
    public func lastCaptureError() async -> String? {
        await screenStream.lastErrorMessage()
    }

    // MARK: - Capture cycle

    private func runCycle() async {
        let interval = Self.signposter.beginInterval("captureCycle")
        defer { Self.signposter.endInterval("captureCycle", interval) }

        guard let box = await screenStream.latestFrame() else {
            // ещё не пришёл первый кадр (или TCC denied). Просто ждём.
            return
        }
        let image = box.image

        // Frame-diff: пропускаем OCR на не изменившихся экранах.
        if let digest = FrameDigest(image: image) {
            if let prev = lastDigest,
               digest.similarity(to: prev) >= frameSimilarityThreshold
            {
                Self.signposter.emitEvent("frameSkipped", id: .exclusive)
                return
            }
            lastDigest = digest
        }

        let strings = await Self.recognizeText(image: image)
        let redacted = redactor.redact(strings)
        await writeState(strings: redacted)
        await contextStore?.push(lines: redacted)
    }

    // MARK: - OCR

    /// Распознавание текста. `nonisolated` + `Sendable`-возврат, чтобы тяжёлая работа
    /// не блокировала actor (Vision сам прыгнет в свой пул).
    nonisolated private static func recognizeText(image: CGImage) async -> [String] {
        let interval = signposter.beginInterval("ocr")
        defer { signposter.endInterval("ocr", interval) }

        return await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
            let request = VNRecognizeTextRequest { req, _ in
                let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
                let strings = observations.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: strings)
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ru-RU", "en-US"]
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                log.error("vision request failed: \(error.localizedDescription)")
                continuation.resume(returning: [])
            }
        }
    }

    // MARK: - State persistence

    private func writeState(strings: [String]) async {
        let payload: [String: Any] = [
            "timestamp": Date.now.formatted(Self.isoStyle),
            "recognized_text": strings,
            "architecture": "arm64",
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
        ) else { return }

        do {
            try data.write(to: stateFilePath, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: stateFilePath.path
            )
        } catch {
            Self.log.error("state write failed: \(error.localizedDescription)")
        }
    }
}

/// Helper: `Duration.toSeconds` — public нет, реконструируем из components.
private extension Duration {
    var toSeconds: Double {
        let comp = components
        return Double(comp.seconds) + Double(comp.attoseconds) / 1e18
    }
}
