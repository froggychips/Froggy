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

### Pageout strategy `machVM` и `task_for_pid-allow`

ADR 0007 описывает три стратегии pageout. Стратегия `machVM` использует
`task_for_pid` + `mach_vm_behavior_set(VM_BEHAVIOR_PAGEOUT)` и требует
**Apple Developer ID** подпись + provisioning profile с правом
`com.apple.developer.task-for-pid-allow`. На простой dev-подписи это право
не активируется — `task_for_pid` вернёт `KERN_FAILURE`, и `PageoutChain`
автоматически откатится на `jetsam` (а затем `scratch`). Поведение
безопасное по умолчанию: на dev-машине без Developer ID `pageoutStrategy=jetsam`
работает сразу. Чтобы активировать `machVM`, нужно также прописать в
provisioning profile `com.apple.developer.task-for-pid-allow=true` и
выставить `"pageoutStrategy": "machVM"` в `config.json`.

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

mkdir -p ~/Library/LaunchAgents
cp packaging/com.froggychips.froggy.plist \
    ~/Library/LaunchAgents/com.froggychips.froggy.plist

launchctl bootstrap "gui/$(id -u)" \
    ~/Library/LaunchAgents/com.froggychips.froggy.plist
launchctl kickstart -k "gui/$(id -u)/com.froggychips.froggy"
```

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
launchctl bootout "gui/$(id -u)/com.froggychips.froggy"
rm ~/Library/LaunchAgents/com.froggychips.froggy.plist
sudo rm /usr/local/libexec/FroggyDaemon
rm -rf ~/Library/Application\ Support/Froggy
```
