import XCTest
@testable import ThruRNDIS

final class WireGuardConfigurationBuilderTests: XCTestCase {
    func testRendersRoleSpecificServerAndClientConfigurations() {
        let builder = WireGuardConfigurationBuilder(elements: testElements)
        let keyMaterial = WireGuardKeyMaterial(
            serverPrivateKey: "server-private",
            serverPublicKey: "server-public",
            clientPrivateKey: "client-private",
            clientPublicKey: "client-public"
        )

        let serverConfiguration = builder.serverConfiguration(
            keyMaterial: keyMaterial
        )
        let clientConfiguration = builder.clientConfiguration(
            keyMaterial: keyMaterial,
            endpoint: nil
        )

        XCTAssertEqual(
            serverConfiguration,
            """
            [Interface]
            PrivateKey = server-private
            Address = 10.77.0.1/24
            ListenPort = 12345
            MTU = 1300

            [Peer]
            PublicKey = client-public
            AllowedIPs = 10.77.0.2/32
            PersistentKeepalive = 17

            """
        )
        XCTAssertEqual(
            clientConfiguration,
            """
            [Interface]
            PrivateKey = client-private
            Address = 10.77.0.2/24
            MTU = 1250
            DNS = 192.0.2.53, 198.51.100.53

            [Peer]
            PublicKey = server-public
            AllowedIPs = 203.0.113.0/24
            Endpoint = <test-endpoint>
            PersistentKeepalive = 17
            """
        )
    }

    func testDefaultConfigurationsPreserveTheDocumentedNetworkContract() {
        let builder = WireGuardConfigurationBuilder(elements: .defaults)
        let keyMaterial = WireGuardKeyMaterial(
            serverPrivateKey: "server-private",
            serverPublicKey: "server-public",
            clientPrivateKey: "client-private",
            clientPublicKey: "client-public"
        )

        let serverConfiguration = builder.serverConfiguration(
            keyMaterial: keyMaterial
        )
        let clientConfiguration = builder.clientConfiguration(
            keyMaterial: keyMaterial,
            endpoint: "192.168.64.2:51820"
        )

        XCTAssertTrue(serverConfiguration.contains("Address = 10.100.0.1/24"))
        XCTAssertTrue(serverConfiguration.contains("ListenPort = 51820"))
        XCTAssertTrue(serverConfiguration.contains("AllowedIPs = 10.100.0.2/32"))
        XCTAssertTrue(clientConfiguration.contains("Address = 10.100.0.2/24"))
        XCTAssertTrue(clientConfiguration.contains("AllowedIPs = 0.0.0.0/0"))
        XCTAssertTrue(
            clientConfiguration.contains(
                "DNS = 1.1.1.1, 1.0.0.1, 8.8.8.8, 8.8.4.4"
            )
        )
        XCTAssertTrue(
            clientConfiguration.contains("Endpoint = 192.168.64.2:51820")
        )
    }

    func testClientConfigurationAcceptsConnectionOverrides() {
        let builder = WireGuardConfigurationBuilder(elements: testElements)
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

        XCTAssertEqual(
            configuration.components(separatedBy: .newlines).filter {
                $0.hasPrefix("DNS = ")
                    || $0.hasPrefix("AllowedIPs = ")
                    || $0.hasPrefix("Endpoint = ")
            },
            [
                "DNS = 9.9.9.9, 149.112.112.112",
                "AllowedIPs = 10.0.0.0/8",
                "Endpoint = example.com:12345",
            ]
        )
    }

    private var testElements: WireGuardConfigurationElements {
        WireGuardConfigurationElements(
            serverAddress: "10.77.0.1/24",
            clientAddress: "10.77.0.2/24",
            serverPeerAllowedIPs: "10.77.0.2/32",
            clientAllowedIPs: "203.0.113.0/24",
            listenPort: 12_345,
            serverMTU: 1_300,
            clientMTU: 1_250,
            dnsServers: ["192.0.2.53", "198.51.100.53"],
            persistentKeepalive: 17,
            endpointPlaceholder: "<test-endpoint>"
        )
    }
}
