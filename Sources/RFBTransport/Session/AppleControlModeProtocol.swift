import Foundation

/// Apple's control-mode command:
///
///     0  UInt8   message type (10)
///     1  UInt8   padding
///     2  UInt16  mode: 1 control, 2 absolute control
///
/// Absolute control disables the Mac's local keyboard and mouse until the
/// viewer returns to mode 1 or disconnects. In mode 1 the Mac drops key-downs
/// and pointer moves for 2 s after a display change re-centres its cursor;
/// absolute control skips that window. The server needs the ServerInit
/// absolute-control flag and sends no reply.
enum AppleControlModeProtocol {
    static let setModeMessageType: UInt8 = 10

    enum Mode: UInt16 {
        case control = 1
        case absoluteControl = 2
    }

    static func setModeMessage(_ mode: Mode) -> Data {
        Data([
            setModeMessageType,
            0,
            UInt8(truncatingIfNeeded: mode.rawValue >> 8),
            UInt8(truncatingIfNeeded: mode.rawValue),
        ])
    }
}
