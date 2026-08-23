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

struct NetworkRouteSnapshot: Codable, Equatable, Sendable {
    let state: NetworkRouteState
    let guestIPv4Address: String?
    let hostIPv4Address: String?
    let interfaceName: String?
    let installedPrefixes: [String]

    static let inactive = Self(
        state: .inactive,
        guestIPv4Address: nil,
        hostIPv4Address: nil,
        interfaceName: nil,
        installedPrefixes: []
    )
}
