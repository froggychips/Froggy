import Foundation

/// Sliding window последних OCR-снапшотов.
/// Phase 6: добавлен опциональный семантический дедуп — если новый snapshot
/// похож на предыдущий выше порога, его не добавляем (экономим окно
/// контекста для уникальных экранов).
public actor ContextStore {
    public struct Snapshot: Sendable, Codable, Equatable {
        public let timestamp: Date
        public let lines: [String]

        public init(timestamp: Date, lines: [String]) {
            self.timestamp = timestamp
            self.lines = lines
        }
    }

    private var ring: [Snapshot] = []
    private let capacity: Int
    private let scorer: any SimilarityScorer
    private let dedupThreshold: Double

    /// - Parameters:
    ///   - capacity: размер ring buffer (>=1).
    ///   - scorer: чем мерять похожесть для дедупа. По умолчанию — `NoopSimilarityScorer`,
    ///     то есть дедуп выключен.
    ///   - dedupThreshold: similarity ≥ threshold → snapshot отбрасывается. 1.0 значит
    ///     «отбрасывать только идентичные», 0.0 — «всегда отбрасывать».
    public init(
        capacity: Int = 30,
        scorer: any SimilarityScorer = NoopSimilarityScorer(),
        dedupThreshold: Double = 0.85
    ) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.scorer = scorer
        self.dedupThreshold = dedupThreshold
    }

    public func push(lines: [String]) async {
        await push(Snapshot(timestamp: Date(), lines: lines))
    }

    public func push(_ snapshot: Snapshot) async {
        if let last = ring.last {
            let sim = await scorer.similarity(last.lines, snapshot.lines)
            if sim >= dedupThreshold { return }
        }
        ring.append(snapshot)
        if ring.count > capacity {
            ring.removeFirst(ring.count - capacity)
        }
    }

    public func snapshots() -> [Snapshot] { ring }

    public func count() -> Int { ring.count }

    /// Текстовая склейка последних снапшотов от старого к новому, бюджет
    /// в `maxChars` (Swift `String.count` — grapheme clusters).
    /// Если очередной snapshot не помещается целиком, обрезается префиксом —
    /// раньше блок просто пропускался, что давало неточные границы на не-ASCII.
    public func recentContext(maxChars: Int = 4096) -> String {
        guard !ring.isEmpty, maxChars > 0 else { return "" }
        let formatter = ISO8601DateFormatter()
        var blocks: [String] = []
        var remaining = maxChars
        for snap in ring.reversed() {
            let body = snap.lines.joined(separator: " ")
            let block = "[\(formatter.string(from: snap.timestamp))] \(body)"
            if block.count <= remaining {
                blocks.insert(block, at: 0)
                remaining -= block.count
                if !blocks.isEmpty { remaining -= 1 } // место под '\n' между блоками
            } else if blocks.isEmpty {
                // Самый свежий блок не помещается целиком — берём его prefix,
                // чтобы вообще что-то вернуть.
                blocks.append(String(block.prefix(remaining)))
                break
            } else {
                break
            }
        }
        return blocks.joined(separator: "\n")
    }

    public func clear() { ring.removeAll() }
}
