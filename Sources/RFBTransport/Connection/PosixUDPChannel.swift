import Foundation
import Darwin
import RFBProtocol

/// Amortized-O(1) FIFO used between the socket read source and the transport
/// actor. `Array.removeFirst()` shifts every remaining element and made the old
/// queue progressively more expensive precisely when an RTP burst built a
/// backlog. This queue advances a head index and compacts only occasionally.
public struct PosixUDPDatagram: Sendable, Equatable {
    public let data: Data
    /// Monotonic timestamp captured as the datagram is drained from the socket.
    /// Keeping this with the bytes lets congestion control see userspace/actor
    /// queueing instead of mistaking delayed processing for network arrival.
    public let arrivalNanos: UInt64

    public init(data: Data, arrivalNanos: UInt64) {
        self.data = data
        self.arrivalNanos = arrivalNanos
    }
}

struct BoundedDatagramFIFO {
    private var storage: [PosixUDPDatagram] = []
    private var head = 0
    let capacity: Int

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    var count: Int { storage.count - head }
    var isEmpty: Bool { count == 0 }
    var first: PosixUDPDatagram? {
        head < storage.count ? storage[head] : nil
    }

    /// Appends datagrams in order and, if the hard memory bound is exceeded,
    /// drops the oldest entries. Returns the number dropped.
    mutating func append(contentsOf datagrams: [PosixUDPDatagram]) -> Int {
        guard !datagrams.isEmpty else { return 0 }
        storage.append(contentsOf: datagrams)
        let overflow = max(0, count - capacity)
        head += overflow
        compactIfNeeded()
        return overflow
    }

    mutating func popFirst() -> PosixUDPDatagram? {
        guard head < storage.count else { return nil }
        let value = storage[head]
        head += 1
        compactIfNeeded()
        return value
    }

    /// Removes up to `limit` datagrams without an actor/continuation round trip
    /// for every packet in a burst.
    mutating func popFirst(upTo limit: Int) -> [PosixUDPDatagram] {
        guard limit > 0, head < storage.count else { return [] }
        let end = min(storage.count, head + limit)
        let values = Array(storage[head..<end])
        head = end
        compactIfNeeded()
        return values
    }

    private mutating func compactIfNeeded() {
        guard head > 0 else { return }
        if head == storage.count {
            storage.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 4096 && head >= storage.count / 2 {
            storage.removeFirst(head)
            head = 0
        }
    }
}

enum PosixUDPAddressFamily: Sendable, Equatable {
    case ipv4
    case ipv6

    init?(numericHost: String) {
        var name = numericHost
        if name.hasPrefix("["), name.hasSuffix("]") {
            name = String(name.dropFirst().dropLast())
        }
        if let scope = name.firstIndex(of: "%") {
            name = String(name[..<scope])
        }

        var ipv4 = in_addr()
        if inet_pton(AF_INET, name, &ipv4) == 1 {
            self = .ipv4
            return
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, name, &ipv6) == 1 {
            self = .ipv6
            return
        }
        return nil
    }

    var systemValue: Int32 {
        switch self {
        case .ipv4: AF_INET
        case .ipv6: AF_INET6
        }
    }
}

/// A UDP channel backed directly by a POSIX socket.
///
/// The media transport requires a symmetric-port UDP socket configured as
/// follows:
///
/// ```
/// fd = socket(family, SOCK_DGRAM, 0)   // family follows the resolved peer
/// setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, 1)
/// setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, 1)
/// bind(fd, wildcard : port)
/// connect(fd, serverIP : port)     // symmetric RTP: same port both ends
/// ```
///
/// The socket's address family is chosen from the resolved remote.
/// `TransportSession` normally supplies the exact numeric peer selected by
/// TCP, so a dual-stack Bonjour hostname cannot split TCP and UDP across
/// different families. Tailscale keeps its DNS endpoint identity but constrains
/// resolution to TCP's selected family. Other callers that supply a hostname
/// retain the historical IPv4-first resolution, with IPv6 used when it is the
/// only available family.
///
/// `Network.framework` (`NWListener`/`NWConnection`) does not reliably expose
/// `SO_REUSEPORT`, which this transport requires so the viewer can bind the
/// *same* UDP port the server already holds (this is what makes loopback and
/// symmetric-port RTP work). This actor uses the BSD socket API to satisfy
/// those transport requirements.
public actor PosixUDPChannel {

    // MARK: - Properties

    private let requestedLocalPort: UInt16?
    private let remoteHost: String?
    private let remotePort: UInt16?
    private let remoteAddressFamily: PosixUDPAddressFamily?
    private let enableReusePort: Bool
    /// Set for a host-supplied connected socket; `start()` skips resolve,
    /// bind and connect.
    private let adoptedLabel: String?

    private var fd: Int32 = -1
    private var boundPort: UInt16?
    private var readSource: DispatchSourceRead?
    private let readQueue = DispatchQueue(label: "com.rootshell.vnc.udp.read", qos: .userInitiated)
    private nonisolated let log = VNCLogger(category: "PosixUDPChannel")

    // Datagram handoff state, guarded by `stateLock` (NOT actor-isolated: the
    // read source appends from `readQueue`, `receive()` consumes from the
    // actor). Ordering is required: the previous design spawned one
    // unstructured Task per drained batch to hop onto the actor, and Swift
    // gives NO FIFO guarantee between separately-created Tasks — under load,
    // batch N+1 regularly landed before batch N, reordering RTP packets inside
    // the client. Reordered video packets shred HEVC fragmentation units and
    // read as sequence gaps, i.e. macroblocks that worsen with system load.
    private let stateLock = NSLock()
    private nonisolated(unsafe) var pendingDatagrams = BoundedDatagramFIFO(
        capacity: 8192)
    private nonisolated(unsafe) var receiveWaiters: [
        CheckedContinuation<PosixUDPDatagram, Error>
    ] = []
    private nonisolated(unsafe) var lastBacklogLogNanos: UInt64 = 0
    private nonisolated(unsafe) var backlogHighWater = 0
    private nonisolated(unsafe) var publishedSinceBacklogLog = 0
    private nonisolated(unsafe) var droppedSinceBacklogLog = 0
    private nonisolated(unsafe) var lockedClosed = false
    /// Soft cap so a stalled consumer degrades like a kernel buffer overflow
    /// (bounded memory, oldest dropped) instead of growing without bound.
    private var closed = false

    // MARK: - Init

    /// Create a POSIX UDP channel.
    ///
    /// - Parameters:
    ///   - localPort: Local port to bind (INADDR_ANY). `nil`/`0` lets the OS choose.
    ///   - remoteHost: If provided, `connect()` the socket to this host so it only
    ///     receives datagrams from (and `send`s to) that peer.
    ///   - remotePort: Remote port to connect to. Native uses the same value as
    ///     `localPort` (symmetric RTP).
    ///   - enableReusePort: Set `SO_REUSEADDR`/`SO_REUSEPORT` before bind. Required
    ///     to bind a port the server already holds (loopback / symmetric port).
    public init(
        localPort: UInt16?,
        remoteHost: String? = nil,
        remotePort: UInt16? = nil,
        enableReusePort: Bool = true
    ) {
        self.requestedLocalPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.remoteAddressFamily = nil
        self.enableReusePort = enableReusePort
        self.adoptedLabel = nil
    }

    init(
        localPort: UInt16?,
        remoteHost: String?,
        remotePort: UInt16?,
        remoteAddressFamily: PosixUDPAddressFamily?,
        enableReusePort: Bool
    ) {
        self.requestedLocalPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.remoteAddressFamily = remoteAddressFamily
        self.enableReusePort = enableReusePort
        self.adoptedLabel = nil
    }

    /// Wrap a connected datagram socket of any family, such as one end of an
    /// AF_UNIX socketpair. The channel owns `fd` and closes it.
    public init(adoptingConnectedDescriptor fd: Int32, label: String) {
        self.requestedLocalPort = nil
        self.remoteHost = nil
        self.remotePort = nil
        self.remoteAddressFamily = nil
        self.enableReusePort = false
        self.adoptedLabel = label
        self.fd = fd
    }

    // MARK: - Lifecycle

    public func start() async throws {
        if let adoptedLabel {
            guard fd >= 0, !closed else {
                throw VNCProtocolError.ioError("UDP adopted descriptor for \(adoptedLabel) is closed")
            }
            setIntOption(SO_RCVBUF, value: 8 * 1024 * 1024)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
            startReadSource()
            log.info("POSIX UDP started on adopted descriptor for \(adoptedLabel)")
            return
        }
        // Resolve the remote first (when connecting) so socket, bind, and
        // connect all use the peer's address family.
        var remoteStorage: sockaddr_storage?
        if let remoteHost, let remotePort {
            guard var storage = Self.resolveHost(
                remoteHost,
                requiredFamily: remoteAddressFamily) else {
                throw VNCProtocolError.ioError("UDP connect: cannot resolve remote host \(remoteHost)")
            }
            Self.setPort(remotePort, in: &storage)
            remoteStorage = storage
        }
        let family = remoteStorage.map { Int32($0.ss_family) } ?? AF_INET

        let sock = socket(family, SOCK_DGRAM, 0)
        guard sock >= 0 else {
            throw VNCProtocolError.ioError("UDP socket() failed: \(errnoString())")
        }
        fd = sock

        if enableReusePort {
            setBoolOption(SO_REUSEADDR)
            setBoolOption(SO_REUSEPORT)
        }

        // Apple's HEVC media bursts hard; the default receive buffer holds only
        // tens of milliseconds, so processing bursts drop packets and shred
        // large keyframes. Request a much larger buffer (macOS may cap it).
        setIntOption(SO_RCVBUF, value: 8 * 1024 * 1024)

        // bind(wildcard : localPort) in the peer's family
        let bindResult: Int32
        if family == AF_INET6 {
            var localAddr = sockaddr_in6()
            localAddr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            localAddr.sin6_family = sa_family_t(AF_INET6)
            localAddr.sin6_port = (requestedLocalPort ?? 0).bigEndian
            localAddr.sin6_addr = in6addr_any
            bindResult = withUnsafePointer(to: &localAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var localAddr = sockaddr_in()
            localAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            localAddr.sin_family = sa_family_t(AF_INET)
            localAddr.sin_port = (requestedLocalPort ?? 0).bigEndian
            localAddr.sin_addr = in_addr(s_addr: INADDR_ANY)
            bindResult = withUnsafePointer(to: &localAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard bindResult == 0 else {
            let err = errnoString()
            closeFD()
            throw VNCProtocolError.ioError("UDP bind(:\(requestedLocalPort ?? 0)) failed: \(err)")
        }

        // connect(remoteIP : remotePort) — native always connects (symmetric).
        if var remoteAddr = remoteStorage, let remoteHost, let remotePort {
            let addrLen = socklen_t(remoteAddr.ss_len)
            let connectResult = withUnsafePointer(to: &remoteAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    connect(fd, sa, addrLen)
                }
            }
            guard connectResult == 0 else {
                let err = errnoString()
                closeFD()
                throw VNCProtocolError.ioError("UDP connect(\(remoteHost):\(remotePort)) failed: \(err)")
            }
        }

        // Resolve the actually-bound local port.
        var boundAddr = sockaddr_storage()
        var boundLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &boundLen)
            }
        }
        if nameResult == 0, let port = Self.port(of: boundAddr) {
            boundPort = port
        } else {
            boundPort = requestedLocalPort
        }

        // Non-blocking + dispatch read source.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        startReadSource()

        var actualRcvBuf: Int32 = 0
        var optLen = socklen_t(MemoryLayout<Int32>.size)
        _ = getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &actualRcvBuf, &optLen)
        log.info("POSIX UDP SO_RCVBUF=\(actualRcvBuf)")

        log.info("POSIX UDP started local=\(boundPort.map(String.init) ?? "?") "
            + "remote=\(remoteHost ?? "-"):\(remotePort.map(String.init) ?? "-") "
            + "family=\(family == AF_INET6 ? "IPv6" : "IPv4") "
            + "reusePort=\(enableReusePort)")
    }

    /// Receive the next datagram (payload only; connected peer filtering applied).
    /// Datagrams are delivered in exact socket-drain order.
    public func receive() async throws -> Data {
        try await receiveDatagram().data
    }

    /// Receive bytes together with their socket-drain time. The timestamp is
    /// required by the media congestion controller; `receive()` remains as the
    /// compatibility convenience for callers that need only bytes.
    public func receiveDatagram() async throws -> PosixUDPDatagram {
        try await withCheckedThrowingContinuation { continuation in
            stateLock.lock()
            if let datagram = pendingDatagrams.popFirst() {
                stateLock.unlock()
                continuation.resume(returning: datagram)
            } else if lockedClosed {
                stateLock.unlock()
                continuation.resume(throwing: VNCProtocolError.connectionClosed)
            } else {
                receiveWaiters.append(continuation)
                stateLock.unlock()
            }
        }
    }

    /// Receive one ordered socket burst. The first datagram uses the existing
    /// waiter path; everything already queued behind it is drained under the
    /// same lock. Large compound HEVC pictures contain hundreds of RTP packets,
    /// and crossing two Swift actor boundaries per datagram allowed the
    /// userspace FIFO to overflow under GUI load.
    public func receiveDatagramBatch(maxCount: Int = 512) async throws -> [PosixUDPDatagram] {
        let limit = max(1, maxCount)
        let first = try await receiveDatagram()
        guard limit > 1 else { return [first] }

        let remainder = stateLock.withLock {
            pendingDatagrams.popFirst(upTo: limit - 1)
        }
        return [first] + remainder
    }

    /// Send a datagram to the connected peer.
    public func send(_ data: Data) async throws {
        guard fd >= 0 else {
            throw VNCProtocolError.protocolViolation("UDP channel is not open")
        }
        let sent: Int = data.withUnsafeBytes { raw in
            Darwin.send(fd, raw.baseAddress, raw.count, 0)
        }
        if sent < 0 {
            throw VNCProtocolError.ioError("UDP send failed: \(errnoString())")
        }
    }

    public func close() {
        guard !closed else { return }
        closed = true
        log.info("Closing POSIX UDP channel")
        readSource?.cancel()
        readSource = nil
        closeFD()

        stateLock.lock()
        lockedClosed = true
        let waiters = receiveWaiters
        receiveWaiters.removeAll()
        stateLock.unlock()
        for cont in waiters {
            cont.resume(throwing: VNCProtocolError.connectionClosed)
        }
    }

    /// The local port this channel is bound to (after `start`).
    public var localPort: UInt16? { boundPort }

    // MARK: - Private

    private func setBoolOption(_ option: Int32) {
        var value: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<Int32>.size))
    }

    private func setIntOption(_ option: Int32, value: Int32) {
        var v = value
        _ = setsockopt(fd, SOL_SOCKET, option, &v, socklen_t(MemoryLayout<Int32>.size))
    }

    private func startReadSource() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        let capturedFD = fd
        source.setEventHandler { [weak self] in
            // Drain the socket as fast as possible into a batch (a Task per
            // datagram was slow enough that the kernel buffer overflowed even
            // on loopback), then publish the batch under the state lock, still
            // on this serial read queue — NEVER via a spawned Task, which has
            // no FIFO guarantee and reordered batches under load.
            var buffer = [UInt8](repeating: 0, count: 65_536)
            var batch: [PosixUDPDatagram] = []
            while true {
                let n = recv(capturedFD, &buffer, buffer.count, 0)
                if n > 0 {
                    batch.append(PosixUDPDatagram(
                        data: Data(buffer[0..<n]),
                        arrivalNanos: DispatchTime.now().uptimeNanoseconds))
                } else {
                    break
                }
            }
            if !batch.isEmpty {
                self?.publishBatchInOrder(batch)
            }
        }
        readSource = source
        source.resume()
    }

    /// Append a drained batch and satisfy any waiting `receive()` calls, all
    /// under the state lock so socket-drain order is exactly delivery order.
    /// `nonisolated` — runs on the serial read queue, not the actor.
    private nonisolated func publishBatchInOrder(_ batch: [PosixUDPDatagram]) {
        stateLock.lock()
        let dropped = pendingDatagrams.append(contentsOf: batch)
        let queuedBeforeDelivery = pendingDatagrams.count
        backlogHighWater = max(backlogHighWater, queuedBeforeDelivery)
        publishedSinceBacklogLog += batch.count
        droppedSinceBacklogLog += dropped
        let now = DispatchTime.now().uptimeNanoseconds
        var resumes: [(CheckedContinuation<PosixUDPDatagram, Error>, PosixUDPDatagram)] = []
        while !receiveWaiters.isEmpty, let datagram = pendingDatagrams.popFirst() {
            resumes.append((receiveWaiters.removeFirst(), datagram))
        }
        let queued = pendingDatagrams.count
        let oldestDelayMilliseconds = pendingDatagrams.first.map {
            now >= $0.arrivalNanos ? (now - $0.arrivalNanos) / 1_000_000 : 0
        } ?? 0
        let shouldLogBacklog = (queued >= 512 || droppedSinceBacklogLog > 0)
            && (lastBacklogLogNanos == 0 || now &- lastBacklogLogNanos >= 1_000_000_000)
        let diagnosticHighWater = backlogHighWater
        let diagnosticPublished = publishedSinceBacklogLog
        let diagnosticDropped = droppedSinceBacklogLog
        if shouldLogBacklog {
            lastBacklogLogNanos = now
            backlogHighWater = queued
            publishedSinceBacklogLog = 0
            droppedSinceBacklogLog = 0
        }
        stateLock.unlock()
        if dropped > 0 {
            log.error("UDP userspace receive queue overflow; dropped \(dropped) oldest datagrams "
                + "queued=\(queued) highWater=\(diagnosticHighWater) oldest=\(oldestDelayMilliseconds)ms")
        }
        if shouldLogBacklog {
            log.warning("UDP userspace receive backlog queued=\(queued) "
                + "highWater=\(diagnosticHighWater) oldest=\(oldestDelayMilliseconds)ms "
                + "published=\(diagnosticPublished) dropped=\(diagnosticDropped)")
        }
        for (cont, datagram) in resumes {
            cont.resume(returning: datagram)
        }
    }

    private func closeFD() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    private nonisolated func errnoString() -> String {
        String(cString: strerror(errno))
    }

    /// Resolve a host (numeric IPv4/IPv6 literal — brackets and scope IDs
    /// accepted — or a hostname) to a socket address. A required family keeps
    /// DNS resolution aligned with TCP. Otherwise IPv4 is preferred when a host
    /// resolves to both families, with IPv6 used when it is the only family.
    private static func resolveHost(
        _ host: String,
        requiredFamily: PosixUDPAddressFamily? = nil
    ) -> sockaddr_storage? {
        var name = host
        if name.hasPrefix("["), name.hasSuffix("]") {
            name = String(name.dropFirst().dropLast())
        }
        var hints = addrinfo()
        hints.ai_family = requiredFamily?.systemValue ?? AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &result) == 0 else { return nil }
        defer { freeaddrinfo(result) }

        var v6Fallback: sockaddr_storage?
        var node = result
        while let info = node?.pointee {
            if let sa = info.ai_addr {
                var storage = sockaddr_storage()
                let length = min(Int(info.ai_addrlen), MemoryLayout<sockaddr_storage>.size)
                withUnsafeMutableBytes(of: &storage) { dest in
                    dest.copyMemory(
                        from: UnsafeRawBufferPointer(start: sa, count: length))
                }
                if info.ai_family == AF_INET { return storage }
                if info.ai_family == AF_INET6, v6Fallback == nil { v6Fallback = storage }
            }
            node = info.ai_next
        }
        return v6Fallback
    }

    private static func setPort(_ port: UInt16, in storage: inout sockaddr_storage) {
        withUnsafeMutablePointer(to: &storage) { ptr in
            switch Int32(ptr.pointee.ss_family) {
            case AF_INET:
                ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_port = port.bigEndian
                }
            case AF_INET6:
                ptr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    $0.pointee.sin6_port = port.bigEndian
                }
            default:
                break
            }
        }
    }

    private static func port(of storage: sockaddr_storage) -> UInt16? {
        var copy = storage
        return withUnsafeMutablePointer(to: &copy) { ptr -> UInt16? in
            switch Int32(ptr.pointee.ss_family) {
            case AF_INET:
                return ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    UInt16(bigEndian: $0.pointee.sin_port)
                }
            case AF_INET6:
                return ptr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    UInt16(bigEndian: $0.pointee.sin6_port)
                }
            default:
                return nil
            }
        }
    }
}
