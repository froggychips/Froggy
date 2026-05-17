import Foundation
import os

/// Issue #61: regex-based skip-list для динамических элементов в OCR.
///
/// Vision возвращает всё что видит, включая menubar clock, прогрессбары,
/// "75%" из downloads, "1.2 GB" из file sizes — это не полезный сигнал
/// для LLM, но съедает место в sliding context window.
///
/// SkipList применяется per-line после `VNRecognizeTextRequest` и до
/// `Redactor.redact` / semantic OCR-diff (#60). Compiled regex'ы кэшируются
/// в init'е, runtime overhead — O(N×P) на цикл (N строк, P паттернов).
///
/// Источники паттернов (объединяются):
/// 1. Hardcoded defaults — см. `defaultPatterns`. Покрывают самые шумные
///    случаи которые есть у всех (часы, проценты, размеры файлов).
/// 2. `FroggyConfig.ocrSkipPatterns` — массив строк в config.json, если
///    задан. Не **заменяет** defaults, а добавляется. Для отключения
///    defaults — задайте пустой array и не добавляйте свои.
/// 3. `~/Library/Application Support/Froggy/ocr-skip-patterns.json` —
///    JSON array of strings, по аналогии с `Redactor`'овским пользовательским
///    file'ом. Удобно держать user-specific patterns отдельно от config.json
///    (легче дополнять/чистить без правки общего конфига).
public final class OCRSkipList: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.froggychips.froggy", category: "ocr-skip")

    /// Default-набор regex'ей. Намеренно строгие (anchored / структурные),
    /// чтобы не выбрасывать полезный текст: «1.2 GB free disk» не матчится
    /// (есть слово после), а отдельная строка «1.2 GB» — да.
    public static let defaultPatterns: [String] = [
        // Часы: HH:MM или HH:MM:SS. Anchored — целая строка, иначе бы
        // «meeting at 10:30» тоже выбрасывалось.
        #"^\d{1,2}:\d{2}(:\d{2})?$"#,
        // Percent: «75%» или «100%». Anchored как отдельная строка.
        #"^\d+%$"#,
        // File sizes: «1.2 GB», «512KB», «3 MB». Только-цифра + unit без
        // других слов в строке.
        #"^\d+(\.\d+)?\s*(KB|MB|GB|TB|B)$"#,
        // Версии типа «1.2.3» или «1.2.3.4» (semver / build numbers).
        // Без префикса/суффикса, исключительно для menubar app-version
        // индикаторов.
        #"^\d+\.\d+\.\d+(\.\d+)?$"#,
        // Bare numeric (counter widgets, FPS overlays): «42», «1234».
        // Только если строка ровно одно число.
        #"^\d+$"#,
    ]

    private let compiledPatterns: [NSRegularExpression]

    /// - Parameters:
    ///   - patterns: список regex-строк. Невалидные паттерны логируются
    ///     warning'ом и пропускаются — никогда не throws (это бы убило
    ///     daemon на старте если кто-то ошибётся в config.json).
    public init(patterns: [String]) {
        var compiled: [NSRegularExpression] = []
        for p in patterns {
            do {
                let re = try NSRegularExpression(pattern: p, options: [])
                compiled.append(re)
            } catch {
                Self.log.warning(
                    "OCR skip pattern invalid: \(p, privacy: .public) — \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        self.compiledPatterns = compiled
    }

    /// Loads from default + config + user-file сразу. Невалидные паттерны
    /// пропускаются.
    public static func loadDefaults(
        configPatterns: [String]? = nil,
        userPatternsFile: URL? = nil
    ) -> OCRSkipList {
        var all = defaultPatterns
        if let cfg = configPatterns {
            all.append(contentsOf: cfg)
        }
        if let url = userPatternsFile,
           let data = try? Data(contentsOf: url),
           let userList = try? JSONDecoder().decode([String].self, from: data) {
            all.append(contentsOf: userList)
        }
        return OCRSkipList(patterns: all)
    }

    public static var defaultUserPatternsURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Froggy", isDirectory: true)
            .appendingPathComponent("ocr-skip-patterns.json")
    }

    /// True если строка целиком матчится хотя бы одному паттерну.
    public func shouldSkip(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let range = NSRange(location: 0, length: trimmed.utf16.count)
        for re in compiledPatterns {
            if re.firstMatch(in: trimmed, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    /// Удобный helper: фильтрует массив строк, оставляя только non-skip.
    public func filter(_ lines: [String]) -> [String] {
        lines.filter { !shouldSkip($0) }
    }

    /// Кол-во compiled паттернов — для observability/тестов.
    public var patternCount: Int { compiledPatterns.count }
}
