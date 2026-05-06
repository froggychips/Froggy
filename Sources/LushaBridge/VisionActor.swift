import CoreGraphics
import Foundation
import os
import ScreenCaptureKit
import Vision

/// Снимки экрана + OCR. Все мутации состояния — через actor.
/// Phase 2 добавил frame-diff (пропуск OCR при неизменном экране),
/// redaction секретов перед записью и push в `ContextStore`.
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

    public init(
        captureInterval: Duration = .seconds(2),
        redactor: Redactor = Redactor(),
        contextStore: ContextStore? = nil,
        frameSimilarityThreshold: Double = 0.98
    ) {
        self.captureInterval = captureInterval
        self.redactor = redactor
        self.contextStore = contextStore
        self.frameSimilarityThreshold = frameSimilarityThreshold
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

    /// Запускает цикл захвата. Кооперативно реагирует на `Task.isCancelled`,
    /// поэтому отмена внешней Task сразу прервёт цикл.
    public func startCapture() async {
        guard !isCapturing else { return }
        isCapturing = true
        Self.log.info("capture loop started")

        defer {
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

    // MARK: - Capture

    private func runCycle() async {
        let interval = Self.signposter.beginInterval("captureCycle")
        defer { Self.signposter.endInterval("captureCycle", interval) }

        do {
            guard let image = try await captureMainDisplay() else { return }

            // Frame-diff: если экран почти не изменился — OCR пропускаем.
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
        } catch {
            Self.log.error("capture cycle failed: \(error.localizedDescription)")
        }
    }

    /// ScreenCaptureKit-захват главного дисплея. Заменяет deprecated `CGDisplayCreateImage`.
    private func captureMainDisplay() async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else { return nil }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        )
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
