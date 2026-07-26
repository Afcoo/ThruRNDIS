/*
Copyright (C) 2026 Afcoo.
*/

import AppKit
import XCTest
@testable import ThruRNDIS

@MainActor
final class MenuBarStatusDotImageFactoryTests: XCTestCase {
    func testImageUsesMenuIconSizeAndPreservesItsColors() {
        let image = MenuBarStatusDotImageFactory.makeImage(color: .systemGreen)

        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        XCTAssertFalse(image.isTemplate)
        XCTAssertNotNil(image.tiffRepresentation)
    }
}
