import Foundation

/// Errors raised while parsing Apple's negotiated Remote Desktop system-audio
/// stream.
public enum AppleRemoteAudioRTPError: Error, Sendable, LocalizedError, Equatable {
    case unexpectedPayloadType(UInt8)
    case missingAUHeaderSection
    case invalidAUHeaderLength(Int)
    case truncatedAUHeaders(expectedBytes: Int, availableBytes: Int)
    case invalidAccessUnitData(expectedBytes: Int, availableBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .unexpectedPayloadType(let type):
            return "Unexpected remote-audio RTP payload type: \(type)"
        case .missingAUHeaderSection:
            return "Remote-audio RTP packet has no RFC 3640 AU header section."
        case .invalidAUHeaderLength(let bits):
            return "Invalid RFC 3640 AU header length: \(bits) bits."
        case .truncatedAUHeaders(let expected, let available):
            return "Truncated RFC 3640 AU headers: expected \(expected) bytes, found \(available)."
        case .invalidAccessUnitData(let expected, let available):
            return "Invalid RFC 3640 access-unit data: expected \(expected) bytes, found \(available)."
        }
    }
}

/// Packetization selected for payload 101 by the audio-stream negotiation.
/// Apple's mode-8 system-audio stream uses codec bundling: every RTP payload is
/// one complete AAC-ELD access unit. RFC 3640 is retained as an explicit option
/// for peers that negotiate external bundling; compressed bytes themselves are
/// never inspected to guess which packetization is in use.
public enum AppleRemoteAudioPacketization: Sendable, Equatable {
    case codecAccessUnit
    case rfc3640
}

/// One depacketized AAC-ELD/SBR RTP packet from Apple's system-audio stream.
public struct AppleRemoteAudioRTPPacket: Sendable, Equatable {
    public let sequenceNumber: UInt16
    public let timestamp: UInt32
    public let ssrc: UInt32
    public let marker: Bool
    public let accessUnits: [Data]

    public init(
        sequenceNumber: UInt16,
        timestamp: UInt32,
        ssrc: UInt32,
        marker: Bool,
        accessUnits: [Data]
    ) {
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
        self.ssrc = ssrc
        self.marker = marker
        self.accessUnits = accessUnits
    }
}

/// Parses the public wire formats negotiated by Apple's Remote Desktop audio
/// stream. The negotiated profile assigns payload 101 to 48 kHz stereo MPEG-4
/// AAC-ELD with SBR. The live system-audio encoder applies AAC bundling inside
/// the codec and sends one complete access unit per RTP payload. RFC 3640
/// external bundling remains available when selected by negotiation.
public enum AppleRemoteAudioRTPDepacketizer {
    public static let payloadType: UInt8 = 101
    public static let sampleRate: Int32 = 48_000
    public static let channelCount: UInt32 = 2
    public static let framesPerAccessUnit: Int64 = 480

    /// A cheap RTP-header check suitable for routing packets before parsing.
    public static func canHandle(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        return data[data.startIndex] >> 6 == 2
            && data[data.startIndex + 1] & 0x7f == payloadType
    }

    public static func parse(
        _ data: Data,
        packetization: AppleRemoteAudioPacketization = .codecAccessUnit
    ) throws -> AppleRemoteAudioRTPPacket {
        let rtp = try RTPDemuxer.parsePacket(data)
        guard rtp.payloadType == payloadType else {
            throw AppleRemoteAudioRTPError.unexpectedPayloadType(rtp.payloadType)
        }

        let payload = rtp.payload
        guard !payload.isEmpty else {
            throw AppleRemoteAudioRTPError.missingAUHeaderSection
        }

        let accessUnits: [Data]
        switch packetization {
        case .codecAccessUnit:
            // The four-byte inactive frame is also a complete codec AU and must
            // reach the decoder for its packet-loss/silence state to advance.
            accessUnits = [payload]
        case .rfc3640:
            guard payload.count >= 2 else {
                throw AppleRemoteAudioRTPError.missingAUHeaderSection
            }
            let base = payload.startIndex
            let headerLengthBits = Int(
                UInt16(payload[base]) << 8 | UInt16(payload[base + 1]))
            guard headerLengthBits > 0, headerLengthBits.isMultiple(of: 16) else {
                throw AppleRemoteAudioRTPError.invalidAUHeaderLength(headerLengthBits)
            }
            guard let parsed = parseRFC3640AccessUnits(
                payload: payload,
                headerLengthBits: headerLengthBits) else {
                throw AppleRemoteAudioRTPError.invalidAccessUnitData(
                    expectedBytes: headerLengthBits / 8,
                    availableBytes: max(0, payload.count - 2))
            }
            accessUnits = parsed
        }

        return AppleRemoteAudioRTPPacket(
            sequenceNumber: rtp.sequenceNumber,
            timestamp: rtp.timestamp,
            ssrc: rtp.ssrc,
            marker: rtp.marker,
            accessUnits: accessUnits)
    }

    private static func parseRFC3640AccessUnits(
        payload: Data,
        headerLengthBits: Int
    ) -> [Data]? {
        let base = payload.startIndex
        let headerBytes = headerLengthBits / 8
        let headerEnd = 2 + headerBytes
        guard payload.count >= headerEnd else { return nil }

        let accessUnitCount = headerLengthBits / 16
        var sizes: [Int] = []
        sizes.reserveCapacity(accessUnitCount)
        var totalSize = 0
        for index in 0..<accessUnitCount {
            let offset = 2 + index * 2
            let word = UInt16(payload[base + offset]) << 8
                | UInt16(payload[base + offset + 1])
            let size = Int(word >> 3)
            sizes.append(size)
            totalSize += size
        }
        guard totalSize == payload.count - headerEnd else { return nil }

        var accessUnits: [Data] = []
        accessUnits.reserveCapacity(accessUnitCount)
        var dataOffset = headerEnd
        for size in sizes {
            accessUnits.append(Data(payload[base + dataOffset ..< base + dataOffset + size]))
            dataOffset += size
        }
        return accessUnits
    }
}

/// Small bounded audio jitter buffer. Normal in-order packets are released
/// immediately; reordering waits for the missing sequence, while a confirmed
/// gap is skipped after a few newer packets so audio loss cannot freeze sound.
public struct AppleRemoteAudioRTPReorderBuffer: Sendable {
    private var expectedSequence: UInt16?
    private var ssrc: UInt32?
    private var pending: [UInt16: AppleRemoteAudioRTPPacket] = [:]
    private let gapConfirmationPacketCount: Int

    public init(gapConfirmationPacketCount: Int = 3) {
        self.gapConfirmationPacketCount = max(1, gapConfirmationPacketCount)
    }

    public mutating func reset() {
        expectedSequence = nil
        ssrc = nil
        pending.removeAll(keepingCapacity: true)
    }

    public mutating func enqueue(
        _ packet: AppleRemoteAudioRTPPacket
    ) -> [AppleRemoteAudioRTPPacket] {
        if ssrc != packet.ssrc {
            reset()
            ssrc = packet.ssrc
        }

        guard let expectedSequence else {
            self.expectedSequence = packet.sequenceNumber &+ 1
            return [packet]
        }

        let distance = Int16(bitPattern: packet.sequenceNumber &- expectedSequence)
        guard distance >= 0 else { return [] } // late or duplicate packet
        pending[packet.sequenceNumber] = packet

        var output = drainConsecutivePackets()
        if output.isEmpty, pending.count >= gapConfirmationPacketCount,
           let nearest = pending.keys.min(by: {
               UInt16($0 &- expectedSequence) < UInt16($1 &- expectedSequence)
           }) {
            // The missing packet has now been overtaken by enough newer audio
            // to confirm loss. Resume from the closest available sequence.
            self.expectedSequence = nearest
            output = drainConsecutivePackets()
        }
        return output
    }

    private mutating func drainConsecutivePackets() -> [AppleRemoteAudioRTPPacket] {
        var output: [AppleRemoteAudioRTPPacket] = []
        while let sequence = expectedSequence,
              let packet = pending.removeValue(forKey: sequence) {
            output.append(packet)
            expectedSequence = sequence &+ 1
        }
        return output
    }
}
