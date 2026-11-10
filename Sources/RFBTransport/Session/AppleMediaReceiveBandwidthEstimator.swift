import Foundation

/// The bandwidth estimate a native feedback-only screen receiver reports in
/// RCTL (statistics-collector mode 8, non-cellular radio). It measures packet
/// trains, at most one frame every two seconds; the sender's own controller
/// reacts to delay, RTT, and loss.
struct AppleMediaReceiveBandwidthEstimator {
    enum State: Int {
        case initialized = 0
        case stable = 1
        case trendingUp = 2
        case trendingDown = 3
        case jumpedUp = 4
        case jumpedDown = 5
        case noSample = 6
    }

    static let maximumDetectableBps: Double = 60_000_000
    private static let minimumTrainBytes = 250
    private static let initialMinimumBps: Double = 100_000
    private static let bandMarginBps: Double = 200_000
    private static let bandFraction = 0.5
    private static let minimumDivergentSamples = 4
    private static let fastDivergentSamples = 10
    private static let divergenceDurationSeconds = 4.0
    private static let probingIntervalSeconds = 2.0

    private(set) var estimateBps: Double = 0
    private(set) var state: State = .initialized

    private var isInitialized = false
    private var trainTimestamp: UInt32 = 0
    private var trainFirstArrival = 0.0
    private var trainLastArrival = 0.0
    private var trainBytes = 0
    private var trainPackets = 0
    private var divergeCount = 0
    private var divergeSum = 0.0
    private var divergeStart = 0.0

    private var lastProbeEnd = 0.0
    private var isProbing = false
    private var probeTimestamp: UInt32 = 0

    /// RCTL bytes 18-19: kbps rounded down to a multiple of 8, plus one when stable.
    var rctlKbps: UInt16 {
        let bps = UInt32(min(estimateBps, Double(UInt32.max)))
        guard bps != 0 else { return 0 }
        let kbps = (bps / 1_000) & 0x7F_FFF8 + (state == .stable ? 1 : 0)
        return UInt16(min(kbps, UInt32(UInt16.max)))
    }

    /// Feed every received video RTP packet in arrival order. The probing gate
    /// admits one frame's packet train after each two-second interval.
    mutating func notePacket(
        arrivalSeconds: Double,
        rtpTimestamp: UInt32,
        sizeBytes: Int,
        marker: Bool,
        startsProbe: Bool
    ) {
        guard arrivalSeconds - lastProbeEnd >= Self.probingIntervalSeconds else {
            return
        }
        let inTrain: Bool
        if startsProbe {
            probeTimestamp = rtpTimestamp
            isProbing = true
            inTrain = true
        } else if rtpTimestamp == probeTimestamp {
            isProbing = true
            inTrain = true
        } else if isProbing {
            isProbing = false
            probeTimestamp = 0
            inTrain = false
        } else {
            return
        }
        calculate(
            time: arrivalSeconds,
            rtpTimestamp: rtpTimestamp,
            sizeBytes: sizeBytes,
            inTrain: inTrain,
            endOfFrame: marker)
        if marker || !isProbing {
            lastProbeEnd = arrivalSeconds
        }
    }

    /// HEVC fragmentation units (RFC 7798 type 49) and single VCL NAL units
    /// open a probe.
    static func startsProbe(payloadFirstByte: UInt8) -> Bool {
        let nalType = (payloadFirstByte >> 1) & 0x3F
        return nalType == 49 || nalType < 32
    }

    /// Native estimator step, fed without the probing gate.
    mutating func calculate(
        time: Double,
        rtpTimestamp: UInt32,
        sizeBytes: Int,
        inTrain: Bool,
        endOfFrame: Bool
    ) {
        if !isInitialized {
            isInitialized = true
            trainTimestamp = inTrain ? rtpTimestamp &- 1 : rtpTimestamp
            divergeStart = time
            divergeCount = 0
        }

        var sample: (bps: Double, bytes: Int, packets: Int, duration: Double)?
        func completedTrain() -> (Double, Int, Int, Double)? {
            guard trainBytes > Self.minimumTrainBytes else { return nil }
            let duration = trainLastArrival - trainFirstArrival
            return (8 * Double(trainBytes) / duration, trainBytes, trainPackets, duration)
        }

        if inTrain, rtpTimestamp == trainTimestamp {
            // The train's first packet anchors time and is not counted.
            trainLastArrival = max(trainLastArrival, time)
            trainBytes += sizeBytes
            trainPackets += 1
            if endOfFrame { sample = completedTrain() }
        } else {
            // A new train re-applies the previous one, as native does.
            sample = completedTrain()
            trainBytes = 0
            trainPackets = 0
            trainTimestamp = rtpTimestamp
            trainFirstArrival = time
            trainLastArrival = 0
        }

        guard let sample, sample.bps > 0 else { return }
        let accepted: Double
        if estimateBps == 0 {
            accepted = sample.bps
        } else if sample.packets < 1 || sample.bytes < Self.minimumTrainBytes {
            accepted = 0
        } else {
            // Short trains are accepted: fast sudden-bandwidth detection is on.
            accepted = sample.bps
        }
        update(sampleBps: accepted, time: time)
    }

    private mutating func update(sampleBps: Double, time: Double) {
        guard sampleBps > 0 else {
            state = .noSample
            return
        }
        let sample = min(sampleBps, Self.maximumDetectableBps)
        let lower = sample <= Self.bandFraction * estimateBps
            || estimateBps - sample > Self.bandMarginBps
        let higher = sample >= (1 + Self.bandFraction) * estimateBps
            || sample - estimateBps > Self.bandMarginBps
        if estimateBps == 0 {
            estimateBps = max(sample, Self.initialMinimumBps)
            state = .initialized
            return
        }
        if !lower && !higher {
            estimateBps = 0.9 * estimateBps + 0.1 * sample
            divergeCount = 0
            divergeSum = 0
            state = .stable
            return
        }

        let sustained = time - divergeStart >= Self.divergenceDurationSeconds
        if lower {
            if divergeCount >= 0 {
                divergeSum = 0
                divergeStart = time
                divergeCount = -1
            } else {
                divergeCount -= 1
            }
            state = .trendingDown
        } else {
            if divergeCount > 0 {
                divergeCount += 1
            } else {
                divergeSum = 0
                divergeStart = time
                divergeCount = 1
            }
            state = .trendingUp
        }
        divergeSum += sample
        let count = abs(divergeCount)
        if (count >= Self.minimumDivergentSamples && sustained)
            || count >= Self.fastDivergentSamples {
            estimateBps = divergeSum / Double(count)
            state = divergeCount < 0 ? .jumpedDown : .jumpedUp
            divergeCount = 0
            divergeSum = 0
        }
    }

    /// First byte of the RTP payload, past CSRCs and any header extension.
    static func rtpPayloadFirstByte(_ packet: Data) -> UInt8? {
        guard packet.count >= 12 else { return nil }
        let base = packet.startIndex
        let csrcCount = Int(packet[base] & 0x0F)
        var offset = 12 + csrcCount * 4
        if packet[base] & 0x10 != 0 {
            guard packet.count >= offset + 4 else { return nil }
            let words = Int(packet[base + offset + 2]) << 8 | Int(packet[base + offset + 3])
            offset += 4 + words * 4
        }
        guard packet.count > offset else { return nil }
        return packet[base + offset]
    }
}
