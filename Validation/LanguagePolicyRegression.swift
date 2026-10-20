import Foundation

@main struct LanguagePolicyRegression {
    static func main() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(), name); checks += 1
        }
        for (preferences, expected) in [(["zh-TW"], AppLanguage.traditionalChinese),
            (["zh-Hans-CN"], .simplifiedChinese), (["ja-JP"], .japanese),
            (["es-MX"], .spanish), (["fr-CA"], .french), (["de", "en-GB"], .english),
            (["de", "fr"], .french), (["ko"], .english)] {
            expect(AppLanguage.suggested(preferences: preferences) == expected, "language preference order/script/region")
        }
        let suite = "ChaiPhoto.CILanguagePolicy." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = LanguagePreference.initial(defaults: defaults, preferences: ["es"], existingUser: false)
        expect(initial.needsConfirmation && initial.language == .spanish, "fresh suggestion")
        expect(defaults.object(forKey: "language") == nil, "suggestion is not a saved decision")
        defaults.set("progress-sentinel", forKey: "sorting-progress")
        for language in AppLanguage.allCases {
            LanguagePreference.confirm(language, defaults: defaults)
            let reopen = LanguagePreference.initial(defaults: defaults, preferences: ["de", "ja"], existingUser: true)
            expect(reopen.language == language && !reopen.needsConfirmation, "concrete choice stays locked")
            expect(defaults.string(forKey: "sorting-progress") == "progress-sentinel", "no data reset")
        }
        defaults.removeObject(forKey: "language")
        expect(LanguagePreference.initial(defaults: defaults, preferences: ["ja"], existingUser: true).language == .traditionalChinese, "preserve implicit legacy default")
        expect(AppLanguage.concrete("system") == nil, "no follow-system option")
        print("PASS: \(checks) executable language-policy assertions; no network or private media")
    }
}
