import CoreGraphics
import Foundation
import os
import ScreenCaptureKit
import Vision

/// Снимки экрана + OCR. Все мутации состояния — через actor.
public actor VisionActor {
    private static let log = Logger(subsystem: "com.froggychips.froggy", category: "vision")
    private static let isoStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private var isCapturing = false
    private let stateFilePath: URL
    private let captureInterval: Duration

    public init(captureInterval: Duration = .seconds(2)) {
        self.captureInterval = captureInterval
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
                break // отмена
            }
        }
    }

    public func stopCapture() {
        isCapturing = false
    }

    // MARK: - Capture

    private func runCycle() async {
        do {
            guard let image = try await captureMainDisplay() else { return }
            let strings = await Self.recognizeText(image: image)
            await writeState(strings: strings)
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
        await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
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
                Self.log.error("vision request failed: \(error.localizedDescription)")
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
            // Atomic write пересоздаёт файл; права надо выставить заново.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: stateFilePath.path
            )
        } catch {
            Self.log.error("state write failed: \(error.localizedDescription)")
        }
    }
}
