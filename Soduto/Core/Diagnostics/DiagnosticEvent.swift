import Foundation

/// Metadata only. Never pass packet bodies, clipboard text, paths or credentials.
struct DiagnosticEvent: Codable {
    enum Level: String, Codable { case debug, info, warning, error }

    let timestamp: Date
    let uptime: TimeInterval
    let session: String
    let level: Level
    let event: String
    let fields: [String: String]

    // Explicit allowlist prevents an accidental `content` or `body` field from
    // turning a support bundle into a copy of the user's clipboard/messages.
    static let allowedFields: Set<String> = [
        "connection", "device", "packet_type", "packet_id", "bytes", "payload_bytes",
        "state", "previous_state", "reason", "phase", "protocol", "direction",
        "error_domain", "error_code", "error_type", "error_case", "elapsed_ms", "available", "interfaces",
        "expensive", "constrained", "ipv4", "ipv6", "tcp_port", "pending",
        "paired", "reachable", "unavailable", "app_version", "build", "os_version",
        "architecture", "enabled", "count", "incoming", "outgoing", "service",
        "image_file_send_supported", "image_file_receive_supported",
        "change_count", "timestamp_ms", "remote_timestamp_ms", "local_timestamp_ms",
        "result", "retry_seconds", "active_uploads", "received", "sent", "generation"
    ]

    init(session: String, level: Level, event: String, fields: [String: String] = [:],
         timestamp: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.timestamp = timestamp
        self.uptime = uptime
        self.session = session
        self.level = level
        self.event = String(event.prefix(120))
        self.fields = fields.filter { Self.allowedFields.contains($0.key) }
            .mapValues { String($0.prefix(200)) }
    }
}
