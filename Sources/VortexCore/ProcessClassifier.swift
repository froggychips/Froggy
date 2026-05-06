import Darwin
import Darwin.libproc
import Foundation

/// Default-deny классификатор процессов: всё, что НЕ удовлетворяет всем
/// проверкам, попадает в `.forbidden`. Это сменяет старый «blacklist
/// нескольких системных бинарей» — потому что blacklist в принципе нельзя
/// сделать полным.
public struct ProcessClassifier: Sendable {
    public enum Verdict: Sendable, Equatable {
        case freezable(executablePath: String)
        case forbidden(reason: String)
    }

    /// Дополнительные path-префиксы, которые считать «пользовательскими»
    /// (например, `/opt/homebrew/Caskroom/...`). Дефолт — только канонические.
    public let extraAllowedPrefixes: [String]

    public init(extraAllowedPrefixes: [String] = []) {
        self.extraAllowedPrefixes = extraAllowedPrefixes
    }

    public func classify(pid: Int32) -> Verdict {
        // 1. Numeric guard.
        guard pid > 100 else { return .forbidden(reason: "system pid (<=100)") }
        guard pid != getpid() else { return .forbidden(reason: "self") }

        // 2. EUID/existence probe via signal 0.
        if kill(pid, 0) != 0 {
            switch errno {
            case ESRCH: return .forbidden(reason: "no such process")
            case EPERM: return .forbidden(reason: "different EUID")
            default: return .forbidden(reason: "kill probe failed: errno=\(errno)")
            }
        }

        // 3. Executable path must be under an allowed root.
        guard let path = Self.executablePath(pid: pid) else {
            return .forbidden(reason: "cannot read executable path")
        }
        guard isUserApp(path: path) else {
            return .forbidden(reason: "not a user app: \(path)")
        }
        return .freezable(executablePath: path)
    }

    // MARK: - Path policy

    private func isUserApp(path: String) -> Bool {
        for prefix in Self.defaultAllowedPrefixes + extraAllowedPrefixes {
            if path.hasPrefix(prefix) { return true }
        }
        return false
    }

    /// Корни, под которыми установлены приложения текущего пользователя
    /// или сторонних разработчиков. `/System/...`, `/usr/...`, `/Library/...`,
    /// `/sbin/...`, `/private/var/...` сюда сознательно НЕ входят.
    public static var defaultAllowedPrefixes: [String] {
        let home = NSHomeDirectory()
        return [
            "/Applications/",
            "\(home)/Applications/",
            "/opt/homebrew/Cellar/",
        ]
    }

    /// Тонкая обёртка над BSD `proc_pidpath`. Возвращает абсолютный путь
    /// к исполняемому файлу процесса.
    public static func executablePath(pid: Int32) -> String? {
        let bufSize = Int(MAXPATHLEN)
        var buffer = [CChar](repeating: 0, count: bufSize)
        let written = proc_pidpath(pid, &buffer, UInt32(bufSize))
        guard written > 0 else { return nil }
        return String(cString: buffer)
    }
}
