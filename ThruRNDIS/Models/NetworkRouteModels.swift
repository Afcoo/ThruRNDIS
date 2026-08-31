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
}

struct NetworkRouteSnapshot: Codable, Equatable, Sendable {
    let state: NetworkRouteState
    let guestIPv4Address: String?
    let vznatGatewayIPv4Address: String?
    let bridgeInterfaceName: String?
    let bondInterfaceName: String?

    static let inactive = Self(
        state: .inactive,
        guestIPv4Address: nil,
        vznatGatewayIPv4Address: nil,
        bridgeInterfaceName: nil,
        bondInterfaceName: nil
    )
}
