import Foundation
import RFBProtocol
import RFBTransport

/// In-memory ``RFBConnection`` for offline protocol tests.
///
/// The test enqueues the server→client byte stream with
/// ``enqueueServerBytes(_:)``; reads suspend until enough bytes exist and
/// throw `.connectionClosed` at EOF (``finishServerStream()``) or after
/// ``close()``, matching the `RFBConnection` error contract. Every client
/// send is recorded verbatim for later assertion via ``sentBytes()``, and an
/// optional ``setOnSend(_:)`` responder can script request/response exchanges.
actor ScriptedRFBConnection: RFBConnection {

    private var serverBytes = Data()
    private var readOffset = 0
    private var serverStreamFinished = false
    private var closed = false
    private var sent = Data()
    private var disconnectHandler: (@Sendable (VNCProtocolError) -> Void)?
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private var sendsHeld = false
    private var heldSendWaiters: [CheckedContinuation<Void, Never>] = []
    private var onSend: (@Sendable (Data) -> Data?)?
    private var tlsUpgradeEndpoint: (String, UInt16)?
    private var totalBytesRead = 0
    private var tlsUpgradeReadCount: Int?

    // MARK: - Test scripting

    /// Append server→client bytes and wake any suspended reads.
    func enqueueServerBytes(_ data: Data) {
        serverBytes.append(data)
        resumeReadWaiters()
    }

    /// Mark the server stream as ended: reads that cannot be satisfied from
    /// the remaining buffered bytes throw `.connectionClosed`.
    func finishServerStream() {
        serverStreamFinished = true
        resumeReadWaiters()
    }

    /// Install a responder invoked for every client send; returned bytes are
    /// enqueued as the server's reply.
    func setOnSend(_ responder: (@Sendable (Data) -> Data?)?) {
        onSend = responder
    }

    /// Everything the client has sent, concatenated in order.
    func sentBytes() -> Data {
        sent
    }

    /// Suspend client sends until `releaseSends()`, so a test can enter the
    /// session actor while one of its writes is in flight.
    func holdSends() {
        sendsHeld = true
    }

    func releaseSends() {
        sendsHeld = false
        let waiters = heldSendWaiters
        heldSendWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    var heldSendCount: Int {
        heldSendWaiters.count
    }

    func upgradedTLSEndpoint() -> (String, UInt16)? {
        tlsUpgradeEndpoint
    }

    /// How many server bytes the client had consumed when it started TLS.
    func bytesReadBeforeTLSUpgrade() -> Int? {
        tlsUpgradeReadCount
    }

    /// Simulate an out-of-band transport failure reported through the
    /// disconnect handler (a suspended socket failing, for example).
    func reportTransportFailure(_ error: VNCProtocolError) {
        disconnectHandler?(error)
    }

    // MARK: - RFBConnection

    func connect() async throws {
        if closed { throw VNCProtocolError.connectionClosed }
    }

    func read(exactly count: Int) async throws -> Data {
        while true {
            if closed { throw VNCProtocolError.connectionClosed }
            if availableByteCount >= count { return consume(count) }
            if serverStreamFinished { throw VNCProtocolError.connectionClosed }
            await waitForMoreBytes()
        }
    }

    func read(upTo maxCount: Int) async throws -> Data {
        while true {
            if closed { throw VNCProtocolError.connectionClosed }
            if availableByteCount > 0 {
                return consume(min(availableByteCount, maxCount))
            }
            if serverStreamFinished { throw VNCProtocolError.connectionClosed }
            await waitForMoreBytes()
        }
    }

    func send(_ data: Data) async throws {
        while sendsHeld {
            await withCheckedContinuation { heldSendWaiters.append($0) }
        }
        if closed { throw VNCProtocolError.connectionClosed }
        sent.append(data)
        if let response = onSend?(data) {
            enqueueServerBytes(response)
        }
    }

    func close() {
        closed = true
        resumeReadWaiters()
    }

    func setDisconnectHandler(
        _ handler: (@Sendable (VNCProtocolError) -> Void)?
    ) {
        disconnectHandler = handler
    }

    func supportsTLSUpgrade() async -> Bool { true }

    func startTLS(configuration: RFBTLSConfiguration) async throws {
        tlsUpgradeEndpoint = (
            configuration.serverHostname,
            configuration.serverPort)
        tlsUpgradeReadCount = totalBytesRead
    }

    // MARK: - Internals

    private var availableByteCount: Int {
        serverBytes.count - readOffset
    }

    private func waitForMoreBytes() async {
        await withCheckedContinuation { readWaiters.append($0) }
    }

    private func resumeReadWaiters() {
        let waiters = readWaiters
        readWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func consume(_ count: Int) -> Data {
        let start = serverBytes.startIndex + readOffset
        let result = serverBytes.subdata(in: start..<(start + count))
        readOffset += count
        totalBytesRead += count
        if readOffset == serverBytes.count {
            serverBytes.removeAll(keepingCapacity: true)
            readOffset = 0
        }
        return result
    }
}
