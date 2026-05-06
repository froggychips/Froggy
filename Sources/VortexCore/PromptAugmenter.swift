import Foundation

/// Прокладывает свежий OCR-контекст в пользовательский промпт.
/// Используется daemon-side, чтобы любой клиент (MenuBar, CLI, скрипт)
/// мог опт-инить «знать что у меня на экране» через одно поле IPC.
public struct PromptAugmenter: Sendable {
    /// Шаблон с placeholder'ами `{context}` и `{prompt}`.
    public let template: String
    /// Жёсткий потолок на длину context-блока, в graphemes.
    public let maxContextChars: Int

    public init(
        template: String = PromptAugmenter.defaultTemplate,
        maxContextChars: Int = 4096
    ) {
        self.template = template
        self.maxContextChars = maxContextChars
    }

    public static let defaultTemplate: String = """
    You are an assistant with awareness of the user's current screen context.
    The CONTEXT block below is recent OCR text from the user's display, sorted
    oldest → newest. Use it to ground your answer when relevant; ignore it
    when it isn't. Do not echo the CONTEXT verbatim.

    --- CONTEXT ---
    {context}
    --- END CONTEXT ---

    User: {prompt}
    Assistant:
    """

    /// Если `context` пустой — возвращаем prompt без обёртки, чтобы не
    /// тратить токены на CONTEXT-блок «ничего».
    public func augment(prompt: String, context: String) -> String {
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return prompt }
        let bounded = trimmed.count <= maxContextChars
            ? trimmed
            : String(trimmed.suffix(maxContextChars))
        return template
            .replacingOccurrences(of: "{context}", with: bounded)
            .replacingOccurrences(of: "{prompt}", with: prompt)
    }
}
