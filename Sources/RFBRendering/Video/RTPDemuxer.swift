import Foundation
import RFBProtocol

/// Errors that can occur during RTP packet parsing.
public enum RTPError: Error, Sendable, LocalizedError {
    case packetTooShort(Int)
    case unsupportedVersion(UInt8)
    case invalidPayload(String)

    public var errorDescription: String? {
        switch self {
        case .packetTooShort(let size):
            return "RTP packet too short: \(size) bytes (minimum 12)"
        case .unsupportedVersion(let version):
            return "Unsupported RTP version: \(version) (expected 2)"
        case .invalidPayload(let detail):
            return "Invalid RTP payload: \(detail)"
        }
    }
}

/// Reassembles RTP packets into complete HEVC NAL units.
///
/// Implements RFC 7798 (RTP Payload Format for HEVC) packetization modes:
/// - Single NAL unit packets: payload is a complete NAL unit
/// - Fragmentation Units (FU, type 49): large NAL units split across packets
/// - Aggregation Packets (AP, type 48): multiple small NAL units in one packet
public final class RTPDemuxer: @unchecked Sendable {

    // MARK: - Types

    public struct RTPPacket: Sendable {
        public let version: UInt8
        public let payloadType: UInt8
        public let sequenceNumber: UInt16
        public let timestamp: UInt32
        public let ssrc: UInt32
        public let payload: Data
        public let marker: Bool

        public init(
            version: UInt8,
            payloadType: UInt8,
            sequenceNumber: UInt16,
            timestamp: UInt32,
            ssrc: UInt32,
            payload: Data,
            marker: Bool
        ) {
            self.version = version
            self.payloadType = payloadType
            self.sequenceNumber = sequenceNumber
            self.timestamp = timestamp
            self.ssrc = ssrc
            self.payload = payload
            self.marker = marker
        }
    }

    /// A reassembled NAL unit tagged with its decoding-order number (DON, the
    /// low 16 bits / DONL), RTP presentation timestamp, and source SSRC.
    public struct DemuxedNAL: Sendable, Equatable {
        public let don: UInt16
        public let timestamp: UInt32
        public let ssrc: UInt32
        public let nal: Data
        /// True when this NAL ends the RTP access unit. HEVC pictures may
        /// contain several VCL NALs; VideoToolbox must receive them together.
        public let endOfAccessUnit: Bool
        public init(
            don: UInt16,
            timestamp: UInt32 = 0,
            ssrc: UInt32,
            nal: Data,
            endOfAccessUnit: Bool = true
        ) {
            self.don = don
            self.timestamp = timestamp
            self.ssrc = ssrc
            self.nal = nal
            self.endOfAccessUnit = endOfAccessUnit
        }
    }

    // MARK: - FU reassembly state

    /// State for reassembling fragmentation units.
    private struct FUState {
        var nalData: Data
        var timestamp: UInt32
        var lastSequence: UInt16
        var nalType: UInt8
        var layerID: UInt8
        var temporalID: UInt8
        var don: UInt16
    }

    // MARK: - Private state

    private let lock = NSLock()
    private let usesDONL: Bool
    // Reassembly state is tracked per SSRC: Apple multiplexes several media
    // streams (e.g. video PT 100 and PT 101) with independent sequence spaces.
    // Key everything by SSRC so interleaving cannot scramble FU state.
    private var fuStates: [UInt32: FUState] = [:]
    private var lastSequenceNumbers: [UInt32: UInt16] = [:]

    // MARK: - Init

    /// - Parameter usesDecodingOrderNumbers: Whether the negotiated HEVC RTP
    ///   mode inserts a DONL field. Apple's interleaved multi-tile mode does;
    ///   its conventional one-tile mode does not.
    public init(usesDecodingOrderNumbers: Bool = true) {
        self.usesDONL = usesDecodingOrderNumbers
    }

    /// Return whether the datagram is an RTCP packet rather than RTP media.
    ///
    /// RTCP packet types are carried in the second byte and currently occupy
    /// the 192...223 range. Apple's media stream uses RTCP receiver/sender
    /// reports alongside RTP-shaped video packets on the same UDP port.
    public static func isRTCPPacket(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        let packetType = data[data.startIndex + 1]
        return packetType >= 192 && packetType <= 223
    }

    // MARK: - Packet Parsing

    /// Parse an RTP packet from raw UDP data.
    ///
    /// RTP header layout (12 bytes minimum):
    /// ```
    ///  Byte 0:    V(2) P(1) X(1) CC(4)
    ///  Byte 1:    M(1) PT(7)
    ///  Bytes 2-3: Sequence Number (big-endian)
    ///  Bytes 4-7: Timestamp (big-endian)
    ///  Bytes 8-11: SSRC (big-endian)
    ///  Followed by CC * 4 bytes of CSRC (if CC > 0)
    ///  Followed by extension header (if X == 1)
    /// ```
    public func parsePacket(_ data: Data) throws -> RTPPacket {
        try Self.parsePacket(data)
    }

    /// Parse an RTP packet from raw UDP data without allocating a demuxer or
    /// copying the payload bytes (the returned payload is a zero-copy slice).
    public static func parsePacket(_ data: Data) throws -> RTPPacket {
        let count = data.count
        guard count >= 12 else {
            throw RTPError.packetTooShort(count)
        }

        let parsed: (
            version: UInt8,
            payloadType: UInt8,
            sequenceNumber: UInt16,
            timestamp: UInt32,
            ssrc: UInt32,
            marker: Bool,
            payloadOffset: Int,
            payloadEnd: Int
        ) = try data.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw RTPError.packetTooShort(count)
            }
            let byte0 = ptr[0]
            let version = (byte0 >> 6) & 0x03
            guard version == 2 else {
                throw RTPError.unsupportedVersion(version)
            }

            let padding = (byte0 >> 5) & 0x01
            let hasExtension = (byte0 >> 4) & 0x01
            let csrcCount = Int(byte0 & 0x0F)

            let byte1 = ptr[1]
            let marker = (byte1 >> 7) & 0x01 == 1
            let payloadType = byte1 & 0x7F

            let sequenceNumber = UInt16(ptr[2]) << 8 | UInt16(ptr[3])
            let timestamp = UInt32(ptr[4]) << 24
                | UInt32(ptr[5]) << 16
                | UInt32(ptr[6]) << 8
                | UInt32(ptr[7])
            let ssrc = UInt32(ptr[8]) << 24
                | UInt32(ptr[9]) << 16
                | UInt32(ptr[10]) << 8
                | UInt32(ptr[11])

            var payloadOffset = 12 + csrcCount * 4
            guard count >= payloadOffset else {
                throw RTPError.packetTooShort(count)
            }

            if hasExtension == 1 {
                guard count >= payloadOffset + 4 else {
                    throw RTPError.packetTooShort(count)
                }
                let extensionLength = Int(
                    UInt16(ptr[payloadOffset + 2]) << 8 | UInt16(ptr[payloadOffset + 3]))
                payloadOffset += 4 + extensionLength * 4
            }

            guard count >= payloadOffset else {
                throw RTPError.packetTooShort(count)
            }

            var payloadEnd = count
            if padding == 1 && count > payloadOffset {
                let paddingLength = Int(ptr[count - 1])
                payloadEnd = max(payloadOffset, count - paddingLength)
            }

            return (
                version,
                payloadType,
                sequenceNumber,
                timestamp,
                ssrc,
                marker,
                payloadOffset,
                payloadEnd
            )
        }

        let payload: Data
        if parsed.payloadEnd > parsed.payloadOffset {
            let base = data.startIndex
            payload = data[base + parsed.payloadOffset ..< base + parsed.payloadEnd]
        } else {
            payload = Data()
        }

        return RTPPacket(
            version: parsed.version,
            payloadType: parsed.payloadType,
            sequenceNumber: parsed.sequenceNumber,
            timestamp: parsed.timestamp,
            ssrc: parsed.ssrc,
            payload: payload,
            marker: parsed.marker
        )
    }

    // MARK: - NAL Unit Reassembly

    /// Feed a packet and get back every complete NAL unit that is ready.
    /// Returns an empty array if a fragmented NAL unit is still being assembled.
    ///
    /// HEVC NAL unit header (2 bytes):
    /// ```
    ///  Byte 0: F(1) Type(6) LayerID-high(1)
    ///  Byte 1: LayerID-low(5) TID(3)
    /// ```
    public func feedPacket(_ packet: RTPPacket) -> [DemuxedNAL] {
        lock.lock()
        defer { lock.unlock() }

        let ssrc = packet.ssrc

        // Detect sequence number gaps within this SSRC's stream.
        if let lastSeq = lastSequenceNumbers[ssrc] {
            let expected = lastSeq &+ 1
            if packet.sequenceNumber != expected {
                // Gap detected; discard any in-progress FU for this stream.
                fuStates[ssrc] = nil
            }
        }
        lastSequenceNumbers[ssrc] = packet.sequenceNumber

        guard packet.payload.count >= 2 else { return [] }

        let payloadBase = packet.payload.startIndex

        // Parse HEVC NAL unit header from RTP payload
        let byte0 = packet.payload[payloadBase]

        // NAL unit type is bits 1-6 of the first byte
        let nalType = (byte0 >> 1) & 0x3F

        switch nalType {
        case 48:
            // Aggregation Packet (AP)
            return handleAggregationPacket(
                packet.payload,
                ssrc: ssrc,
                timestamp: packet.timestamp,
                marker: packet.marker)

        case 49:
            // Fragmentation Unit (FU)
            return handleFragmentationUnit(packet)

        default:
            fuStates[ssrc] = nil
            // With DON enabled, Apple inserts a 2-byte DONL between the NAL
            // header and RBSP. The one-tile mode is ordinary HEVC RTP and its
            // RBSP starts immediately after the NAL header.
            let don = usesDONL ? Self.donl(in: packet.payload) : 0
            return [DemuxedNAL(
                don: don,
                timestamp: packet.timestamp,
                ssrc: ssrc,
                nal: usesDONL ? stripSingleNALUnitDONL(packet.payload) : packet.payload,
                endOfAccessUnit: packet.marker)]
        }
    }

    /// Read the 2-byte DONL that follows the NAL/PayloadHdr in Apple's DON-mode
    /// packets. The DONL sits at payload offset 2 (after the 2-byte header) for
    /// single-NAL and AP packets. Returns 0 if the payload is too short.
    private static func donl(in payload: Data) -> UInt16 {
        let base = payload.startIndex
        guard payload.count >= 4 else { return 0 }
        return UInt16(payload[base + 2]) << 8 | UInt16(payload[base + 3])
    }

    /// Remove the DONL between the 2-byte NAL header and the NAL payload in a
    /// single-NAL-unit packet.
    private func stripSingleNALUnitDONL(_ payload: Data) -> Data {
        guard payload.count > 2 + Self.donlLength else { return payload }
        let base = payload.startIndex
        var nal = Data(capacity: payload.count - Self.donlLength)
        nal.append(payload[base ..< base + 2])
        nal.append(payload[base + 2 + Self.donlLength ..< payload.endIndex])
        return nal
    }

    /// Reset state (e.g., on sequence number discontinuity).
    public func reset() {
        lock.lock()
        defer { lock.unlock() }

        fuStates.removeAll()
        lastSequenceNumbers.removeAll()
    }

    // MARK: - FU Handling

    /// Handle a Fragmentation Unit (FU) packet (NAL type 49).
    ///
    /// FU header layout (1 byte, after the 2-byte HEVC NAL header):
    /// ```
    ///  Bit 0: S (Start)
    ///  Bit 1: E (End)
    ///  Bits 2-7: FuType (the actual NAL unit type being fragmented)
    /// ```
    private func handleFragmentationUnit(_ packet: RTPPacket) -> [DemuxedNAL] {
        // 2-byte PayloadHdr + 1-byte FU header, followed by DONL only in the
        // negotiated interleaved mode.
        let metadataLength = usesDONL ? Self.donlLength : 0
        guard packet.payload.count >= 3 + metadataLength else { return [] }

        let payloadBase = packet.payload.startIndex
        let byte0 = packet.payload[payloadBase]
        let byte1 = packet.payload[payloadBase + 1]
        let fuHeader = packet.payload[payloadBase + 2]

        let isStart = (fuHeader >> 7) & 0x01 == 1
        let isEnd = (fuHeader >> 6) & 0x01 == 1
        let fuType = fuHeader & 0x3F

        // Extract layerID and temporalID from the RTP NAL header
        let layerID = ((byte0 & 0x01) << 5) | ((byte1 >> 3) & 0x1F)
        let temporalID = byte1 & 0x07

        // Apple's HEVC RTP uses decoding-order numbers (sprop-max-don-diff > 0),
        // so a 2-byte DONL follows the FU header in *every* fragment (not just
        // the start fragment as RFC 7798 specifies). Skip it; it is not part of
        // the reassembled NAL unit. Leaving it in corrupts every slice.
        let don = usesDONL
            ? UInt16(packet.payload[payloadBase + 3]) << 8
                | UInt16(packet.payload[payloadBase + 4])
            : 0
        let fragmentData = packet.payload.suffix(from: payloadBase + 3 + metadataLength)

        if isStart {
            // Start of a new FU: construct the real NAL header
            // The NAL header reconstructs the original type
            let nalByte0 = (byte0 & 0x81) | (fuType << 1)
            let nalByte1 = byte1

            let initialCapacity = isEnd
                ? 2 + fragmentData.count
                : max(2 + fragmentData.count, 8_192)
            var nalData = Data(capacity: initialCapacity)
            nalData.append(nalByte0)
            nalData.append(nalByte1)
            nalData.append(fragmentData)

            if isEnd {
                // Single-fragment FU (unusual but valid)
                fuStates[packet.ssrc] = nil
                return [DemuxedNAL(
                    don: don,
                    timestamp: packet.timestamp,
                    ssrc: packet.ssrc,
                    nal: nalData,
                    endOfAccessUnit: packet.marker)]
            }

            fuStates[packet.ssrc] = FUState(
                nalData: nalData,
                timestamp: packet.timestamp,
                lastSequence: packet.sequenceNumber,
                nalType: fuType,
                layerID: layerID,
                temporalID: temporalID,
                don: don
            )
            return []

        } else if var state = fuStates.removeValue(forKey: packet.ssrc) {
            // Remove from the dictionary before mutating so `state.nalData`
            // remains uniquely referenced (prevents O(N^2) CoW copies across
            // hundreds of RTP fragments in a single HEVC slice).
            state.nalData.append(fragmentData)
            state.lastSequence = packet.sequenceNumber

            if isEnd {
                // FU complete. Use the DON captured from the start fragment.
                return [DemuxedNAL(
                    don: state.don,
                    timestamp: state.timestamp,
                    ssrc: packet.ssrc,
                    nal: state.nalData,
                    endOfAccessUnit: packet.marker)]
            } else {
                fuStates[packet.ssrc] = state
                return []
            }

        } else {
            // Middle/end fragment with no start — discard
            return []
        }
    }

    // MARK: - AP Handling

    /// Handle an Aggregation Packet (AP, NAL type 48).
    ///
    /// Apple's layout is: 2-byte PayloadHdr, a single 2-byte DONL, then each
    /// aggregation unit as `2-byte NAL size + NAL unit`. Despite RFC 7798
    /// specifying a per-unit DOND when DON is in use, Apple omits it (verified
    /// on the wire: `... 00 17 [VPS] 00 52 [SPS] 00 07 [PPS]`).
    private func handleAggregationPacket(
        _ payload: Data,
        ssrc: UInt32,
        timestamp: UInt32,
        marker: Bool
    ) -> [DemuxedNAL] {
        let base = payload.startIndex
        let don = usesDONL ? Self.donl(in: payload) : 0
        var offset = base + 2 + (usesDONL ? Self.donlLength : 0)
        var nalUnits: [DemuxedNAL] = []

        while offset + 2 <= payload.endIndex {
            let nalSize = Int(UInt16(payload[offset]) << 8 | UInt16(payload[offset + 1]))
            offset += 2

            guard nalSize > 0, offset + nalSize <= payload.endIndex else {
                return nalUnits
            }

            // Apple omits per-unit DOND, so all units in the AP share the AP's
            // DON. APs carry only VPS/SPS/PPS (sent together just before an IDR),
            // so grouping them under one DON keeps them ahead of that IDR.
            nalUnits.append(DemuxedNAL(
                don: don,
                timestamp: timestamp,
                ssrc: ssrc,
                nal: Data(payload[offset ..< offset + nalSize]),
                endOfAccessUnit: false))
            offset += nalSize
        }

        if marker, let last = nalUnits.indices.last {
            let unit = nalUnits[last]
            nalUnits[last] = DemuxedNAL(
                don: unit.don,
                timestamp: unit.timestamp,
                ssrc: unit.ssrc,
                nal: unit.nal,
                endOfAccessUnit: true)
        }
        return nalUnits
    }

    /// Length of the DONL (decoding-order-number, LSB) field, in bytes.
    private static let donlLength = 2
}
