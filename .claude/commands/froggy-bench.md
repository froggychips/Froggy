---
description: Снимает baseline по unified memory + IPC-замерам и сравнивает с bench/baseline.json
argument-hint: "[--save]"
allowed-tools: Bash, Read, Write
---

Сними бенчмарк-снимок текущего состояния Froggy и сравни с baseline.

## Что делать

1. Если в аргументах есть `--save` — пиши результат в `bench/baseline.json`
   (создай директорию если нет, mode 0644). Иначе — просто выведи diff.

2. Собрать метрики:

   ```bash
   echo "=== vm_stat ==="; vm_stat
   echo "=== memory_pressure ==="; memory_pressure 2>/dev/null || echo "n/a"
   echo "=== Froggy daemon RSS ==="; ps -o pid,rss,comm -p $(pgrep FroggyDaemon 2>/dev/null) 2>/dev/null || echo "no daemon"
   echo "=== Froggy worker RSS ==="; ps -o pid,rss,comm -p $(pgrep FroggyMLXWorker 2>/dev/null) 2>/dev/null || echo "no worker"
   echo "=== Frontmost app RSS ==="; ps -o pid,rss,comm -p $(osascript -e 'tell application "System Events" to get unix id of first process whose frontmost is true' 2>/dev/null) 2>/dev/null || echo "n/a"
   echo "=== froggy status ==="; froggy status 2>/dev/null || echo "no socket"
   echo "=== froggy pressure ==="; echo '{"cmd":"pressure"}' | nc -U "$HOME/Library/Application Support/Froggy/froggy.sock" 2>/dev/null || echo "no socket"
   echo "=== time-to-first-token ==="; time (echo '{"cmd":"generate","prompt":"hi","maxTokens":1}' | nc -U "$HOME/Library/Application Support/Froggy/froggy.sock" 2>/dev/null | head -1) 2>&1 || echo "no socket"
   ```

3. Если есть `bench/baseline.json` и НЕ --save — читай его, сравни с
   текущим snapshot'ом, выведи diff:
   - daemon RSS Δ
   - worker RSS Δ
   - vm_stat compressor pages Δ
   - time-to-first-token Δ

4. Формат сохранения (`bench/baseline.json`):

   ```json
   {
     "schema_version": 1,
     "captured_at": "<ISO 8601>",
     "scenario": "<idle|model-loaded|under-pressure>",
     "daemon_rss_kb": ...,
     "worker_rss_kb": ...,
     "frontmost_rss_kb": ...,
     "vm_stat_raw": "<full vm_stat output>",
     "froggy_status": <status JSON>,
     "froggy_pressure": <pressure JSON>,
     "ttft_ms": ...
   }
   ```

   Сценарий определяется автоматически: если worker запущен и
   modelLoaded=true → "model-loaded"; если pressure level == "warning"
   или "critical" → "under-pressure"; иначе "idle".

5. На конце — короткий summary: «прирост N MB на worker'е, NN ms TTFT,
   pressure level X». Пользователь читает только это.

## Что НЕ делать
- Не запускать ничего, что требует sudo.
- Не убивать процессы, не вызывать malloc-pressure (для этого есть
  отдельный сценарий «under pressure» — пользователь его создаёт сам
  через ютуб + Xcode build).
- Не делать `swift build` — это инструмент замера, не сборки.
