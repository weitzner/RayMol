// WhatsNewUITests.swift — functional verification of the "What's New" splash
// carousel. Launched via the PYMOL_AUTOSHEET=whatsnew screenshot hook, which
// calls WhatsNewModel.presentManually() ~3.5s after the UI comes up.
//
// AX contract (see WhatsNewModal):
//   - Container:      id='whatsNewModal'
//   - Primary button: id='whatsNewPrimary'  (label "Next" → "Get Started" on last page)
//   - Close button:   id='whatsNewClose'
//
// Seed content (Resources/WhatsNew.json) is a single release with THREE pages,
// so the carousel pages Next → Next → Get Started.

import XCTest

final class WhatsNewUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["PYMOL_AUTOSHEET"] = "whatsnew"
        app.launchEnvironment["PYMOL_SKIP_GESTURE_HELP"] = "1"
        // Suppress the one-time first-boot Theme Studio so it doesn't occupy the
        // presentation slot the What's New sheet needs (a fresh-install-only
        // collision that never happens in normal use — auto-show doesn't fire on a
        // first launch). Without this the What's New sheet is dropped under XCUITest.
        app.launchEnvironment["PYMOL_SKIP_FIRSTBOOT_THEME"] = "1"
    }

    private func primary() -> XCUIElement { app.buttons["whatsNewPrimary"] }

    // Wait for the primary button; on timeout, dump the AX tree to aid debugging.
    private func waitForPrimary(_ timeout: TimeInterval = 20) -> Bool {
        if primary().waitForExistence(timeout: timeout) { return true }
        print("=== WHATS-NEW AX DUMP ===\n\(app.debugDescription)\n=== END DUMP ===")
        return false
    }

    private func attach(_ name: String) {
        let att = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }

    // The modal appears, shows "Next" on a multi-page set, pages through to the
    // last page (button becomes "Get Started"), and dismisses on Get Started.
    func testCarouselPagesToGetStartedThenDismisses() throws {
        app.launch()

        XCTAssertTrue(waitForPrimary(), "What's New primary button never appeared")
        attach("wn_1_page1")
        XCTAssertEqual(primary().label, "Next", "First page of a 3-page set should show Next")

        // Page 1 → 2 (still "Next").
        primary().tap()
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(primary().label, "Next", "Second page of a 3-page set should still show Next")
        attach("wn_2_page2")

        // Page 2 → 3 (now the last page → "Get Started").
        primary().tap()
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(primary().label, "Get Started", "Last page should show Get Started")
        attach("wn_3_lastpage")

        // Get Started dismisses the sheet.
        primary().tap()
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertFalse(app.buttons["whatsNewPrimary"].exists, "Modal did not dismiss on Get Started")
        XCTAssertEqual(app.state, .runningForeground, "App crashed after dismiss")
        attach("wn_4_dismissed")
    }

    // The ✕ close button dismisses the modal from any page.
    func testCloseButtonDismisses() throws {
        app.launch()

        XCTAssertTrue(waitForPrimary(), "What's New never appeared")
        let close = app.buttons["whatsNewClose"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Close button not found")
        close.tap()
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertFalse(app.buttons["whatsNewPrimary"].exists, "Modal did not dismiss on Close")
        XCTAssertEqual(app.state, .runningForeground, "App crashed after Close")
    }
}
