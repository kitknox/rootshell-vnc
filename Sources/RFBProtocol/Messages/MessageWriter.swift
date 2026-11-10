import Foundation

/// Serializes RFB client messages to their wire-format `Data` representation.
///
/// All methods are static — `MessageWriter` is a namespace, not an instance type.
public enum MessageWriter: Sendable {

    // MARK: - Client → Server messages

    /// Serialize a SetPixelFormat message (type 0).
    ///
    /// Wire layout: [0] [padding×3] [pixel-format×16]  = 20 bytes.
    public static func writeSetPixelFormat(_ pf: PixelFormat) -> Data {
        var data = Data(count: 20)
        data[0] = 0  // message type
        data[1] = 0  // padding
        data[2] = 0
        data[3] = 0
        let pfBytes = pf.wireBytes()
        data.replaceSubrange(4..<20, with: pfBytes)
        return data
    }

    /// Serialize a SetEncodings message (type 2).
    ///
    /// Wire layout: [2] [padding] [number-of-encodings UInt16] [encoding×Int32]...
    public static func writeSetEncodings(_ encodings: [Encoding]) -> Data {
        let count = encodings.count
        var data = Data(count: 4 + count * 4)
        data[0] = 2  // message type
        data[1] = 0  // padding
        writeUInt16(UInt16(count), into: &data, at: 2)
        for (i, enc) in encodings.enumerated() {
            writeInt32(enc.rawValue, into: &data, at: 4 + i * 4)
        }
        return data
    }

    /// Serialize a FramebufferUpdateRequest message (type 3).
    ///
    /// Wire layout: [3] [incremental] [x UInt16] [y UInt16] [width UInt16] [height UInt16] = 10 bytes.
    public static func writeFramebufferUpdateRequest(
        incremental: Bool,
        x: UInt16,
        y: UInt16,
        width: UInt16,
        height: UInt16
    ) -> Data {
        var data = Data(count: 10)
        data[0] = 3
        data[1] = incremental ? 1 : 0
        writeUInt16(x, into: &data, at: 2)
        writeUInt16(y, into: &data, at: 4)
        writeUInt16(width, into: &data, at: 6)
        writeUInt16(height, into: &data, at: 8)
        return data
    }

    /// Serialize a KeyEvent message (type 4).
    ///
    /// Wire layout: [4] [down-flag] [padding×2] [key UInt32] = 8 bytes.
    public static func writeKeyEvent(downFlag: Bool, key: UInt32) -> Data {
        var data = Data(count: 8)
        data[0] = 4
        data[1] = downFlag ? 1 : 0
        data[2] = 0  // padding
        data[3] = 0
        writeUInt32(key, into: &data, at: 4)
        return data
    }

    /// Serialize a PointerEvent message (type 5).
    ///
    /// Wire layout: [5] [button-mask] [x UInt16] [y UInt16] = 6 bytes.
    public static func writePointerEvent(buttonMask: UInt8, x: UInt16, y: UInt16) -> Data {
        var data = Data(count: 6)
        data[0] = 5
        data[1] = buttonMask
        writeUInt16(x, into: &data, at: 2)
        writeUInt16(y, into: &data, at: 4)
        return data
    }

    /// Serialize a ClientCutText message (type 6).
    ///
    /// Wire layout: [6] [padding×3] [length UInt32] [text bytes] = 8 + length.
    public static func writeClientCutText(_ text: String) -> Data {
        let textBytes = Data(text.utf8)
        var data = Data(count: 8 + textBytes.count)
        data[0] = 6
        data[1] = 0  // padding
        data[2] = 0
        data[3] = 0
        writeUInt32(UInt32(textBytes.count), into: &data, at: 4)
        if !textBytes.isEmpty {
            data.replaceSubrange(8..<(8 + textBytes.count), with: textBytes)
        }
        return data
    }

    /// Serialize Apple's AutoFrameBufferUpdate message (type 9).
    ///
    /// This 16-byte layout is used by native Apple-compatible clients: type,
    /// padding, one region, a signed millisecond pacing
    /// interval, then the subscribed rectangle. Unlike ordinary type-3
    /// requests, the server continues sending change-gated updates and uses
    /// socket delivery time to adapt DCT quality to available bandwidth.
    public static func writeAppleAutoFramebufferUpdate(
        intervalMilliseconds: Int32,
        x: UInt16,
        y: UInt16,
        width: UInt16,
        height: UInt16
    ) -> Data {
        var data = Data(count: 16)
        data[0] = 9
        data[1] = 0
        writeUInt16(1, into: &data, at: 2)
        writeInt32(intervalMilliseconds, into: &data, at: 4)
        writeUInt16(x, into: &data, at: 8)
        writeUInt16(y, into: &data, at: 10)
        writeUInt16(width, into: &data, at: 12)
        writeUInt16(height, into: &data, at: 14)
        return data
    }

    /// Serialize standard RFB `SetDesktopSize` (message 251).
    public static func writeSetDesktopSize(_ request: SetDesktopSizeRequest) -> Data {
        let totalSize = SetDesktopSizeRequest.headerWireSize
            + request.screens.count * ExtendedDesktopSizePayload.screenWireSize
        var data = Data(count: totalSize)
        data[0] = SetDesktopSizeRequest.messageType
        data[1] = 0
        writeUInt16(request.width, into: &data, at: 2)
        writeUInt16(request.height, into: &data, at: 4)
        data[6] = UInt8(request.screens.count)
        data[7] = 0

        var offset = SetDesktopSizeRequest.headerWireSize
        for screen in request.screens {
            writeUInt32(screen.id, into: &data, at: offset)
            writeUInt16(screen.x, into: &data, at: offset + 4)
            writeUInt16(screen.y, into: &data, at: offset + 6)
            writeUInt16(screen.width, into: &data, at: offset + 8)
            writeUInt16(screen.height, into: &data, at: offset + 10)
            writeUInt32(screen.flags, into: &data, at: offset + 12)
            offset += ExtendedDesktopSizePayload.screenWireSize
        }
        return data
    }

    /// Serialize Apple's negotiated virtual-display configuration command.
    public static func writeAppleDisplayConfiguration(
        _ configuration: AppleDisplayConfiguration
    ) -> Data {
        let recordsSize = configuration.displays.reduce(0) { $0 + $1.wireSize }
        let totalSize = AppleDisplayConfiguration.headerWireSize + recordsSize
        precondition(totalSize - 4 <= Int(UInt16.max))

        var data = Data(count: totalSize)
        data[0] = AppleDisplayConfiguration.messageType
        data[1] = 0
        writeUInt16(UInt16(totalSize - 4), into: &data, at: 2)
        writeUInt16(AppleDisplayConfiguration.version, into: &data, at: 4)
        data[6] = 0
        data[7] = UInt8(configuration.displays.count)
        writeUInt32(0, into: &data, at: 8)

        var offset = AppleDisplayConfiguration.headerWireSize
        for display in configuration.displays {
            writeUInt16(UInt16(display.wireSize), into: &data, at: offset)

            let nameBytes = Data(display.name.utf8.prefix(
                AppleVirtualDisplay.nameByteCount - 1))
            if !nameBytes.isEmpty {
                data.replaceSubrange(
                    (offset + 2)..<(offset + 2 + nameBytes.count),
                    with: nameBytes)
            }

            writeUInt32(display.flags, into: &data, at: offset + 122)
            writeUInt32(display.attributes, into: &data, at: offset + 126)
            writeUInt32(
                display.widthInMillimeters.bitPattern,
                into: &data,
                at: offset + 130)
            writeUInt32(
                display.heightInMillimeters.bitPattern,
                into: &data,
                at: offset + 134)
            writeUInt32(display.maximumPixelWidth, into: &data, at: offset + 138)
            writeUInt32(display.maximumPixelHeight, into: &data, at: offset + 142)
            writeUInt16(display.originX, into: &data, at: offset + 146)
            writeUInt16(display.originY, into: &data, at: offset + 148)
            writeUInt32(display.identifier, into: &data, at: offset + 150)
            writeUInt16(UInt16(display.modes.count), into: &data, at: offset + 154)

            var modeOffset = offset + AppleVirtualDisplay.fixedWireSize
            for mode in display.modes {
                writeUInt32(mode.pixelWidth, into: &data, at: modeOffset)
                writeUInt32(mode.pixelHeight, into: &data, at: modeOffset + 4)
                writeUInt32(mode.pointWidth, into: &data, at: modeOffset + 8)
                writeUInt32(mode.pointHeight, into: &data, at: modeOffset + 12)
                let rate = mode.refreshRate.bitPattern
                writeUInt32(UInt32(rate >> 32), into: &data, at: modeOffset + 16)
                writeUInt32(UInt32(rate & 0xffff_ffff), into: &data, at: modeOffset + 20)
                writeUInt32(mode.flags, into: &data, at: modeOffset + 24)
                modeOffset += AppleVirtualDisplayMode.wireSize
            }
            offset += display.wireSize
        }
        return data
    }

    /// Serialize Apple's precise scroll-wheel command (message type 23).
    ///
    /// The 54-byte payload contains event kind 1, subtype 11, all three forms
    /// of the three scroll axes, phase/count/flags, and pointer coordinates.
    public static func writeAppleScrollEvent(_ event: AppleScrollEvent) -> Data {
        var data = Data(count: AppleScrollEvent.wireByteCount)
        data[0] = AppleScrollEvent.messageType
        data[1] = 0
        writeUInt16(AppleScrollEvent.payloadByteCount, into: &data, at: 2)
        writeUInt16(AppleScrollEvent.inputEventVersion, into: &data, at: 4)
        writeUInt16(AppleScrollEvent.scrollWheelEventSubtype, into: &data, at: 6)
        writeInt16(event.deltaX, into: &data, at: 8)
        writeInt16(event.deltaY, into: &data, at: 10)
        writeInt16(event.deltaZ, into: &data, at: 12)
        writeInt32(event.fixedDeltaX, into: &data, at: 14)
        writeInt32(event.fixedDeltaY, into: &data, at: 18)
        writeInt32(event.fixedDeltaZ, into: &data, at: 22)
        writeInt32(event.pointDeltaX, into: &data, at: 26)
        writeInt32(event.pointDeltaY, into: &data, at: 30)
        writeInt32(event.pointDeltaZ, into: &data, at: 34)
        writeUInt32(event.scrollPhase.rawValue, into: &data, at: 38)
        writeUInt32(event.momentumPhase.rawValue, into: &data, at: 42)
        writeUInt32(event.scrollCount, into: &data, at: 46)
        writeUInt32(event.flags.rawValue, into: &data, at: 50)
        writeUInt16(event.x, into: &data, at: 54)
        writeUInt16(event.y, into: &data, at: 56)
        return data
    }

    /// Serialize the gesture begin/end envelope used around Apple's precise
    /// scroll stream.
    ///
    /// Wire layout (16 bytes): type 23, payload length 12, input version 1,
    /// gesture kind 1/2, source subtype, and framebuffer coordinates.
    public static func writeAppleGestureEvent(_ event: AppleGestureEvent) -> Data {
        var data = Data(count: AppleGestureEvent.wireByteCount)
        data[0] = AppleGestureEvent.messageType
        data[1] = 0
        writeUInt16(AppleGestureEvent.payloadByteCount, into: &data, at: 2)
        writeUInt16(AppleGestureEvent.inputEventVersion, into: &data, at: 4)
        writeUInt16(event.kind.rawValue, into: &data, at: 6)
        writeUInt32(event.sourceSubtype.rawValue, into: &data, at: 8)
        writeUInt16(event.x, into: &data, at: 12)
        writeUInt16(event.y, into: &data, at: 14)
        return data
    }

    /// Serialize the gesture-scroll subtype using its defined wire layout:
    /// three big-endian Float32 deltas, natural direction, phase, gesture mask,
    /// and framebuffer coordinates in a 32-byte type-23 payload.
    public static func writeAppleGestureScrollEvent(
        _ event: AppleGestureScrollEvent
    ) -> Data {
        var data = Data(count: AppleGestureScrollEvent.wireByteCount)
        data[0] = AppleGestureScrollEvent.messageType
        data[1] = 0
        writeUInt16(AppleGestureScrollEvent.payloadByteCount, into: &data, at: 2)
        writeUInt16(AppleGestureScrollEvent.inputEventVersion, into: &data, at: 4)
        writeUInt16(AppleGestureScrollEvent.gestureScrollSubtype, into: &data, at: 6)
        writeUInt32(event.deltaX.bitPattern, into: &data, at: 8)
        writeUInt32(event.deltaY.bitPattern, into: &data, at: 12)
        writeUInt32(event.deltaZ.bitPattern, into: &data, at: 16)
        writeUInt32(event.naturalScrolling ? 1 : 0, into: &data, at: 20)
        writeUInt32(event.gesturePhase.rawValue, into: &data, at: 24)
        writeUInt32(event.gestureMask, into: &data, at: 28)
        writeUInt16(event.x, into: &data, at: 32)
        writeUInt16(event.y, into: &data, at: 34)
        return data
    }

    /// Serialize Apple's client media-stream configuration request.
    ///
    /// Send this `0x21` message after ServerInit and before accepting the
    /// `RFBMediaStreamMessage1Encoding` offer. It is the viewer-info message
    /// carrying the server messages a High Performance session accepts.
    public static func writeAppleMediaStreamConfiguration() -> Data {
        writeAppleViewerInfo(acceptedServerMessages: [
            0, 2, 3, 0x14, 0x15, 0x1e, 0x1f, 0x20, 0x22, 0x23, 0x49,
        ])
    }

    /// Serialize Apple's `0x21` viewer info: message version, app id, app and
    /// OS versions, then a 256-bit MSB-first map of the server message types
    /// the viewer accepts.
    public static func writeAppleViewerInfo(acceptedServerMessages: [UInt8]) -> Data {
        var data = Data(count: 66)
        data[0] = 0x21
        writeUInt16(62, into: &data, at: 2)
        writeUInt16(1, into: &data, at: 4)
        // App id 2, app version 6.2.0, OS version 26.3.1.
        for (index, value) in [UInt32]([2, 6, 2, 0, 26, 3, 1]).enumerated() {
            writeUInt32(value, into: &data, at: 6 + index * 4)
        }
        for type in acceptedServerMessages {
            data[34 + Int(type >> 3)] |= 0x80 >> (type & 7)
        }
        return data
    }

    /// Serialize Apple's client media-stream request.
    ///
    /// Send this `0x12` message immediately after the `0x21` media-stream
    /// configuration. It prompts the server to send the
    /// `RFBMediaStreamMessage1Encoding` offer rectangle.
    public static func writeAppleMediaStreamRequest() -> Data {
        Data([
            0x12, 0x00, 0x00, 0x01,
            0x00, 0x01, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x01,
            0x0a, 0x00, 0x00, 0x01,
        ])
    }

    // MARK: - Handshake messages

    /// Serialize a ProtocolVersion handshake response (12 bytes).
    public static func writeProtocolVersion(_ version: ProtocolVersion) -> Data {
        version.wireBytes()
    }

    /// Serialize a security type selection (1 byte).
    public static func writeSecurityType(_ type: SecurityType) -> Data {
        Data([type.rawValue])
    }

    // MARK: - Helpers

    private static func writeUInt16(_ value: UInt16, into data: inout Data, at offset: Int) {
        data[offset]     = UInt8(value >> 8)
        data[offset + 1] = UInt8(value & 0xFF)
    }

    private static func writeUInt32(_ value: UInt32, into data: inout Data, at offset: Int) {
        data[offset]     = UInt8((value >> 24) & 0xFF)
        data[offset + 1] = UInt8((value >> 16) & 0xFF)
        data[offset + 2] = UInt8((value >> 8)  & 0xFF)
        data[offset + 3] = UInt8(value & 0xFF)
    }

    private static func writeInt16(_ value: Int16, into data: inout Data, at offset: Int) {
        writeUInt16(UInt16(bitPattern: value), into: &data, at: offset)
    }

    private static func writeInt32(_ value: Int32, into data: inout Data, at offset: Int) {
        writeUInt32(UInt32(bitPattern: value), into: &data, at: offset)
    }
}
