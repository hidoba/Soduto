# Diagnosing connectivity and clipboard failures

This fork combines `fix/network-reliability` (`ca7db3a`) and
`feat/refine-services` (`afcc62d`) from sannidhyaroy/Soduto. It adds recovery
fixes and a persistent, bounded diagnostic journal. The app uses bundle ID
`com.hidoba.Soduto` and version 3.2.1 (32). A first install pairs as a new Mac device;
updates retain the existing identity and pairings.

The menu bar icon has a small badge over its upper-right corner showing the number
of paired, reachable devices, or `×` when none are connected. Counts above 99 show
`99+`. It updates as devices connect, disconnect or change pairing state, including
after sleep or network recovery. Hover for the full connection count.

## Capture a failure

1. Enable **Write diagnostic logs** in **Preferences → Diagnostics**, or in the
   **Diagnostics** menu directly above **Quit**. It is off by default, including
   when upgrading from builds that only had the packet-tracing setting.
2. Reproduce the failure with one Mac client running. On GNOME/Wayland, use
   GSConnect v74 or newer, with the separate KDE Connect daemon stopped.
3. Note the time, direction (Mac → Ubuntu or Ubuntu → Mac), and what failed:
   fresh text clipboard, file transfer, discovery, pairing, or all traffic.
4. Select **Diagnostics → Export Diagnostic Bundle…** before choosing
   **Reconnect All Devices**. Reconnect can recover the session without restarting.
5. Turn **Write diagnostic logs** off when the capture is finished. Turning it off
   drains queued writes, closes the journal and stops further collection. It keeps
   existing logs; enable writing again to export them. The choice is remembered.

Settings and the menu toggle stay synchronized. Export, Open Diagnostic Logs and
Detailed Packet Logging are disabled while writing is off. Reconnect All Devices
remains available. No diagnostic journal is created or appended automatically
while writing is off. Ordinary macOS Console logging is separate.

The ZIP contains the journal and a `summary.json` snapshot. It does not contain
clipboard text, notifications, filenames, file contents, IP/MAC addresses,
certificates, private keys, or preferences dumps. Device IDs are replaced with
random aliases that are stable during one launch. Packet types, IDs, sizes,
protocol versions, timestamps and service capabilities are included.

The journal keeps **four files of at most 5 MiB each**, surviving app restarts.
The newest file is `events.jsonl`, followed by `events.1.jsonl`, etc. Each line is
JSON and contains wall-clock time, monotonic uptime, session, severity, event
name, and metadata. Partial records left by a crash are trimmed on next open.
Files are private to the user (0600, directory 0700).

**Detailed Packet Logging** defaults on **only after Write diagnostic logs is enabled**. Turn it off to retain a longer
window of lifecycle events when packet traffic is high. It logs packet metadata
and service dispatch results, never the packet body. No logs are uploaded.

**Open Diagnostic Logs** opens the live journal directory in Finder. A sandboxed
build normally stores it under:

```text
~/Library/Containers/com.hidoba.Soduto/Data/Library/Application Support/Soduto/Diagnostics/
```

An unsandboxed development build uses:

```text
~/Library/Application Support/Soduto/Diagnostics/
```

The save dialog exports a consistent snapshot while logging continues. Export
failures display an error, and journal write failures are reported in the
summary. Apple Console logs are intentionally excluded from the ZIP: inherited
upstream logging statements can contain personal information in debug builds.

## Keychain access prompts

Build 32 adds complete ad-hoc app-bundle signing and a strict signature check
before packaging. It is not Developer ID signing or notarization. Build 31's
bundle failed signature verification despite its linker-signed executable.
Legacy keys retain their `<key>` access description. The affected key has separate
signing and app-trust checks. On 2026-10-23, macOS recorded Always Allow for the
installed build 32. Restarting that exact unchanged copy completed eight TLS
handshakes without additional Keychain prompts or signing failures during
observation. This interactive result is separate from the automated tests and
does not guarantee that a different app binary will retain the same approval.

Build 31 avoids the implicit private-key exports that still occurred in build 30
for legacy identities. Apple's high-level RSA signing and algorithm-support APIs
read private-key attributes, internally attempting export. TLS now uses only the
public certificate's metadata, encodes its signature padding and requests raw RSA
signing inside Keychain. Control and payload transfers share that path. Existing
identities are retained. New keys display **Soduto Device Identity**. Legacy keys can retain the
`<key>` display name; this update does not replace them or loosen their access controls.
Because these releases lack a stable Developer ID signature, macOS may request normal
Keychain access after an app replacement. If access is denied,
further attempts are suspended for that identity until **Diagnostics → Reconnect
All Devices** or an app restart. This prevents discovery/reconnect loops from
repeatedly opening authorization dialogs. Enable log writing before retrying to
capture the error domain and code. Temporary failures can retry during normal
connection recovery after wake or unlock. The logs never contain the key, signed data,
signature bytes, or certificate.

## Read the timeline

Filter by `session`, then match the `connection` UUID and `device` alias:

| Event | Meaning |
| --- | --- |
| `app.will_sleep` / `app.woke` | Sleep/wake boundary. Wake forces fresh connections. |
| `network.path_changed` | Reachability, interface types, IPv4/IPv6 and cost changed. |
| `network.restarting` | Why listeners and existing connections are being reset. |
| `discovery.mdns_*` | Browse/resolve/retry and advertisement failures. |
| `discovery.udp_*` | Announcements accepted or discarded. |
| `connection.tcp_connected` | TCP finished; the first identity is now sent. |
| `connection.tls_*` | TLS progress or failure. |
| `keychain.signature_completed` | Keychain signed a TLS challenge; only the algorithm number is logged. |
| `keychain.signing_suspended` | Access was denied; an explicit reconnect retries access. |
| `keychain.signing_failed` | An operational Keychain error; ordinary connection recovery can retry. |
| `connection.handshake_timeout` | Ten-second initialization deadline expired; `phase` identifies where. |
| `connection.state_changed` | Initializing → Open → Closed lifecycle. |
| `pairing.request_received` | A valid incoming pairing or re-pair request needs user approval. |
| `pairing.invalid_packet` | Malformed pairing data or a v8 clock difference exceeding thirty minutes. |
| `pairing.interrupted` / `pairing.timed_out` | A pending request lost its connection or reached its deadline. Existing pairing pins survive ordinary disconnects. |
| `pairing.duplicate_ignored` | A duplicate acceptance was ignored without generating another reply. |
| `packet.sending` / `packet.received` | Packet type, ID and byte count. Sending means queued to the socket, not acknowledged by the peer. |
| `service.packet_handled` | Service that consumed an incoming packet. |
| `service.packet_unhandled` | Packet arrived but no active service accepted it. |
| `clipboard.*` | Local observation, send, apply or ignore decision and timestamps. |
| `payload.*` | Transfer completion or failure. |
| `app.health` | Thirty-second reachable/unavailable device counts. |

If the UI says connected but there is no `packet.received` after new text is
copied on Ubuntu, inspect the Ubuntu clipboard integration and connection path.
If `kdeconnect.clipboard` arrives but no `clipboard.applied` follows, inspect the
service dispatch and direction settings. A `clipboard.connect_ignored` event
with `remote_not_newer` is expected for stale/unknown reconnect contents; a fresh
`kdeconnect.clipboard` packet is still applied.

Clipboard decisions also distinguish identical content, previously seen generations,
older generations and timestamp ties. A bounded in-memory cache remembers only
SHA256 fingerprints and timestamps; fingerprints are never written to the journal.
Decision records include timestamps to help compare freshness. Copies
observed in the same millisecond receive increasing timestamps. This fork marks
its ordered normal clipboard packets with `sodutoTimestamped`; ordinary KDE
Connect packets remain live edits without depending on their sender's clock.
Identical text never clears the pasteboard, preserving its other representations.
On reconnect, obsolete queued clipboard sends are discarded and current text
is synchronized instead. Images synchronize on copy while connected; the protocol
has no image reconnect freshness handshake.
KDE's reconnect text packet can contain the temporary URL of a received image;
`image_file_url_connect` records ignoring that URL while a local image is present.
Ordinary live text packets containing URLs remain supported.

From build 33, `clipboard.image_receiving`, `image_sent`, `image_applied`,
`image_ignored`, `image_cancelled`, and `image_failed` events record image decisions
under the `clipboard.` prefix. Reasons distinguish disabled directions, peers
without image capability, invalid/oversized images, incomplete payloads, transfer
timeouts, identical pixels, replayed generations, and clipboard/connection changes.
Only byte counts, timestamps, peer aliases and fixed reason codes are logged;
image data, filenames and pixel fingerprints are excluded. Incoming image payloads
use `kdeconnect.clipboard.file` and the existing authenticated TLS payload transport.
The limits are 50 MiB encoded and 16,777,216 pixels decoded, with a 35-second
transfer deadline. Copies and disconnects cancel pending downloads; decoding runs
off the main thread and checks freshness again before touching the pasteboard.
While a generation is downloading, older marked packets cannot cancel it. A new
local copy supersedes even an in-flight generation from a peer whose clock is
ahead. Equal-timestamp image conflicts send a bounded correction to converge on
the same pixel fingerprint across peers.
Superseded sockets can finish existing payload uploads but cannot apply delayed
clipboard updates or unpair the replacement session.

Error records contain error domain, numeric code, Swift type and associated enum
case label rather than arbitrary error
descriptions, which may contain paths or other personal data. Handshake timeout
records include the last phase and elapsed time. They cannot by themselves prove
whether a firewall, peer bug, certificate mismatch or network outage caused a
timeout; compare the peer's logs at the same time.

## Regression checks

```sh
swift test
python3 scripts/test-clipboard-service.py
python3 scripts/test-pairing-transport.py
python3 scripts/test-diagnostics-settings.py
```

The Swift package tests clipboard timestamp state, port validation, restart
cooldowns, log privacy, permissions, rotation, persistence, concurrent writes,
export snapshots, the actual ZIP export, I/O failure reporting and recovery from a partial record.
The integration harness compiles the actual `ClipboardService.swift` against a
fake pasteboard/peer boundary. It covers offline copies, copies between timer
ticks, non-text clipboard protection, legacy clients, three-peer relay loops,
hub forwarding, interleaved generations, direction preferences, intentional
repeated copies and invalid timestamps. Image scenarios cover real ImageIO
PNG/TIFF conversion, independent per-peer streams, capability negotiation,
direction settings, malformed/truncated/oversized data, slow-transfer cancellation,
decode/reconnect races, timeouts, duplicate pixels, and mixed text/image relay meshes.
A native AppKit check writes to a unique private pasteboard and verifies that
NSImage recognizes the resulting PNG. The system's general pasteboard is untouched.
The pairing/transport harness runs the production pairing handler, device,
device manager, service dispatch and extracted connection event callbacks with
fake transport, certificates and UI. It covers protocol 7/8, verification hashes,
invalid and expired requests, explicit re-pair approval, duplicate accepts,
missing certificates, interrupted requests, stale verification prompts, callback ordering, capability refresh
and stale clipboard queues, including refused and disconnected image uploads.
Both harnesses avoid the user's clipboard and keychain. The diagnostic settings
harness uses isolated preferences and temporary journals to check default-off
behavior, privacy, concurrent stop, persistence, menu order, UI synchronization and
disabled actions. It does not change the actual app settings or journal.

GitHub Actions also builds the entire Release app and extensions on macOS 26.
It uploads an **ad-hoc-signed** app ZIP and checksum for review; this is not a
notarized release. The historical Xcode certificate tests are not run by this
workflow because they change the user's default keychain.

Before treating a build as stable, exercise these with the actual Ubuntu peer:

- Plain text both directions, including several consecutive copies.
- Copy on Mac while disconnected, then reconnect with older text on Ubuntu.
- Sleep/wake repeatedly, including after a Wi-Fi address change.
- Disable/re-enable Wi-Fi and switch between Wi-Fi and Ethernet/VPN routes.
- Relaunch each client independently; test a transfer after reconnecting.
- Toggle incoming/outgoing clipboard settings and inspect the resulting events.
- Disable/re-enable the peer's clipboard plugin, then reconnect within fifteen seconds.
- Pair from each side, cancel from each side, and disconnect during a pending request.
- Re-pair after forgetting the Mac on Ubuntu; compare the verification codes.
- Pair three clients and confirm that one copy settles without repeated packets.
- Export while a transfer is active, relaunch, and confirm prior events remain.

## Fork updates

Automatic Sparkle updates from upstream are disabled for this fork. The menu
opens [our releases](https://github.com/hidoba/Soduto/releases) instead. This
prevents an upstream update from silently replacing the recovery fixes and
diagnostics. Never reuse upstream's signing identity for a fork release.
