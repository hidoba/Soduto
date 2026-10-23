# Soduto — hidoba fork

## TLDR

- Supports copying images and single files with compatible peers. Official GSConnect supports text clipboard only; see my [GSConnect fork](https://github.com/hidoba/gnome-shell-extension-gsconnect/tree/hidoba) for image/file clipboard work.
- Shows the number of connected devices as a small badge over the menu bar icon, or `×` when none are connected. Device rows include icons, connection status, and reported battery details.
- Includes unfinished and unreleased work from [sannidhyaroy/Soduto](https://github.com/sannidhyaroy/Soduto): protocol v8, SMS conversation browsing and sending through a paired Android phone, contact syncing, and service/interface refinements.
- Adds diagnostic logs, **off by default**, to help report and debug problems.
- Includes connection improvements and bugfixes for clipboard sync, pairing, sleep/wake, Wi-Fi changes, and repeated Keychain prompts.

**[Download Soduto 3.2.1](https://github.com/hidoba/Soduto/releases/latest)**
· [Release notes](docs/releases/3.2.1.md)

Requires **macOS 14 or newer**. The app supports **Apple Silicon and Intel** and is ad-hoc signed, without Developer ID signing or notarization.

## Clipboard

Copy text, an image, or one regular file on either computer and paste it on the other. Image and file transfers require a peer supporting KDE Connect's `kdeconnect.clipboard.file` protocol, such as KDE Connect 25.12.3. A successful text copy or pairing alone does not establish image/file support.

- Image and file transfers are limited to **50 MiB**. Folders, symlinks, and multiple-file selections are unsupported.
- Incoming and outgoing clipboard sharing can be enabled separately. Outdated transfers cannot overwrite newer copies.
- Source files are preserved. Received files use a private temporary cache and are never opened automatically.

On Linux, received images are exposed as temporary file URLs. Paste behavior depends on the target application and desktop clipboard integration, particularly on GNOME/Wayland. End-to-end image/file clipboard compatibility with Ubuntu GNOME/Wayland still needs real-device validation.

## Connection improvements and bugfixes

Supports KDE Connect protocols **7 and 8**, improves recovery after sleep or network changes, and avoids unnecessary disconnects. Pairing uses certificate verification and handles interrupted requests without reply loops. Clipboard fixes improve freshness, duplicate handling, and transfers between multiple devices.

Keychain fixes avoid private-key exports and repeated authorization attempts while preserving existing identities and pairings. Updating the app may still require normal Keychain approval. Use **Diagnostics → Reconnect All Devices** to retry after denying access.

## Connection badge

The badge shows the number of connected, paired devices: `×` for none, the count for 1–99, and `99+` above that. Hover over the icon for the full count.

![Connection badge examples in dark and light appearances](docs/images/menu-bar-connection-badge.png)

## Diagnostics

Logging is **off by default**. Enable **Write diagnostic logs** in **Preferences → Diagnostics** or the **Diagnostics** menu directly above **Quit**.

To report a problem, enable logging, reproduce it, then select **Diagnostics → Export Diagnostic Bundle…** before reconnecting. Logs cover connections, pairing, and clipboard decisions without recording clipboard contents, filenames, IP/MAC addresses, certificates, or private keys. Nothing is uploaded automatically.

Logs are capped at **20 MiB**. Turning logging off stops collection and keeps existing logs. Log-related menu actions are disabled while logging is off; **Reconnect All Devices** remains available.

See the [diagnostics guide](docs/diagnostics.md) for troubleshooting and testing details.

## Install and update

1. Download the ZIP and matching `.sha256` file from the [latest release](https://github.com/hidoba/Soduto/releases/latest). Verify the ZIP with `shasum -a 256 -c <downloaded-checksum-file>`.
2. Quit Soduto and other Mac KDE Connect clients, extract the ZIP, and move `Soduto.app` into Applications. macOS may block this unnotarized app.
3. Launch Soduto and pair your devices. Updates of this fork preserve its pairings and preferences; the first installation pairs as a new Mac device.

Updates are manual: use **Fork Releases on GitHub…** in the app. Automatic upstream updates are disabled.

## Build and test

Use **Xcode 26 or newer**:

```sh
git clone --branch codex/reliability-diagnostics https://github.com/hidoba/Soduto.git
cd Soduto
cp LocalConfig.xcconfig.example LocalConfig.xcconfig
open Soduto.xcodeproj
```

Set your `DEVELOPMENT_TEAM` in `LocalConfig.xcconfig`, keep the fork's bundle ID, let Xcode resolve the Swift packages, and build the `Soduto` scheme.

Run the regression checks with the Xcode toolchain selected:

```sh
swift test
python3 scripts/test-clipboard-service.py
python3 scripts/test-pairing-transport.py
python3 scripts/test-diagnostics-settings.py
python3 scripts/test-keychain-tls.py
python3 scripts/test-keychain-legacy.py
```

See the [packaging script](scripts/package-release.py) for release packaging, and the [diagnostics guide](docs/diagnostics.md) for real-device tests. Builds and checks can run locally. GitHub Actions builds are manual only, so pushes and pull requests do not start duplicate jobs. To build a universal app with the full regression suite, run:

```sh
gh workflow run build.yml --repo hidoba/Soduto --ref codex/reliability-diagnostics -f runner=macos-26
```

The run uploads the packaged app, its SHA-256 checksum, and separate build/test logs, including logs from failed tests.

## Upstream work and attribution

This fork combines the upstream [`fix/network-reliability`](https://github.com/sannidhyaroy/Soduto/commit/ca7db3a) and [`feat/refine-services`](https://github.com/sannidhyaroy/Soduto/commit/afcc62d) branches with additional clipboard, pairing, and connection fixes.

Other inherited features include notifications, file sharing/SFTP, battery reporting, media controls, and remote input. See [upstream](https://github.com/sannidhyaroy/Soduto) for the broader feature documentation; those services have not all been validated in this fork.

Thanks to [sannidhyaroy/Soduto](https://github.com/sannidhyaroy/Soduto) and the original [soduto/Soduto](https://github.com/soduto/Soduto). Their attribution remains in place. Licensed under the [GNU GPL v3](LICENSE).
