/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

typealias DummyEthernetPrivilegedHelperReply = (Data?, String?) -> Void

@objc(ThruRNDISDummyEthernetPrivilegedHelperProtocol)
protocol DummyEthernetPrivilegedHelperProtocol {
    func status(withReply reply: @escaping DummyEthernetPrivilegedHelperReply)

    func start(
        hostIPv4Address: String,
        memberInterfaceName: String,
        peerInterfaceName: String,
        withReply reply: @escaping DummyEthernetPrivilegedHelperReply
    )

    func stop(withReply reply: @escaping DummyEthernetPrivilegedHelperReply)
}
