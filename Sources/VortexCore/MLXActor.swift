import Foundation
import MLX
import MLXLMModels

/// Актер для управления MLX-инференсом на Apple Silicon.
actor MLXActor {
    private var model: LanguageModel?
    
    init() {
        MLX.GPU.setMemoryLimit(4 * 1024 * 1024 * 1024)
    }
    
    /// Загрузка модели из указанной директории
    func loadModel(modelPath: String) async throws {
        let configuration = LanguageModelConfiguration(modelPath: modelPath)
        self.model = try await LanguageModel.load(configuration: configuration)
    }
    
    func generate(prompt: String) async -> String {
        guard let model = model else { return "Model not loaded" }
        
        return await autoreleasepool {
            // Базовая генерация (упрощенная)
            let result = model.generate(prompt: prompt, maxTokens: 100)
            return result
        }
    }
}
