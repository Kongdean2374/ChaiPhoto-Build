import XCTest

final class LaunchFlowTests: XCTestCase {
    private func finishGuide(_ app: XCUIApplication) {
        // Complete only by using real UI; no launch flag bypasses onboarding.
        for _ in 0..<6 {
            let next = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "下一步", "Next")).firstMatch
            if next.waitForExistence(timeout: 2) && next.isHittable { next.tap() }
            let finish = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "完成", "Finish")).firstMatch
            if finish.exists && finish.isHittable { finish.tap(); break }
            if !next.exists && app.tabBars.firstMatch.exists { break }
        }
    }

    func testFourPreloadModesAndPhotoPermissionStatus() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        finishGuide(app)
        let warning = app.staticTexts["photo-access-warning"]
        if warning.waitForExistence(timeout: 2) {
            XCTAssertTrue(app.buttons["photo-access-button"].exists)
        }
        let settingsTab = app.tabBars.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "設定", "Settings")).firstMatch
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5)); settingsTab.tap()
        let media = app.staticTexts.matching(NSPredicate(format: "label == %@ OR label == %@", "播放與 iCloud", "Playback & iCloud")).firstMatch
        XCTAssertTrue(media.waitForExistence(timeout: 5)); media.tap()
        let modes = app.segmentedControls["preload-modes"]
        for _ in 0..<4 {
            if modes.exists && modes.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(modes.exists)
        XCTAssertEqual(modes.buttons.count, 4)
        let off = modes.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "關閉", "Off")).firstMatch
        off.tap(); XCTAssertTrue(off.isSelected)
        XCTAssertFalse(app.switches["always-download-photos"].exists)
        XCTAssertFalse(app.switches["always-download-videos"].exists)
        XCTAssertFalse(app.staticTexts["照片預載數量"].exists)
        XCTAssertFalse(app.staticTexts["Photos to preload"].exists)
        XCTAssertFalse(app.staticTexts["影片預載數量"].exists)
        let balanced = modes.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "平衡", "Balanced")).firstMatch
        balanced.tap(); XCTAssertTrue(balanced.isSelected)
        XCTAssertTrue(app.switches["always-download-photos"].exists)
        XCTAssertTrue(app.switches["always-download-videos"].exists)
        XCTAssertTrue(app.switches["always-download-photos"].isEnabled)
    }

    func testGeneralGuideShowsDownloadControlsAndSharesPreferencesWithSettings() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch(); finishGuide(app)
        app.tabBars.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "設定", "Settings")).firstMatch.tap()
        let info = app.staticTexts.matching(NSPredicate(format: "label == %@ OR label == %@", "紀錄與關於", "History & about")).firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 5)); info.tap()
        let revisit = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "重新檢視首次導覽", "Revisit getting started")).firstMatch
        XCTAssertTrue(revisit.waitForExistence(timeout: 5)); revisit.tap()
        let next = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "下一步", "Next")).firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5)); next.tap()
        XCTAssertTrue(app.staticTexts["setup-general"].waitForExistence(timeout: 5))
        let modes = app.segmentedControls["preload-modes"]
        modes.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "積極", "Aggressive")).firstMatch.tap()
        for id in ["always-download-photos", "always-download-videos"] {
            let control = app.switches[id]
            for _ in 0..<4 { if control.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(control.exists); XCTAssertTrue(control.isEnabled)
            if control.value as? String != "1" { control.tap() }
        }
        XCTAssertTrue(app.descendants(matching: .any)["photo-download-note"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["video-download-note"].exists)
        finishGuide(app)
        // Closing a reviewed guide keeps the existing Settings navigation stack.
        app.navigationBars.buttons.firstMatch.tap()
        let media = app.staticTexts.matching(NSPredicate(format: "label == %@ OR label == %@", "播放與 iCloud", "Playback & iCloud")).firstMatch
        XCTAssertTrue(media.waitForExistence(timeout: 5)); media.tap()
        XCTAssertEqual(app.switches["always-download-photos"].value as? String, "1")
        XCTAssertEqual(app.switches["always-download-videos"].value as? String, "1")
        app.switches["always-download-photos"].tap()
        app.switches["always-download-videos"].tap()
        app.segmentedControls["preload-modes"].buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "平衡", "Balanced")).firstMatch.tap()
    }

    func testTabsAndNavigationSurviveBackgroundButNotNewProcess() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        finishGuide(app)
        func tab(_ zh: String, _ en: String) -> XCUIElement {
            app.tabBars.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", zh, en)).firstMatch
        }
        let sort = tab("整理", "Sort")
        XCTAssertTrue(sort.waitForExistence(timeout: 10))
        for (zh, en) in [("整理", "Sort"), ("待刪", "Review"), ("設定", "Settings")] {
            let selected = tab(zh, en)
            selected.tap()
            XCUIDevice.shared.press(.home)
            app.activate()
            XCTAssertTrue(selected.isSelected, "Background/foreground must keep the current tab")
        }
        let appearance = app.staticTexts.matching(NSPredicate(format: "label == %@ OR label == %@", "外觀與語言", "Appearance & language")).firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.navigationBars.matching(NSPredicate(format: "identifier == %@ OR identifier == %@", "外觀與語言", "Appearance & language")).firstMatch.waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(sort.waitForExistence(timeout: 10))
        XCTAssertTrue(sort.isSelected, "A new process must start in Sort")
        XCTAssertFalse(app.navigationBars["快速開始"].exists)
        XCTAssertFalse(app.navigationBars["Quick start"].exists)
    }
}
