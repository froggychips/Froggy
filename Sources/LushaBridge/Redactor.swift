import Foundation

/// Replaces secrets in OCR output with `[REDACTED-…]` markers so they never
/// hit the on-disk state file. Better to lose a real string than leak a token.
public struct Redactor: Sendable {
    public init() {}

    public func redact(_ text: String) -> String {
        var s = text
        for rule in Self.rules {
            s = rule.apply(to: s)
        }
        return Self.redactCreditCards(in: s)
    }

    public func redact(_ lines: [String]) -> [String] {
        lines.map(redact)
    }

    // MARK: - Pattern rules

    private struct Rule: Sendable {
        let pattern: String
        let replacement: String
        let options: NSRegularExpression.Options

        func apply(to s: String) -> String {
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return s }
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            return re.stringByReplacingMatches(
                in: s, options: [], range: range, withTemplate: replacement
            )
        }
    }

    private static let rules: [Rule] = [
        // PEM blocks (private keys, certificates' private halves)
        Rule(
            pattern: "-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY-----",
            replacement: "[REDACTED-PEM]",
            options: []
        ),
        // AWS Access Key ID
        Rule(pattern: "AKIA[0-9A-Z]{16}", replacement: "[REDACTED-AWS-KEY]", options: []),
        // GitHub fine-grained PAT
        Rule(pattern: "github_pat_[A-Za-z0-9_]{60,}", replacement: "[REDACTED-GITHUB]", options: []),
        // GitHub legacy PAT / OAuth
        Rule(pattern: "gh[opsu]_[A-Za-z0-9]{30,}", replacement: "[REDACTED-GITHUB]", options: []),
        // Anthropic
        Rule(pattern: "sk-ant-[A-Za-z0-9_-]{20,}", replacement: "[REDACTED-ANTHROPIC]", options: []),
        // OpenAI project / legacy
        Rule(pattern: "sk-(?:proj-)?[A-Za-z0-9_-]{20,}", replacement: "[REDACTED-OPENAI]", options: []),
        // Slack token
        Rule(pattern: "xox[baprs]-[A-Za-z0-9-]{10,}", replacement: "[REDACTED-SLACK]", options: []),
        // JWT (three base64url-like segments separated by '.')
        Rule(
            pattern: "eyJ[A-Za-z0-9_-]+\\.eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+",
            replacement: "[REDACTED-JWT]",
            options: []
        ),
        // Bearer tokens in headers
        Rule(
            pattern: "(?i)bearer\\s+[A-Za-z0-9._\\-]{12,}",
            replacement: "[REDACTED-BEARER]",
            options: []
        ),
        // password: <value>  /  password=<value>
        Rule(
            pattern: "(?i)(password|passwd|pwd)\\s*[:=]\\s*\\S+",
            replacement: "$1=[REDACTED]",
            options: []
        ),
        // api_key: <value>
        Rule(
            pattern: "(?i)(api[_-]?key|secret|token)\\s*[:=]\\s*[\"']?[A-Za-z0-9_\\-\\.]{8,}[\"']?",
            replacement: "$1=[REDACTED]",
            options: []
        ),
    ]

    // MARK: - Credit cards (Luhn-validated to avoid false positives on order numbers)

    private static func redactCreditCards(in text: String) -> String {
        let pattern = "\\b\\d[\\d \\-]{11,21}\\d\\b"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        var result = ""
        var cursor = 0

        re.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match else { return }
            let r = match.range
            let candidate = nsText.substring(with: r)
            let digits = candidate.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
            let digitString = String(String.UnicodeScalarView(digits))
            result += nsText.substring(with: NSRange(location: cursor, length: r.location - cursor))
            if digitString.count >= 13, digitString.count <= 19, luhnValid(digitString) {
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
