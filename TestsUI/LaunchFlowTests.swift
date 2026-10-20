import XCTest

final class LaunchFlowTests: XCTestCase {
    private func scrollPage(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.72))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.28))
        start.press(forDuration: 0.01, thenDragTo: end)
    }

    private func reachable(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let target = app.descendants(matching: .any).matching(identifier: id).firstMatch
        for _ in 0..<8 {
            if target.exists && target.isHittable { break }
            scrollPage(app)
        }
        XCTAssertTrue(target.waitForExistence(timeout: 5), id)
        XCTAssertTrue(target.isHittable, "Must scroll to the real reachable control: " + id)
        return target
    }

    override func record(_ issue: XCTIssue) {
        print("UI test issue: \(issue.compactDescription)")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "visual-failure"
        attachment.lifetime = .keepAlways
        add(attachment)
        super.record(issue)
    }

    // Captures the real app using only CI-generated Photos assets, never a mock UI.
    func testCaptureVisualReview() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-language", "zh-Hant", "-appearance", "light", "-textSize", "standard", "-preload.mode.v3", "off", "-autoplay", "NO", "-autoEstimate", "NO"]
        let fullAccess = NSPredicate(format: "label CONTAINS[c] 'Full Access' OR label CONTAINS[c] 'All Photos' OR label CONTAINS '完整存取' OR label CONTAINS '所有照片'")
        func allowFullPhotoAccess(_ alert: XCUIElement) -> Bool {
            let allow = alert.buttons.matching(fullAccess).firstMatch
            guard allow.exists else {
                XCTFail("Unrecognized Photos permission alert buttons: \(alert.buttons.allElementsBoundByIndex.map(\.label))")
                return false
            }
            print("Photos access handler selecting: \(allow.label)")
            allow.tap()
            return true
        }
        // Install before launch: the hosted unit-test app may already have requested
        // Photos access. XCTest's default interruption handler otherwise taps Don't Allow.
        let interruption = addUIInterruptionMonitor(withDescription: "Allow synthetic CI Photos access") { alert in
            let title = alert.label.lowercased()
            guard title.contains("photo") || title.contains("照片") || title.contains("相片") else { return false }
            return allowFullPhotoAccess(alert)
        }
        defer { removeUIInterruptionMonitor(interruption) }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let systemAlert = springboard.alerts.firstMatch
        // The unit-test host can leave its Photos consent alert on screen. Resolve
        // that real alert before the visual app process reads authorization state.
        if systemAlert.waitForExistence(timeout: 2) {
            XCTAssertTrue(allowFullPhotoAccess(systemAlert))
        }
        app.launch()
        let permission = app.buttons["photo-access-button"]
        if systemAlert.waitForExistence(timeout: 3) {
            XCTAssertTrue(allowFullPhotoAccess(systemAlert), "An existing Photos alert must grant full access, never use the default denial handler")
        } else if app.alerts.firstMatch.exists {
            XCTAssertTrue(allowFullPhotoAccess(app.alerts.firstMatch))
        } else if permission.waitForExistence(timeout: 3) {
            permission.tap()
            if systemAlert.waitForExistence(timeout: 3) {
                XCTAssertTrue(allowFullPhotoAccess(systemAlert))
            } else if app.alerts.firstMatch.exists {
                XCTAssertTrue(allowFullPhotoAccess(app.alerts.firstMatch))
            }
        }
        XCTAssertTrue(app.descendants(matching: .any)["photo-access-full"].waitForExistence(timeout: 10),
                      "Full Photos access must actually be granted before visual review")
        finishGuide(app)
        let mark = app.buttons["photo-mark-delete"]
        XCTAssertTrue(mark.waitForExistence(timeout: 12), "Synthetic Photos must be visible; do not substitute an empty permission screen")
        let gotIt = app.buttons["知道了"]
        if gotIt.waitForExistence(timeout: 4) {
            for _ in 0..<3 { if gotIt.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(gotIt.isHittable); gotIt.tap()
        }
        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "visual-" + name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        capture("01-sort-light-zh")
        for _ in 0..<2 {
            // SwiftUI may expose Text as StaticText or Other on newer iOS.
            // Require the exact unique identifier and its displayed count either way.
            let matches = app.descendants(matching: .any).matching(identifier: "sort-remaining")
            let remaining = matches.firstMatch
            XCTAssertTrue(remaining.waitForExistence(timeout: 5), "The visible remaining count must be exposed independently of the summary container")
            XCTAssertEqual(matches.count, 1, "The remaining count must have a unique accessibility identifier")
            let count = Int(remaining.label.replacingOccurrences(of: ",", with: "")) ?? 0
            XCTAssertGreaterThan(count, 1)
            mark.tap()
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", String(count - 1)), object: remaining)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        }
        app.buttons["篩選"].tap()
        capture("02-filters-light-zh")
        XCTAssertFalse(app.staticTexts["App 辨識"].exists)
        app.buttons["取消"].tap()
        app.tabBars.buttons["待刪"].tap()
        capture("03-review-light-zh")
        app.tabBars.buttons["設定"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings-brand"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["App 辨識・僅本機預覽"].exists)
        capture("04-settings-light-zh")
        app.terminate()
        app.launchArguments = ["-language", "en", "-appearance", "dark", "-textSize", "extra", "-preload.mode.v3", "off", "-autoplay", "NO", "-autoEstimate", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["photo-mark-delete"].waitForExistence(timeout: 10))
        capture("05-sort-dark-en-large")
        app.buttons["Filters"].tap()
        capture("06-filters-dark-en-large")
        app.buttons["Cancel"].tap()
        app.tabBars.buttons["Review"].tap()
        capture("07-review-dark-en-large")
        app.tabBars.buttons["Settings"].tap()
        capture("08-settings-dark-en-large")
        app.terminate()
    }

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
        app.launchArguments = ["-language", "en", "-appearance", "light", "-textSize", "standard", "-preload.mode.v3", "off", "-autoplay", "NO"]
        app.launch(); finishGuide(app)
        app.tabBars.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "設定", "Settings")).firstMatch.tap()
        reachable(app, "settings-information").tap()
        let revisit = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "重新檢視首次導覽", "Revisit getting started")).firstMatch
        XCTAssertTrue(revisit.waitForExistence(timeout: 5)); revisit.tap()
        let next = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "下一步", "Next")).firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5)); next.tap()
        XCTAssertTrue(app.staticTexts["setup-general"].waitForExistence(timeout: 5))
        let modes = app.segmentedControls["preload-modes"]
        modes.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "積極", "Aggressive")).firstMatch.tap()
        for id in ["always-download-photos", "always-download-videos"] {
            let control = app.switches[id]
            for _ in 0..<4 { if control.isHittable { break }; scrollPage(app) }
            XCTAssertTrue(control.exists); XCTAssertTrue(control.isEnabled)
            if control.value as? String != "1" { control.tap() }
        }
        XCTAssertTrue(app.descendants(matching: .any)["photo-download-note"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["video-download-note"].exists)
        finishGuide(app)
        // Closing a reviewed guide keeps the existing Settings navigation stack.
        app.navigationBars.buttons.firstMatch.tap()
        reachable(app, "settings-media").tap()
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
