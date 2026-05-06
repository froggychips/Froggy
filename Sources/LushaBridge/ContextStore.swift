import Foundation

/// Sliding window последних OCR-снапшотов.
/// Доступен из IPC (`{"cmd":"context"}`) и из MLXActor для аугментации промпта.
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

    public init(capacity: Int = 30) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public func push(lines: [String]) {
        push(Snapshot(timestamp: Date(), lines: lines))
    }

    public func push(_ snapshot: Snapshot) {
        ring.append(snapshot)
        if ring.count > capacity {
            ring.removeFirst(ring.count - capacity)
        }
    }

    public func snapshots() -> [Snapshot] { ring }

    public func count() -> Int { ring.count }

    /// Текстовая склейка последних снапшотов от старого к новому,
    /// обрезается до `maxChars` (отсчёт идёт от свежих кадров).
    public func recentContext(maxChars: Int = 4096) -> String {
        guard !ring.isEmpty else { return "" }
        var blocks: [String] = []
        var total = 0
        let formatter = ISO8601DateFormatter()
        for snap in ring.reversed() {
            let body = snap.lines.joined(separator: " ")
            let block = "[\(formatter.string(from: snap.timestamp))] \(body)"
            if total + block.count > maxChars && !blocks.isEmpty { break }
            blocks.insert(block, at: 0)
            total += block.count
        }
        return blocks.joined(separator: "\n")
    }

    public func clear() { ring.removeAll() }
}
