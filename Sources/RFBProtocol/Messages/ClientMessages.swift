import Foundation

/// All client-to-server RFB message types.
public enum ClientMessage: Sendable, Equatable {

    /// Message type 0: Set the pixel format to use for framebuffer updates.
    case setPixelFormat(PixelFormat)

    /// Message type 2: Declare the list of encodings the client supports.
    case setEncodings([Encoding])

    /// Message type 3: Request a framebuffer update for the specified region.
    case framebufferUpdateRequest(incremental: Bool, x: UInt16, y: UInt16, width: UInt16, height: UInt16)

    /// Message type 4: A key press or release event.
    case keyEvent(downFlag: Bool, key: UInt32)

    /// Message type 5: A pointer (mouse/touch) event.
    case pointerEvent(buttonMask: UInt8, x: UInt16, y: UInt16)

    /// Message type 6: The client's clipboard text has changed.
    case clientCutText(String)

    /// Apple message type 9: subscribe to change-gated framebuffer updates.
    ///
    /// `intervalMilliseconds` is the server-side frame pacing interval. Apple
    /// uses -1 to disable and positive millisecond values to cap delivery.
    case appleAutoFramebufferUpdate(
        intervalMilliseconds: Int32,
        x: UInt16,
        y: UInt16,
        width: UInt16,
        height: UInt16)

    /// Standard message type 251: request a new framebuffer/screen layout.
    case setDesktopSize(SetDesktopSizeRequest)

    /// Apple message type 23: a precise, phased scroll-wheel event.
    case appleScrollEvent(AppleScrollEvent)

    /// Apple message type 23: begin/end envelope for a trackpad/touch gesture.
    case appleGestureEvent(AppleGestureEvent)

    /// Apple message type 23/subtype 8: gesture-scroll targeting metadata.
    case appleGestureScrollEvent(AppleGestureScrollEvent)

    /// Apple message type 33: request accelerated media-stream configuration.
    case appleMediaStreamConfiguration

    /// Apple message type 33: describe the viewer and the server message
    /// types it accepts.
    case appleViewerInfo(acceptedServerMessages: [UInt8])

    /// Apple message type 18: request/open an accelerated media stream.
    case appleMediaStreamRequest

    /// Apple message type 29: configure one or two virtual displays.
    case appleDisplayConfiguration(AppleDisplayConfiguration)

    // MARK: - Message type IDs

    /// The RFB message-type byte for this message.
    public var messageType: UInt8 {
        switch self {
        case .setPixelFormat:              return 0
        case .setEncodings:                return 2
        case .framebufferUpdateRequest:    return 3
        case .keyEvent:                    return 4
        case .pointerEvent:                return 5
        case .clientCutText:               return 6
        case .appleAutoFramebufferUpdate:  return 9
        case .setDesktopSize:              return SetDesktopSizeRequest.messageType
        case .appleScrollEvent:            return AppleScrollEvent.messageType
        case .appleGestureEvent:           return AppleGestureEvent.messageType
        case .appleGestureScrollEvent:     return AppleGestureScrollEvent.messageType
        case .appleMediaStreamConfiguration: return 0x21
        case .appleViewerInfo:             return 0x21
        case .appleMediaStreamRequest:     return 0x12
        case .appleDisplayConfiguration:   return AppleDisplayConfiguration.messageType
        }
    }

    // MARK: - Serialization

    /// Serialize this message to its wire-format `Data`.
    public func serialize() -> Data {
        switch self {
        case .setPixelFormat(let pf):
            return MessageWriter.writeSetPixelFormat(pf)
        case .setEncodings(let encodings):
            return MessageWriter.writeSetEncodings(encodings)
        case .framebufferUpdateRequest(let incremental, let x, let y, let w, let h):
            return MessageWriter.writeFramebufferUpdateRequest(
                incremental: incremental, x: x, y: y, width: w, height: h
            )
        case .keyEvent(let down, let key):
            return MessageWriter.writeKeyEvent(downFlag: down, key: key)
        case .pointerEvent(let mask, let x, let y):
            return MessageWriter.writePointerEvent(buttonMask: mask, x: x, y: y)
        case .clientCutText(let text):
            return MessageWriter.writeClientCutText(text)
        case .appleAutoFramebufferUpdate(let interval, let x, let y, let width, let height):
            return MessageWriter.writeAppleAutoFramebufferUpdate(
                intervalMilliseconds: interval,
                x: x, y: y, width: width, height: height)
        case .setDesktopSize(let request):
            return MessageWriter.writeSetDesktopSize(request)
        case .appleScrollEvent(let event):
            return MessageWriter.writeAppleScrollEvent(event)
        case .appleGestureEvent(let event):
            return MessageWriter.writeAppleGestureEvent(event)
        case .appleGestureScrollEvent(let event):
            return MessageWriter.writeAppleGestureScrollEvent(event)
        case .appleMediaStreamConfiguration:
            return MessageWriter.writeAppleMediaStreamConfiguration()
        case .appleViewerInfo(let acceptedServerMessages):
            return MessageWriter.writeAppleViewerInfo(
                acceptedServerMessages: acceptedServerMessages)
        case .appleMediaStreamRequest:
            return MessageWriter.writeAppleMediaStreamRequest()
        case .appleDisplayConfiguration(let configuration):
            return MessageWriter.writeAppleDisplayConfiguration(configuration)
        }
    }
}
