// CameraOverlayUITests.swift — functional verification of the camera chip overlay
// and CameraControlsView bottom sheet on iPhone (compact size class).
//
// AX tree findings (from CameraAXDumpTests):
//   - Camera chip: id='camera', label='Camera settings'
//   - Sheet switches: EMPTY id/label — located by index (0=Ortho, 1=DOF, 2+= sub-rows)
//   - Sheet slider:   EMPTY id/label — only slider in app when sheet is open
//   - Row labels are staticTexts: "Camera", "Lens (mm)", "Orthographic", "Depth of field"
//   - Reset view is a button with label='Reset view'
//
// Steps verified:
//   1. Camera chip renders at viewport bottom-left when structure is loaded.
//   2. Tapping the chip opens a bottom sheet with Camera header, Lens slider,
//      Orthographic row, Depth of field row, and Reset view button.
//   3. Toggling "Depth of field" (switch index 1) ON reveals four sub-rows.
//   4. Toggling "Orthographic" (switch index 0) ON disables the Lens slider.
//   5. "Reset view" button tap does not crash the app.

import XCTest

final class CameraOverlayUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["PYMOL_AUTOLOAD"] = "1ubq.cif"
        app.launchEnvironment["PYMOL_AUTOPANEL"] = "closed"
        app.launchEnvironment["PYMOL_AUTOCMD"] = "hide everything; show cartoon; orient"
    }

    // MARK: - Step 1+2: chip visible, tap opens sheet

    func testStep1And2_CameraChipOpensSheet() throws {
        app.launch()
        XCTAssertTrue(waitForRender(timeout: 30), "molecule never rendered — app may have crashed at launch")

        // Step 1: chip must be present (gated on objects being loaded)
        let chip = cameraChipButton()
        XCTAssertTrue(chip.waitForExistence(timeout: 10),
                      "Camera chip button (id='camera') not found at viewport bottom-left")
        attach("cam_ov_1_chip")

        // Step 2: tap chip, verify sheet contents
        chip.tap()
        Thread.sleep(forTimeInterval: 2.0)
        attach("cam_ov_2_open")

        // Header "Camera" as static text
        XCTAssertTrue(app.staticTexts["Camera"].waitForExistence(timeout: 5),
                      "Sheet 'Camera' header staticText not found")

        // "Lens (mm)" label row
        XCTAssertTrue(app.staticTexts["Lens (mm)"].waitForExistence(timeout: 5),
                      "'Lens (mm)' label not found in sheet")

        // Slider (only one when sheet is open)
        XCTAssertTrue(app.sliders.firstMatch.waitForExistence(timeout: 5),
                      "Lens slider not found in sheet")

        // "Orthographic" label row
        XCTAssertTrue(app.staticTexts["Orthographic"].waitForExistence(timeout: 5),
                      "'Orthographic' label not found in sheet")

        // "Depth of field" label row
        XCTAssertTrue(app.staticTexts["Depth of field"].waitForExistence(timeout: 5),
                      "'Depth of field' label not found in sheet")

        // Reset view button
        XCTAssertTrue(app.buttons["Reset view"].waitForExistence(timeout: 5),
                      "'Reset view' button not found in sheet")

        // The sheet's two core toggles are present (Objects panel may add more switches
        // to the AX tree globally, so we verify by label presence, not by count).
        attach("cam_ov_2_sheet_verified")
    }

    // MARK: - Step 3: DOF toggle reveals sub-rows

    func testStep3_DepthOfFieldSubRows() throws {
        app.launch()
        XCTAssertTrue(waitForRender(timeout: 30), "molecule never rendered")

        cameraChipButton().tap()
        Thread.sleep(forTimeInterval: 2.0)

        // Verify DOF label exists (sheet is open)
        XCTAssertTrue(app.staticTexts["Depth of field"].waitForExistence(timeout: 5),
                      "Sheet did not open — DOF label not found")

        // Sub-rows should NOT be present before enabling DOF
        XCTAssertFalse(app.staticTexts["Auto lock focus"].exists,
                       "Sub-rows should be hidden before DOF is enabled")

        // DOF is switch index 1 (after Orthographic at index 0)
        let dofSwitch = app.switches.element(boundBy: 1)
        XCTAssertTrue(dofSwitch.waitForExistence(timeout: 3), "DOF switch (index 1) not found")
        dofSwitch.tap()
        Thread.sleep(forTimeInterval: 1.0)
        attach("cam_ov_3_dof")

        // Four sub-rows must appear as static text labels.
        // Actual labels observed in AX dump (screenshot confirmed):
        //   "Auto lock focus", "DOF focus (0=auto)", "DOF aperture (blur)", "High-quality DOF (2-…)"
        XCTAssertTrue(app.staticTexts["Auto lock focus"].waitForExistence(timeout: 5),
                      "'Auto lock focus' sub-row not found after DOF enabled")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'DOF focus'")).firstMatch.waitForExistence(timeout: 3),
            "'DOF focus' sub-row not found after DOF enabled")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'DOF aperture'")).firstMatch.waitForExistence(timeout: 3),
            "'DOF aperture' sub-row not found after DOF enabled")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'High-quality DOF'")).firstMatch.waitForExistence(timeout: 3),
            "'High-quality DOF' sub-row not found after DOF enabled")

        attach("cam_ov_3_dof_verified")
    }

    // MARK: - Step 4: Orthographic disables Lens slider

    func testStep4_OrthographicGreysOutLens() throws {
        app.launch()
        XCTAssertTrue(waitForRender(timeout: 30), "molecule never rendered")

        cameraChipButton().tap()
        Thread.sleep(forTimeInterval: 2.0)

        XCTAssertTrue(app.staticTexts["Orthographic"].waitForExistence(timeout: 5),
                      "Sheet did not open — Orthographic label not found")

        let slider = app.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 3), "Lens slider not found")

        // Lens slider should be enabled in perspective mode
        XCTAssertTrue(slider.isEnabled,
                      "Lens slider should be enabled in perspective mode — already disabled?")

        // Orthographic is switch index 0
        let orthoSwitch = app.switches.element(boundBy: 0)
        XCTAssertTrue(orthoSwitch.waitForExistence(timeout: 3), "Orthographic switch (index 0) not found")
        orthoSwitch.tap()
        Thread.sleep(forTimeInterval: 0.8)
        attach("cam_ov_4_ortho")

        // Lens slider should now be disabled
        XCTAssertFalse(slider.isEnabled,
                       "Lens slider should be DISABLED in orthographic mode")
        attach("cam_ov_4_ortho_verified")
    }

    // MARK: - Step 5: Reset view does not crash

    func testStep5_ResetViewNoCrash() throws {
        app.launch()
        XCTAssertTrue(waitForRender(timeout: 30), "molecule never rendered")

        cameraChipButton().tap()
        Thread.sleep(forTimeInterval: 2.0)

        let resetBtn = app.buttons["Reset view"]
        XCTAssertTrue(resetBtn.waitForExistence(timeout: 5), "'Reset view' button not found")
        resetBtn.tap()
        Thread.sleep(forTimeInterval: 1.5)

        XCTAssertEqual(app.state, .runningForeground, "App crashed or went to background after Reset view")
        attach("cam_ov_5_reset")
    }

    // MARK: - Helpers

    private func cameraChipButton() -> XCUIElement {
        // From AX dump: id='camera', label='Camera settings'
        let byID = app.buttons["camera"]
        if byID.exists { return byID }
        return app.buttons["Camera settings"]
    }

    private func attach(_ name: String) {
        let att = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }

    private func waitForRender(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if viewportSignature().contains(where: { $0 > 40 }) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    private func viewportSignature() -> [UInt8] {
        guard let cg = XCUIScreen.main.screenshot().image.cgImage else { return [] }
        let w = cg.width, h = cg.height
        let crop = CGRect(x: 0, y: Int(Double(h) * 0.10),
                          width: w, height: Int(Double(h) * 0.50))
        guard let region = cg.cropping(to: crop) else { return [] }
        let sw = 32, sh = 32
        var buf = [UInt8](repeating: 0, count: sw * sh)
        guard let ctx = CGContext(data: &buf, width: sw, height: sh,
                                  bitsPerComponent: 8, bytesPerRow: sw,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        ctx.draw(region, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        return buf
    }
}
