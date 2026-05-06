import AppKit
import Foundation

/// Абстракция «получить pids приложений с такими bundle-id». Нужна, чтобы
/// Coordinator-а можно было тестировать без живого NSWorkspace.
public protocol ProcessFinder: Sendable {
    func pids(forBundleIds bundleIds: [String]) async -> [Int32]
}

/// Реальный finder поверх `NSWorkspace.runningApplications` (Main-actor-isolated
/// в Swift 6, поэтому хопаем туда явно).
public struct NSWorkspaceProcessFinder: ProcessFinder {
    public init() {}

    public func pids(forBundleIds bundleIds: [String]) async -> [Int32] {
        guard !bundleIds.isEmpty else { return [] }
        let set = Set(bundleIds)
        return await MainActor.run {
            NSWorkspace.shared.runningApplications
                .filter { app in
                    guard let bid = app.bundleIdentifier else { return false }
                    return set.contains(bid)
                }
                .map(\.processIdentifier)
        }
    }
}
