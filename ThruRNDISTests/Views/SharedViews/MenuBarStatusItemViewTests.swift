/*
Copyright (C) 2026 Afcoo.
*/

import AppKit
import XCTest
@testable import ThruRNDIS

@MainActor
final class MenuBarStatusItemViewTests: XCTestCase {
    func testStableWidthIsSharedAcrossDebugStatusTitles() {
        let shortTitleView = MenuBarStatusItemView(
            title: "VM: Running",
            dotColor: .systemGreen
        )
        let longTitleView = MenuBarStatusItemView(
            title: "WireGuard: Provider connected",
            dotColor: .systemGreen
        )

        XCTAssertEqual(
            shortTitleView.intrinsicContentSize.width,
            longTitleView.intrinsicContentSize.width
        )
    }

    func testContentFittingWidthTracksUpdatedTitle() {
        let view = MenuBarStatusItemView(
            title: "Inactive",
            dotColor: .systemRed,
            widthBehavior: .contentFitting
        )
        let inactiveWidth = view.intrinsicContentSize.width

        view.update(
            title: "WireGuard Disconnected",
            dotColor: .systemOrange
        )

        XCTAssertGreaterThan(view.intrinsicContentSize.width, inactiveWidth)
    }

}
