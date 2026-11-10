import Foundation
import RFBProtocol

/// Screen Sharing file transfer for Mac servers: drag in to upload, drag out
/// to download, and the 0x22 file stream. The Mac hands 0x22 to its file-copy
/// helper, so the item header mirrors its catalog info record. Big-endian.
public enum AppleFileTransferProtocol {
    /// Client: ask for the files being dragged on the Mac.
    public static let dragOutRequestMessageType: UInt8 = 0x0e
    /// Server: the folder an upload drag was dropped into.
    public static let uploadRequestMessageType: UInt8 = 0x1e
    /// Client: start an upload drag. Server: the drag-out reply.
    public static let dragMessageType: UInt8 = 0x20
    public static let fileCopyMessageType: UInt8 = 0x22

    static let fileCopyVersion: UInt16 = 1
    static let fileCopyPrefixSize = 6
    /// The server drops a session whose message length exceeds this.
    static let maximumFileCopyLength = 0x100000
    /// High Performance frames each client message in a record of at most
    /// 64 KiB, so data chunks stay well below that in both modes.
    public static let dataChunkSize = 32 * 1024
    static let maximumPathLength = 64 * 1024
    static let maximumSymbolicLinkLength = 0x3ff
    static let dragHeaderSize = 16
    static let uploadRequestHeaderSize = 12
    static let itemHeaderSize = 104
    static let maximumDragScrapSize = 16 * 1024 * 1024
    /// Seconds between 1904-01-01 and 1970-01-01.
    static let macEpochOffset: Double = 2_082_844_800

    static let fileURLType = "public.file-url"
    static let dragImageType = "com.apple.remotedesktop.dragimage-png"

    public enum Command: UInt16, Sendable {
        case startDownload = 1
        case startUpload = 2
        case pause = 3
        case resume = 4
        case stop = 5
        case summary = 0x64
        case item = 0x65
        case fileData = 0x66
        case compressedFileData = 0x67
        case endSession = 0x68
        case completion = 0xc8
        case progress = 0x12c
    }

    public enum ItemKind: UInt8, Sendable {
        case file = 1
        case folder = 2
        case symbolicLink = 3
    }

    /// One item in the stream; `level` is its depth below the top-level item.
    /// Files are followed by `dataSize` then `resourceForkSize` bytes of data.
    public struct Item: Sendable, Equatable {
        public var kind: ItemKind
        public var name: String
        public var level: UInt16
        public var dataSize: UInt64
        public var resourceForkSize: UInt64
        public var mode: UInt16
        public var creationDate: Date?
        public var modificationDate: Date?
        public var symbolicLinkTarget: String?

        public init(
            kind: ItemKind,
            name: String,
            level: UInt16,
            dataSize: UInt64 = 0,
            resourceForkSize: UInt64 = 0,
            mode: UInt16? = nil,
            creationDate: Date? = nil,
            modificationDate: Date? = nil,
            symbolicLinkTarget: String? = nil
        ) {
            self.kind = kind
            self.name = name
            self.level = level
            self.dataSize = dataSize
            self.resourceForkSize = resourceForkSize
            // The receiver chmods to this value, so zero would lock the user out.
            self.mode = mode ?? (kind == .folder ? 0o040755 : kind == .symbolicLink ? 0o120755 : 0o100644)
            self.creationDate = creationDate
            self.modificationDate = modificationDate
            self.symbolicLinkTarget = symbolicLinkTarget
        }

        /// Bytes of file data that follow this header.
        public var streamedSize: UInt64 {
            kind == .file ? dataSize + resourceForkSize : 0
        }
    }

    public struct Summary: Sendable, Equatable {
        public let totalBytes: UInt64
        public let fileCount: UInt64
        public let folderCount: UInt64
    }

    /// Messages the server sends inside 0x22.
    public enum ServerMessage: Sendable, Equatable {
        case summary(session: UInt32, Summary)
        case item(session: UInt32, Item)
        case fileData(session: UInt32, Data)
        /// Part of one zlib stream that spans the whole session.
        case compressedFileData(session: UInt32, uncompressedSize: Int, Data)
        /// Download finished; status 0 is success.
        case end(session: UInt32, status: UInt32)
        /// Upload progress: fraction of the summary bytes written so far.
        case progress(session: UInt32, fraction: Double)
        /// Upload finished; status 0 is success, `name` is what the Mac created.
        case completion(session: UInt32, status: Int16, name: String)
        case unknown(session: UInt32, command: UInt16)

        /// File bytes carried, which the receiver acknowledges once written.
        public var dataByteCount: Int {
            switch self {
            case .fileData(_, let data), .compressedFileData(_, _, let data):
                return data.count
            default:
                return 0
            }
        }

        public var session: UInt32 {
            switch self {
            case .summary(let session, _), .item(let session, _),
                 .fileData(let session, _), .compressedFileData(let session, _, _),
                 .end(let session, _), .progress(let session, _),
                 .completion(let session, _, _), .unknown(let session, _):
                return session
            }
        }
    }

    /// 0x1e: the folder an upload drag was dropped into.
    public struct UploadRequest: Sendable, Equatable {
        public let handle: UInt32
        public let destinationPath: String
    }

    /// 0x20 from the server: what was being dragged on the Mac.
    public struct DragOutReply: Sendable, Equatable {
        public let handle: UInt32
        public let paths: [String]
        public let dragImagePNG: Data?
    }

    // MARK: - Capabilities

    public static func supportsUpload(_ capabilities: AppleServerCapabilities?) -> Bool {
        guard let capabilities else { return false }
        return [uploadRequestMessageType, dragMessageType, fileCopyMessageType]
            .allSatisfy(capabilities.supportsServerCommand)
    }

    public static func supportsDownload(_ capabilities: AppleServerCapabilities?) -> Bool {
        guard let capabilities else { return false }
        return [dragOutRequestMessageType, dragMessageType, fileCopyMessageType]
            .allSatisfy(capabilities.supportsServerCommand)
    }

    // MARK: - Client messages

    /// Starts an upload drag at the Mac's current pointer. Only the names in
    /// the URLs matter; the files arrive after the drop.
    public static func dragInMessage(handle: UInt32, fileURLs: [URL]) throws -> Data {
        var scrap = Data()
        for url in fileURLs {
            let urlBytes = Data(url.absoluteString.utf8)
            appendUInt32(1, to: &scrap)
            appendString(fileURLType, to: &scrap)
            appendUInt32(0, to: &scrap)
            appendUInt32(1, to: &scrap)
            appendString("com.apple.ostype", to: &scrap)
            appendString("furl", to: &scrap)
            appendUInt32(UInt32(urlBytes.count), to: &scrap)
            scrap.append(urlBytes)
        }
        let compressed = try ClipboardCompression.deflate(
            scrap, finishStream: false, outputLimit: AppleClipboardProtocol.maximumSendSize)
        var message = Data([dragMessageType, 0, 0, 0])
        appendUInt32(handle, to: &message)
        appendUInt32(UInt32(scrap.count), to: &message)
        appendUInt32(UInt32(compressed.count), to: &message)
        message.append(compressed)
        return message
    }

    /// Sent while a drag is held on the Mac; the reply lists what it carries.
    public static func dragOutRequestMessage(handle: UInt32) -> Data {
        var message = Data([dragOutRequestMessageType, 0, 0, 0])
        appendUInt32(handle, to: &message)
        return message
    }

    public static func startDownloadMessage(session: UInt32, path: String) -> Data {
        let pathBytes = Data(path.utf8.prefix(1279))
        var body = Data()
        appendUInt32(1, to: &body) // start now, not paused
        appendUInt16(0, to: &body)
        appendUInt32(UInt32(pathBytes.count), to: &body)
        body.append(pathBytes)
        body.append(0)
        return fileCopyMessage(.startDownload, session: session, body: body)
    }

    public static func startUploadMessage(session: UInt32, destinationPath: String) -> Data {
        let path = Data(destinationPath.utf8)
        var body = Data(count: 6)
        appendUInt32(UInt32(path.count), to: &body)
        body.append(path)
        body.append(0)
        return fileCopyMessage(.startUpload, session: session, body: body)
    }

    public static func summaryMessage(
        session: UInt32,
        totalBytes: UInt64,
        fileCount: UInt64,
        folderCount: UInt64
    ) -> Data {
        var body = Data(count: 8)
        appendUInt64(totalBytes, to: &body)
        appendUInt64(totalBytes, to: &body)
        appendUInt64(fileCount, to: &body)
        appendUInt64(fileCount, to: &body)
        appendUInt64(folderCount, to: &body)
        appendUInt32(0, to: &body)
        return fileCopyMessage(.summary, session: session, body: body)
    }

    public static func itemMessage(session: UInt32, item: Item) -> Data {
        // Mac names cannot contain ':'; the catalog spells it '/'.
        let name = Data(item.name.replacingOccurrences(of: ":", with: "/").utf8)
        let target = item.kind == .symbolicLink
            ? Data((item.symbolicLinkTarget ?? "").utf8.prefix(maximumSymbolicLinkLength))
            : Data()
        var body = Data([item.kind.rawValue, 0])
        body.append(Data(count: 32)) // Finder info
        appendUInt64(item.kind == .file ? item.resourceForkSize : 0, to: &body)
        switch item.kind {
        case .file: appendUInt64(item.dataSize, to: &body)
        case .folder: appendUInt64(0, to: &body)
        case .symbolicLink: appendUInt64(UInt64(target.count), to: &body)
        }
        let created = item.creationDate ?? item.modificationDate
        for date in [created, item.modificationDate, item.modificationDate, item.modificationDate, nil] {
            appendMacDate(date, to: &body)
        }
        appendUInt16(item.kind == .folder ? 0x10 : 0, to: &body)
        appendUInt16(item.level, to: &body)
        appendUInt16(item.mode, to: &body)
        appendUInt32(0, to: &body)
        appendUInt16(UInt16(truncatingIfNeeded: name.count), to: &body)
        appendUInt16(UInt16(target.count), to: &body)
        body.append(name)
        body.append(0)
        body.append(target)
        return fileCopyMessage(.item, session: session, body: body)
    }

    /// A chunk never spans the data and resource forks.
    public static func fileDataMessage(session: UInt32, bytes: Data) -> Data {
        var body = Data(capacity: 4 + bytes.count)
        appendUInt32(UInt32(bytes.count), to: &body)
        body.append(bytes)
        return fileCopyMessage(.fileData, session: session, body: body)
    }

    public static func endSessionMessage(session: UInt32) -> Data {
        fileCopyMessage(.endSession, session: session, body: Data())
    }

    public static func stopMessage(session: UInt32) -> Data {
        fileCopyMessage(.stop, session: session, body: Data())
    }

    static func fileCopyMessage(_ command: Command, session: UInt32, body: Data) -> Data {
        var message = Data(capacity: fileCopyPrefixSize + 8 + body.count)
        message.append(fileCopyMessageType)
        message.append(0)
        appendUInt32(UInt32(8 + body.count), to: &message)
        appendUInt16(fileCopyVersion, to: &message)
        appendUInt16(command.rawValue, to: &message)
        appendUInt32(session, to: &message)
        message.append(body)
        return message
    }

    // MARK: - Server messages

    static func uploadRequestPathLength(header: Data) throws -> Int {
        guard let length = uint32(header, at: 8) else {
            throw VNCProtocolError.protocolViolation("Truncated Apple upload request")
        }
        guard length <= maximumPathLength else {
            throw VNCProtocolError.protocolViolation("Apple upload request path is out of range")
        }
        return Int(length)
    }

    static func uploadRequest(header: Data, path: Data) -> UploadRequest? {
        guard let handle = uint32(header, at: 4) else { return nil }
        return UploadRequest(
            handle: handle,
            destinationPath: String(decoding: path, as: UTF8.self))
    }

    /// Compressed length of a 0x20 drag-out reply, from its 16-byte header.
    static func dragOutReplyLength(header: Data) throws -> Int {
        guard let uncompressed = uint32(header, at: 8),
              let compressed = uint32(header, at: 12) else {
            throw VNCProtocolError.protocolViolation("Truncated Apple drag reply")
        }
        guard uncompressed <= maximumDragScrapSize, compressed <= maximumDragScrapSize else {
            throw VNCProtocolError.protocolViolation("Apple drag reply size is out of range")
        }
        return Int(compressed)
    }

    /// A malformed reply yields no paths rather than ending the session.
    static func dragOutReply(header: Data, compressed: Data) -> DragOutReply {
        let handle = uint32(header, at: 4) ?? 0
        let size = Int(uint32(header, at: 8) ?? 0)
        guard size > 0, !compressed.isEmpty,
              let inflater = try? RFBZlibStreamInflater(),
              let scrap = try? inflater.decompress(compressed, maxOutputSize: size + 1),
              scrap.count == size else {
            return DragOutReply(handle: handle, paths: [], dragImagePNG: nil)
        }
        var paths: [String] = []
        var image: Data?
        for flavor in scrapFlavors(scrap) {
            switch flavor.type {
            case fileURLType:
                let string = String(decoding: flavor.data, as: UTF8.self)
                if let url = URL(string: string), url.isFileURL, !url.path.isEmpty {
                    paths.append(url.path)
                }
            case dragImageType:
                image = flavor.data
            default:
                break
            }
        }
        return DragOutReply(handle: handle, paths: paths, dragImagePNG: image)
    }

    /// Length of the 0x22 payload after its 6-byte type/length prefix.
    static func fileCopyPayloadLength(prefix: Data) throws -> Int {
        guard let length = uint32(prefix, at: 2) else {
            throw VNCProtocolError.protocolViolation("Truncated Apple file copy message")
        }
        guard length >= 8, length <= maximumFileCopyLength else {
            throw VNCProtocolError.protocolViolation(
                "Apple file copy message length \(length) is out of range")
        }
        return Int(length)
    }

    static func serverMessage(payload: Data) -> ServerMessage? {
        guard let commandValue = uint16(payload, at: 2),
              let session = uint32(payload, at: 4) else { return nil }
        let body = Data(payload.dropFirst(8))
        switch Command(rawValue: commandValue) {
        case .summary:
            guard let total = uint64(body, at: 8),
                  let files = uint64(body, at: 24),
                  let folders = uint64(body, at: 40) else { return nil }
            return .summary(session: session, Summary(
                totalBytes: total, fileCount: files, folderCount: folders))
        case .item:
            return parseItem(body).map { .item(session: session, $0) }
        case .fileData:
            guard let length = uint32(body, at: 0), Int(length) <= body.count - 4 else { return nil }
            return .fileData(session: session, body.subdata(in: 4..<4 + Int(length)))
        case .compressedFileData:
            guard let uncompressed = uint32(body, at: 2),
                  let length = uint32(body, at: 6),
                  Int(length) <= body.count - 10,
                  Int(uncompressed) <= maximumFileCopyLength * 4 else { return nil }
            return .compressedFileData(
                session: session,
                uncompressedSize: Int(uncompressed),
                body.subdata(in: 10..<10 + Int(length)))
        case .endSession:
            // The Mac writes this status in its own (little-endian) byte order.
            let status = body.count >= 4
                ? UInt32(body[0]) | UInt32(body[1]) << 8 | UInt32(body[2]) << 16 | UInt32(body[3]) << 24
                : 0
            return .end(session: session, status: status)
        case .progress:
            guard let bits = uint64(body, at: 0) else { return nil }
            let fraction = Double(bitPattern: bits)
            return .progress(session: session, fraction: fraction.isFinite ? min(max(fraction, 0), 1) : 0)
        case .completion:
            guard let status = uint16(body, at: 0) else { return nil }
            let nameLength = Int(uint16(body, at: 2) ?? 0)
            let name = body.count >= 4 + nameLength
                ? String(decoding: body[4..<4 + nameLength], as: UTF8.self)
                : ""
            return .completion(session: session, status: Int16(bitPattern: status), name: name)
        default:
            return .unknown(session: session, command: commandValue)
        }
    }

    static func parseItem(_ body: Data) -> Item? {
        guard body.count >= itemHeaderSize,
              let kind = ItemKind(rawValue: body[0]),
              let resourceForkSize = uint64(body, at: 34),
              let dataSize = uint64(body, at: 42),
              let level = uint16(body, at: 92),
              let mode = uint16(body, at: 94),
              let nameLength = uint16(body, at: 100),
              itemHeaderSize + Int(nameLength) <= body.count else { return nil }
        // Catalog names spell a POSIX ':' as '/'.
        let name = String(decoding: body[itemHeaderSize..<itemHeaderSize + Int(nameLength)], as: UTF8.self)
            .replacingOccurrences(of: "/", with: ":")
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        var target: String?
        if kind == .symbolicLink {
            let start = itemHeaderSize + Int(nameLength) + 1
            let end = min(start + Int(min(dataSize, UInt64(maximumSymbolicLinkLength))), body.count)
            target = start < end ? String(decoding: body[start..<end], as: UTF8.self) : ""
        }
        return Item(
            kind: kind,
            name: name,
            level: level,
            dataSize: kind == .file ? dataSize : 0,
            resourceForkSize: kind == .file ? resourceForkSize : 0,
            mode: mode,
            creationDate: macDate(body, at: 50),
            modificationDate: macDate(body, at: 58),
            symbolicLinkTarget: target)
    }

    /// Flattens a packed scrap: items are concatenated with no count.
    static func scrapFlavors(_ scrap: Data) -> [(type: String, data: Data)] {
        var flavors: [(type: String, data: Data)] = []
        var cursor = 0
        func readUInt32() -> Int? {
            guard let value = uint32(scrap, at: cursor) else { return nil }
            cursor += 4
            return Int(value)
        }
        func readBytes() -> Data? {
            guard let length = readUInt32(), length <= scrap.count - cursor else { return nil }
            defer { cursor += length }
            return scrap.subdata(in: scrap.startIndex + cursor..<scrap.startIndex + cursor + length)
        }
        while cursor < scrap.count {
            guard let flavorCount = readUInt32(), flavorCount <= 4_096 else { break }
            for _ in 0..<flavorCount {
                guard let typeData = readBytes(),
                      readUInt32() != nil, // flavor flags
                      let tagCount = readUInt32(), tagCount <= 4_096 else { return flavors }
                for _ in 0..<tagCount * 2 {
                    guard readBytes() != nil else { return flavors }
                }
                guard let data = readBytes() else { return flavors }
                flavors.append((String(decoding: typeData, as: UTF8.self), data))
            }
        }
        return flavors
    }

    // MARK: - Encoding helpers

    /// Mac UTCDateTime: U16 high seconds, U32 low seconds, U16 1/65536 fraction.
    static func appendMacDate(_ date: Date?, to data: inout Data) {
        guard let date else {
            data.append(Data(count: 8))
            return
        }
        let seconds = max(0, date.timeIntervalSince1970 + macEpochOffset)
        let whole = UInt64(seconds)
        appendUInt16(UInt16(truncatingIfNeeded: whole >> 32), to: &data)
        appendUInt32(UInt32(truncatingIfNeeded: whole), to: &data)
        appendUInt16(UInt16(min((seconds - Double(whole)) * 65_536, 65_535)), to: &data)
    }

    static func macDate(_ data: Data, at offset: Int) -> Date? {
        guard let high = uint16(data, at: offset),
              let low = uint32(data, at: offset + 2),
              let fraction = uint16(data, at: offset + 6) else { return nil }
        let seconds = Double(UInt64(high) << 32 | UInt64(low))
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds - macEpochOffset + Double(fraction) / 65_536)
    }

    private static func appendString(_ string: String, to data: inout Data) {
        let bytes = Data(string.utf8)
        appendUInt32(UInt32(bytes.count), to: &data)
        data.append(bytes)
    }

    static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xff))
    }

    static func appendUInt32(_ value: UInt32, to data: inout Data) {
        AppleClipboardProtocol.appendUInt32BE(value, to: &data)
    }

    static func appendUInt64(_ value: UInt64, to data: inout Data) {
        appendUInt32(UInt32(value >> 32), to: &data)
        appendUInt32(UInt32(value & 0xffff_ffff), to: &data)
    }

    /// Offsets are relative to the data's start index.
    static func uint16(_ data: Data, at offset: Int) -> UInt16? {
        let index = data.startIndex + offset
        guard offset >= 0, index + 2 <= data.endIndex else { return nil }
        return UInt16(data[index]) << 8 | UInt16(data[index + 1])
    }

    static func uint32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0 else { return nil }
        return AppleClipboardProtocol.uint32BE(data, at: data.startIndex + offset)
    }

    static func uint64(_ data: Data, at offset: Int) -> UInt64? {
        guard let high = uint32(data, at: offset),
              let low = uint32(data, at: offset + 4) else { return nil }
        return UInt64(high) << 32 | UInt64(low)
    }
}
