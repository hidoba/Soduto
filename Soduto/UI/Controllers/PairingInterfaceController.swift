//
//  PairingInterfaceController.swift
//  Soduto
//
//  Created by Giedrius Stanevičius on 2016-11-23.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Foundation

/// Handles the pairing window UI entry points and updates.
public class PairingInterfaceController {
    
    /// Shows the pairing window for an incoming pairing request.
    /// - Parameter device: The device requesting to be paired.
    public static func showPairingWindow(for device: Device) {
        let show: @MainActor () -> Void = {
            guard device.isReachable, device.pairingStatus == .RequestedByPeer else { return }
            PairingWindowController.showIncomingRequest(for: device)
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { show() }
        } else {
            DispatchQueue.main.async { show() }
        }
    }
    
    /// Updates the pairing window state for a device.
    /// Call this when pairing succeeds or fails.
    public static func updatePairingUI(for deviceId: Device.Id, success: Bool) {
        // DeviceManager already validates the current request on main. A second
        // queue hop could apply this result to a replacement verification prompt.
        let update: @MainActor () -> Void = {
            if success {
                PairingWindowController.updateState(for: deviceId, state: .success)
            } else {
                // Close immediately on failure - the device will handle status reset
                PairingWindowController.close(for: deviceId)
            }
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { update() }
        } else {
            DispatchQueue.main.async { update() }
        }
    }
    
}
