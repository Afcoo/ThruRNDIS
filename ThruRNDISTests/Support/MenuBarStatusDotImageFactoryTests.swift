/*
Copyright (C) 2026 Afcoo.
*/

import AppKit
import XCTest
@testable import ThruRNDIS

@MainActor
final class MenuBarStatusDotImageFactoryTests: XCTestCase {
    func testImageRendersRequestedColorAsNonTemplateArtwork() throws {
        let greenImage = MenuBarStatusDotImageFactory.makeImage(
            color: .systemGreen
        )
        let redImage = MenuBarStatusDotImageFactory.makeImage(
            color: .systemRed
        )

        XCTAssertFalse(greenImage.isTemplate)
        XCTAssertFalse(redImage.isTemplate)
        XCTAssertNotEqual(
            try XCTUnwrap(greenImage.tiffRepresentation),
            try XCTUnwrap(redImage.tiffRepresentation)
        )
    }
}
