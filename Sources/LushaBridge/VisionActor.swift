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
    /// Отдельный signposter в категории `PointsOfInterest` — Instruments
    /// автоматически визуализирует это в одноимённом track'е без ручного
    /// `.instrpkg`. Используется для frame-budget overlay'я при profile'е.
    /// Dev-tool, не меняет behaviour в release-сборке.
    private static let poi = OSSignposter(subsystem: "com.froggychips.froggy", category: "PointsOfInterest")
    private static let isoStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    /// Монотонный счётчик кадров — попадает в metadata signpost'а как
    /// `frame_id=…`, чтобы в Instruments было видно конкретный цикл.
    private var frameCounter: UInt64 = 0

    private var isCapturing = false
    private var lastDigest: FrameDigest?
    private let stateFilePath: URL
    private let captureInterval: Duration
    private let redactor: Redactor
    private let contextStore: ContextStore?
    private let frameSimilarityThreshold: Double
    private let screenStream: ScreenStream
    /// Внутренний gate: «не запускать OCR чаще, чем раз в `captureInterval`»
    /// (FCP-1, ADR 0011). Frame, пришедший раньше окна, дропается без
    /// буферизации. Существует параллельно с polling-sleep'ом ниже —
    /// внешний sleep остаётся как cooperative-yield, internal pacer — как
    /// authoritative-gate.
    private var pacer: FramePacer

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
        self.pacer = FramePacer(interval: captureInterval)
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

    /// Тестовый seam: заменить time-source pacer'а на fake-clock. Public
    /// API (init выше) трогать не хочется — продакшн всегда использует
    /// `ContinuousClock`. Возвращаем pacer reference в тест через `runCycle`
    /// нельзя (actor isolation), поэтому даём перезаливку.
    func _setPacerClock(now: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.pacer = FramePacer(interval: captureInterval, now: now)
    }

    /// Тестовый seam: один прогон pacer'а без обращения к SCStream и OCR.
    /// Возвращает `true` если кадр был бы admitted (то есть pacer пропустил
    /// бы pipeline дальше).
    func _admitForTest() -> Bool {
        pacer.shouldAdmit()
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
            Self.log.error("screen stream failed to start: \(error.localizedDescription, privacy: .private)")
            isCapturing = false
            return
        }

        defer {
            Task { [screenStream] in await screenStream.stop() }
            isCapturing = false
            Self.log.info("capture loop stopped")
        }

        // Внешний sleep больше не authoritative-pacing: реальный gate —
        // `FramePacer` внутри runCycle (FCP-1). Здесь оставлен короткий
        // poll-interval как cooperative-yield + защита от hot-spin (когда
        // `latestFrame()` возвращает один и тот же кадр многократно).
        // Берём min(captureInterval, 100ms): для маленьких captureInterval
        // (например 0 — throttle off) не хотим спать дольше, чем pacer
        // допустит обработку.
        let pollInterval = pollIntervalFor(captureInterval)

        while isCapturing && !Task.isCancelled {
            await runCycle()
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                break
            }
        }
    }

    /// Polling-кадр-интервал. Быстрее, чем `captureInterval`, но не настолько,
    /// чтобы спалить CPU. Для `captureInterval == 0` (throttle off) тоже
    /// кладём минимальный sleep — без него цикл превращается в busy-loop.
    private func pollIntervalFor(_ interval: Duration) -> Duration {
        let upperBoundMs = 100
        let intervalMs = interval.inMilliseconds
        if intervalMs <= 0 {
            return .milliseconds(10)
        }
        return .milliseconds(min(upperBoundMs, max(10, intervalMs / 4)))
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

        // POI-уровень: один interval на весь pipeline (capture → digest →
        // ocr → redact → ContextStore.append). В Instruments → Points of
        // Interest сразу виден frame-budget per кадр.
        frameCounter &+= 1
        let frameId = frameCounter
        let poiId = Self.poi.makeSignpostID()
        let poiState = Self.poi.beginInterval("frame_pipeline", id: poiId, "frame_id=\(frameId)")
        var ocrChars = 0
        var skipped = false
        defer {
            Self.poi.endInterval(
                "frame_pipeline",
                poiState,
                "frame_id=\(frameId) ocr_chars=\(ocrChars) skipped=\(skipped ? 1 : 0)"
            )
        }

        guard let box = await screenStream.latestFrame() else {
            // ещё не пришёл первый кадр (или TCC denied). Просто ждём.
            // Pacer не трогаем: дроп без админa = окно остаётся открытым,
            // как только реальный кадр придёт — он будет admitted.
            skipped = true
            return
        }

        // FCP-1: внутренний throttle. Если кадр пришёл раньше окна
        // `captureInterval` — дропаем, не вызывая ни digest, ни OCR, ни
        // redact, ни ContextStore. Без буферизации — ровно как требует
        // ADR 0011.
        guard pacer.shouldAdmit() else {
            Self.signposter.emitEvent("framePacerDropped", id: .exclusive)
            skipped = true
            return
        }

        let image = box.image

        // Frame-diff: пропускаем OCR на не изменившихся экранах.
        if let digest = FrameDigest(image: image) {
            if let prev = lastDigest,
               digest.similarity(to: prev) >= frameSimilarityThreshold
            {
                Self.signposter.emitEvent("frameSkipped", id: .exclusive)
                skipped = true
                return
            }
            lastDigest = digest
        }

        let strings = await Self.recognizeText(image: image)
        let redacted = redactor.redact(strings)
        ocrChars = redacted.reduce(0) { $0 + $1.count }
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
                log.error("vision request failed: \(error.localizedDescription, privacy: .private)")
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
            Self.log.error("state write failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}

/// Helper: `Duration.toSeconds` / `inMilliseconds` — public нет,
/// реконструируем из components.
private extension Duration {
    var toSeconds: Double {
        let comp = components
        return Double(comp.seconds) + Double(comp.attoseconds) / 1e18
    }

    /// Округлённое количество миллисекунд (Int, может быть 0). Используется
    /// для polling-интервала: точность до 1ms здесь избыточна.
    var inMilliseconds: Int {
        let comp = components
        let ms = comp.seconds * 1_000 + comp.attoseconds / 1_000_000_000_000_000
        // attoseconds — Int64; для разумных Duration не переполняется в Int.
        return Int(ms)
    }
}
