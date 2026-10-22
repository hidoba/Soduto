# Diagnosing connectivity and clipboard failures

This fork combines `fix/network-reliability` (`ca7db3a`) and
`feat/refine-services` (`afcc62d`) from sannidhyaroy/Soduto. It adds recovery
fixes and a persistent, bounded diagnostic journal. The app uses bundle ID
`com.hidoba.Soduto` and version 3.2.0 (26). Pair this fork as a new Mac device.

## Capture a failure

1. Reproduce the failure with one Mac client running. On GNOME/Wayland, use
   GSConnect v74 or newer, with the separate KDE Connect daemon stopped.
2. Note the time, direction (Mac → Ubuntu or Ubuntu → Mac), and what failed:
   fresh text clipboard, file transfer, discovery, pairing, or all traffic.
3. In Soduto's menu, select **Diagnostics → Export Diagnostic Bundle…**.
4. After exporting, **Diagnostics → Reconnect All Devices** can recover the
   session without restarting the app. Capture before recovering when possible.

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

**Detailed Packet Logging** is on by default. Turn it off to retain a longer
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
SHA256 fingerprints and timestamps; neither is written to the journal. Copies
observed in the same millisecond receive increasing timestamps. This fork marks
its ordered normal clipboard packets with `sodutoTimestamped`; ordinary KDE
Connect packets remain live edits without depending on their sender's clock.
Identical text never clears the pasteboard, preserving its other representations.
On reconnect, obsolete queued clipboard sends are discarded and the current
pasteboard is synchronized instead.
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
```

The Swift package tests clipboard timestamp state, port validation, restart
cooldowns, log privacy, permissions, rotation, persistence, concurrent writes,
export snapshots, the actual ZIP export, I/O failure reporting and recovery from a partial record.
The integration harness compiles the actual `ClipboardService.swift` against a
fake pasteboard/peer boundary. It covers offline copies, copies between timer
ticks, non-text clipboard protection, legacy clients, three-peer relay loops,
interleaved generations, intentional repeated copies and invalid timestamps.
The pairing/transport harness runs the production pairing handler, device,
device manager, service dispatch and extracted connection event callbacks with
fake transport, certificates and UI. It covers protocol 7/8, verification hashes,
invalid and expired requests, explicit re-pair approval, duplicate accepts,
missing certificates, interrupted requests, callback ordering, capability refresh
and stale clipboard queues. Both harnesses avoid the real clipboard and keychain.

GitHub Actions also builds the entire Release app and extensions on macOS 26.
It uploads an **unsigned** app ZIP and checksum for review; this is not a
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
