# Packaging Froggy

This directory contains the bits needed to install `FroggyDaemon` as a per-user
LaunchAgent. **None of this is run by CI** — codesigning and notarization
require Apple Developer ID secrets that don't belong in the repo.

## 1. Build release binaries

```sh
swift build -c release --product FroggyDaemon
swift build -c release --product FroggyMLXWorker
swift build -c release --product FroggyMenuBar
swift build -c release --product froggy
```

С Mem-3 у нас **два** обязательных бинаря для работы LLM: `FroggyDaemon`
и `FroggyMLXWorker`. Worker должен лежать рядом с демоном (`<exec_dir>/FroggyMLXWorker`)
или путь к нему указан в `config.json` (`mlxWorkerPath`). См. ADR 0008.

## 2. Codesign with hardened runtime + entitlements

```sh
codesign --force --options runtime --timestamp \
    --entitlements packaging/Froggy.entitlements \
    --sign "Developer ID Application: Your Name (TEAMID)" \
    .build/arm64-apple-macosx/release/FroggyDaemon
```

The hardened runtime is required for notarization. The shipped
`Froggy.entitlements` keeps the App Sandbox **off** because Vortex needs to
`kill()` other processes the user owns — sandboxed processes cannot signal
pids outside the sandbox, which would break the headline feature.

ScreenCaptureKit, Vision and Apple Events still need user consent in
**System Settings → Privacy & Security** on first run regardless of
entitlements; sandbox vs. hardened-runtime control which APIs you're allowed
to *try*, TCC controls whether the user lets you actually do it.

For `FroggyMenuBar` repeat the same `codesign` invocation against
`.build/arm64-apple-macosx/release/FroggyMenuBar`.

### Pageout strategy `machVM` и `task_for_pid-allow` — честная документация

ADR 0007 описывает три стратегии pageout. Стратегия `machVM` использует
`task_for_pid` + `mach_vm_behavior_set(VM_BEHAVIOR_PAGEOUT)` и в
**стандартной поставке третьему лицу не работает** на чужих процессах.
Для активации требуется одно из двух:

1. **`com.apple.developer.task-for-pid-allow` entitlement** в provisioning
   profile, **выпущенном Apple для этого конкретного приложения**. Это
   право не активируется ни простой dev-подписью, ни Developer ID +
   notarization — нужно отдельно запрашивать у Apple через Apple Developer
   Program. Для third-party tooling Apple **обычно отказывает**: это
   право предполагается для отладочных утилит самого Apple и для
   платформенных партнёров. Раньше существовавший `com.apple.security.cs.debugger`
   entitlement из hardened runtime **не эквивалентен** `task-for-pid-allow`
   — он позволяет attach'иться отладчиком, но `task_for_pid()` против
   чужого процесса всё равно вернёт `KERN_FAILURE`. Прежняя редакция
   этого README ошибочно их объединяла.
2. **Отключённый SIP** (System Integrity Protection). На дев-машинах
   делается через `csrutil disable` в Recovery — не для прода.

В обоих случаях `pageoutStrategy=machVM` нужно явно прописать в
`config.json`. Без этого `PageoutChain` автоматически откатывается на
`jetsam` → `scratch` (см. ADR 0007). Дефолт `jetsam` работает с любой
подписью (даже adhoc) и не требует никаких entitlement'ов.

**TL;DR:** на стандартной поставке ставьте `pageoutStrategy=jetsam`
(default). `machVM` — только если у вас одобренный Apple
provisioning profile или вы у себя в dev-окружении с SIP off.

## 3. Notarize

```sh
xcrun notarytool submit FroggyDaemon.zip \
    --keychain-profile "AC_NOTARY" --wait
xcrun stapler staple .build/arm64-apple-macosx/release/FroggyDaemon
```

(Setup `AC_NOTARY` once with `xcrun notarytool store-credentials`.)

## 4. Install

```sh
sudo install -m 0755 \
    .build/arm64-apple-macosx/release/FroggyDaemon \
    /usr/local/libexec/FroggyDaemon
sudo install -m 0755 \
    .build/arm64-apple-macosx/release/FroggyMenuBar \
    /usr/local/libexec/FroggyMenuBar

mkdir -p ~/Library/LaunchAgents
cp packaging/com.froggychips.froggy.plist \
    ~/Library/LaunchAgents/com.froggychips.froggy.plist
cp packaging/com.froggychips.froggy-menubar.plist \
    ~/Library/LaunchAgents/com.froggychips.froggy-menubar.plist

launchctl bootstrap "gui/$(id -u)" \
    ~/Library/LaunchAgents/com.froggychips.froggy.plist
launchctl bootstrap "gui/$(id -u)" \
    ~/Library/LaunchAgents/com.froggychips.froggy-menubar.plist
launchctl kickstart -k "gui/$(id -u)/com.froggychips.froggy"
launchctl kickstart -k "gui/$(id -u)/com.froggychips.froggy-menubar"
```

### Зачем второй LaunchAgent (ADR 0017)

`com.froggychips.froggy-menubar.plist` поднимает MenuBar UI параллельно
с daemon-ом. Без него daemon молча морозит процессы в фоне, и единственный
способ выключить его — `launchctl bootout` через терминал. С отдельным
agent-ом у пользователя всегда есть On/Off-тумблер в меню-баре: Off
выгружает MLX-модель и thaw-ит все замороженные pid-ы за один клик.

Daemon respect-ит `config.freezingEnabled` при старте — если предыдущая
сессия завершилась в Off, daemon поднимется в idle-режиме (~50 MB,
модель не грузится, freeze-логика отключена) и будет ждать On из MenuBar.

## 5. First run

macOS will prompt twice on first capture:

1. **Screen Recording** — required for ScreenCaptureKit. Approve in
   System Settings → Privacy & Security → Screen Recording.
2. **Accessibility** — only if a future feature needs it. Phase 2 doesn't.

Watch logs:

```sh
log stream --predicate 'subsystem == "com.froggychips.froggy"' --info
```

Or via the IPC socket:

```sh
echo '{"cmd":"status"}' | nc -U ~/Library/Application\ Support/Froggy/froggy.sock
```

## Uninstall

```sh
launchctl bootout "gui/$(id -u)/com.froggychips.froggy-menubar"
launchctl bootout "gui/$(id -u)/com.froggychips.froggy"
rm ~/Library/LaunchAgents/com.froggychips.froggy-menubar.plist
rm ~/Library/LaunchAgents/com.froggychips.froggy.plist
sudo rm /usr/local/libexec/FroggyMenuBar
sudo rm /usr/local/libexec/FroggyDaemon
rm -rf ~/Library/Application\ Support/Froggy
```
