/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

enum DummyEthernetHelperRegistrationStatus: Equatable, Sendable {
    case unknown
    case notRegistered
    case enabled
    case updateRequired
    case requiresApproval
    case notFound
}

enum DummyEthernetNetworkState: String, Codable, Equatable, Sendable {
    case inactive
    case active
    case degraded
}

struct DummyEthernetConfiguration: Equatable, Sendable {
    var hostIPv4Address: String
    var memberInterfaceName: String
    var peerInterfaceName: String

    var routerIPv4Address: String {
        hostIPv4Address.split(separator: ".").prefix(3)
            .joined(separator: ".") + ".1"
    }
}

struct DummyEthernetNetworkSnapshot: Codable, Equatable, Sendable {
    let state: DummyEthernetNetworkState
    let bondInterfaceName: String?
    let memberInterfaceName: String?
    let peerInterfaceName: String?
    let configuredIPv4Address: String?

    static let inactive = Self(
        state: .inactive,
        bondInterfaceName: nil,
        memberInterfaceName: nil,
        peerInterfaceName: nil,
        configuredIPv4Address: nil
    )
}
