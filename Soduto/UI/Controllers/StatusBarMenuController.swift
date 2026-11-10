//
//  StatusBarMenuController.swift
//  Soduto
//
//  Created by Giedrius Stanevicius on 2016-07-26.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Foundation
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import Combine

public class StatusBarMenuController: NSObject, NSWindowDelegate, NSMenuDelegate, NSDraggingDestination {
    
    @IBOutlet weak var statusBarMenu: NSMenu!
    @IBOutlet weak var availableDevicesItem: NSMenuItem!
    @IBOutlet weak var launchOnLoginItem: NSMenuItem!
    @IBOutlet weak var dashboardMenuItem: NSMenuItem!
    
    public var deviceDataSource: DeviceDataSource? {
        didSet { updateConnectionCount() }
    }
    public var serviceManager: ServiceManager?
    public var config: Configuration?
    
    let statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var statusBarBaseIcon: NSImage?
    private var displayedConnectionCount: Int?
    private var cancellables: Set<AnyCancellable> = []
    /// Persistent references to device menu items keyed by device ID, for in-place image updates
    private var deviceMenuItems: [String: NSMenuItem] = [:]
    
    lazy var preferencesWindowController: PreferencesWindowController? = {
        let controller = PreferencesWindowController.loadController()
        controller.deviceDataSource = self.deviceDataSource
        controller.config = self.config
        return controller
    }()
    
    private var dashboardWindowController: DeviceDashboardWindowController?
    private var remoteControlWindowController: RemoteControlWindowController?
    
    private var dragOperationPerformed: Bool = false
    
    override public func awakeFromNib() {
        let statusBarIcon = #imageLiteral(resourceName: "statusBarIcon")
        statusBarIcon.isTemplate = true
        statusBarBaseIcon = statusBarIcon
        
        if #available(macOS 10.14, *) {
            self.statusBarItem.button?.image = statusBarIcon
        } else {
            self.statusBarItem.image = statusBarIcon
        }
        self.statusBarItem.menu = self.statusBarMenu
        self.statusBarItem.button?.imagePosition = .imageOnly
        self.statusBarMenu.minimumWidth = 280
        updateConnectionCount()
        
        let dragTypes: [NSPasteboard.PasteboardType] = [
            NSPasteboard.PasteboardType(UTType.url.identifier),
            NSPasteboard.PasteboardType(UTType.text.identifier) ]
        self.statusBarItem.button?.window?.registerForDraggedTypes(dragTypes)
        self.statusBarItem.button?.window?.delegate = self
    }
    
    private func setupServiceObservers() {
        cancellables.removeAll()
        guard let serviceManager = self.serviceManager else { return }
        
        if let rcService = serviceManager.service(ofType: RemoteControlService.self) {
            if remoteControlWindowController == nil {
                remoteControlWindowController = RemoteControlWindowController(service: rcService)
            }
            rcService.openPanel = { [weak self] device in
                self?.remoteControlWindowController?.show(for: device)
            }
        }
        
        if let batteryService = serviceManager.service(ofType: BatteryService.self) {
            batteryService.$statuses
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in Task { @MainActor [weak self] in self?.updateDeviceImages() } }
                .store(in: &cancellables)
        }
        
        if let connectivityService = serviceManager.service(ofType: ConnectivityReportService.self) {
            connectivityService.$statuses
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in Task { @MainActor [weak self] in self?.updateDeviceImages() } }
                .store(in: &cancellables)
        }
    }
    
    
    // MARK: Actions
    
    @IBAction func quit(_ sender: Any?) {
        NSApp.terminate(sender)
    }
    
    @IBAction func toggleLaunchOnLogin(_ sender: Any?) {
        self.config?.launchOnLogin = !(self.config?.launchOnLogin ?? false)
    }
    
    @IBAction func refreshNotifications(_ sender: Any?) {
        AppDelegate.shared().serviceManager.service(ofType: NotificationsService.self)?.refreshNotifications()
        
    }
    
    @IBAction func openPreferences(_ sender: Any?) {
        self.preferencesWindowController?.showWindow(nil)
    }
    
    @IBAction func openDashboard(_ sender: Any?) {
        if dashboardWindowController == nil {
            guard let deviceDataSource = deviceDataSource,
                  let serviceManager = serviceManager else { return }
            let controller = DeviceDashboardWindowController(
                deviceDataSource: deviceDataSource,
                mediaPlayerService: serviceManager.service(ofType: MediaPlayerService.self),
                systemVolumeService: serviceManager.service(ofType: SystemVolumeService.self),
                batteryService: serviceManager.service(ofType: BatteryService.self),
                connectivityReportService: serviceManager.service(ofType: ConnectivityReportService.self),
                lockService: serviceManager.service(ofType: LockService.self)
            )
            controller.onClose = { [weak self] in self?.dashboardWindowController = nil }
            dashboardWindowController = controller
        }
        dashboardWindowController?.show()
    }
    
    @IBAction func showAboutWindow(_ sender: Any?) {
        AboutWindowController.showAboutWindow()
    }
    
    
    // MARK: Drag'n'Drop
    
    public dynamic func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperationPerformed = false
        for service in self.serviceManager?.services ?? [] {
            guard let destination = service as? NSDraggingDestination else { continue }
            guard let operation = destination.draggingEntered?(sender) else { continue }
            guard !operation.isEmpty else { continue }
            return operation
        }
        return []
    }
    
    public dynamic func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperationPerformed = false
        for service in self.serviceManager?.services ?? [] {
            guard let destination = service as? NSDraggingDestination else { continue }
            guard let operation = destination.draggingUpdated?(sender) else { continue }
            guard !operation.isEmpty else { continue }
            return operation
        }
        return []
    }
    
    public dynamic func draggingEnded(_ sender: NSDraggingInfo) {
        for service in self.serviceManager?.services ?? [] {
            guard let destination = service as? NSDraggingDestination else { continue }
            destination.draggingEnded?(sender)
        }
        
        // A workaround for items dragged from dock stack - in such case performDragOperation is not called
        if !dragOperationPerformed && self.statusBarItem.button?.frame.contains(sender.draggingLocation) == true {
            _ = performDragOperation(sender)
        }
    }
    
    public dynamic func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dragOperationPerformed = true
        for service in self.serviceManager?.services ?? [] {
            guard let destination = service as? NSDraggingDestination else { continue }
            guard destination.performDragOperation?(sender) == true else { continue }
            return true
        }
        return false
    }
    
    
    // MARK: NSMenuDelegate
    
    public func menuNeedsUpdate(_ menu: NSMenu) {
        // Removed automatic broadcast - not part of official KDE Connect protocol
        // Only broadcast on: app start, network change, manual Cmd+R
        
        if menu == self.statusBarMenu {
            updateConnectionCount()
            Diagnostics.shared.updateMenuState()
            self.dashboardMenuItem?.isEnabled = !(deviceDataSource?.pairedDevices.isEmpty ?? true) || !(deviceDataSource?.unavailableDevices.isEmpty ?? true)
            self.refreshMenuDeviceList()
            if #available(macOS 13.0, *) {
                let loginItem = SMAppService.mainApp
                switch (loginItem.status.rawValue) {
                case 0:
                    self.launchOnLoginItem.state = NSControl.StateValue.off
                    break
                case 1:
                    self.launchOnLoginItem.state = NSControl.StateValue.on
                    break
                default:
                    self.launchOnLoginItem.state = NSControl.StateValue.mixed
                    break
                }
            } else {
                self.launchOnLoginItem.state = (self.config?.launchOnLogin ?? false) ? NSControl.StateValue.on : NSControl.StateValue.off
            }
        }
    }
    
    
    // MARK: Public methods

    func installDiagnosticsMenu(_ item: NSMenuItem) {
        let index = statusBarMenu.items.firstIndex { $0.action == #selector(quit(_:)) } ?? statusBarMenu.numberOfItems
        statusBarMenu.insertItem(item, at: index)
    }
    
    func refreshDeviceLists() {
        let refresh: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.updateConnectionCount()
            self.updateDeviceImages()
            self.preferencesWindowController?.refreshDeviceLists()
            self.dashboardWindowController?.refreshDeviceList()
            self.dashboardMenuItem?.isEnabled = !(self.deviceDataSource?.pairedDevices.isEmpty ?? true) || !(self.deviceDataSource?.unavailableDevices.isEmpty ?? true)
        }
        // Device callbacks have no actor annotation in older SDKs. Keep main
        // callbacks synchronous and marshal other callers before touching UI.
        if Thread.isMainThread {
            MainActor.assumeIsolated { refresh() }
        } else {
            DispatchQueue.main.async { refresh() }
        }
    }
    
    /// Call this once from AppDelegate after all services have been registered.
    func startServiceObservers() {
        setupServiceObservers()
    }
    
    
    // MARK: Private methods

    private func updateConnectionCount() {
        // Count usable paired peers, rather than discovery results or sockets.
        let count = deviceDataSource?.pairedRechableDevices.count ?? 0
        guard let button = statusBarItem.button else { return }
        button.title = ""
        if let baseIcon = statusBarBaseIcon, displayedConnectionCount != count {
            button.image = Self.connectionCountIcon(base: baseIcon, count: count)
            displayedConnectionCount = count
        }
        let summary: String
        switch count {
        case 0: summary = "No connected devices"
        case 1: summary = "1 connected device"
        default: summary = "\(count) connected devices"
        }
        button.toolTip = "Soduto — \(summary)"
        button.setAccessibilityLabel("Soduto, \(summary)")
    }

    private static func connectionCountIcon(base: NSImage, count: Int) -> NSImage {
        let size = NSSize(width: 20, height: 20)
        let label = (count == 0 ? "×" : count > 99 ? "99+" : String(count)) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 7, weight: .bold),
            .foregroundColor: NSColor.black
        ]
        let textSize = label.size(withAttributes: attributes)
        let badgeWidth = max(9, ceil(textSize.width) + 3)
        let badge = NSRect(x: size.width - badgeWidth, y: size.height - 9, width: badgeWidth, height: 9)
        let image = NSImage(size: size, flipped: false) { _ in
            base.draw(in: NSRect(origin: .zero, size: size))
            // Clear a halo so the small badge stays distinct from the icon.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: badge.insetBy(dx: -0.75, dy: -0.75), xRadius: 5.25, yRadius: 5.25).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.setFill()
            NSBezierPath(roundedRect: badge, xRadius: 4.5, yRadius: 4.5).fill()
            // Knock the glyph out of the template's alpha, preserving contrast
            // in light/dark appearances and while the menu is highlighted.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            label.draw(at: NSPoint(x: badge.midX - textSize.width / 2,
                                   y: badge.midY - textSize.height / 2), withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = true
        return image
    }
    
    @MainActor
    private func refreshMenuDeviceList() {
        // Remove all existing device items and clear stored references
        deviceMenuItems.removeAll()
        var item = self.statusBarMenu.item(withTag: InterfaceElementTags.availableDeviceMenuItem.rawValue)
        while item != nil {
            self.statusBarMenu.removeItem(item!)
            item = self.statusBarMenu.item(withTag: InterfaceElementTags.availableDeviceMenuItem.rawValue)
        }
        
        // Re-add device items, storing references for live image updates
        let devices = (self.deviceDataSource?.pairedDevices ?? []).sorted {
            if $0.isReachable != $1.isReachable { return $0.isReachable }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        self.availableDevicesItem.title = !devices.isEmpty && devices.allSatisfy(\.isReachable) ? "Connected devices" : "Devices"
        guard devices.count > 0 else { return }
        
        var index = self.statusBarMenu.index(of: self.availableDevicesItem)
        assert(index != -1, "availableDevicesItem expected to be item of statusBarMenu")
        for device in devices {
            let item = NSMenuItem(title: device.name, action: nil, keyEquivalent: "")
            item.tag = InterfaceElementTags.availableDeviceMenuItem.rawValue
            item.submenu = DeviceMenu(device: device)
            updatePresentation(of: item, for: device)
            index += 1
            self.statusBarMenu.insertItem(item, at: index)
            deviceMenuItems[device.id] = item
        }
    }
    
    /// Update the existing row without interrupting an open device submenu.
    @MainActor
    private func updateDeviceImages() {
        guard let devices = self.deviceDataSource?.pairedDevices else { return }
        for device in devices {
            guard let item = deviceMenuItems[device.id] else { continue }
            updatePresentation(of: item, for: device)
        }
    }
    
    @MainActor
    private func updatePresentation(of item: NSMenuItem, for device: Device) {
        let battery = serviceManager?.service(ofType: BatteryService.self)?.statuses[device.id]
        let networks = serviceManager?.service(ofType: ConnectivityReportService.self)?.statuses[device.id] ?? []
        DeviceMenuPresentation.apply(to: item, name: device.name, type: device.type.rawValue,
                                     connected: device.isReachable, battery: battery?.currentCharge,
                                     charging: battery?.isCharging ?? false,
                                     networks: networks.map(\.networkType))
    }
}
