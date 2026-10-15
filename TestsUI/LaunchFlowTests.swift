import XCTest

final class LaunchFlowTests: XCTestCase {
    func testTabsAndNavigationSurviveBackgroundButNotNewProcess() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        // Complete only by using real UI; no launch flag bypasses onboarding.
        for _ in 0..<6 {
            if app.tabBars.firstMatch.exists { break }
            let next = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "下一步", "Next")).firstMatch
            if next.waitForExistence(timeout: 2) { next.tap() }
            let finish = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "完成", "Finish")).firstMatch
            if finish.exists { finish.tap(); break }
        }
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
        XCTAssertFalse(app.navigationBars["首次使用設定"].exists)
        XCTAssertFalse(app.navigationBars["Getting started"].exists)
    }
}
