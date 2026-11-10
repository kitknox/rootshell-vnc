import Foundation
import RFBProtocol
import zlib

enum ClipboardCompression {
    static let chunkSize = 64 * 1024

    /// zlib-wrapped DEFLATE. Apple's inflater rejects `Z_STREAM_END`, so its
    /// payloads stop at a `Z_SYNC_FLUSH` boundary; ExtendedClipboard readers
    /// may inflate in one shot and need a finished stream.
    static func deflate(
        _ input: Data,
        finishStream: Bool,
        outputLimit: Int
    ) throws -> Data {
        var stream = z_stream()
        let level = input.count > 1 << 20 ? Z_DEFAULT_COMPRESSION : Z_BEST_COMPRESSION
        let initializeStatus = deflateInit_(
            &stream,
            level,
            zlibVersion(),
            Int32(MemoryLayout<z_stream>.size))
        guard initializeStatus == Z_OK else {
            throw VNCProtocolError.ioError(
                "Could not initialize clipboard zlib stream "
                    + "(status \(initializeStatus))")
        }
        defer { deflateEnd(&stream) }

        let flush = finishStream ? Z_FINISH : Z_SYNC_FLUSH
        // compressBound is only an allocation hint; it is not guaranteed for
        // Z_SYNC_FLUSH. Drain until deflate leaves output space unused.
        var output = Data()
        output.reserveCapacity(min(Int(compressBound(uLong(input.count))), outputLimit))
        var chunk = Data(count: chunkSize)

        try input.withUnsafeBytes { inputBytes in
            let inputBase = inputBytes.bindMemory(to: Bytef.self).baseAddress
            stream.next_in = UnsafeMutablePointer(mutating: inputBase)
            stream.avail_in = uInt(input.count)

            while true {
                let inputBefore = stream.avail_in
                let status = chunk.withUnsafeMutableBytes { outputBytes in
                    guard let outputBase = outputBytes
                        .bindMemory(to: Bytef.self).baseAddress else {
                        return Z_BUF_ERROR
                    }
                    stream.next_out = outputBase
                    stream.avail_out = uInt(chunkSize)
                    return zlib.deflate(&stream, flush)
                }
                let produced = chunkSize - Int(stream.avail_out)
                let progressed = produced > 0 || stream.avail_in < inputBefore
                guard status == Z_OK || status == Z_STREAM_END,
                      progressed || status == Z_STREAM_END else {
                    throw VNCProtocolError.ioError(
                        "Could not compress clipboard (zlib status \(status))")
                }
                output.append(chunk.prefix(produced))
                guard output.count <= outputLimit else {
                    throw VNCProtocolError.protocolViolation(
                        "Clipboard size is out of range")
                }
                if finishStream {
                    if status == Z_STREAM_END { break }
                } else if stream.avail_in == 0, stream.avail_out != 0 {
                    break
                }
            }
        }
        return output
    }

    /// Inflate a sync-flushed or finished stream whose size is unknown,
    /// growing the output in chunks rather than allocating the limit.
    static func inflate(_ compressed: Data, outputLimit: Int) throws -> Data {
        guard !compressed.isEmpty else { return Data() }
        var stream = z_stream()
        let initializeStatus = inflateInit_(
            &stream, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard initializeStatus == Z_OK else {
            throw VNCProtocolError.ioError(
                "Could not initialize clipboard zlib stream "
                    + "(status \(initializeStatus))")
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        var chunk = Data(count: chunkSize)
        try compressed.withUnsafeBytes { inputBytes in
            let inputBase = inputBytes.bindMemory(to: Bytef.self).baseAddress
            stream.next_in = UnsafeMutablePointer(mutating: inputBase)
            stream.avail_in = uInt(compressed.count)

            while true {
                let inputBefore = stream.avail_in
                let status = chunk.withUnsafeMutableBytes { outputBytes in
                    guard let outputBase = outputBytes
                        .bindMemory(to: Bytef.self).baseAddress else {
                        return Z_BUF_ERROR
                    }
                    stream.next_out = outputBase
                    stream.avail_out = uInt(chunkSize)
                    return zlib.inflate(&stream, Z_SYNC_FLUSH)
                }
                let produced = chunkSize - Int(stream.avail_out)
                output.append(chunk.prefix(produced))
                guard output.count <= outputLimit else {
                    throw VNCProtocolError.protocolViolation(
                        "Clipboard size is out of range")
                }
                switch status {
                case Z_STREAM_END:
                    return
                case Z_OK, Z_BUF_ERROR:
                    if stream.avail_in == 0, stream.avail_out != 0 { return }
                    if produced == 0, stream.avail_in == inputBefore {
                        throw VNCProtocolError.protocolViolation(
                            "Clipboard zlib stream made no progress")
                    }
                default:
                    throw VNCProtocolError.protocolViolation(
                        "Invalid clipboard zlib stream (status \(status))")
                }
            }
        }
        return output
    }
}
