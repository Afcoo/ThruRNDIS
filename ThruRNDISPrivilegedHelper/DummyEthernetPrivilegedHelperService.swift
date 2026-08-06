/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

final class DummyEthernetPrivilegedHelperService: NSObject,
    DummyEthernetPrivilegedHelperProtocol {
    private let manager: DummyEthernetBondManager

    init(manager: DummyEthernetBondManager) {
        self.manager = manager
        super.init()
    }

    func status(
        withReply reply: @escaping DummyEthernetPrivilegedHelperReply
    ) {
        manager.status { result in
            self.send(result, to: reply)
        }
    }

    func start(
        hostIPv4Address: String,
        memberInterfaceName: String,
        peerInterfaceName: String,
        withReply reply: @escaping DummyEthernetPrivilegedHelperReply
    ) {
        let configuration = DummyEthernetConfiguration(
            hostIPv4Address: hostIPv4Address,
            memberInterfaceName: memberInterfaceName,
            peerInterfaceName: peerInterfaceName
        )
        manager.start(configuration: configuration) { result in
            self.send(result, to: reply)
        }
    }

    func stop(
        withReply reply: @escaping DummyEthernetPrivilegedHelperReply
    ) {
        manager.stop { result in
            self.send(result, to: reply)
        }
    }

    private func send(
        _ result: Result<DummyEthernetNetworkSnapshot, Error>,
        to reply: DummyEthernetPrivilegedHelperReply
    ) {
        switch result {
        case .success(let snapshot):
            do {
                reply(try JSONEncoder().encode(snapshot), nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        case .failure(let error):
            reply(nil, error.localizedDescription)
        }
    }
}

final class DummyEthernetPrivilegedHelperListenerDelegate: NSObject,
    NSXPCListenerDelegate {
    private let manager: DummyEthernetBondManager

    init(manager: DummyEthernetBondManager) {
        self.manager = manager
        super.init()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(
            with: DummyEthernetPrivilegedHelperProtocol.self
        )
        newConnection.exportedObject = DummyEthernetPrivilegedHelperService(
            manager: manager
        )
        newConnection.activate()
        return true
    }
}
