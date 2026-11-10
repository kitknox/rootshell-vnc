import Foundation

/// RFB encoding types used in SetEncodings and FramebufferUpdate messages.
///
/// Standard encodings have non-negative values. Pseudo-encodings (used to
/// signal capabilities rather than pixel data) have negative values.
public enum Encoding: Sendable, Equatable, Hashable {

    // MARK: - Standard encodings

    case raw
    case copyRect
    case rre
    case hextile
    case zlib
    case tight
    case zlibhex
    case zrle

    // MARK: - Standard pseudo-encodings

    case cursor
    /// TightVNC's two-color X-style cursor pseudo-encoding.
    case xCursor
    case lastRect
    case desktopSize
    case extendedDesktopSize
    /// Clipboard data beyond Latin-1 text: rich text, HTML and images.
    case extendedClipboard

    // MARK: - Apple encodings

    case appleJPEG
    case apple1
    case appleMultiVariantScreenshare
    case appleSubZlibThousands
    case appleH264

    // MARK: - Apple pseudo-encodings

    case encryptionInfo
    case serverDisplayInfo
    case mediaStreamOffer
    case mediaStreamAnswer

    // MARK: - Fallback

    case unknown(Int32)

    // MARK: - Raw value mapping

    /// The 32-bit signed integer transmitted on the wire for this encoding.
    public var rawValue: Int32 {
        switch self {
        case .raw:                  return 0
        case .copyRect:             return 1
        case .rre:                  return 2
        case .hextile:              return 5
        case .zlib:                 return 6
        case .tight:                return 7
        case .zlibhex:              return 8
        case .zrle:                 return 16
        case .cursor:               return -239
        case .xCursor:              return -240
        case .lastRect:             return -224
        case .desktopSize:          return -223
        case .extendedDesktopSize:  return -308
        case .extendedClipboard:    return -1063131698
        case .appleJPEG:            return -1000
        case .apple1:               return -261
        case .appleMultiVariantScreenshare: return 1011
        case .appleSubZlibThousands: return 1002
        case .appleH264:            return 1010
        case .encryptionInfo:       return -267
        case .serverDisplayInfo:    return -300
        case .mediaStreamOffer:     return 1103
        case .mediaStreamAnswer:    return -302
        case .unknown(let v):       return v
        }
    }

    /// Create an `Encoding` from its wire value.
    public init(rawValue: Int32) {
        switch rawValue {
        case 0:     self = .raw
        case 1:     self = .copyRect
        case 2:     self = .rre
        case 5:     self = .hextile
        case 6:     self = .zlib
        case 7:     self = .tight
        case 8:     self = .zlibhex
        case 16:    self = .zrle
        case -239:  self = .cursor
        case -240:  self = .xCursor
        case -224:  self = .lastRect
        case -223:  self = .desktopSize
        case -308:  self = .extendedDesktopSize
        case -1063131698: self = .extendedClipboard
        case -1000: self = .appleJPEG
        case -261:  self = .apple1
        case 1002:  self = .appleSubZlibThousands
        case 1010:  self = .appleH264
        case 1011:  self = .appleMultiVariantScreenshare
        case 1103:  self = .mediaStreamOffer
        case -267:  self = .encryptionInfo
        case -300:  self = .serverDisplayInfo
        case -301:  self = .mediaStreamOffer
        case -302:  self = .mediaStreamAnswer
        default:    self = .unknown(rawValue)
        }
    }

    /// Whether this encoding is a pseudo-encoding (negative value).
    public var isPseudo: Bool {
        rawValue < 0 || self == .mediaStreamOffer
    }

    /// Whether rectangles of this encoding carry framebuffer pixel content,
    /// as opposed to pseudo-encodings and Apple metadata records.
    public var isFramebufferContent: Bool {
        switch self {
        case .raw, .copyRect, .rre, .hextile, .zlib, .tight, .zlibhex, .zrle,
             .appleJPEG, .appleMultiVariantScreenshare, .appleSubZlibThousands,
             .appleH264:
            return true
        default:
            return false
        }
    }

    /// Whether the transport can consume this content encoding's payload off
    /// the wire.
    ///
    /// A rectangle's payload length is implied by its encoding. Advertising a
    /// content encoding the parsers cannot frame therefore desynchronizes the
    /// byte stream the first time a server uses one: the payload bytes are
    /// left in place and the next of them is read as a message type. The
    /// failure then surfaces one message later as an unrelated protocol
    /// violation, so the invariant is enforced at both ends instead — nothing
    /// outside this set is ever advertised, and the parsers refuse anything
    /// outside it that arrives regardless.
    ///
    /// `.appleH264` qualifies because its pixels ride the UDP media path; its
    /// RFB rectangle carries a UInt16-framed media-control payload rather than
    /// framebuffer pixels.
    ///
    /// Keep this in step with the `switch rect.encoding` in
    /// `TransportSession.handleFramebufferUpdate` and its encrypted-channel
    /// twin `drainAppleDecryptedFramebufferUpdate`.
    public var hasKnownFramebufferFraming: Bool {
        switch self {
        case .raw, .copyRect, .zlib, .zrle, .tight,
             .appleMultiVariantScreenshare, .appleH264:
            return true
        default:
            return false
        }
    }

    /// Content encodings that must never be advertised or accepted, because
    /// their payload cannot be framed. Empty for everything that is not
    /// framebuffer content.
    public var isUnframeableContent: Bool {
        isFramebufferContent && !hasKnownFramebufferFraming
    }

    /// Human-readable name for diagnostics UI. Technical proper nouns,
    /// deliberately not localized.
    public var displayName: String {
        switch self {
        case .raw:                  return "Raw"
        case .copyRect:             return "CopyRect"
        case .rre:                  return "RRE"
        case .hextile:              return "Hextile"
        case .zlib:                 return "Zlib"
        case .tight:                return "Tight"
        case .zlibhex:              return "ZlibHex"
        case .zrle:                 return "ZRLE"
        case .cursor:               return "Cursor"
        case .xCursor:              return "X Cursor"
        case .lastRect:             return "LastRect"
        case .desktopSize:          return "DesktopSize"
        case .extendedDesktopSize:  return "ExtendedDesktopSize"
        case .extendedClipboard:    return "ExtendedClipboard"
        case .appleJPEG:            return "Apple JPEG"
        case .apple1:               return "Apple Extension"
        case .appleMultiVariantScreenshare: return "Apple Adaptive DCT"
        case .appleSubZlibThousands: return "Apple SubZlib"
        case .appleH264:            return "Apple HEVC"
        case .encryptionInfo:       return "EncryptionInfo"
        case .serverDisplayInfo:    return "ServerDisplayInfo"
        case .mediaStreamOffer:     return "MediaStreamOffer"
        case .mediaStreamAnswer:    return "MediaStreamAnswer"
        case .unknown(let v):       return "Encoding \(v)"
        }
    }
}
