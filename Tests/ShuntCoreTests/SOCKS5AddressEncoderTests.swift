import XCTest
@testable import ShuntCore

final class SOCKS5AddressEncoderTests: XCTestCase {
    func testEncodeIPv4AddressUsesIPv4Atyp() throws {
        let encoded = try SOCKS5AddressEncoder.encodeAddress(host: "192.0.2.10")
        XCTAssertEqual(Array(encoded), [0x01, 192, 0, 2, 10])
    }

    func testEncodeDomainNameUsesDomainAtyp() throws {
        let encoded = try SOCKS5AddressEncoder.encodeAddress(host: "example.com")
        XCTAssertEqual(Array(encoded), [0x03, 11] + Array("example.com".utf8))
    }

    func testEncodeIPv6AddressUsesIPv6Atyp() throws {
        let encoded = try SOCKS5AddressEncoder.encodeAddress(host: "2001:db8::1")
        XCTAssertEqual(Array(encoded), [
            0x04,
            0x20, 0x01, 0x0d, 0xb8,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x01,
        ])
    }

    func testRejectsDomainLongerThanSocksLimit() {
        let tooLong = String(repeating: "a", count: 256)
        XCTAssertThrowsError(try SOCKS5AddressEncoder.encodeAddress(host: tooLong))
    }
}
