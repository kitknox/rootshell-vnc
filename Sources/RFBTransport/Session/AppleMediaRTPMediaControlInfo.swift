import Foundation

/// Public wire representation of the media-control information Apple places in
/// the standard RTP header-extension slot.
///
/// Unlike RFC 8285 extensions, the first two bytes are not an opaque profile
/// identifier. This profile defines them as a version/status byte and a
/// flags/LTR byte. The following big-endian word count remains the RTP
/// extension length.
struct AppleMediaRTPMediaControlInfo: Equatable {
    let version: UInt8
    let cameraStatus: UInt8
    let ltrBits: UInt8
    let ltrTimestamp: UInt32?
    let totalPacketsPerFrame: UInt16?
    let frameSequenceNumber: UInt16?
}

/// Parse the media-control RTP extension from its wire representation.
func appleMediaRTPMediaControlInfo(
    _ packet: Data
) -> AppleMediaRTPMediaControlInfo? {
    let minimumRTPHeaderLength = 12
    let count = packet.count
    guard count >= minimumRTPHeaderLength else { return nil }
    return packet.withUnsafeBytes { rawBuffer -> AppleMediaRTPMediaControlInfo? in
        guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }
        let firstByte = ptr[0]
        guard firstByte >> 6 == 2,
              firstByte & 0x10 != 0 else { return nil }

        let csrcBytes = Int(firstByte & 0x0f) * 4
        let extensionOffset = minimumRTPHeaderLength + csrcBytes
        guard extensionOffset + 4 <= count else { return nil }

        let statusAndVersion = ptr[extensionOffset]
        let version = statusAndVersion >> 6
        // The media-control profile defines versions 1 through 3. Reject zero so
        // an unrelated extension cannot be mistaken for
        // media control merely because its flags happen to line up.
        guard (1...3).contains(version) else { return nil }

        let flagsAndLTRBits = ptr[extensionOffset + 1]
        let extensionWordCount = Int(
            UInt16(ptr[extensionOffset + 2]) << 8
                | UInt16(ptr[extensionOffset + 3]))
        let extensionEnd = extensionOffset + 4 + extensionWordCount * 4
        guard extensionEnd <= count else { return nil }

        let frameExtensionPresent: UInt8 = 0x01
        let ltrTimestampPresent: UInt8 = 0x02
        var cursor = extensionOffset + 4
        var ltrTimestamp: UInt32?
        var totalPacketsPerFrame: UInt16?
        var frameSequenceNumber: UInt16?

        if flagsAndLTRBits & ltrTimestampPresent != 0 {
            guard cursor + 4 <= extensionEnd else { return nil }
            // This optional field is little-endian, unlike the network-byte-order
            // frame fields below.
            ltrTimestamp = UInt32(ptr[cursor])
                | UInt32(ptr[cursor + 1]) << 8
                | UInt32(ptr[cursor + 2]) << 16
                | UInt32(ptr[cursor + 3]) << 24
            cursor += 4
        }

        if version == 2, flagsAndLTRBits & frameExtensionPresent != 0 {
            guard cursor + 4 <= extensionEnd else { return nil }
            totalPacketsPerFrame = UInt16(ptr[cursor]) << 8
                | UInt16(ptr[cursor + 1])
            frameSequenceNumber = UInt16(ptr[cursor + 2]) << 8
                | UInt16(ptr[cursor + 3])
        }

        return AppleMediaRTPMediaControlInfo(
            version: version,
            cameraStatus: statusAndVersion & 0x3f,
            ltrBits: flagsAndLTRBits >> 4,
            ltrTimestamp: ltrTimestamp,
            totalPacketsPerFrame: totalPacketsPerFrame,
            frameSequenceNumber: frameSequenceNumber)
    }
}

struct AppleMediaLTRFrameAcknowledgement: Equatable {
    let ssrc: UInt32
    let rtpTimestamp: UInt32
}

/// Tracks complete LTR-marked Apple video subframes.
///
/// Apple's screen profile never sets the ordinary RTP marker bit. Instead,
/// every packet carries a media-control extension containing the total packet
/// count and frame sequence number. Native emits APP type-5 feedback once all
/// packets belonging to an LTR-marked tile subframe have arrived. Tracking by
/// SSRC is necessary because the four compound-HEVC bands advance in parallel.
struct AppleMediaLTRFrameCompletionTracker {
    private struct Frame {
        let frameSequenceNumber: UInt16
        let rtpTimestamp: UInt32
        let expectedPacketCount: Int
        var rtpSequences: Set<UInt16>
    }

    private struct CompletedFrame {
        let frameSequenceNumber: UInt16
        let rtpTimestamp: UInt32
    }

    private var activeFramesBySSRC: [UInt32: Frame] = [:]
    private var completedFramesBySSRC: [UInt32: CompletedFrame] = [:]

    mutating func insert(
        _ packet: Data
    ) -> AppleMediaLTRFrameAcknowledgement? {
        let minimumRTPHeaderLength = 12
        guard packet.count >= minimumRTPHeaderLength else { return nil }
        let base = packet.startIndex
        guard packet[base] >> 6 == 2,
              let mediaControl = appleMediaRTPMediaControlInfo(packet),
              mediaControl.ltrBits != 0,
              let totalPackets = mediaControl.totalPacketsPerFrame,
              totalPackets > 0,
              let frameSequence = mediaControl.frameSequenceNumber else {
            return nil
        }

        let rtpSequence = UInt16(packet[base + 2]) << 8
            | UInt16(packet[base + 3])
        let rtpTimestamp = UInt32(packet[base + 4]) << 24
            | UInt32(packet[base + 5]) << 16
            | UInt32(packet[base + 6]) << 8
            | UInt32(packet[base + 7])
        let ssrc = UInt32(packet[base + 8]) << 24
            | UInt32(packet[base + 9]) << 16
            | UInt32(packet[base + 10]) << 8
            | UInt32(packet[base + 11])

        if let completed = completedFramesBySSRC[ssrc],
           completed.frameSequenceNumber == frameSequence,
           completed.rtpTimestamp == rtpTimestamp {
            return nil
        }

        // Remove before mutating so `frame.rtpSequences` stays uniquely
        // referenced (avoids O(N^2) Set CoW copies across multi-packet frames).
        var frame: Frame
        if let active = activeFramesBySSRC.removeValue(forKey: ssrc),
           active.frameSequenceNumber == frameSequence,
           active.rtpTimestamp == rtpTimestamp {
            frame = active
        } else {
            var sequences = Set<UInt16>()
            // Cap initial reservation so a single packet advertising a large
            // frame cannot pre-allocate space for tens of thousands of entries.
            sequences.reserveCapacity(min(Int(totalPackets), 64))
            frame = Frame(
                frameSequenceNumber: frameSequence,
                rtpTimestamp: rtpTimestamp,
                expectedPacketCount: Int(totalPackets),
                rtpSequences: sequences)
        }
        frame.rtpSequences.insert(rtpSequence)

        guard frame.rtpSequences.count >= frame.expectedPacketCount else {
            activeFramesBySSRC[ssrc] = frame
            return nil
        }

        completedFramesBySSRC[ssrc] = CompletedFrame(
            frameSequenceNumber: frameSequence,
            rtpTimestamp: rtpTimestamp)
        return AppleMediaLTRFrameAcknowledgement(
            ssrc: ssrc,
            rtpTimestamp: rtpTimestamp)
    }

    mutating func reset() {
        activeFramesBySSRC.removeAll(keepingCapacity: true)
        completedFramesBySSRC.removeAll(keepingCapacity: true)
    }
}
