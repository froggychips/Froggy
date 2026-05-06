import AppKit
import Foundation
import os

/// Связывает `MLXActor` и `VortexActor`: перед загрузкой тяжёлой модели
/// замораживает фоновые приложения из allowlist, после выгрузки — отпускает.
public actor VortexCoordinator {
    private static let log = Logger(subsystem: "com.froggychips.froggy", category: "coordinator")
    private static let signposter = OSSignposter(subsystem: "com.froggychips.froggy", category: "coordinator")

    public let mlx: MLXActor
    public let vortex: VortexActor
    private let freezeBundleIds: [String]

    /// Какие именно pids мы заморозили в текущем «эпизоде» — чтобы не попутать
    /// с pids, замороженными по другому поводу.
    private var frozenForCurrentLoad: Set<Int32> = []

    public init(mlx: MLXActor, vortex: VortexActor, freezeBundleIds: [String]) {
        self.mlx = mlx
        self.vortex = vortex
        self.freezeBundleIds = freezeBundleIds
    }

    /// Замораживает целевые приложения и затем загружает модель.
    /// Если загрузка падает — pids всё равно отпускаем, чтобы не оставить
    /// пользователя с зависшим Slack.
    public func loadModel(modelPath: String) async throws {
        let interval = Self.signposter.beginInterval("coordinator.loadModel")
        defer { Self.signposter.endInterval("coordinator.loadModel", interval) }

        let pids = await Self.pids(forBundleIds: freezeBundleIds)
        Self.log.info("freezing \(pids.count) processes before model load")

        for pid in pids {
            do {
                try await vortex.freezeProcess(pid: pid)
                frozenForCurrentLoad.insert(pid)
            } catch {
                Self.log.warning("freeze pid=\(pid) skipped: \(error.localizedDescription)")
            }
        }

        do {
            try await mlx.loadModel(modelPath: modelPath)
        } catch {
            await thawForCurrentLoad()
            throw error
        }
    }

    /// Выгружает модель и отпускает ранее замороженные процессы.
    public func unloadModel() async {
        await mlx.unloadModel()
        await thawForCurrentLoad()
    }

    /// Гарантирует, что все процессы, замороженные через этот координатор,
    /// будут отпущены. Вызывать из обработчика SIGINT/SIGTERM.
    public func emergencyThaw() async {
        await thawForCurrentLoad()
        await vortex.thawAll()
    }

    /// Прокси к `MLXActor.generate` — чтобы IPC-handler не лез к mlx напрямую.
    public func generate(prompt: String, maxTokens: Int = 200) async throws -> String {
        try await mlx.generate(prompt: prompt, maxTokens: maxTokens)
    }

    private func thawForCurrentLoad() async {
        for pid in frozenForCurrentLoad {
            await vortex.thawProcess(pid: pid)
        }
        frozenForCurrentLoad.removeAll()
    }

    /// Снимок pid'ов запущенных приложений с указанными bundle ID.
    /// Делается на MainActor, потому что NSWorkspace в Swift 6 — main-isolated.
    private static func pids(forBundleIds bundleIds: [String]) async -> [Int32] {
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
