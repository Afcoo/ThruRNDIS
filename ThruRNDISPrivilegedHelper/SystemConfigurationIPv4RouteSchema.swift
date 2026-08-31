/*
Copyright (C) 2026 Afcoo.
*/

import Foundation
import SystemConfiguration

enum NetworkRouteSystemConfigurationRouteState: Equatable, Sendable {
    case absent
    case exact
    case conflicting
}

enum SystemConfigurationIPv4RouteSchema {
    static let additionalRoutesKey = Key.additionalRoutes

    static var additionalRoutesConfiguration: [[String: String]] {
        managedAdditionalRoutes.map { $0.configuration }
    }

    static func routeState(
        in configuration: [String: Any]?
    ) -> NetworkRouteSystemConfigurationRouteState {
        guard let value = configuration?[Key.additionalRoutes] else {
            return .absent
        }
        guard let values = value as? [Any] else {
            return .conflicting
        }
        guard !values.isEmpty else {
            return .absent
        }
        let routes = values.compactMap { value -> AdditionalRoute? in
            guard let dictionary = value as? [String: Any] else {
                return nil
            }
            return AdditionalRoute(configuration: dictionary)
        }
        guard routes.count == values.count,
              Set(routes).count == routes.count,
              Set(routes) == Set(managedAdditionalRoutes) else {
            return .conflicting
        }
        return .exact
    }

    static func configurationIsExact(
        _ configuration: [String: Any]?
    ) -> Bool {
        let routeState = routeState(in: configuration)
        guard let configuration,
              Set(configuration.keys) == Key.ipv4ConfigurationKeys,
              configuration[
                kSCPropNetIPv4ConfigMethod as String
              ] as? String == kSCValNetIPv4ConfigMethodManual as String,
              configuration[
                kSCPropNetIPv4Addresses as String
              ] as? [String] == [ThruRNDISNetworkRoute.hostIPv4Address],
              configuration[
                kSCPropNetIPv4SubnetMasks as String
              ] as? [String] == [ThruRNDISNetworkRoute.subnetMask],
              configuration[
                kSCPropNetIPv4Router as String
              ] as? String == ThruRNDISNetworkRoute.routerIPv4Address else {
            return false
        }
        return routeState == .exact
    }

    private struct AdditionalRoute: Hashable {
        let destinationAddress: String
        let subnetMask: String
        let gatewayAddress: String

        init(
            destinationAddress: String,
            subnetMask: String,
            gatewayAddress: String
        ) {
            self.destinationAddress = destinationAddress
            self.subnetMask = subnetMask
            self.gatewayAddress = gatewayAddress
        }

        init?(configuration: [String: Any]) {
            guard Set(configuration.keys) == Key.routeKeys,
                  let destinationAddress = configuration[
                    Key.destinationAddress
                  ] as? String,
                  let subnetMask = configuration[Key.subnetMask] as? String,
                  let gatewayAddress = configuration[
                    Key.gatewayAddress
                  ] as? String,
                  let route = Self.managedRoute(
                    destinationAddress: destinationAddress,
                    subnetMask: subnetMask,
                    gatewayAddress: gatewayAddress
                  ) else {
                return nil
            }
            self = route
        }

        var configuration: [String: String] {
            [
                Key.destinationAddress: destinationAddress,
                Key.subnetMask: subnetMask,
                Key.gatewayAddress: gatewayAddress,
            ]
        }

        private static func managedRoute(
            destinationAddress: String,
            subnetMask: String,
            gatewayAddress: String
        ) -> Self? {
            managedAdditionalRoutes.first {
                $0.destinationAddress == destinationAddress
                    && $0.subnetMask == subnetMask
                    && $0.gatewayAddress == gatewayAddress
            }
        }
    }

    private enum Key {
        static let additionalRoutes = "AdditionalRoutes"
        static let destinationAddress = "DestinationAddress"
        static let subnetMask = "SubnetMask"
        static let gatewayAddress = "GatewayAddress"
        static let routeKeys: Set<String> = [
            destinationAddress,
            subnetMask,
            gatewayAddress,
        ]
        static let ipv4ConfigurationKeys: Set<String> = [
            kSCPropNetIPv4ConfigMethod as String,
            kSCPropNetIPv4Addresses as String,
            kSCPropNetIPv4SubnetMasks as String,
            kSCPropNetIPv4Router as String,
            additionalRoutes,
        ]
    }

    private static let managedAdditionalRoutes = [
        AdditionalRoute(
            destinationAddress: "0.0.0.0",
            subnetMask: "128.0.0.0",
            gatewayAddress: ThruRNDISNetworkRoute.routerIPv4Address
        ),
        AdditionalRoute(
            destinationAddress: "128.0.0.0",
            subnetMask: "128.0.0.0",
            gatewayAddress: ThruRNDISNetworkRoute.routerIPv4Address
        ),
    ]
}
