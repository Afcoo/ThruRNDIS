import XCTest
@testable import ThruRNDIS

final class WireGuardConfBuilderTests: XCTestCase {
    func testDefaultClientConfigurationUsesFullTunnelIPv4AllowedIPs() {
        let builder = WireGuardConfBuilder(elements: .defaults)
        let keyMaterial = WireGuardKeyMaterial(
            serverPrivateKey: "server-private",
            serverPublicKey: "server-public",
            clientPrivateKey: "client-private",
            clientPublicKey: "client-public"
        )

        let configuration = builder.clientConfiguration(
            keyMaterial: keyMaterial,
            endpoint: "192.168.64.2:51820"
        )
        let allowedIPLines = configuration
            .components(separatedBy: .newlines)
            .filter { $0.hasPrefix("AllowedIPs = ") }
        let serverConfiguration = builder.serverConfiguration(keyMaterial: keyMaterial)

        XCTAssertEqual(WireGuardConfElements.defaults.clientAllowedIPs, "0.0.0.0/0")
        XCTAssertEqual(
            WireGuardConfElements.defaults.dnsServers,
            ["1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4"]
        )
        XCTAssertEqual(allowedIPLines, ["AllowedIPs = 0.0.0.0/0"])
        XCTAssertTrue(configuration.contains("DNS = 1.1.1.1, 1.0.0.1, 8.8.8.8, 8.8.4.4"))
        XCTAssertFalse(configuration.contains("10.100.0.0/24"))
        XCTAssertFalse(configuration.contains("0.0.0.0/1"))
        XCTAssertFalse(configuration.contains("128.0.0.0/1"))
        XCTAssertFalse(configuration.contains("::/0"))
        XCTAssertTrue(serverConfiguration.contains("AllowedIPs = 10.100.0.2/32"))
        XCTAssertFalse(serverConfiguration.contains("AllowedIPs = 0.0.0.0/0"))
    }

    func testClientConfigurationAcceptsConnectionOverrides() {
        let builder = WireGuardConfBuilder(elements: .defaults)
        let keyMaterial = WireGuardKeyMaterial(
            serverPrivateKey: "server-private",
            serverPublicKey: "server-public",
            clientPrivateKey: "client-private",
            clientPublicKey: "client-public"
        )

        let configuration = builder.clientConfiguration(
            keyMaterial: keyMaterial,
            endpoint: "example.com:12345",
            dnsServers: ["9.9.9.9", "149.112.112.112"],
            allowedIPs: "10.0.0.0/8"
        )

        XCTAssertTrue(configuration.contains("DNS = 9.9.9.9, 149.112.112.112"))
        XCTAssertTrue(configuration.contains("AllowedIPs = 10.0.0.0/8"))
        XCTAssertTrue(configuration.contains("Endpoint = example.com:12345"))

        let configurationUsingDefaultDNS = builder.clientConfiguration(
            keyMaterial: keyMaterial,
            endpoint: "example.com:12345",
            dnsServers: []
        )
        XCTAssertTrue(
            configurationUsingDefaultDNS.contains(
                "DNS = 1.1.1.1, 1.0.0.1, 8.8.8.8, 8.8.4.4"
            )
        )
    }
}
