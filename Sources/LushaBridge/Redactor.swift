import Foundation

/// Описание одного правила редактирования. Сериализуемо в JSON, чтобы
/// пользователь мог добавлять корпоративные паттерны без пересборки.
public struct RedactionRule: Codable, Sendable, Equatable {
    public let name: String
    public let pattern: String
    public let replacement: String
    public let caseInsensitive: Bool

    public init(name: String, pattern: String, replacement: String, caseInsensitive: Bool = false) {
        self.name = name
        self.pattern = pattern
        self.replacement = replacement
        self.caseInsensitive = caseInsensitive
    }
}

/// Заменяет секреты в OCR-выводе на маркеры `[REDACTED-...]`.
/// Регулярки компилируются один раз при инициализации (раньше — на каждом
/// вызове, ~12 regex × N строк × 0.5 Гц = тысячи компиляций/час).
public struct Redactor: Sendable {
    private let compiled: [CompiledRule]

    /// Использует встроенные правила. Если на диске лежит
    /// `~/Library/Application Support/Froggy/redaction-rules.json`,
    /// его правила добавляются ПОСЛЕ встроенных.
    public init(loadUserRules: Bool = true) {
        var rules = Self.builtInRules
        if loadUserRules, let userRules = Self.loadUserRulesFromDisk() {
            rules.append(contentsOf: userRules)
        }
        self.compiled = rules.compactMap(CompiledRule.init)
    }

    /// Конструктор для тестов и кастомных сценариев.
    public init(rules: [RedactionRule]) {
        self.compiled = rules.compactMap(CompiledRule.init)
    }

    public func redact(_ text: String) -> String {
        var s = text
        for rule in compiled {
            s = rule.apply(to: s)
        }
        return Self.redactCreditCards(in: s)
    }

    public func redact(_ lines: [String]) -> [String] {
        lines.map(redact)
    }

    // MARK: - Built-in rules

    public static let builtInRules: [RedactionRule] = [
        // PEM-блоки (приватные ключи, сертификаты).
        .init(
            name: "pem-private-key",
            pattern: "-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY-----",
            replacement: "[REDACTED-PEM]"
        ),
        .init(name: "aws-access-key", pattern: "AKIA[0-9A-Z]{16}", replacement: "[REDACTED-AWS-KEY]"),
        .init(name: "github-pat-fine", pattern: "github_pat_[A-Za-z0-9_]{60,}", replacement: "[REDACTED-GITHUB]"),
        .init(name: "github-pat-legacy", pattern: "gh[opsu]_[A-Za-z0-9]{30,}", replacement: "[REDACTED-GITHUB]"),
        .init(name: "anthropic", pattern: "sk-ant-[A-Za-z0-9_-]{20,}", replacement: "[REDACTED-ANTHROPIC]"),
        .init(name: "openai", pattern: "sk-(?:proj-)?[A-Za-z0-9_-]{20,}", replacement: "[REDACTED-OPENAI]"),
        .init(name: "slack", pattern: "xox[baprs]-[A-Za-z0-9-]{10,}", replacement: "[REDACTED-SLACK]"),
        .init(
            name: "jwt",
            pattern: "eyJ[A-Za-z0-9_-]+\\.eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+",
            replacement: "[REDACTED-JWT]"
        ),
        .init(
            name: "bearer",
            pattern: "bearer\\s+[A-Za-z0-9._\\-]{12,}",
            replacement: "[REDACTED-BEARER]",
            caseInsensitive: true
        ),
        .init(
            name: "password-label",
            pattern: "(password|passwd|pwd)\\s*[:=]\\s*\\S+",
            replacement: "$1=[REDACTED]",
            caseInsensitive: true
        ),
        .init(
            name: "secret-label",
            pattern: "(api[_-]?key|secret|token)\\s*[:=]\\s*[\"']?[A-Za-z0-9_\\-\\.]{8,}[\"']?",
            replacement: "$1=[REDACTED]",
            caseInsensitive: true
        ),
    ]

    public static let userRulesFileName = "redaction-rules.json"

    public static var userRulesURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Froggy", isDirectory: true)
            .appendingPathComponent(userRulesFileName)
    }

    public static func loadUserRulesFromDisk() -> [RedactionRule]? {
        loadUserRules(from: userRulesURL)
    }

    public static func loadUserRules(from url: URL) -> [RedactionRule]? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let rules = try? JSONDecoder().decode([RedactionRule].self, from: data)
        else { return nil }
        return rules
    }

    // MARK: - Credit cards (Luhn-validated, отдельно от regex-rules)

    private static let cardCandidatePattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\\b\\d[\\d \\-]{11,21}\\d\\b")
    }()

    private static func redactCreditCards(in text: String) -> String {
        guard let re = cardCandidatePattern else { return text }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        var result = ""
        var cursor = 0
        re.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match else { return }
            let r = match.range
            let candidate = nsText.substring(with: r)
            let digitChars = candidate.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
            let digits = String(String.UnicodeScalarView(digitChars))
            result += nsText.substring(with: NSRange(location: cursor, length: r.location - cursor))
            if digits.count >= 13, digits.count <= 19, luhnValid(digits) {
                result += "[REDACTED-CARD]"
            } else {
                result += candidate
            }
            cursor = r.location + r.length
        }
        result += nsText.substring(from: cursor)
        return result
    }

    private static func luhnValid(_ digits: String) -> Bool {
        var sum = 0
        var alt = false
        for ch in digits.reversed() {
            guard let d = ch.wholeNumberValue else { return false }
            var v = d
            if alt {
                v *= 2
                if v > 9 { v -= 9 }
            }
            sum += v
            alt.toggle()
        }
        return sum % 10 == 0
    }
}

/// Pre-compiled rule. Один объект `NSRegularExpression` живёт всю жизнь
/// `Redactor`-а — никаких `try? NSRegularExpression(pattern:)` per call.
private struct CompiledRule: Sendable {
    let regex: NSRegularExpression
    let replacement: String

    init?(_ rule: RedactionRule) {
        var options: NSRegularExpression.Options = []
        if rule.caseInsensitive { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: options) else {
            return nil
        }
        self.regex = regex
        self.replacement = rule.replacement
    }

    func apply(to s: String) -> String {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return regex.stringByReplacingMatches(
            in: s, options: [], range: range, withTemplate: replacement
        )
    }
}
