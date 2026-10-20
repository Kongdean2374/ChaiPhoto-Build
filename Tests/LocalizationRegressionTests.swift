import Foundation
import XCTest
@testable import ChaiPhoto

final class LocalizationRegressionTests: XCTestCase {
    private func isolated(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "ChaiPhoto.LanguageTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testMatchingRespectsPreferenceOrderRegionsScriptsAndEnglishFallback() {
        for (preferences, expected) in [
            (["zh-TW", "en"], AppLanguage.traditionalChinese),
            (["zh-HK"], .traditionalChinese), (["zh-Hans-TW"], .simplifiedChinese),
            (["zh-CN"], .simplifiedChinese), (["zh-SG"], .simplifiedChinese),
            (["es-MX", "fr"], .spanish), (["fr-CA"], .french),
            (["ja-JP"], .japanese), (["de-DE", "fr-FR"], .french),
            (["de-DE"], .english), ([], .english)
        ] {
            XCTAssertEqual(AppLanguage.suggested(preferences: preferences), expected, preferences.joined(separator: ","))
        }
        XCTAssertEqual(AppLanguage.allCases.count, 6)
        XCTAssertNil(AppLanguage.concrete("system"))
    }

    func testSuggestionIsNotSavedUntilUserConfirmsAndNeverFollowsLaterPreferences() {
        isolated { defaults in
            let first = LanguagePreference.initial(defaults: defaults, preferences: ["fr-CA"], existingUser: false)
            XCTAssertTrue(first.needsConfirmation)
            XCTAssertEqual(first.language, .french)
            XCTAssertNil(defaults.object(forKey: "language"))
            LanguagePreference.confirm(.spanish, defaults: defaults)
            for preferences in [["ja"], ["zh-Hant"], [], ["fr"]] {
                let reopened = LanguagePreference.initial(defaults: defaults, preferences: preferences, existingUser: false)
                XCTAssertEqual(reopened.language, .spanish)
                XCTAssertFalse(reopened.needsConfirmation)
            }
        }
    }

    @MainActor func testManualSelectionAndRelaunchKeepAllOtherPreferencesAndGuideState() throws {
        let oldLanguage = AppLocalization.language
        defer { AppLocalization.use(oldLanguage) }
        try isolated { defaults in
            defaults.set(true, forKey: OnboardingPolicy.completedKey)
            defaults.set("zh-Hant", forKey: "language")
            defaults.set(Data("filter-and-resume-sentinel".utf8), forKey: "lastMediaFilter.v2")
            defaults.set("asset-cursor", forKey: "sorting.resume.v1|photos|all|all")
            defaults.set(["video-id"], forKey: "videoFavorites")
            defaults.set(true, forKey: "deleteOnRight")
            let baseline = defaults.dictionaryRepresentation()
            let settings = AppSettings(defaults: defaults)
            XCTAssertFalse(settings.showOnboarding)
            for language in AppLanguage.allCases {
                settings.selectLanguage(language.rawValue)
                XCTAssertEqual(defaults.string(forKey: "language"), language.rawValue)
                XCTAssertEqual(AppLocalization.language, language)
                XCTAssertEqual(AppSettings(defaults: defaults).language, language.rawValue)
                XCTAssertFalse(settings.showOnboarding)
                for key in ["lastMediaFilter.v2", "sorting.resume.v1|photos|all|all", "videoFavorites", "deleteOnRight", OnboardingPolicy.completedKey] {
                    XCTAssertEqual(defaults.object(forKey: key) as? NSObject, baseline[key] as? NSObject, key)
                }
            }
            settings.selectLanguage("system")
            XCTAssertEqual(settings.language, AppLanguage.french.rawValue)
        }
    }

    func testLegacyConcreteLanguageAndImplicitTraditionalChineseArePreserved() {
        isolated { defaults in
            defaults.set("en-GB", forKey: "language")
            let old = LanguagePreference.initial(defaults: defaults, preferences: ["ja"], existingUser: true)
            XCTAssertEqual(old.language, .english)
            XCTAssertFalse(old.needsConfirmation)
            defaults.removeObject(forKey: "language")
            let implicit = LanguagePreference.initial(defaults: defaults, preferences: ["es"], existingUser: true)
            XCTAssertEqual(implicit.language, .traditionalChinese)
            XCTAssertFalse(implicit.needsConfirmation)
        }
    }

    func testAllNativeBundlesAndPluralSafetyTextRenderWithoutKeys() {
        let previous = AppLocalization.language
        defer { AppLocalization.use(previous) }
        for language in AppLanguage.allCases {
            XCTAssertNotNil(Bundle.main.path(forResource: language.rawValue, ofType: "lproj"))
            AppLocalization.use(language)
            for count in [0, 1, 2, 1_001] {
                let title = L("刪除 \(count) 項", "Delete \(count) items")
                XCTAssertFalse(title.contains(" || "), title)
                XCTAssertFalse(title.contains("%"), title)
                XCTAssertFalse(title.isEmpty)
                if language == .english {
                    XCTAssertEqual(title, count == 1 ? "Delete 1 item" : "Delete \(count) items")
                }
                if language == .french && count == 1 { XCTAssertEqual(title, "Supprimer 1 élément") }
                if language == .spanish && count == 1 { XCTAssertEqual(title, "Borrar 1 elemento") }
            }
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            XCTAssertEqual(appDateTime(date), date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(language.locale)))
            XCTAssertFalse(byteText(0).contains("Zero"))
            XCTAssertEqual(appDecimal(1.5, digits: 1), [AppLanguage.french, .spanish].contains(language) ? "1,5" : "1.5")
        }
    }

    @MainActor func testSerialProgressWritesSurviveLanguageChangesAndReopen() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("photo-choices.json")
        let action = DecisionAction(assetID: "synthetic-a", before: .keep, after: .delete)
        let saved = ProgressFixture(decisions: ["synthetic-a": .delete, "synthetic-b": .keep], history: [action],
            exclusions: [], deletions: [], deletedIDs: ["previously-deleted"], reopenedIDs: ["restored-c"])
        try JSONEncoder().encode(saved).write(to: url)
        let store = PhotoLibraryStore(saveURL: url)
        let previous = AppLocalization.language
        defer { AppLocalization.use(previous) }
        for index in 0..<24 {
            AppLocalization.use(AppLanguage.allCases[index % 6])
            store.toggleExclusion("synthetic-a")
        }
        await store.flushPendingWrites()
        let reopened = PhotoLibraryStore(saveURL: url)
        XCTAssertEqual(reopened.decisions, saved.decisions)
        XCTAssertEqual(reopened.history.map(\.id), [action.id])
        XCTAssertTrue(reopened.exclusions.isEmpty)
        XCTAssertEqual(reopened.deletedIDs, saved.deletedIDs)
        XCTAssertEqual(reopened.reopenedIDs, saved.reopenedIDs)
    }

    func testLargeIncomingPriorityUsesStableDeduplicationWithoutDroppingExistingItems() {
        let incoming = (0..<10_000).map(String.init)
        let result = ReviewQueueOrdering.prepending(incoming + incoming, to: ["existing", "2", "existing"])
        XCTAssertEqual(result, incoming + ["existing"])
    }
}

private struct ProgressFixture: Codable {
    let decisions: [String: PhotoDecision]
    let history: [DecisionAction]
    let exclusions: Set<String>
    let deletions: [DeletionRecord]
    let deletedIDs: Set<String>
    let reopenedIDs: [String]
}
