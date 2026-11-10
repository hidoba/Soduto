//
//  PreferencesWindowController.swift
//  Soduto
//
//  Created by Giedrius Stanevičius on 2016-08-30.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Foundation
import Cocoa

public class PreferencesWindowController: NSWindowController {
    
    private var localKeyMonitor: Any?
    
    deinit {
        if let monitor = localKeyMonitor { NSEvent.removeMonitor(monitor) }
    }
    
    var deviceDataSource: DeviceDataSource? {
        didSet { self.preferencesTabViewController?.deviceDataSource = self.deviceDataSource }
    }
    var config: HostConfiguration? {
        didSet { self.preferencesTabViewController?.config = self.config }
    }
    
    var preferencesTabViewController: PreferencesTabViewController? {
        assert(self.contentViewController is PreferencesTabViewController)
        return self.contentViewController as? PreferencesTabViewController
    }
    
    static func loadController() -> PreferencesWindowController {
        let storyboard = NSStoryboard(name: "PreferencesWindow", bundle: nil)
        return storyboard.instantiateInitialController() as! PreferencesWindowController
    }
    
    func refreshDeviceLists() {
        self.preferencesTabViewController?.refreshDeviceLists()
    }
    
    public override func windowDidLoad() {
        super.windowDidLoad()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window,
                  event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers == "w" else { return event }
            self.window?.performClose(nil)
            return nil
        }
        
        let screenRect = NSScreen.main?.frame ?? NSRect.zero
        self.window?.setFrame(NSRect(x: screenRect.width / 2 - 340, y: screenRect.height / 2 - 200, width: 680, height: 400), display: false)
        
        // Configure window for modern macOS appearance
        if let window = self.window {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            
            // Remove title but preserve window controls (close, minimize, zoom buttons)
            if let titlebarView = window.standardWindowButton(.closeButton)?.superview {
                titlebarView.superview?.wantsLayer = true
            }
        }
        
        self.preferencesTabViewController?.deviceDataSource = self.deviceDataSource
        self.preferencesTabViewController?.config = self.config
    }
    
    public override func showWindow(_ sender: Any?) {
        // make sure window is loaded
        let _ = self.window
        
        NSApp.activate(ignoringOtherApps: true)
        
        super.showWindow(sender)
    }
}


// MARK: - PreferencesTabViewController

class PreferencesTabViewController: NSTabViewController {
    
    var deviceDataSource: DeviceDataSource? { didSet { updateDeviceDataSourceForSelectedTab() } }
    var config: HostConfiguration? { didSet { updateConfigForSelectedTab() } }
    
    override var selectedTabViewItemIndex: Int {
        didSet {
            updateDeviceDataSourceForSelectedTab()
            updateConfigForSelectedTab()
            refreshDeviceLists()
        }
    }
    
    func refreshDeviceLists() {
        guard !self.tabView.tabViewItems.isEmpty else { return }
        let selectedTabViewItem = self.tabView.tabViewItem(at: selectedTabViewItemIndex)
        if let controller = selectedTabViewItem.viewController as? DevicePreferencesViewController {
            controller.refreshDeviceList()
        }
        else if let controller = selectedTabViewItem.viewController as? ServicePreferencesViewController {
            controller.refreshDeviceList()
        }
    }
    
    public override func viewDidLoad() {
        super.viewDidLoad()
        let diagnosticsTab = NSTabViewItem(viewController: DiagnosticsPreferencesViewController())
        diagnosticsTab.label = "Diagnostics"
        diagnosticsTab.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: nil)
        addTabViewItem(diagnosticsTab)
        updateDeviceDataSourceForSelectedTab()
        updateConfigForSelectedTab()
    }
    
    private func updateDeviceDataSourceForSelectedTab() {
        guard !self.tabView.tabViewItems.isEmpty else { return }
        let selectedTabViewItem = self.tabView.tabViewItem(at: selectedTabViewItemIndex)
        if let controller = selectedTabViewItem.viewController as? DevicePreferencesViewController {
            controller.deviceDataSource = self.deviceDataSource
        }
        else if let controller = selectedTabViewItem.viewController as? ServicePreferencesViewController {
            controller.deviceDataSource = deviceDataSource
        }
    }
    
    private func updateConfigForSelectedTab() {
        guard !self.tabView.tabViewItems.isEmpty else { return }
        let selectedTabViewItem = self.tabView.tabViewItem(at: selectedTabViewItemIndex)
        if let controller = selectedTabViewItem.viewController as? DevicePreferencesViewController {
            controller.config = self.config
        }
    }
}

/// Shares the same setting as the Diagnostics menu; logging starts disabled.
final class DiagnosticsPreferencesViewController: NSViewController {
    private let diagnostics: Diagnostics
    private var writeLogsCheckbox: NSButton!

    init(diagnostics: Diagnostics = .shared) {
        self.diagnostics = diagnostics
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init(diagnostics:)") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func loadView() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 320))
        let heading = NSTextField(labelWithString: "Diagnostics")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        writeLogsCheckbox = NSButton(checkboxWithTitle: "Write diagnostic logs", target: self, action: #selector(toggleLogWriting(_:)))
        let explanation = NSTextField(wrappingLabelWithString: "Record connection, pairing and clipboard events to help troubleshoot problems. Off by default. Clipboard text, messages, file contents and keys are never included.")
        explanation.textColor = .secondaryLabelColor
        let retention = NSTextField(wrappingLabelWithString: "Logs stay on this Mac and use up to 20 MiB. Turning logging off stops writing and keeps existing logs. Enable it again to export them from the Diagnostics menu.")
        retention.textColor = .secondaryLabelColor
        for control in [heading, writeLogsCheckbox!, explanation, retention] {
            control.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(control)
        }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            writeLogsCheckbox.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            writeLogsCheckbox.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 20),
            explanation.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            explanation.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
            explanation.topAnchor.constraint(equalTo: writeLogsCheckbox.bottomAnchor, constant: 12),
            retention.leadingAnchor.constraint(equalTo: explanation.leadingAnchor),
            retention.trailingAnchor.constraint(equalTo: explanation.trailingAnchor),
            retention.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 16)
        ])
        view = content
        syncLogWriting()
        NotificationCenter.default.addObserver(self, selector: #selector(syncLogWriting),
                                              name: Diagnostics.loggingSettingDidChange, object: diagnostics)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        syncLogWriting()
    }

    @objc private func syncLogWriting() {
        writeLogsCheckbox.state = diagnostics.writeLogsEnabled ? .on : .off
    }

    @objc private func toggleLogWriting(_ sender: NSButton) {
        diagnostics.writeLogsEnabled = sender.state == .on
    }
}
