import Foundation

/// Считает похожесть двух блоков OCR-текста для семантического дедупа
/// в `ContextStore`. 1.0 — идентичны, 0.0 — не пересекаются.
public protocol SimilarityScorer: Sendable {
    func similarity(_ a: [String], _ b: [String]) async -> Double
}

/// Дешёвый baseline: токенизация по whitespace и пунктуации, |A∩B|/|A∪B|.
/// Достаточно, чтобы поймать «тот же экран что 2 секунды назад» без
/// загрузки эмбеддинг-модели.
public struct JaccardSimilarityScorer: SimilarityScorer {
    private let lowercased: Bool
    private let minTokenLength: Int

    public init(lowercased: Bool = true, minTokenLength: Int = 2) {
        self.lowercased = lowercased
        self.minTokenLength = minTokenLength
    }

    public func similarity(_ a: [String], _ b: [String]) async -> Double {
        let setA = tokens(in: a)
        let setB = tokens(in: b)
        if setA.isEmpty && setB.isEmpty { return 1.0 }
        let intersection = setA.intersection(setB).count
        let union = setA.union(setB).count
        guard union > 0 else { return 0.0 }
        return Double(intersection) / Double(union)
    }

    private func tokens(in lines: [String]) -> Set<String> {
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        var out: Set<String> = []
        for line in lines {
            let normalized = lowercased ? line.lowercased() : line
            for raw in normalized.components(separatedBy: separators)
            where raw.count >= minTokenLength {
                out.insert(raw)
            }
        }
        return out
    }
}

/// Выключатель: всегда 0.0 → дедуп никогда не срабатывает.
public struct NoopSimilarityScorer: SimilarityScorer {
    public init() {}
    public func similarity(_ a: [String], _ b: [String]) async -> Double { 0.0 }
}
