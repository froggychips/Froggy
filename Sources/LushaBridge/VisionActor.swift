import Foundation
import Vision
import CoreGraphics
import ScreenCaptureKit

/// Актер для управления состоянием и OCR-процессами.
/// Обеспечивает потокобезопасность в соответствии со стандартами Swift 6.
actor VisionActor {
    private var isCapturing = false
    private let stateFilePath: URL
    
    init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        self.stateFilePath = homeDir.appendingPathComponent(".froggy_state.json")
    }
    
    /// Запуск цикла захвата и анализа
    func startCapture() async {
        guard !isCapturing else { return }
        isCapturing = true
        
        print("[VisionActor] Starting capture loop on ARM64...")
        
        while isCapturing {
            autoreleasepool {
                performCaptureCycle()
            }
            try? await Task.sleep(nanoseconds: 2 * 1_000_000_000) // 2 секунды интервал
        }
    }
    
    func stopCapture() {
        isCapturing = false
    }
    
    private func performCaptureCycle() {
        // Здесь будет логика ScreenCaptureKit для ARM64
        // Для MVP используем упрощенный захват основного дисплея
        let displayID = CGMainDisplayID()
        guard let image = CGDisplayCreateImage(displayID) else { return }
        
        processImage(image)
    }
    
    private func processImage(_ image: CGImage) {
        let requestHandler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNRecognizeTextRequest { [weak self] request, error in
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
            
            let recognizedStrings = observations.compactMap { observation in
                observation.topCandidates(1).first?.string
            }
            
            Task { [weak self] in
                await self?.updateState(with: recognizedStrings)
            }
        }
        
        request.recognitionLevel = .accurate
        try? requestHandler.perform([request])
    }
    
    private func updateState(with strings: [String]) async {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let state: [String: Any] = [
            "timestamp": timestamp,
            "recognized_text": strings,
            "architecture": "arm64"
        ]
        
        await atomicWriteState(state)
    }
    
    private func atomicWriteState(_ state: [String: Any]) async {
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: .prettyPrinted) else { return }
        
        let tempURL = stateFilePath.appendingPathExtension("tmp")
        do {
            try data.write(to: tempURL)
            try FileManager.default.replaceItemAt(stateFilePath, withItemAt: tempURL)
            // print("[VisionActor] State updated atomically.")
        } catch {
            print("[VisionActor] Error writing state: \(error)")
        }
    }
}
