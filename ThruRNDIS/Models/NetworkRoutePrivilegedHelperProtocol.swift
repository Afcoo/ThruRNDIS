/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

typealias NetworkRoutePrivilegedHelperReply = (Data?, String?) -> Void

@objc(ThruRNDISNetworkRoutePrivilegedHelperProtocol)
protocol NetworkRoutePrivilegedHelperProtocol {
    func status(withReply reply: @escaping NetworkRoutePrivilegedHelperReply)

    func start(
        guestIPv4Address: String,
        vznatGatewayIPv4Address: String,
        withReply reply: @escaping NetworkRoutePrivilegedHelperReply
    )

    func stop(withReply reply: @escaping NetworkRoutePrivilegedHelperReply)
}
