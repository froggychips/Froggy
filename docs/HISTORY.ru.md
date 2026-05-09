# История проекта — от Lusha к VortexSentinel к Froggy

Froggy начался как **Lusha** — Python-прототип, написанный в марте 2026 года.
Несколько дней спустя архитектура была переписана на Swift как
**VortexSentinelGUI**: появилось разделение на daemon + menu-bar, multi-signal
`RiskEngine` и IPC на основе JSON-файлов. Два месяца спустя тот же чертёж
был реализован с нуля как Froggy — с изоляцией MLX в subprocess, реактивным
memory pressure и Unix-socket IPC вместо файловой шины.

Этот файл сохраняет архитектурную родословную и roadmap-пункты, которые
не попали в текущую кодовую базу, но остаются кандидатами для будущей работы.

## Родословная (март 2026 → май 2026)

| Этап | Проект | Что добавил |
|---|---|---|
| 11–12 мар | **Lusha** (Python-прототип) | Концепция «AI screen copilot»; multi-engine оркестратор (`Harmonizer` + `subprocess.Popen`); имена, переиспользованные позже: `LushaCore`, `RAM_GUARD`, `REASONING` («Vortex / Logic»). |
| 14–15 мар | **VortexSentinelGUI** (Swift-прототип) | Разделение daemon + menu-bar. JSON-file IPC (`state.json`, `timeline.json`, `snapshots.json`). Multi-signal `RiskEngine` для принятия решения «заморозить или оставить» (сетевые соединения через `lsof` + Accessibility API + audio assertions через `pmset`, оценка 0..1). `Vortex` повышен с имени одного движка до архитектурного префикса. |
| Май → | **Froggy** (Swift, текущий) | Изоляция MLX в subprocess (ADR-0008). Реактивный memory pressure (ADR-0006). Стратегии pageout (ADR-0007). Unix-socket JSON IPC (ADR-0002) взамен file-polling. Frontmost-veto (ADR-0015) как минималистичный преемник `RiskEngine`. |

### Родословная компонентов

| Lusha → VortexSentinel → Froggy | Примечания |
|---|---|
| `RAM_GUARD` → polling `getMemoryUsage()` в daemon → `MemoryPressureMonitor` + ADR-0006 | Реактивный `dispatch_source_memorypressure` заменил опрос каждые 5 секунд. |
| `REASONING / Vortex` → `VortexSentinelDaemon` / `VortexSentinelGUI` → `Sources/VortexCore` | `Vortex` переехал с имени одного движка на общеархитектурный префикс. |
| `Harmonizer` (Python, `subprocess.Popen`) → daemon + GUI как отдельные процессы → Swift coordinator + ADR-0008 (изоляция MLX в subprocess) | Каждый шаг сохранял изоляцию процессов, совершенствуя IPC. |
| `state.json` + `ai_voice_command.txt` (touch-file команды) → polling 4 JSON каждые 2с → Unix-socket IPC (ADR-0002) | File-based IPC перестал масштабироваться; переключились на настоящий сокет. |
| (нет) → `RiskEngine` (сеть + AX + audio, взвешенная оценка 0..1) → frontmost-veto (ADR-0015) | Тройной сигнал свёлся к единственной проверке фронтального окна. |
| LM Studio / Ollama / Qwen / DeepSeek | (LLM не было в VortexSentinel — тот этап был только мониторингом системы) | MLX, только on-device, облачный fallback убран. |

Имена `Lusha` и `Vortex` остаются в текущей кодовой базе как намеренная отсылка к прототипам.

## Перенесённый roadmap (не в текущем Froggy)

Пункты из прототипов, которые не попали в Swift-переписывание. Кандидаты для будущей v2.

### Сканер UI на основе Accessibility API

Использовать Apple Accessibility API для извлечения `{role, title, position, hierarchy}`
для активного окна. Рассматривать OCR и AX как избыточные сигналы — при расхождении
AX побеждает для кликабельных элементов управления. Сейчас Froggy работает
только с Vision OCR.

В VortexSentinel уже было частичное использование AX в `RiskEngine`
(`AXUIElementCreateApplication`, `kAXMainWindowAttribute`) — этот код является
отправной точкой, если функция будет реализована.

### Overlay HUD

Рисовать подсказки прямо на экране через `NSPanel` (или Hammerspoon). Сейчас
Froggy отображает текст только в popover меню-бара; overlay-слой откроет UX
в стиле «нажми на эту кнопку».

### Цикл дистилляции Teacher / Student

Периодически запускать более мощную модель (класса DeepSeek-R1) для получения
chain-of-thought «золотого ответа» на данный экран, сохранять кортеж
`(screen, AX, gold)` в локальном датасете, fine-tune меньшую рабочую модель
(класса Qwen) на нём. Цель: модель, которая со временем становится заметно
лучше на воркфлоу конкретного пользователя. Сейчас Froggy просто запускает
MLX без обратной связи.

### Multi-signal `RiskEngine` (возрождение)

Frontmost-veto (ADR-0015) намеренно минималистичен. Предыдущий `RiskEngine`
в VortexSentinel взвешивал три ортогональных сигнала — сетевую активность,
AX-взаимодействие, воспроизведение аудио — для более тонкого решения
«безопасно ли сейчас замораживать это приложение?». Если ложные заморозки
станут проблемой на практике, этот подход с оценкой — естественное расширение.

## Альтернативная архитектура, заслуживающая переосмысления

`LushaMCPServer.py` прототипа (построенный на FastMCP) открывал Froggy как
**MCP-сервер**, а не клиент:

- `get_lusha_vision()` — возвращает текущее состояние экрана в виде JSON.
- `send_command_to_lusha(command)` — отправляет текстовую команду в reasoning-цикл демона.

Любой MCP-совместимый клиент (Claude Desktop, Cursor, Gemini CLI) мог бы
читать контекст экрана Froggy локально, не требуя от Froggy создания
собственной экосистемы инструментов. Существенно меньше работы, чем строить
реестр инструментов внутри Froggy, а поверхность интеграции — опубликованный
протокол, а не частный контракт.

## Архив исходников

Исходники прототипов были архивированы локально 2026-05-08:

- `~/Archive/ai-screen-copilot-dev/` — Lusha:
  - `MASTER_PLAN.md` — поэтапный roadmap (фазы 1–6).
  - `LushaMCPServer.py` — заглушка FastMCP-сервера.
- `~/Archive/VortexSentinelGUI/` — полные Swift-исходники прототипа
  VortexSentinelGUI: daemon, GUI, модели, `RiskEngine`, образцы state JSON.
