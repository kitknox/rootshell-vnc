import Foundation
import XCTest

@testable import RFBProtocol
@testable import RFBRendering

/// Offline workloads: no server, capture file, or wall-clock assertion required.
final class AppleDCTPerformanceTests: XCTestCase {
    private struct Bits {
        var bytes: [UInt8] = []
        var count = 0
        mutating func put(_ value: Int, _ width: Int) {
            for shift in stride(from: width - 1, through: 0, by: -1) {
                if count % 8 == 0 { bytes.append(0) }
                bytes[count / 8] |= UInt8((value >> shift) & 1) << (7 - count % 8)
                count += 1
            }
        }
        mutating func run(_ count: Int) {
            if count == 1 {
                put(0, 1)
                return
            }
            put(1, 1)
            if count <= 16 {
                put(count - 2, 4)
                return
            }
            put(15, 4)
            var value = count - 17
            repeat {
                let next = value >> 7
                put((value & 127) | (next == 0 ? 0 : 128), 8)
                value = next
            } while value != 0
        }
    }

    private func framed(_ bytes: [UInt8]) -> Data {
        let n = bytes.count
        return Data(
            [
                UInt8((n >> 24) & 255), UInt8((n >> 16) & 255),
                UInt8((n >> 8) & 255), UInt8(n & 255),
            ] + bytes)
    }

    private func base(tiles: Int, kind: String) -> Data {
        var commands = Bits()
        var data = Bits()
        commands.put(0, 1)
        let command = kind == "palette" ? 3 : kind == "solid" ? 0 : 5
        commands.put(command, 3)
        commands.run(kind == "copy" ? 1 : tiles)
        if kind == "copy", tiles > 1 {
            commands.put(1, 3)
            commands.run(tiles - 1)
        }
        if command == 5 {
            for tile in 0..<(kind == "copy" ? 1 : tiles) {
                if kind == "reuse", tile > 0 {
                    data.put(1, 1)
                    continue
                }
                data.put(0, 1)  // new coefficients
                data.put(1, 1)  // reuse zero chroma DC
                data.put(0, 1)  // low cutoff = 15
                data.put(0, 2)  // Y DC delta = zero
                if kind != "dc" {
                    for coefficient in 1...8 {
                        data.put(0, 1)
                        data.put((tile + coefficient) % 2 == 0 ? 2 : 3, 2)
                    }
                }
                data.put(0, 1)
                data.put(1, 2)
                data.put(0, 1)  // EOB
            }
        } else if command == 3 {
            for tile in 0..<tiles {
                data.put(0, 8)
                for row in 0..<8 { data.put((tile + row) % 2 == 0 ? 0xaa : 0x55, 8) }
            }
        }
        if data.bytes.isEmpty { data.put(0, 8) }
        let offset = 6 + commands.bytes.count
        return framed(
            [
                0, 15, 25, UInt8((offset >> 16) & 255),
                UInt8((offset >> 8) & 255), UInt8(offset & 255),
            ]
                + commands.bytes + data.bytes)
    }

    private func refinement(tiles: Int) -> Data {
        var bits = Bits()
        for _ in 0..<tiles {
            bits.put(1, 2)
            bits.put(7, 6)
            bits.put(0, 7)  // retain the first seven nonzero Y coefficients
            bits.put(0, 1)
            bits.put(0, 1)  // chroma adjustments
        }
        return framed([1, 0, 0] + bits.bytes)
    }

    private func cache(tiles: Int) -> Data {
        var commands = Bits()
        var data = Bits()
        commands.put(0, 1)
        commands.put(6, 3)
        commands.run(tiles)
        for tile in 0..<tiles { data.put(tile % 64_999 + 1, 16) }
        let offset = 6 + commands.bytes.count
        return framed(
            [
                0, 15, 25, UInt8((offset >> 16) & 255),
                UInt8((offset >> 8) & 255), UInt8(offset & 255),
            ]
                + commands.bytes + data.bytes)
    }

    private func checksum(_ data: Data) -> UInt64 {
        data.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }

    func testDeterministicPixels() throws {
        let rect = FramebufferRect(
            x: 8, y: 8, width: 33, height: 17,
            encoding: .appleMultiVariantScreenshare)
        let tiles = 15
        // Captured from the pre-refactor decoder in both Debug (-O) and Release.
        let expected: [String: UInt64] = [
            "fresh": 18_280_112_449_598_222_571, "dc": 12_521_420_704_458_275_416,
            "reuse": 4_715_330_786_532_373_541, "copy": 18_264_730_359_969_776_853,
            "solid": 14_102_461_243_796_094_609, "palette": 7_407_592_857_414_059_249,
            "refine": 18_318_370_942_552_003_671, "cache": 18_318_370_942_552_003_671,
        ]
        for kind in ["fresh", "dc", "reuse", "copy", "solid", "palette", "refine", "cache"] {
            let decoder = AppleAdaptiveDCTDecoder()
            let framebuffer = Framebuffer(width: 41, height: 25, pixelFormat: .bgra8888)
            try decoder.render(rect: rect, payload: base(tiles: tiles, kind: kind), to: framebuffer)
            if kind == "refine" || kind == "cache" {
                try decoder.render(rect: rect, payload: refinement(tiles: tiles), to: framebuffer)
            }
            if kind == "cache" {
                try decoder.render(rect: rect, payload: cache(tiles: tiles), to: framebuffer)
            }
            XCTAssertEqual(
                checksum(framebuffer.getPixels(x: 0, y: 0, width: 41, height: 25)),
                expected[kind], kind)
        }
    }

    func testBorrowedBitReaderAcrossByteBoundaries() throws {
        let storage = Data([0xff] + (0..<128).map { UInt8(truncatingIfNeeded: $0 * 73 + 19) })
        let slice = storage.dropFirst()
        XCTAssertEqual(slice.startIndex, 1)
        try slice.withUnsafeBytes { bytes in
            var reader = AppleAdaptiveDCTDecoder.BitReader(bytes)
            var offset = 0
            for width in [0, 1, 32, 7, 1, 16, 3, 32, 8, 1, 31, 0] {
                var expected: UInt32 = 0
                for bit in offset..<(offset + width) {
                    expected = (expected << 1) | UInt32((bytes[bit / 8] >> (7 - bit % 8)) & 1)
                }
                let actual = width == 1 ? try reader.readBit() : try reader.readBits(width)
                XCTAssertEqual(actual, expected)
                offset += width
                XCTAssertEqual(reader.bitOffset, offset)
                XCTAssertEqual(reader.remainingBitCount, bytes.count * 8 - offset)
            }
            while reader.remainingBitCount > 0 { _ = try reader.readBit() }
            XCTAssertEqual(try reader.readBits(0), 0)
            XCTAssertThrowsError(try reader.readBit())
            XCTAssertThrowsError(try reader.readBits(1))
            XCTAssertThrowsError(try reader.readBits(-1))
            XCTAssertThrowsError(try reader.readBits(33))
        }
    }

    func testSlicedPayloadAndTruncatedStreams() throws {
        let rect = FramebufferRect(
            x: 0, y: 0, width: 16, height: 8,
            encoding: .appleMultiVariantScreenshare)
        let payload = base(tiles: 2, kind: "fresh")
        let sliced = (Data([0xff]) + payload).dropFirst()
        let expected = Framebuffer(width: 16, height: 8, pixelFormat: .bgra8888)
        let actual = Framebuffer(width: 16, height: 8, pixelFormat: .bgra8888)
        try AppleAdaptiveDCTDecoder().render(rect: rect, payload: payload, to: expected)
        try AppleAdaptiveDCTDecoder().render(rect: rect, payload: sliced, to: actual)
        XCTAssertEqual(
            actual.getPixels(x: 0, y: 0, width: 16, height: 8),
            expected.getPixels(x: 0, y: 0, width: 16, height: 8))
        for end in 0..<payload.count {
            let truncated = end < 4 ? Data(payload.prefix(end)) : framed(Array(payload[4..<end]))
            XCTAssertThrowsError(
                try AppleAdaptiveDCTDecoder().render(
                    rect: rect, payload: truncated, to: actual), "byte \(end)")
        }
        let refined = refinement(tiles: 2)
        for end in 4..<refined.count {
            let decoder = AppleAdaptiveDCTDecoder()
            try decoder.render(rect: rect, payload: payload, to: actual)
            XCTAssertThrowsError(
                try decoder.render(
                    rect: rect, payload: framed(Array(refined[4..<end])), to: actual))
        }
    }

    /// The Mac keeps cache keys across display size changes within a
    /// connection; only per-tile coefficient state belongs to one size.
    func testResizeKeepsCacheKeysButDiscardsTileCoefficients() throws {
        let rect = FramebufferRect(
            x: 0, y: 0, width: 16, height: 8,
            encoding: .appleMultiVariantScreenshare)
        let expected = Framebuffer(width: 24, height: 8, pixelFormat: .bgra8888)
        let reference = AppleAdaptiveDCTDecoder()
        try reference.render(rect: rect, payload: base(tiles: 2, kind: "fresh"), to: expected)
        try reference.render(rect: rect, payload: refinement(tiles: 2), to: expected)
        try reference.render(rect: rect, payload: cache(tiles: 2), to: expected)

        let decoder = AppleAdaptiveDCTDecoder()
        let framebuffer = Framebuffer(width: 16, height: 8, pixelFormat: .bgra8888)
        try decoder.render(rect: rect, payload: base(tiles: 2, kind: "fresh"), to: framebuffer)
        try decoder.render(rect: rect, payload: refinement(tiles: 2), to: framebuffer)
        framebuffer.resize(width: 24, height: 8)
        try decoder.render(rect: rect, payload: cache(tiles: 2), to: framebuffer)
        XCTAssertEqual(
            framebuffer.getPixels(x: 0, y: 0, width: 16, height: 8),
            expected.getPixels(x: 0, y: 0, width: 16, height: 8))
        let gray = Data((0..<(16 * 8)).flatMap { _ in [UInt8(128), 128, 128, 255] })
        XCTAssertNotEqual(framebuffer.getPixels(x: 0, y: 0, width: 16, height: 8), gray)
        XCTAssertThrowsError(try decoder.render(rect: rect, payload: refinement(tiles: 2), to: framebuffer))
    }

    func testCacheRejectsInvalidKeys() throws {
        let rect = FramebufferRect(
            x: 0, y: 0, width: 8, height: 8,
            encoding: .appleMultiVariantScreenshare)
        let framebuffer = Framebuffer(width: 8, height: 8, pixelFormat: .bgra8888)
        for key in [0, 65_000, 65_535] {
            var data = Bits()
            data.put(key, 16)
            let payload = framed([0, 15, 25, 0, 0, 7, 0x60] + data.bytes)
            XCTAssertThrowsError(
                try AppleAdaptiveDCTDecoder().render(rect: rect, payload: payload, to: framebuffer))
        }
    }

    func testCacheRingWrapKeepsIndependentSnapshots() throws {
        let decoder = AppleAdaptiveDCTDecoder()
        let width = 2048
        let height = 2040
        let tiles = 65_280
        let framebuffer = Framebuffer(width: width, height: height, pixelFormat: .bgra8888)
        let full = FramebufferRect(
            x: 0, y: 0, width: UInt16(width), height: UInt16(height),
            encoding: .appleMultiVariantScreenshare)
        try decoder.render(rect: full, payload: base(tiles: tiles, kind: "fresh"), to: framebuffer)
        try decoder.render(rect: full, payload: refinement(tiles: tiles), to: framebuffer)
        // Key 1 was overwritten at tile 64,999; key 283 still holds tile 282.
        let wrapped = framebuffer.getPixels(x: (64_999 % 256) * 8, y: (64_999 / 256) * 8, width: 8, height: 8)
        let retained = framebuffer.getPixels(x: (282 % 256) * 8, y: (282 / 256) * 8, width: 8, height: 8)
        var commands = Bits()
        var data = Bits()
        commands.put(0, 1)
        commands.put(6, 3)
        commands.run(2)
        data.put(1, 16)
        data.put(283, 16)
        let offset = 6 + commands.bytes.count
        let payload = framed([0, 15, 25, 0, 0, UInt8(offset)] + commands.bytes + data.bytes)
        let rect = FramebufferRect(
            x: 0, y: 0, width: 16, height: 8,
            encoding: .appleMultiVariantScreenshare)
        // Overwrite predictor scratch and framebuffer coefficients before the cache read.
        try decoder.render(rect: rect, payload: base(tiles: 2, kind: "dc"), to: framebuffer)
        try decoder.render(rect: rect, payload: payload, to: framebuffer)
        XCTAssertEqual(framebuffer.getPixels(x: 0, y: 0, width: 8, height: 8), wrapped)
        XCTAssertEqual(framebuffer.getPixels(x: 8, y: 0, width: 8, height: 8), retained)
    }

    func testMalformedStreamsRemainBounded() throws {
        var seed: UInt32 = 0x1234_5678
        func next() -> UInt8 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: seed >> 24)
        }
        let decoder = AppleAdaptiveDCTDecoder()
        let framebuffer = Framebuffer(width: 17, height: 17, pixelFormat: .bgra8888)
        let rect = FramebufferRect(
            x: 1, y: 1, width: 17, height: 17,
            encoding: .appleMultiVariantScreenshare)
        for iteration in 0..<1000 {
            var message = (0..<(7 + Int(next() % 64))).map { _ in next() }
            message[0] = UInt8(iteration % 2)
            if message[0] == 0 {
                message[3] = 0
                message[4] = 0
                message[5] = 7
            } else {
                message[1] %= 16
                message[2] %= 21
            }
            do {
                try decoder.render(rect: rect, payload: framed(message), to: framebuffer)
            } catch is AppleAdaptiveDCTError {
                // Invalid syntax/state must throw, never access outside a buffer.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testQuantizationChangeAppliesToCachedCoefficients() throws {
        let decoder = AppleAdaptiveDCTDecoder()
        let framebuffer = Framebuffer(width: 16, height: 8, pixelFormat: .bgra8888)
        let rect = FramebufferRect(
            x: 0, y: 0, width: 16, height: 8,
            encoding: .appleMultiVariantScreenshare)
        try decoder.render(rect: rect, payload: base(tiles: 2, kind: "fresh"), to: framebuffer)
        try decoder.render(rect: rect, payload: refinement(tiles: 2), to: framebuffer)
        try decoder.render(
            rect: rect, payload: framed([2] + Array(repeating: 0, count: 128)), to: framebuffer)
        try decoder.render(rect: rect, payload: cache(tiles: 2), to: framebuffer)
        let gray = Data((0..<(16 * 8)).flatMap { _ in [UInt8(128), 128, 128, 255] })
        XCTAssertEqual(framebuffer.getPixels(x: 0, y: 0, width: 16, height: 8), gray)
    }

    func testOfflineBenchmark() throws {
        guard ProcessInfo.processInfo.environment["VNC_DCT_BENCHMARK"] == "1" else {
            throw XCTSkip("Set VNC_DCT_BENCHMARK=1 for offline Retina benchmarks")
        }
        let width = 2976
        let height = 1860
        let tiles = ((width + 7) / 8) * ((height + 7) / 8)
        let rect = FramebufferRect(
            x: 0, y: 0, width: UInt16(width), height: UInt16(height),
            encoding: .appleMultiVariantScreenshare)
        for draw in [false, true] {
            for kind in ["fresh", "dc", "reuse", "copy", "solid", "palette", "refine", "cache"] {
                let decoder = AppleAdaptiveDCTDecoder()
                let framebuffer = Framebuffer(width: width, height: height, pixelFormat: .bgra8888)
                let initial = base(tiles: tiles, kind: kind)
                let refined = refinement(tiles: tiles)
                let payload = kind == "refine" ? refined : kind == "cache" ? cache(tiles: tiles) : initial
                var times: [Double] = []
                for iteration in 0..<4 {
                    if kind == "refine" || kind == "cache" {
                        try decoder.render(rect: rect, payload: initial, to: framebuffer, drawPixels: draw)
                    }
                    if kind == "cache" {
                        try decoder.render(rect: rect, payload: refined, to: framebuffer, drawPixels: draw)
                    }
                    let start = DispatchTime.now().uptimeNanoseconds
                    try decoder.render(rect: rect, payload: payload, to: framebuffer, drawPixels: draw)
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
                    if iteration > 0 { times.append(ms) }
                }
                print(
                    String(
                        format: "DCT BENCH %@ draw=%@ median_ms=%.3f", kind, String(draw), times.sorted()[1]))
            }
        }
    }
}
