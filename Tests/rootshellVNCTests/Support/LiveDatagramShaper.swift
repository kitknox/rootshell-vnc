import Foundation
import Darwin
import RFBProtocol
@testable import RFBTransport

/// Downlink bottleneck for the opt-in live High Performance probes.
///
/// Every media socket the session opens goes through one fixed-rate link with
/// a drop-tail buffer measured in time, the way a cellular or relayed path
/// queues and then drops. The uplink (RTCP, RCTL) is forwarded untouched.
final class LiveDatagramShaper: @unchecked Sendable {
    struct Configuration: Sendable {
        var downlinkBitsPerSecond: Int
        var queueMilliseconds: Int
        var oneWayDelayMilliseconds: Int
    }

    struct Snapshot: Sendable {
        var forwardedPackets = 0
        var forwardedBytes = 0
        var droppedPackets = 0
        var droppedBytes = 0
        var maxQueueMilliseconds = 0.0
    }

    private struct Flow {
        let network: Int32
        let local: Int32
    }

    private struct Queued {
        let flow: Int
        let data: [UInt8]
        let deliverNanos: UInt64
    }

    private let lock = NSLock()
    private var configuration: Configuration
    private var flows: [Flow] = []
    private var queue: [Queued] = []
    private var queueHead = 0
    private var linkFreeNanos: UInt64 = 0
    private var stats = Snapshot()
    private var stopped = false
    private var thread: Thread?
    private let wake: (read: Int32, write: Int32)

    init(configuration: Configuration) {
        self.configuration = configuration
        var fds: [Int32] = [0, 0]
        _ = pipe(&fds)
        _ = fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL, 0) | O_NONBLOCK)
        wake = (fds[0], fds[1])
    }

    deinit { stop() }

    func update(_ configuration: Configuration) {
        lock.lock()
        self.configuration = configuration
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    func stop() {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        let open = flows
        flows.removeAll()
        lock.unlock()
        guard !wasStopped else { return }
        var byte: UInt8 = 1
        _ = write(wake.write, &byte, 1)
        for flow in open {
            close(flow.network)
            close(flow.local)
        }
    }

    var provider: AppleMediaDatagramProvider {
        { [self] host, remotePort, localPort in
            try self.addFlow(host: host, remotePort: remotePort, localPort: localPort)
        }
    }

    private func addFlow(host: String, remotePort: UInt16, localPort: UInt16) throws -> Int32 {
        let network = try Self.connectedSocket(host: host, remotePort: remotePort, localPort: localPort)
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &pair) == 0 else {
            close(network)
            throw VNCProtocolError.ioError("shaper socketpair failed: \(errno)")
        }
        var big: Int32 = 4 * 1024 * 1024
        setsockopt(pair[1], SOL_SOCKET, SO_SNDBUF, &big, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(pair[0], SOL_SOCKET, SO_RCVBUF, &big, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(pair[1], F_SETFL, fcntl(pair[1], F_GETFL, 0) | O_NONBLOCK)
        lock.lock()
        flows.append(Flow(network: network, local: pair[1]))
        if thread == nil {
            let worker = Thread { [weak self] in self?.run() }
            worker.name = "LiveDatagramShaper"
            worker.qualityOfService = .userInteractive
            thread = worker
            worker.start()
        }
        lock.unlock()
        var byte: UInt8 = 1
        _ = write(wake.write, &byte, 1)
        return pair[0]
    }

    private static func connectedSocket(host: String, remotePort: UInt16, localPort: UInt16) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(remotePort), &hints, &result) == 0, let info = result else {
            throw VNCProtocolError.ioError("shaper could not resolve \(host)")
        }
        defer { freeaddrinfo(result) }
        let fd = socket(info.pointee.ai_family, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw VNCProtocolError.ioError("shaper socket failed: \(errno)") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
        var rcv: Int32 = 8 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))
        var bound: Int32
        if info.pointee.ai_family == AF_INET6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = localPort.bigEndian
            address.sin6_addr = in6addr_any
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = localPort.bigEndian
            address.sin_addr.s_addr = INADDR_ANY
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard bound == 0, connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else {
            let code = errno
            close(fd)
            throw VNCProtocolError.ioError("shaper bind/connect failed: \(code)")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        return fd
    }

    private func run() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            lock.lock()
            if stopped {
                lock.unlock()
                return
            }
            let current = flows
            let nextDelivery = queueHead < queue.count ? queue[queueHead].deliverNanos : nil
            lock.unlock()

            var pollFDs = [pollfd(fd: wake.read, events: Int16(POLLIN), revents: 0)]
            for flow in current {
                pollFDs.append(pollfd(fd: flow.network, events: Int16(POLLIN), revents: 0))
                pollFDs.append(pollfd(fd: flow.local, events: Int16(POLLIN), revents: 0))
            }
            var timeout: Int32 = 50
            if let nextDelivery {
                let now = DispatchTime.now().uptimeNanoseconds
                timeout = nextDelivery <= now ? 0 : Int32(min(50, (nextDelivery - now) / 1_000_000 + 1))
            }
            _ = poll(&pollFDs, nfds_t(pollFDs.count), timeout)

            if pollFDs[0].revents != 0 {
                while read(wake.read, &buffer, buffer.count) > 0 {}
            }
            for (index, flow) in current.enumerated() {
                if pollFDs[1 + index * 2].revents & Int16(POLLIN) != 0 {
                    while true {
                        let count = recv(flow.network, &buffer, buffer.count, 0)
                        guard count > 0 else { break }
                        enqueue(flow: index, bytes: Array(buffer[0..<count]))
                    }
                }
                if pollFDs[2 + index * 2].revents & Int16(POLLIN) != 0 {
                    while true {
                        let count = recv(flow.local, &buffer, buffer.count, 0)
                        guard count > 0 else { break }
                        _ = send(flow.network, buffer, count, 0)
                    }
                }
            }
            deliverDue(flows: current)
        }
    }

    /// A fixed-rate link: each packet serializes after the previous one, and
    /// one that would wait longer than the buffer allows is dropped.
    private func enqueue(flow: Int, bytes: [UInt8]) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        defer { lock.unlock() }
        let rate = max(1, configuration.downlinkBitsPerSecond)
        let start = max(now, linkFreeNanos)
        let serialization = UInt64(bytes.count) * 8 * 1_000_000_000 / UInt64(rate)
        let finish = start + serialization
        let waitMilliseconds = Double(finish - now) / 1_000_000
        if waitMilliseconds > Double(configuration.queueMilliseconds) {
            stats.droppedPackets += 1
            stats.droppedBytes += bytes.count
            return
        }
        stats.maxQueueMilliseconds = max(stats.maxQueueMilliseconds, waitMilliseconds)
        linkFreeNanos = finish
        let delay = UInt64(max(0, configuration.oneWayDelayMilliseconds)) * 1_000_000
        queue.append(Queued(flow: flow, data: bytes, deliverNanos: finish + delay))
    }

    private func deliverDue(flows current: [Flow]) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        var due: [Queued] = []
        while queueHead < queue.count, queue[queueHead].deliverNanos <= now {
            due.append(queue[queueHead])
            queueHead += 1
        }
        if queueHead > 4_096, queueHead * 2 > queue.count {
            queue.removeFirst(queueHead)
            queueHead = 0
        }
        lock.unlock()
        var delivered = 0
        var deliveredBytes = 0
        for packet in due where packet.flow < current.count {
            if send(current[packet.flow].local, packet.data, packet.data.count, 0) > 0 {
                delivered += 1
                deliveredBytes += packet.data.count
            }
        }
        guard delivered > 0 else { return }
        lock.lock()
        stats.forwardedPackets += delivered
        stats.forwardedBytes += deliveredBytes
        lock.unlock()
    }
}
