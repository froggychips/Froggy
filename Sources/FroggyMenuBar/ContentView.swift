import SwiftUI
import VortexCore

struct ContentView: View {
    @ObservedObject var model: MenuBarViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("🐸 Froggy").font(.headline)
                Spacer()
                Button {
                    Task { await model.refreshStatus() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }

            activeToggle

            if model.needsScreenRecordingPermission {
                tccBanner
            }

            Divider()
            statusBlock
            Divider()
            modelBlock
            Divider()
            generationBlock
            Divider()
            contextBlock

            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            HStack {
                Button("Thaw all") { Task { await model.thawAll() } }
                Spacer()
                Button("Quit Froggy UI") { NSApp.terminate(nil) }
            }
            .padding(.top, 4)
        }
        .padding(12)
    }

    // MARK: - Active toggle (ADR 0017)

    /// Большой On/Off-тумблер. Off — daemon перестаёт морозить процессы и
    /// выгружает MLX-модель (idle ~50 MB). Daemon продолжает крутиться,
    /// IPC и capture работают.
    @ViewBuilder
    private var activeToggle: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.freezingEnabled ? Color.green : Color.gray)
                .frame(width: 10, height: 10)
            Text(model.freezingEnabled ? "Active" : "Paused")
                .font(.subheadline).bold()
                .foregroundStyle(model.freezingEnabled ? .primary : .secondary)
            Spacer()
            Toggle("", isOn: Binding(
                get: { model.freezingEnabled },
                set: { newValue in Task { await model.setActive(newValue) } }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .disabled(model.isBusy)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            (model.freezingEnabled ? Color.green : Color.gray).opacity(0.10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(
                    (model.freezingEnabled ? Color.green : Color.gray).opacity(0.4),
                    lineWidth: 1
                )
        )
    }

    // MARK: - TCC banner

    @ViewBuilder
    private var tccBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("Screen Recording permission needed")
                    .font(.subheadline).bold()
            }
            Text(model.status?.lastCaptureError
                 ?? "Capture is running but no frames have arrived. macOS likely blocked screen recording for FroggyDaemon.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Privacy Settings") {
                model.openScreenRecordingSettings()
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Color.yellow.opacity(0.15))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.yellow.opacity(0.5), lineWidth: 1)
        )
    }

    // MARK: - Status

    @ViewBuilder
    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Capturing", boolValue(model.status?.capturing))
            row("Model loaded", boolValue(model.status?.modelLoaded))
            row("Model path", model.status?.modelPath ?? "—")
            row("Memory pressure", model.status.flatMap { $0.memoryPressure.map { "\($0)%" } } ?? "—")
            row("Frozen procs", model.status?.frozen.map(String.init) ?? "—")
            row("Snapshots", model.status?.snapshots.map(String.init) ?? "—")
        }
    }

    // MARK: - Model

    @ViewBuilder
    private var modelBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Model").font(.subheadline).bold()
            TextField("/path/to/local/mlx-model", text: $model.modelPathInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
            HStack {
                Button("Load") { Task { await model.loadModel() } }
                    .disabled(model.isBusy || model.modelPathInput.isEmpty)
                Button("Unload") { Task { await model.unloadModel() } }
                    .disabled(model.isBusy || model.status?.modelLoaded != true)
            }
        }
    }

    // MARK: - Streaming generation

    @ViewBuilder
    private var generationBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Generate").font(.subheadline).bold()
                Spacer()
                if model.isGenerating {
                    ProgressView().controlSize(.small)
                }
            }
            TextField("Prompt", text: $model.promptInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .disabled(model.isGenerating)
            HStack {
                Button("Generate") { model.startGeneration() }
                    .disabled(
                        model.isGenerating
                        || model.promptInput.isEmpty
                        || model.status?.modelLoaded != true
                    )
                Button("Cancel") { model.cancelGeneration() }
                    .disabled(!model.isGenerating)
            }
            if !model.streamOutput.isEmpty {
                ScrollView {
                    Text(model.streamOutput)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 100)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            }
        }
    }

    // MARK: - Context

    @ViewBuilder
    private var contextBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent context").font(.subheadline).bold()
                Spacer()
                Button("Fetch") { Task { await model.refreshContext() } }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            ScrollView {
                Text(model.contextText.isEmpty ? "—" : model.contextText)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 120)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 11, design: .monospaced))
        }
        .font(.caption)
    }

    private func boolValue(_ v: Bool?) -> String {
        switch v {
        case .some(true): return "yes"
        case .some(false): return "no"
        case .none: return "—"
        }
    }
}
