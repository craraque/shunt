import Darwin
import Foundation

/// Encodes SOCKS5 destination addresses using RFC 1928 ATYP formats.
public enum SOCKS5AddressEncoder {
    public enum Error: Swift.Error, Equatable {
        case hostnameTooLong(Int)
    }

    /// Returns `ATYP + ADDR` for a SOCKS5 CONNECT request.
    ///
    /// - IPv4 literals encode as `0x01 + 4 bytes`.
    /// - IPv6 literals encode as `0x04 + 16 bytes`.
    /// - Everything else encodes as domain name `0x03 + length + UTF-8 bytes`.
    public static func encodeAddress(host: String) throws -> Data {
        if let ipv4 = ipv4Bytes(host) {
            var data = Data([0x01])
            data.append(contentsOf: ipv4)
            return data
        }
        if let ipv6 = ipv6Bytes(host) {
            var data = Data([0x04])
            data.append(contentsOf: ipv6)
            return data
        }

        let utf8 = Array(host.utf8)
        guard utf8.count <= 255 else {
            throw Error.hostnameTooLong(utf8.count)
        }
        var data = Data([0x03, UInt8(utf8.count)])
        data.append(contentsOf: utf8)
        return data
    }

    private static func ipv4Bytes(_ host: String) -> [UInt8]? {
        var addr = in_addr()
        guard inet_pton(AF_INET, host, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        var addr = in6_addr()
        guard inet_pton(AF_INET6, host, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }
}
