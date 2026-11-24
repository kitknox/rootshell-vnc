//
//  VNCDesktopControls.swift
//  rootshellVNC
//
//  Lets a host app drive two actions of the HUD menu from its own menu (the Mac menu bar).
//

import Foundation
import Observation

/// Requests from the host app to `RemoteDesktopView`. The view watches the counters: each increase is one request.
/// Pass one object to the view and keep it in the host.
@MainActor
@Observable
public final class VNCDesktopControls {
    /// Attaching, swapping, or removing a controller moves the counters the
    /// view sees without a request; the view only acts within one identity.
    let identity = UUID()

    #if canImport(UIKit)
    /// Shows or hides the file transfers panel (the HUD item "File Transfers").
    public private(set) var fileTransfersToggleRequests = 0
    #endif
    /// Opens the Curtain Mode prompt (turning curtain mode on asks for a message first).
    /// Ignored unless the session is connected and `supportsCurtainMode`.
    public private(set) var curtainPromptRequests = 0

    public init() {}

    #if canImport(UIKit)
    public func toggleFileTransfers() { fileTransfersToggleRequests &+= 1 }
    #endif
    public func requestCurtainPrompt() { curtainPromptRequests &+= 1 }
}
