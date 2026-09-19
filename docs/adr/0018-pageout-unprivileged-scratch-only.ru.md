# ADR 0018 — Pageout без привилегий недостижим: `scratch` — единственная рабочая стратегия

* **Статус:** Принято
* **Дата:** 2026-09-19
* **Частично заменяет:** [`0007-pageout-strategies.ru.md`](0007-pageout-strategies.ru.md)
  (дефолтную стратегию и обещания про `jetsam` / `machVM`)

## Контекст

ADR 0007 ввёл три стратегии pageout и сделал дефолтом `jetsam` с формулировкой
«работает на любой подписи, entitlement'ы не нужны». Ревью 19.09.2026 (Codex
как второй ревьюер, затем ручная сверка с заголовками macOS SDK и исходниками
XNU) установило четыре факта:

1. **`VM_BEHAVIOR_PAGEOUT` = `11`, а не `6`.** В `Pageout.swift` стоял литерал
   `6`, который `mach/vm_behavior.h` определяет как `VM_BEHAVIOR_FREE` —
   «освободить память без write-back». При удачном `task_for_pid` стратегия
   `machVM` не выгружала бы, а *уничтожала* содержимое всех writable-регионов
   чужого процесса. Тот же заголовок помечает `VM_BEHAVIOR_PAGEOUT` как
   «development only»: release-ядро отвечает `KERN_INVALID_ARGUMENT` на каждый
   регион, а старый код считал это `.success` с нулём страниц.
2. **`MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES` = `2`, а не `1`.** Приватный
   заголовок `bsd/sys/kern_memorystatus.h` определяет `1` как
   `GET_PRIORITY_LIST`. Стратегия `jetsam` всё время посылала команду *чтения*
   с 16-байтовым буфером на запись.
3. **`memorystatus_control` — привилегированный вызов.** В
   `bsd/kern/kern_memorystatus.c` вход в syscall проверяет
   `kauth_cred_issuser() || IOCurrentTaskHasEntitlement("com.apple.private.memorystatus")`,
   иначе `EPERM`. Без проверки проходят только `SET/GET_PROCESS_IS_FREEZABLE`
   и `GET_PROCESS_IS_FROZEN`. Исправление кода команды **не** делает `jetsam`
   достижимым для пользовательского LaunchAgent.
4. **Наш собственный baseline это уже показывал.** Каждый pressure-снимок в
   `bench/baseline.json` содержит `jetsamAttempted: 1, jetsamFailed: 1,
   jetsamSucceeded: 0, scratchSucceeded: 1`. Цепочка всегда проваливалась до
   `scratch`. В `TODO.md` стоял гейт ровно на этот случай («если `succeeded = 0`
   под jetsam — остановиться и разобраться с substrate»); гейт сработал, а
   разработка пошла дальше.

## Решение

* Дефолт `PageoutChain` — `.scratch`. `machVM` и `jetsam` остаются в коде как
  явный opt-in для окружений, где привилегии действительно есть (root,
  отключённый SIP, development-ядро), и задокументированы именно так. Никаких
  «без entitlement'ов».
* Константы берутся из символов SDK (`VM_BEHAVIOR_PAGEOUT`,
  `VM_REGION_BASIC_INFO_64`). Единственное приватное значение без символа в
  SDK (`MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES = 2`) задокументировано со
  ссылкой на источник.
* `MachVMPageoutImpl` возвращает `.failed`, если behavior не принял **ни один**
  регион — цепочка откатывается дальше, а не рапортует пустой успех.
  `JetsamPageoutImpl` при `EPERM` называет причину словами.
* Дефолт `FroggyConfig.pageoutStrategy` — `.scratch` (меняется в ветке
  daemon-hardening того же ревью). Существующие `config.json` с `jetsam`
  продолжают работать: попытка быстро падает с `EPERM` и откатывается на
  `scratch`, как и всегда, — только теперь счётчики и лог объясняют почему.

## Последствия

* **Честные цифры.** `pageoutCounters` в IPC-ответе `pressure` перестают
  показывать вечно падающую стратегию как основную.
* **Что Froggy реально делает под давлением** — `SIGSTOP` плюс 256 МБ scratch-
  аллокации, подталкивающей компрессор. Это слабее, чем обещал ADR 0007, и README
  теперь говорит именно это. Окупает ли `scratch` собственную цену на 8 ГБ —
  вопрос к `bench/`, не к этому ADR.
* **`machVM` снова безопасно включать** там, где работает `task_for_pid`: он либо
  выгружает страницы (development-ядро), либо чисто падает (release-ядро). Он
  больше не освобождает страницы за спиной у процесса.

## Отвергнутые альтернативы

1. **Привилегированный helper с `com.apple.private.memorystatus`.** Отвергнуто:
   entitlement приватный Apple, третьим сторонам не выдаётся; root-helper
   противоречит модели пользовательского LaunchAgent (ADR 0012, `SECURITY.md`).
2. **Требовать SIP off для `machVM`.** Отвергнуто как дефолт: это настройка
   dev-машины, и `VM_BEHAVIOR_PAGEOUT` всё равно требует development-ядра.
3. **Удалить `machVM` и `jetsam`.** Не сделано: код небольшой, покрыт через
   `FakePageoutImpl` и полезен тем, кто гоняет Froggy на development-ядре. Они
   opt-in, а не удалены.
