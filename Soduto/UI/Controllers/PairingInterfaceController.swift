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
        let show = {
            guard device.isReachable, device.pairingStatus == .RequestedByPeer else { return }
            PairingWindowController.showIncomingRequest(for: device)
        }
        if Thread.isMainThread { show() } else { DispatchQueue.main.async(execute: show) }
    }
    
    /// Updates the pairing window state for a device.
    /// Call this when pairing succeeds or fails.
    public static func updatePairingUI(for deviceId: Device.Id, success: Bool) {
        let update = {
            if success {
                PairingWindowController.updateState(for: deviceId, state: .success)
            } else {
                // Close immediately on failure - the device will handle status reset
                PairingWindowController.close(for: deviceId)
            }
        }
        // DeviceManager already validates the current request on main. A second
        // queue hop could apply this result to a replacement verification prompt.
        if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
    }
    
}
