import XCTest
@testable import ThruRNDIS

final class WireGuardConnectionValidatorTests: XCTestCase {
    func testEndpointValidatorRequiresWireGuardHostAndNumericPortSyntax() {
        let validEndpoints = [
            "vpn.example.com:51820",
            "vpn.example.com.:51820",
            "192.168.64.2:51820",
        ]
        let invalidEndpoints = [
            "vpn.example.com",
            "https://vpn.example.com:51820",
            "vpn..example.com:51820",
            "-vpn.example.com:51820",
            "1:51820",
            "1.1:51820",
            "1.1.1:51820",
            "01.1.1.1:51820",
            "999.999.999.999:51820",
            "2001:db8::1:51820",
            "[2001:db8::1]:51820",
            "[2001:db8::1]51820",
            "vpn.example.com:http",
            "vpn.example.com:0",
            "vpn.example.com:65536",
        ]

        validEndpoints.forEach {
            XCTAssertTrue(WireGuardConnectionValidator.isValidEndpoint($0), $0)
        }
        invalidEndpoints.forEach {
            XCTAssertFalse(WireGuardConnectionValidator.isValidEndpoint($0), $0)
        }
    }

    func testAllowedIPsValidatorAcceptsHostPrefixesAndRequiresStrictCIDRBounds() {
        let validAllowedIPs = [
            "0.0.0.0/0",
            "10.100.0.2/32",
            "10.100.0.2",
            "10.0.0.0/8, 192.168.0.0/16",
        ]
        let invalidAllowedIPs = [
            "",
            "1",
            "1/32",
            "1.1/16",
            "01.1.1.1/32",
            "10.100.0.2/33",
            "::/0",
            "2001:db8::1",
            "2001:db8::1/129",
            "10.100.0.999/24",
            "10.0.0.0/8,,192.168.0.0/16",
            "10.0.0.0/8,",
            "+10.0.0.0/8",
        ]

        validAllowedIPs.forEach {
            XCTAssertTrue(WireGuardConnectionValidator.isValidAllowedIPs($0), $0)
        }
        invalidAllowedIPs.forEach {
            XCTAssertFalse(WireGuardConnectionValidator.isValidAllowedIPs($0), $0)
        }
    }

    func testDNSServersValidatorAcceptsOnlyNonemptyIPAddressLists() {
        let validDNSServers = [
            "1.1.1.1",
            "1.1.1.1, 8.8.8.8",
            "1.1.1.1\n8.8.8.8",
        ]
        let invalidDNSServers = [
            "",
            "1",
            "1.1",
            "1.1.1",
            "01.1.1.1",
            "cloudflare-dns.com",
            "1.1.1.1/32",
            "1.1.1.1:53",
            "1.1.1.999",
            "2001:4860:4860::8888",
            "1.1.1.1,,8.8.8.8",
            "1.1.1.1,",
        ]

        validDNSServers.forEach {
            XCTAssertTrue(WireGuardConnectionValidator.isValidDNSServers($0), $0)
        }
        invalidDNSServers.forEach {
            XCTAssertFalse(WireGuardConnectionValidator.isValidDNSServers($0), $0)
        }
    }
}
