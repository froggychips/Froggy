# Packaging Froggy

This directory contains the bits needed to install `FroggyDaemon` as a per-user
LaunchAgent. **None of this is run by CI** — codesigning and notarization
require Apple Developer ID secrets that don't belong in the repo.

## 1. Build a release binary

```sh
swift build -c release --product FroggyDaemon
```

The binary lands in `.build/arm64-apple-macosx/release/FroggyDaemon`.

## 2. Codesign with hardened runtime

```sh
codesign --force --options runtime --timestamp \
    --sign "Developer ID Application: Your Name (TEAMID)" \
    .build/arm64-apple-macosx/release/FroggyDaemon
```

The hardened runtime is required for notarization. ScreenCaptureKit, Vision and
Apple Events all need an entitlements plist if you sandbox; an unsandboxed
LaunchAgent (the default for this template) just needs hardened runtime + user
TCC consent on first run.

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
