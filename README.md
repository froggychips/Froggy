# Froggy 🐸

**AI-powered macOS Resource & Context Orchestrator**

Froggy — это интеллектуальная прослойка между macOS и локальными ИИ-моделями, оптимизированная специально для **Apple Silicon (ARM64)**.

## 🎯 Спецификация и Цели
- **Архитектура:** Только ARM64 (Apple Silicon M1/M2/M3).
- **ИИ-движок:** Глубокая интеграция с **MLX** для максимально эффективного использования унифицированной памяти.
- **Vortex Core:** Управление ресурсами системы (SIGSTOP/SIGCONT) для освобождения RAM под тяжелые модели.
- **Lusha Bridge:** Нативный Swift-слой для захвата контекста (Screen, Accessibility, System Events).

## 🛠 Технологический стек
- **Language:** Swift 6 (Native), Python 3.11+ (MLX logic).
- **Frameworks:** ScreenCaptureKit, Vision, MLX.
- **Target OS:** macOS 14.0+ (Sonoma).

## 🚀 Основные возможности
1. **Dynamic RAM Recovery:** Автоматическая заморозка фоновых приложений при запуске MLX-моделей.
2. **Contextual Awareness:** Понимание текущего рабочего процесса пользователя через семантический анализ экрана.
3. **Zero-Latency Interface:** Нативные Swift-биндинги для управления системой без задержек.

---
*Created for Apple Silicon. Built for Intelligence.*
