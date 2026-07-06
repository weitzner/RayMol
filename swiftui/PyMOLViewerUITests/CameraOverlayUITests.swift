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
//   6. "Zoom (×)" row appears under "Lens (mm)", slider index 1; dragging right
//      zooms in (molecule bigger), dragging left zooms out (molecule smaller).

import XCTest

final class CameraOverlayUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["PYMOL_AUTOLOAD"] = "1ubq.cif"
        app.launchEnvironment["PYMOL_AUTOPANEL"] = "closed"
        // Suppress the first-run gesture-coach overlay: on a fresh simulator it
        // auto-appears once the structure loads and its dimming background swallows
        // the first tap, so tapping the camera chip would dismiss the coach instead
        // of opening the panel.
        app.launchEnvironment["PYMOL_SKIP_GESTURE_HELP"] = "1"
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

        // Four sub-rows must appear as static text labels. (High-quality DOF is now
        // a "DOF quality" slider rather than a toggle — see metal_dof_quality.)
        //   "Auto lock focus", "DOF focus (0=auto)", "DOF aperture (blur)", "DOF quality"
        XCTAssertTrue(app.staticTexts["Auto lock focus"].waitForExistence(timeout: 5),
                      "'Auto lock focus' sub-row not found after DOF enabled")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'DOF focus'")).firstMatch.waitForExistence(timeout: 3),
            "'DOF focus' sub-row not found after DOF enabled")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'DOF aperture'")).firstMatch.waitForExistence(timeout: 3),
            "'DOF aperture' sub-row not found after DOF enabled")
        XCTAssertTrue(
            app.staticTexts["DOF quality"].waitForExistence(timeout: 3),
            "'DOF quality' sub-row not found after DOF enabled")

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

    // MARK: - Step 6: Zoom (×) row appears; drag right zooms in, left zooms out

    func testStep6_ZoomSlider() throws {
        app.launch()
        XCTAssertTrue(waitForRender(timeout: 30), "molecule never rendered")

        // Open the camera panel
        cameraChipButton().tap()
        Thread.sleep(forTimeInterval: 2.0)

        // 1. Verify "Zoom (×)" label exists
        XCTAssertTrue(app.staticTexts["Zoom (×)"].waitForExistence(timeout: 5),
                      "'Zoom (×)' label not found in camera panel — row not rendered")
        attach("zoom_1_panel")

        // 2. Verify the slider index 1 (Zoom) exists.
        //    cameraOverlayKeys order: field_of_view(slider0), zoom(slider1), ortho(switch0), dof(switch1)
        let zoomSlider = app.sliders.element(boundBy: 1)
        XCTAssertTrue(zoomSlider.waitForExistence(timeout: 3),
                      "Zoom slider (sliders[1]) not found")

        // Capture baseline viewport pixel signature before any drag
        let baselineSig = viewportMoleculeSize()

        // 3. Drag right (zoom in): normalizedOffset 0→0.75 on the zoom slider
        zoomSlider.adjust(toNormalizedSliderPosition: 0.75)
        Thread.sleep(forTimeInterval: 1.5)
        attach("zoom_2_in")
        let zoomedInSig = viewportMoleculeSize()

        // 4. Drag left (zoom out): normalizedOffset 0.75→0.1
        zoomSlider.adjust(toNormalizedSliderPosition: 0.10)
        Thread.sleep(forTimeInterval: 1.5)
        attach("zoom_3_out")
        let zoomedOutSig = viewportMoleculeSize()

        // Verify: zoomed-in size > baseline AND zoomed-out size < baseline
        // viewportMoleculeSize returns count of bright (molecule) pixels in center viewport
        XCTAssertGreaterThan(zoomedInSig, baselineSig,
                             "Molecule did not get larger after dragging Zoom slider right (in). baseline=\(baselineSig) zoomedIn=\(zoomedInSig)")
        XCTAssertLessThan(zoomedOutSig, baselineSig,
                          "Molecule did not get smaller after dragging Zoom slider left (out). baseline=\(baselineSig) zoomedOut=\(zoomedOutSig)")

        // 5. Independence check: reset zoom to ~1× (normalizedOffset ≈ 0.13 for 1× on 0.5–8 range)
        //    Then drag Lens slider (index 0) and confirm Zoom slider position is unchanged
        let lensMag1Pos = (1.0 - 0.5) / (8.0 - 0.5)  // ~0.067
        zoomSlider.adjust(toNormalizedSliderPosition: lensMag1Pos)
        Thread.sleep(forTimeInterval: 0.8)
        let zoomPosBefore = zoomSlider.value as? String ?? ""

        let lensSlider = app.sliders.element(boundBy: 0)
        lensSlider.adjust(toNormalizedSliderPosition: 0.8)  // long telephoto
        Thread.sleep(forTimeInterval: 1.0)
        let zoomPosAfter = zoomSlider.value as? String ?? ""
        attach("zoom_4_independence")

        // Zoom slider value should be close to what it was before Lens change.
        // XCUIElement slider .value is a string "N%" on iOS. We just check it's not wildly different.
        // (Lens dollies camera but Zoom control stays put — that's the independence invariant.)
        // If values differ by > 20 percentage points something is wrong.
        if !zoomPosBefore.isEmpty && !zoomPosAfter.isEmpty {
            let beforePct = Double(zoomPosBefore.replacingOccurrences(of: "%", with: "")) ?? 50
            let afterPct  = Double(zoomPosAfter.replacingOccurrences(of: "%", with: ""))  ?? 50
            XCTAssertLessThan(abs(afterPct - beforePct), 20.0,
                              "Zoom slider moved significantly when only Lens was changed (before=\(zoomPosBefore) after=\(zoomPosAfter)). Zoom and Lens are not independent.")
        }
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

    /// Count colorful molecule pixels in the center 60% of the viewport.
    /// The rainbow-cartoon 1ubq sits on a black background, so bright/colorful
    /// pixels are a good proxy for "how much molecule is on screen".
    /// Returns the pixel count; a bigger number means the molecule fills more area.
    private func viewportMoleculeSize() -> Int {
        guard let cg = XCUIScreen.main.screenshot().image.cgImage else { return 0 }
        let w = cg.width, h = cg.height
        // Crop to center 60% horizontally × top 65% vertically (viewport, not panel).
        let cropX = Int(Double(w) * 0.20)
        let cropY = Int(Double(h) * 0.05)
        let cropW = Int(Double(w) * 0.60)
        let cropH = Int(Double(h) * 0.60)
        let crop = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
        guard let region = cg.cropping(to: crop) else { return 0 }

        // Render into an RGBA buffer at 1:1 scale
        let pw = cropW, ph = cropH
        var buf = [UInt8](repeating: 0, count: pw * ph * 4)
        guard let ctx = CGContext(data: &buf, width: pw, height: ph,
                                  bitsPerComponent: 8, bytesPerRow: pw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return 0 }
        ctx.draw(region, in: CGRect(x: 0, y: 0, width: pw, height: ph))

        // Count pixels that are clearly non-black (molecule > background).
        // Background is pure black (0,0,0); molecule pixels exceed 40 in any channel.
        var count = 0
        for i in stride(from: 0, to: buf.count, by: 4) {
            let r = buf[i], g = buf[i+1], b = buf[i+2]
            if Int(r) + Int(g) + Int(b) > 60 { count += 1 }
        }
        return count
    }
}
