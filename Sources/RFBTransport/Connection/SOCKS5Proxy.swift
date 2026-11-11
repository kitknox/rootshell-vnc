import CFNetwork
import Foundation
import Network

/// A SOCKS5 proxy that `TCPConnection` negotiates itself rather than leaving
/// it to Network.framework.
struct SOCKS5ProxyEndpoint: Sendable, Equatable {
    let host: String
    let port: UInt16
}

/// The system proxy settings' answer for one TCP destination.
enum SystemSOCKSProxy {
    /// The SOCKS proxy the system routes `host` through, or nil for a direct
    /// route or a PAC file, which Network.framework still evaluates itself.
    static func endpoint(forHost host: String, port: UInt16) -> SOCKS5ProxyEndpoint? {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() else {
            return nil
        }
        return endpoint(forHost: host, port: port, settings: settings)
    }

    static func endpoint(
        forHost host: String,
        port: UInt16,
        settings: CFDictionary
    ) -> SOCKS5ProxyEndpoint? {
        guard let url = destinationURL(host: host, port: port) else { return nil }
        // A non-HTTP scheme gets only a SOCKS or a direct entry, with the
        // bypass list already applied; a PAC entry, if any, comes first.
        let proxies = CFNetworkCopyProxiesForURL(url as CFURL, settings)
            .takeRetainedValue() as? [[String: Any]]
        guard let first = proxies?.first,
              first[kCFProxyTypeKey as String] as? String == kCFProxyTypeSOCKS as String,
              let proxyHost = first[kCFProxyHostNameKey as String] as? String,
              !proxyHost.isEmpty,
              let proxyPort = (first[kCFProxyPortNumberKey as String] as? NSNumber)
                .flatMap({ UInt16(exactly: $0.intValue) }),
              proxyPort != 0
        else { return nil }
        return SOCKS5ProxyEndpoint(host: proxyHost, port: proxyPort)
    }

    static func destinationURL(host: String, port: UInt16) -> URL? {
        var literal = SOCKS5Handshake.unbracketed(host)
        if literal.contains(":") {
            literal = "[\(literal.replacingOccurrences(of: "%", with: "%25"))]"
        }
        return URL(string: "socks://\(literal):\(port)")
    }
}

/// RFC 1928 CONNECT with no authentication.
enum SOCKS5Handshake {
    enum Failure: Error, Equatable {
        case noAcceptableMethod
        case rejected(UInt8)
        case malformed(String)
        case timedOut(seconds: Int)

        var reason: String {
            switch self {
            case .noAcceptableMethod:
                return "proxy requires authentication"
            case .rejected(let code):
                return "connect failed: \(SOCKS5Handshake.replyText(code))"
            case .malformed(let detail):
                return "malformed reply (\(detail))"
            case .timedOut(let seconds):
                return "no answer within \(seconds)s"
            }
        }
    }

    /// What follows the 4-byte reply header.
    enum BoundAddress: Equatable {
        /// Address and port bytes.
        case fixed(Int)
        /// A length byte, that many name bytes, then the port.
        case domain
    }

    static let methodRequest = Data([0x05, 0x01, 0x00])

    static func checkMethodSelection(_ reply: Data) throws {
        let bytes = [UInt8](reply)
        guard bytes.count == 2, bytes[0] == 0x05 else {
            throw Failure.malformed("method selection \(hex(bytes))")
        }
        switch bytes[1] {
        case 0x00:
            return
        case 0xFF:
            throw Failure.noAcceptableMethod
        default:
            throw Failure.malformed("proxy chose unoffered method \(bytes[1])")
        }
    }

    /// IP literals go as addresses; names go as names so the proxy resolves them.
    static func connectRequest(host: String, port: UInt16) throws -> Data {
        var request: [UInt8] = [0x05, 0x01, 0x00]
        let literal = unbracketed(host)
        if let address = IPv4Address(literal) {
            request.append(0x01)
            request += address.rawValue
        } else if let address = IPv6Address(literal) {
            request.append(0x04)
            request += address.rawValue
        } else {
            let name = Array(literal.utf8)
            guard (1...255).contains(name.count) else {
                throw Failure.malformed("hostname is \(name.count) bytes; SOCKS5 allows 1-255")
            }
            request.append(0x03)
            request.append(UInt8(name.count))
            request += name
        }
        request += [UInt8(port >> 8), UInt8(port & 0xFF)]
        return Data(request)
    }

    static func boundAddress(afterReplyHeader header: Data) throws -> BoundAddress {
        let bytes = [UInt8](header)
        guard bytes.count == 4, bytes[0] == 0x05 else {
            throw Failure.malformed("reply header \(hex(bytes))")
        }
        guard bytes[1] == 0x00 else { throw Failure.rejected(bytes[1]) }
        switch bytes[3] {
        case 0x01:
            return .fixed(4 + 2)
        case 0x04:
            return .fixed(16 + 2)
        case 0x03:
            return .domain
        default:
            throw Failure.malformed("address type \(bytes[3])")
        }
    }

    static func replyText(_ code: UInt8) -> String {
        switch code {
        case 0x01: return "general SOCKS server failure"
        case 0x02: return "connection not allowed by ruleset"
        case 0x03: return "network unreachable"
        case 0x04: return "host unreachable"
        case 0x05: return "connection refused"
        case 0x06: return "TTL expired"
        case 0x07: return "command not supported"
        case 0x08: return "address type not supported"
        default: return "reply code \(code)"
        }
    }

    static func unbracketed(_ host: String) -> String {
        guard host.first == "[", host.last == "]" else { return host }
        return String(host.dropFirst().dropLast())
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.isEmpty ? "empty" : bytes.map { String(format: "%02x", $0) }.joined()
    }
}
