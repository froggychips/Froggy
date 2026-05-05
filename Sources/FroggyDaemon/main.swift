import Foundation
import LushaBridge
import VortexCore

@main
struct FroggyDaemon {
    static func main() async {
        print("🐸 Froggy Daemon v0.1.0 [ARM64/MLX Focus] starting...")
        
        let vision = VisionActor()
        let vortex = VortexActor()
        
        // Запуск захвата в фоновой задаче
        let captureTask = Task {
            await vision.startCapture()
        }
        
        print("🚀 Systems online. Press Ctrl+C to stop.")
        
        // Держим демон запущенным
        while true {
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            let pressure = await vortex.getMemoryPressure()
            print("[Monitor] Memory Pressure: \(pressure)")
        }
    }
}
