import XCTest
import Darwin
@testable import RFBTransport

/// A host-supplied connected datagram socket (one end of an AF_UNIX
/// socketpair) carries media without resolve, bind or connect.
final class PosixUDPChannelAdoptedDescriptorTests: XCTestCase {

    func testAdoptedSocketpairRoundTripsDatagrams() async throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds), 0)
        let peer = fds[1]
        defer { close(peer) }

        let channel = PosixUDPChannel(adoptingConnectedDescriptor: fds[0], label: "pair")
        try await channel.start()

        try await channel.send(Data([1, 2, 3]))
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = recv(peer, &buffer, buffer.count, 0)
        XCTAssertEqual(n, 3)
        XCTAssertEqual(Array(buffer.prefix(3)), [1, 2, 3])

        let reply: [UInt8] = [9, 8, 7, 6]
        XCTAssertEqual(Darwin.send(peer, reply, reply.count, 0), reply.count)
        let received = try await channel.receive()
        XCTAssertEqual(received, Data(reply))

        await channel.close()
    }

    func testStartAfterCloseThrows() async {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds), 0)
        defer { close(fds[1]) }

        let channel = PosixUDPChannel(adoptingConnectedDescriptor: fds[0], label: "pair")
        await channel.close()
        do {
            try await channel.start()
            XCTFail("Expected start() to refuse a closed descriptor")
        } catch {}
    }
}
