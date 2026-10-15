import XCTest

final class LaunchFlowTests: XCTestCase {
    private func finishGuide(_ app: XCUIApplication) {
        // Complete only by using real UI; no launch flag bypasses onboarding.
        for _ in 0..<6 {
            if app.tabBars.firstMatch.exists { break }
            let next = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "下一步", "Next")).firstMatch
            if next.waitForExistence(timeout: 2) { next.tap() }
            let finish = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "完成", "Finish")).firstMatch
            if finish.exists { finish.tap(); break }
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
        XCTAssertFalse(app.staticTexts["照片預載數量"].exists)
        XCTAssertFalse(app.staticTexts["Photos to preload"].exists)
        XCTAssertFalse(app.staticTexts["影片預載數量"].exists)
        let balanced = modes.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "平衡", "Balanced")).firstMatch
        balanced.tap(); XCTAssertTrue(balanced.isSelected)
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
