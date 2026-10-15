import Foundation

enum OnboardingPolicy {
    static let completedKey = "onboarding.v2.completed"
    static let pageKey = "onboarding.v2.page"

    static func needsGuide(_ defaults: UserDefaults) -> Bool {
        if defaults.object(forKey: completedKey) != nil {
            return !defaults.bool(forKey: completedKey)
        }
        let existing = defaults.bool(forKey: "welcome.v1.2") ||
            defaults.bool(forKey: "tutorial.photo.interactions.v2") ||
            defaults.bool(forKey: "tutorial.video.interactions.v2") ||
            defaults.data(forKey: "lastMediaFilter.v2") != nil
        defaults.set(existing, forKey: completedKey)
        return !existing
    }

    static func page(_ defaults: UserDefaults) -> Int {
        min(2, max(0, defaults.integer(forKey: pageKey)))
    }

    static func complete(_ defaults: UserDefaults) {
        defaults.set(true, forKey: completedKey)
        defaults.set(true, forKey: "welcome.v1.2")
        defaults.set(true, forKey: "tutorial.photo.interactions.v2")
        defaults.set(true, forKey: "tutorial.video.interactions.v2")
        defaults.removeObject(forKey: pageKey)
    }
}

enum DownloadPolicy {
    static func allowed(permanent: Bool, session: Bool) -> Bool { permanent || session }
}

struct PreloadConfiguration: Equatable {
    let photos: Int
    let videos: Int
    let fullSpeed: Bool
}

struct PreloadEnvironment: Equatable {
    var connected = true
    var expensive = false
    var constrained = false
    var lowPower = false
    var lowBattery = false
    var charging = false
    var thermallyLimited = false
}

enum PreloadPreset: String, CaseIterable, Identifiable {
    case off, economy, balanced, aggressive
    var id: String { rawValue }
    var configuration: PreloadConfiguration { configuration(in: PreloadEnvironment()) }
    func configuration(in environment: PreloadEnvironment) -> PreloadConfiguration {
        switch self {
        case .off: return .init(photos: 0, videos: 0, fullSpeed: false)
        case .economy: return .init(photos: 1, videos: 0, fullSpeed: false)
        case .aggressive: return .init(photos: 8, videos: 4, fullSpeed: true)
        case .balanced:
            if environment.thermallyLimited { return .init(photos: 0, videos: 0, fullSpeed: false) }
            if environment.lowPower || environment.lowBattery || environment.expensive || environment.constrained || !environment.connected {
                return .init(photos: 1, videos: 0, fullSpeed: false)
            }
            return .init(photos: environment.charging ? 5 : 3, videos: environment.charging ? 3 : 2, fullSpeed: false)
        }
    }
    func authorizedConfiguration(in environment: PreloadEnvironment, photoAllowed: Bool, videoAllowed: Bool) -> PreloadConfiguration {
        let base = configuration(in: environment)
        return .init(photos: photoAllowed ? base.photos : 0, videos: videoAllowed ? base.videos : 0, fullSpeed: base.fullSpeed)
    }
    func allowsBackgroundNetwork(in environment: PreloadEnvironment) -> Bool {
        guard self != .off, environment.connected, !environment.constrained else { return false }
        return self != .balanced || !(environment.expensive || environment.lowPower || environment.lowBattery || environment.thermallyLimited)
    }
    static func migrated(fullSpeed: Bool, photos: Int, videos: Int) -> Self {
        if fullSpeed { return .aggressive }
        return photos <= 1 && videos == 0 ? .economy : .balanced
    }
}

struct ReleaseVersion: Comparable {
    let parts: [Int]
    init?(_ string: String) {
        let pieces = string.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(pieces.count) else { return nil }
        var values: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty,
                  piece.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
                  let value = Int(piece) else { return nil }
            values.append(value)
        }
        parts = values + Array(repeating: 0, count: 3 - values.count)
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

enum ReleaseChannel: String { case beta, store }

struct AppReleaseInfo: Codable, Equatable {
    let latestVersion: String
    let latestBuild: Int

    func isNewer(than version: String, build: Int, channel: ReleaseChannel) -> Bool {
        guard let latest = ReleaseVersion(latestVersion), let current = ReleaseVersion(version),
              channel == .store || (latestBuild > 0 && latestBuild.isMultiple(of: 2)) else { return false }
        return latest > current || (channel == .beta && latest == current && latestBuild > build)
    }

    func identity(channel: ReleaseChannel) -> String {
        let version = ReleaseVersion(latestVersion)?.parts.map(String.init).joined(separator: ".") ?? "invalid"
        return channel.rawValue + ":" + version + (channel == .beta ? ":\(latestBuild)" : "")
    }
}

struct StoreLookup: Decodable {
    struct Entry: Decodable {
        let bundleId: String
        let version: String
        let trackId: Int
        let trackViewUrl: String
    }
    let results: [Entry]

    func release(bundleID: String) -> (AppReleaseInfo, URL)? {
        guard results.count == 1, let entry = results.first, entry.bundleId == bundleID,
              entry.trackId > 0, ReleaseVersion(entry.version) != nil,
              let url = URL(string: entry.trackViewUrl), url.scheme == "https",
              url.host?.lowercased() == "apps.apple.com", url.user == nil, url.password == nil,
              url.path.split(separator: "/").contains(Substring("id\(entry.trackId)")) else { return nil }
        return (AppReleaseInfo(latestVersion: entry.version, latestBuild: 0), url)
    }
}
