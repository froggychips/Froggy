# Инженерный Манифест Froggy 🐸

Добро пожаловать в разработку ядра Froggy. Данный документ определяет стандарты, инструменты и практики для обеспечения высокой производительности на **Apple Silicon (ARM64)**.

## 1. Инструментарий (The Toolchain)
*   **Instruments (Time Profiler & Memory Graph):** Основной инструмент профилирования. Следите за памятью (Unified Memory) — утечки в `VisionActor` критичны.
*   **Swift-Format:** Стандарт форматирования. Обязателен перед каждым коммитом.
*   **xcbeautify:** Используйте для анализа логов сборки: `swift build | xcbeautify`.
*   **Sourcery:** Генерация шаблонного кода (Sendable/Actor-boilerplate).

## 2. Автоматизация (MCP Layer)
Разработка ведется с использованием системы MCP-серверов:
*   **FileSystem MCP:** Доступ к кодовой базе.
*   **GitHub MCP:** Управление репозиторием и PR.
*   **Local LLM MCP:** Управление MLX-моделями на лету.
*   **System Monitor MCP:** Визуализация метрик Vortex (RAM/Process State).

## 3. База знаний и принятие решений
*   **Swift 6 Migration:** Все модули должны соответствовать `Strict Concurrency`.
*   **MLX Swift Reference:** Главный источник по работе с тензорами.
*   **ADR (Architecture Decision Records):** Все ключевые решения (например, выбор Actor вместо Lock) должны фиксироваться в `/docs/adr/`.

## 4. Навыки
*   **Swift Concurrency Debugging:** Глубокое понимание `Task` и `Actor`.
*   **Metal Performance Shaders (MPS):** Оптимизация инференса под кэш GPU M-чипов.
*   **ARM64 Assembly:** Базовое понимание Memory Access для оптимизации MLX-слоев.

---
*Соблюдайте правила, пишите чистый код, оптимизируйте под ARM64.*
