/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

enum NetworkRouteHelperRegistrationStatus: Equatable, Sendable {
    case unknown
    case notRegistered
    case enabled
    case updateRequired
    case requiresApproval
    case notFound
}
enum NetworkRouteState: String, Codable, Equatable, Sendable {
    case inactive
    case active
    case degraded
}

struct NetworkRouteConfiguration: Equatable, Sendable {
    let guestIPv4Address: String
    let vznatGatewayIPv4Address: String
    let bridgeInterfaceName: String
    let hostIPv4Address: String
    let routerIPv4Address: String
    let memberInterfaceName: String
    let peerInterfaceName: String
}

struct NetworkRouteSnapshot: Codable, Equatable, Sendable {
    let state: NetworkRouteState
    let guestIPv4Address: String?
    let vznatGatewayIPv4Address: String?
    let bridgeInterfaceName: String?
    let bondInterfaceName: String?
    let memberInterfaceName: String?
    let peerInterfaceName: String?
    let hostIPv4Address: String?
    let routerIPv4Address: String?
    let installedPrefixes: [String]

    // Preserve the existing view-facing name while the UI is updated
    // independently. Host traffic now leaves through the managed Bond.
    var interfaceName: String? { bondInterfaceName }

    static let inactive = Self(
        state: .inactive,
        guestIPv4Address: nil,
        vznatGatewayIPv4Address: nil,
        bridgeInterfaceName: nil,
        bondInterfaceName: nil,
        memberInterfaceName: nil,
        peerInterfaceName: nil,
        hostIPv4Address: nil,
        routerIPv4Address: nil,
        installedPrefixes: []
    )
}
