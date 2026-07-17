/*
Copyright (C) 2026 Afcoo.
*/

import Foundation

enum EventLogErrorFormatter {
    static func description(for error: Error) -> String {
        let cocoaError = error as NSError
        var components = [
            "domain=\(cocoaError.domain)",
            "code=\(cocoaError.code)",
        ]

        if let underlyingError = cocoaError.userInfo[NSUnderlyingErrorKey] as? NSError {
            components.append("underlyingDomain=\(underlyingError.domain)")
            components.append("underlyingCode=\(underlyingError.code)")
        }

        return components.joined(separator: "; ")
    }
}
