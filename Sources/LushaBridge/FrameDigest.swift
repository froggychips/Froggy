import CoreGraphics
import Foundation

/// 32×32 grayscale «отпечаток» кадра. Дёшево считается, дёшево сравнивается.
/// Используется VisionActor'ом, чтобы пропускать OCR на не изменившихся экранах.
public struct FrameDigest: Sendable, Equatable {
    public let size: Int
    public let bytes: [UInt8]

    /// nil только если CGContext не создаётся (out-of-memory).
    public init?(image: CGImage, size: Int = 32) {
        let bytesPerRow = size
        guard let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let raw = ctx.data else { return nil }
        let buffer = UnsafeBufferPointer(
            start: raw.assumingMemoryBound(to: UInt8.self),
            count: size * size
        )
        self.size = size
        self.bytes = Array(buffer)
    }

    /// Тестовый/стабильный конструктор.
    public init(size: Int, bytes: [UInt8]) {
        precondition(bytes.count == size * size)
        self.size = size
        self.bytes = bytes
    }

    /// 1.0 — кадры идентичны, 0.0 — максимально разные.
    /// Метрика: 1 - средняя нормированная разница пикселей.
    public func similarity(to other: FrameDigest) -> Double {
        guard size == other.size, !bytes.isEmpty else { return 0 }
        var totalDiff: Int = 0
        for i in 0..<bytes.count {
            totalDiff += abs(Int(bytes[i]) - Int(other.bytes[i]))
        }
        let maxDiff = Double(bytes.count) * 255.0
        return 1.0 - (Double(totalDiff) / maxDiff)
    }
}
