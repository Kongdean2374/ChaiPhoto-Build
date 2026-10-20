import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case traditionalChinese = "zh-Hant", simplifiedChinese = "zh-Hans"
    case english = "en", japanese = "ja", spanish = "es", french = "fr"
    var id: String { rawValue }
    var name: String {
        switch self {
        case .traditionalChinese: "繁體中文"
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        case .japanese: "日本語"
        case .spanish: "Español"
        case .french: "Français"
        }
    }
    var locale: Locale { Locale(identifier: rawValue) }

    static func concrete(_ identifier: String) -> Self? {
        let code = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        let parts = code.split(separator: "-").map(String.init)
        guard let base = parts.first else { return nil }
        switch base {
        case "en": return .english
        case "ja": return .japanese
        case "es": return .spanish
        case "fr": return .french
        case "zh":
            if parts.contains("hant") { return .traditionalChinese }
            if parts.contains("hans") { return .simplifiedChinese }
            return parts.contains(where: { ["tw", "hk", "mo"].contains($0) }) ? .traditionalChinese : .simplifiedChinese
        default: return nil
        }
    }

    static func suggested(preferences: [String]) -> Self {
        // Preferences include the public per-app language override when present.
        // No location, network, or persistent system-language observer is used.
        for preference in preferences {
            // An explicit script wins over the region (for example zh-Hans-TW).
            if let language = concrete(preference) { return language }
        }
        return .english
    }
}

enum LanguagePreference {
    struct Initial: Equatable {
        let language: AppLanguage
        let needsConfirmation: Bool
    }

    static func initial(defaults: UserDefaults, preferences: [String], existingUser: Bool) -> Initial {
        if let saved = defaults.string(forKey: "language"), let concrete = AppLanguage.concrete(saved) {
            defaults.set(concrete.rawValue, forKey: "language")
            return Initial(language: concrete, needsConfirmation: false)
        }
        if existingUser {
            // Earlier releases registered zh-Hant without writing it to disk.
            // Preserve that actual old UI for upgrades lacking a saved value.
            let language: AppLanguage = defaults.string(forKey: "language") == nil
                ? .traditionalChinese : .suggested(preferences: preferences)
            defaults.set(language.rawValue, forKey: "language")
            return Initial(language: language, needsConfirmation: false)
        }
        return Initial(language: .suggested(preferences: preferences), needsConfirmation: true)
    }

    static func confirm(_ language: AppLanguage, defaults: UserDefaults) {
        defaults.set(language.rawValue, forKey: "language")
    }
}

/// Public Foundation bundle APIs only. Switching this cache never rebuilds the
/// root view, the Photos store, navigation, current card, or persisted decisions.
enum AppLocalization {
    private static let lock = NSLock()
    private static var selected: AppLanguage = .english
    private static var bundles: [AppLanguage: Bundle] = [:]

    static var language: AppLanguage {
        lock.lock(); defer { lock.unlock() }
        return selected
    }
    static var locale: Locale { language.locale }
    static func use(_ language: AppLanguage) {
        lock.lock(); defer { lock.unlock() }
        selected = language
    }
    static func bundle(for language: AppLanguage) -> Bundle {
        lock.lock(); defer { lock.unlock() }
        if let cached = bundles[language] { return cached }
        guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return .main }
        bundles[language] = bundle
        return bundle
    }
    static func text(_ key: String, fallback: String, arguments: [CVarArg] = [], language: AppLanguage? = nil) -> String {
        let language = language ?? self.language
        // A missing resource must never format the composite lookup key: its
        // metadata contains a second set of placeholders. CI rejects missing keys.
        let format = bundle(for: language).localizedString(forKey: key, value: fallback, table: "Localizable")
        return String(format: format, locale: language.locale, arguments: arguments)
    }
}

/// Keeps interpolation arguments separate from native .strings/.stringsdict keys.
/// Integer overloads let Foundation select real plural categories for counts.
struct AppText: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    var key: String
    var arguments: [CVarArg]
    init(stringLiteral value: String) { key = value.replacingOccurrences(of: "%", with: "%%"); arguments = [] }
    init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key; arguments = stringInterpolation.arguments
    }
    struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [CVarArg] = []
        init(literalCapacity: Int, interpolationCount: Int) { key.reserveCapacity(literalCapacity) }
        mutating func appendLiteral(_ literal: String) { key += literal.replacingOccurrences(of: "%", with: "%%") }
        mutating func appendInterpolation(_ value: Int) { key += "%lld"; arguments.append(Int64(value)) }
        mutating func appendInterpolation<T>(_ value: T) { key += "%@"; arguments.append(String(describing: value)) }
    }
}

func L(_ zh: AppText, _ en: AppText) -> String {
    AppLocalization.text(en.key + " || " + zh.key, fallback: en.key, arguments: en.arguments)
}

func appInteger(_ value: Int) -> String { value.formatted(.number.locale(AppLocalization.locale)) }
func appDecimal(_ value: Double, digits: Int) -> String {
    value.formatted(.number.precision(.fractionLength(digits)).locale(AppLocalization.locale))
}

func appErrorMessage(_ error: Error) -> String {
    // OS-generated descriptions follow OS preferences, which may intentionally
    // differ from the locked in-app language. Keep the code available for support.
    L("請稍後再試。", "Please try again later.") + " (\((error as NSError).code))"
}
