import Foundation
import LushaBridge
import VortexCore

@main
struct FroggyDaemon {
    static func main() async {
        print("🐸 Froggy Daemon v0.1.0 [ARM64/MLX Focus] starting...")
        
        let vision = VisionActor()
        let vortex = VortexActor()
        let mlx = MLXActor()
        
        // 1. Попытка загрузки модели (замени путь на актуальный для тебя)
        do {
            try await mlx.loadModel(modelPath: "/Users/yaroslav/models/mistral-7b-v0.3-4bit")
            print("✅ Model loaded successfully.")
        } catch {
            print("❌ Failed to load model: \(error)")
        }
        
        // 2. Запуск захвата
        let _ = Task { await vision.startCapture() }
        
        // 3. Тестовый инференс
        let response = await mlx.generate(prompt: "Explain how Apple Silicon is great:")
        print("🤖 AI Response: \(response)")
        
        print("🚀 Systems online.")
        
        while true {
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            let pressure = await vortex.getMemoryPressure()
            print("[Monitor] Memory Pressure: \(pressure)")
        }
    }
}
