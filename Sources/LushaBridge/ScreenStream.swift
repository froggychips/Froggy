import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import os
import ScreenCaptureKit

/// CGImage не Sendable, но ScreenStream должен передавать его через actor-границу
/// в VisionActor. Боксируем «обещанием руками не трогать»: к моменту, когда
/// потребитель получает CGImage, мы его уже не модифицируем.
public struct CGImageBox: @unchecked Sendable {
    public let image: CGImage
    public init(_ image: CGImage) { self.image = image }
}

/// Постоянный SCStream вместо `SCScreenshotManager.captureImage` на каждый цикл.
/// SCShareableContent.excludingDesktopWindows стоит ~100–200 мс — вызов раз
/// при `start()` экономит этот overhead на каждом кадре.
public actor ScreenStream {
    private static let log = Logger(subsystem: "com.froggychips.froggy", category: "screen-stream")

    public enum StreamError: Error, Sendable, CustomStringConvertible {
        case noDisplay
        case scStream(String)

        public var description: String {
            switch self {
            case .noDisplay: return "no displays available"
            case let .scStream(m): return "SCStream error: \(m)"
            }
        }
    }

    private var stream: SCStream?
    private var sink: FrameSink?

    public init() {}

    public func isRunning() -> Bool { stream != nil }

    /// Запускает persistent stream. Конфигурация фиксированная: главный
    /// дисплей, без курсора, BGRA, частота кадров — `frameRateHz`.
    public func start(frameRateHz: Double = 1.0) async throws {
        guard stream == nil else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw StreamError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(
            seconds: max(1.0 / max(frameRateHz, 0.1), 0.05),
            preferredTimescale: 600
        )
        config.queueDepth = 3

        let sink = FrameSink()
        let s = SCStream(filter: filter, configuration: config, delegate: sink)
        do {
            try s.addStreamOutput(sink, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
            try await s.startCapture()
        } catch {
            throw StreamError.scStream(error.localizedDescription)
        }
        self.stream = s
        self.sink = sink
        Self.log.info("stream started, frameRate=\(frameRateHz)Hz")
    }

    public func stop() async {
        guard let s = stream else { return }
        try? await s.stopCapture()
        stream = nil
        sink = nil
        Self.log.info("stream stopped")
    }

    /// nil — ещё не пришёл ни один кадр (или TCC denied).
    public func latestFrame() -> CGImageBox? {
        guard let cg = sink?.snapshot() else { return nil }
        return CGImageBox(cg)
    }

    /// Текстовое описание последней ошибки stream'a (для статус-IPC).
    public func lastErrorMessage() -> String? {
        sink?.snapshotError()
    }
}

/// `SCStreamOutput` живёт на dispatch-очереди, поэтому это `class` с lock'ом.
/// Actor использовать нельзя — SCStream не зовёт обратные вызовы через
/// async, и protocol требует `@objc`-метод.
private final class FrameSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CGImage?
    private var lastError: Error?
    private let ciContext = CIContext(options: nil)

    func snapshot() -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    func snapshotError() -> String? {
        lock.lock(); defer { lock.unlock() }
        return lastError.map { String(describing: $0) }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let pixel = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        let ci = CIImage(cvPixelBuffer: pixel)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        lock.lock()
        latest = cg
        // Успешный кадр → сбросить остаток stale-error: например пользователь
        // перезапустил демон после того как разрешил Screen Recording. Иначе
        // TCC-banner в menubar остался бы гореть навсегда.
        lastError = nil
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lock.lock()
        lastError = error
        lock.unlock()
    }
}
