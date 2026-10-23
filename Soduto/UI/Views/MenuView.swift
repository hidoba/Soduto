// Copyright © 2026 Soduto contributors. Licensed under GPL v3.

import AppKit

/// Device rows stay native menu items so submenu tracking, keyboard navigation,
/// accessibility, and the user's appearance settings continue to work.
@MainActor
enum DeviceMenuPresentation {
    static func apply(to item: NSMenuItem, name: String, type: String,
                      connected: Bool, battery: Int?, charging: Bool,
                      networks: [String] = []) {
        let state = connected ? "Connected" : "Offline"
        var details = [state]
        if connected, let battery, (0...100).contains(battery) {
            details.append("\(battery)%" + (charging ? " · Charging" : " battery"))
        }
        if connected {
            // Peer-provided labels stay small and cannot add extra menu lines.
            let labels = networks.prefix(2).compactMap { value -> String? in
                let label = value.filter { !$0.isNewline && !$0.isWhitespace }.prefix(12)
                return label.isEmpty || label == "Unknown" ? nil : String(label)
            }
            details.append(contentsOf: labels)
        }
        let summary = details.joined(separator: " · ")
        item.title = name
        item.toolTip = "\(name) — \(summary)"
        if #available(macOS 14.4, *) {
            // Keep the standard title on 14.x: attributed titles hide its subtitle.
            item.attributedTitle = nil
            item.subtitle = summary
        } else {
            item.attributedTitle = NSAttributedString(string: "\(name) — \(summary)")
        }
        item.image = icon(type: type, connected: connected)
        // macOS 27 normally hides NSMenuItem images. Use its public Objective-C
        // property dynamically so releases can still build with the macOS 26 SDK.
        let visibilitySetter = NSSelectorFromString("setPreferredImageVisibility:")
        if item.responds(to: visibilitySetter) {
            item.setValue(1, forKey: "preferredImageVisibility") // .visible
        }
    }

    static func icon(type: String, connected: Bool) -> NSImage {
        let symbol: String
        let accent: NSColor
        switch type {
        case "desktop": (symbol, accent) = ("desktopcomputer", .systemOrange)
        case "laptop": (symbol, accent) = ("laptopcomputer", .systemBlue)
        case "phone": (symbol, accent) = ("iphone", .systemGreen)
        case "tablet": (symbol, accent) = ("ipad", .systemTeal)
        case "tv": (symbol, accent) = ("tv", .systemPurple)
        default: (symbol, accent) = ("network", .secondaryLabelColor)
        }
        let color = connected ? accent : .secondaryLabelColor
        let size = NSSize(width: 30, height: 30)
        let image = NSImage(size: size, flipped: false) { _ in
            let tile = NSRect(x: 1, y: 1, width: 27, height: 27)
            color.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: tile, xRadius: 7, yRadius: 7).fill()
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))?
                .withSymbolConfiguration(.init(paletteColors: [color])) {
                let factor = min(17 / glyph.size.width, 17 / glyph.size.height)
                let target = NSSize(width: glyph.size.width * factor, height: glyph.size.height * factor)
                glyph.draw(in: NSRect(x: tile.midX - target.width / 2,
                                      y: tile.midY - target.height / 2,
                                      width: target.width, height: target.height))
            }
            let dot = NSRect(x: 23, y: 1, width: 6, height: 6)
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(ovalIn: dot.insetBy(dx: -1, dy: -1)).fill()
            (connected ? NSColor.systemGreen : .tertiaryLabelColor).setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
