import Foundation
import SwiftUI
import VortexCore

@MainActor
final class MenuBarViewModel: ObservableObject {
    @Published var status: IPCResponse?
    @Published var contextText: String = ""
    @Published var modelPathInput: String = ""
    @Published var lastError: String?
    @Published var isBusy: Bool = false

    private let client: IPCClient
    private var pollTask: Task<Void, Never>?

    init(socketPath: String = FroggyConfig.defaultSocketPath) {
        self.client = IPCClient(socketPath: socketPath)
        startPolling()
    }

    deinit {
        pollTask?.cancel()
    }

    var menuBarLabel: String {
        guard let s = status else { return "🐸 …" }
        if s.modelLoaded == true {
            return "🐸 ●"
        }
        if s.capturing == true {
            return "🐸 ◌"
        }
        return "🐸"
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
            status = r
            lastError = nil
        } catch {
            lastError = "daemon offline: \(error)"
            status = nil
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
}
