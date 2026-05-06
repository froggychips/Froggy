import AppKit
import Foundation
import SwiftUI
import VortexCore

@MainActor
final class MenuBarViewModel: ObservableObject {
    @Published var status: IPCResponse?
    @Published var contextText: String = ""
    @Published var modelPathInput: String = ""
    @Published var promptInput: String = ""
    @Published var streamOutput: String = ""
    @Published var isGenerating: Bool = false
    @Published var lastError: String?
    @Published var isBusy: Bool = false

    /// Если capturing уже >10 с, а snapshots всё ещё 0 — скорее всего
    /// TCC denied. Используем как мягкий триггер для warning-banner.
    @Published var capturingSinceWithoutFrames: Date?

    private let client: IPCClient
    private var pollTask: Task<Void, Never>?
    private var generateTask: Task<Void, Never>?

    init(socketPath: String = FroggyConfig.defaultSocketPath) {
        self.client = IPCClient(socketPath: socketPath)
        startPolling()
    }

    deinit {
        pollTask?.cancel()
        generateTask?.cancel()
    }

    var menuBarLabel: String {
        guard let s = status else { return "🐸 …" }
        if needsScreenRecordingPermission { return "🐸 ⚠︎" }
        if s.modelLoaded == true { return "🐸 ●" }
        if s.capturing == true { return "🐸 ◌" }
        return "🐸"
    }

    /// True, если daemon явно сообщает об ошибке захвата ИЛИ если
    /// capture идёт уже >10 с, но ни одного snapshot'а так и не пришло.
    var needsScreenRecordingPermission: Bool {
        if let err = status?.lastCaptureError, !err.isEmpty { return true }
        if let since = capturingSinceWithoutFrames, Date().timeIntervalSince(since) > 10 {
            return true
        }
        return false
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func refreshStatus() async {
        do {
            let r = try await client.status()
            // Отслеживаем «capturing yes, but 0 snapshots» — индикатор TCC.
            if r.capturing == true, (r.snapshots ?? 0) == 0 {
                if capturingSinceWithoutFrames == nil {
                    capturingSinceWithoutFrames = Date()
                }
            } else {
                capturingSinceWithoutFrames = nil
            }
            status = r
            lastError = nil
        } catch {
            lastError = "daemon offline: \(error)"
            status = nil
            capturingSinceWithoutFrames = nil
        }
    }

    func refreshContext() async {
        do {
            let r = try await client.context(maxChars: 4096)
            contextText = r.context ?? ""
        } catch {
            lastError = String(describing: error)
        }
    }

    func loadModel() async {
        guard !modelPathInput.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let r = try await client.loadModel(path: modelPathInput)
            if r.ok != true {
                lastError = r.error ?? "load failed"
            }
            await refreshStatus()
        } catch {
            lastError = String(describing: error)
        }
    }

    func unloadModel() async {
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await client.unloadModel()
            await refreshStatus()
        } catch {
            lastError = String(describing: error)
        }
    }

    func thawAll() async {
        do {
            _ = try await client.thawAll()
            await refreshStatus()
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: - Streaming generation

    func startGeneration() {
        guard !promptInput.isEmpty, !isGenerating else { return }
        let prompt = promptInput
        streamOutput = ""
        isGenerating = true
        let stream = client.generateStream(prompt: prompt, maxTokens: 200)
        generateTask = Task { [weak self] in
            do {
                for try await chunk in stream {
                    await MainActor.run { self?.streamOutput += chunk }
                }
            } catch {
                await MainActor.run { self?.lastError = String(describing: error) }
            }
            await MainActor.run { self?.isGenerating = false }
        }
    }

    func cancelGeneration() {
        generateTask?.cancel()
        generateTask = nil
        isGenerating = false
    }

    // MARK: - TCC

    /// Открывает System Settings → Privacy & Security → Screen Recording.
    func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
