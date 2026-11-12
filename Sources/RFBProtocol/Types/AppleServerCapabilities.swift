import Foundation

/// Structured capability prefix carried ahead of the desktop name in an
/// Apple RFB 3.889 `ServerInit` message.
///
/// Apple sends a two-byte status/reserved value, server flags, and a 128-bit
/// server-command bitmap. Commands are numbered MSB-first within each byte.
public struct AppleServerCapabilities: Sendable, Equatable {
    public static let commandBitmapByteCount = 16
    public static let serverInitPrefixByteCount = 2 + 4 + commandBitmapByteCount

    /// Precise scroll-wheel event command used by the Apple RFB
    /// client. Servers that do not advertise it must receive ordinary RFB
    /// pointer wheel-button events instead.
    public static let preciseScrollCommand = AppleScrollEvent.messageType

    /// Virtual-display configuration command used by Dynamic Resolution.
    public static let displayConfigurationCommand =
        AppleDisplayConfiguration.messageType

    /// Viewer-info command. The server sends pasteboard notices only to
    /// viewers that have described themselves with it.
    public static let viewerInfoCommand: UInt8 = 0x21

    /// Server flag announcing a session-selection exchange after ServerInit.
    public static let sessionSelectionFlag: UInt32 = 0x04

    /// Server flag: this viewer may only observe.
    public static let observeOnlyFlag: UInt32 = 0x01

    /// Server flag: this viewer may take absolute control (control mode 2).
    public static let absoluteControlFlag: UInt32 = 0x02

    public let serverFlags: UInt32
    public let serverCommandBitmap: Data

    init(serverFlags: UInt32, serverCommandBitmap: Data) {
        precondition(serverCommandBitmap.count == Self.commandBitmapByteCount)
        self.serverFlags = serverFlags
        self.serverCommandBitmap = serverCommandBitmap
    }

    /// Parse the capability prefix from the name-sized field following the
    /// fixed `ServerInit` header. Call this only after negotiating RFB 3.889.
    public init?(serverInitNameField data: Data) {
        guard data.count >= Self.serverInitPrefixByteCount,
              data[data.startIndex] == 0,
              data[data.startIndex + 1] == 0 else { return nil }

        let flagsOffset = data.startIndex + 2
        self.serverFlags =
            UInt32(data[flagsOffset]) << 24
            | UInt32(data[flagsOffset + 1]) << 16
            | UInt32(data[flagsOffset + 2]) << 8
            | UInt32(data[flagsOffset + 3])

        let commandsStart = flagsOffset + 4
        let commandsEnd = commandsStart + Self.commandBitmapByteCount
        self.serverCommandBitmap = Data(data[commandsStart..<commandsEnd])
    }

    public var announcesSessionSelection: Bool {
        serverFlags & Self.sessionSelectionFlag != 0
    }

    public var allowsAbsoluteControl: Bool {
        serverFlags & Self.absoluteControlFlag != 0
            && serverFlags & Self.observeOnlyFlag == 0
    }

    public func supportsServerCommand(_ command: UInt8) -> Bool {
        let byteIndex = Int(command >> 3)
        let bitIndex = 7 - Int(command & 7)
        return serverCommandBitmap[serverCommandBitmap.startIndex + byteIndex]
            & (UInt8(1) << UInt8(bitIndex)) != 0
    }

    public static func desktopNameData(fromServerInitNameField data: Data) -> Data {
        guard AppleServerCapabilities(serverInitNameField: data) != nil else {
            return data
        }
        return Data(data.dropFirst(Self.serverInitPrefixByteCount))
    }
}
