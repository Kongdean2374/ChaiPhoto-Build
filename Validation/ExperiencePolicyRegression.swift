import Foundation

@main
struct ExperiencePolicyRegression {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        guard value() else { fatalError("Regression failed: " + name) }
    }
    static func isolated(_ body: (UserDefaults) -> Void) {
        let name = "ChaiPhoto.SyntheticRegression." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }
    static func main() throws {
        isolated { d in
            expect(OnboardingPolicy.needsGuide(d), "new install needs setup")
            d.set(2, forKey: OnboardingPolicy.pageKey)
            d.set(true, forKey: "allowCloudPhoto")
            d.set("synthetic-cursor", forKey: "cursor-fixture")
            expect(OnboardingPolicy.needsGuide(d), "unfinished setup resumes")
            expect(OnboardingPolicy.page(d) == 2, "saved setup page")
            expect(d.bool(forKey: "allowCloudPhoto"), "explicit choice retained")
            OnboardingPolicy.complete(d)
            expect(!OnboardingPolicy.needsGuide(d), "completed setup stays complete")
            expect(d.string(forKey: "cursor-fixture") == "synthetic-cursor", "progress untouched")
        }
        for legacy in ["welcome.v1.2", "tutorial.photo.interactions.v2", "tutorial.video.interactions.v2"] {
            isolated { d in
                d.set(true, forKey: legacy); d.set(8, forKey: "photoPreloadCount")
                d.set(4, forKey: "videoPreloadCount"); d.set(true, forKey: "fullSpeedPreload")
                expect(!OnboardingPolicy.needsGuide(d), "existing user migration")
                expect(d.integer(forKey: "photoPreloadCount") == 8, "old photo preference")
                expect(d.integer(forKey: "videoPreloadCount") == 4, "old video preference")
                expect(d.bool(forKey: "fullSpeedPreload"), "old preload preference")
            }
        }
        isolated { d in
            d.set(Data("synthetic-filter".utf8), forKey: "lastMediaFilter.v2")
            expect(!OnboardingPolicy.needsGuide(d), "existing sorting state migration")
        }
        for mode in PreloadPreset.allCases {
            for permanent in [false, true] {
                for session in [false, true] {
                    expect(DownloadPolicy.allowed(permanent: permanent, session: session) == (permanent || session), "permission independent of " + mode.rawValue)
                }
            }
        }
        expect(PreloadPreset.balanced.configuration == .init(photos: 3, videos: 2, fullSpeed: false), "safe defaults")
        expect(PreloadPreset.economy.configuration == .init(photos: 1, videos: 0, fullSpeed: false), "economy disables video preload")
        expect(PreloadPreset.migrated(fullSpeed: true, photos: 8, videos: 4) == .aggressive, "legacy maximum migrates without rewriting preferences")
        expect(PreloadPreset.allCases.count == 4, "only four modes")
        expect(PreloadPreset.off.configuration == .init(photos: 0, videos: 0, fullSpeed: false), "off makes no preload requests")
        expect(PreloadPreset.aggressive.configuration == .init(photos: 8, videos: 4, fullSpeed: true), "aggressive is bounded maximum")
        expect(PreloadPreset.balanced.configuration(in: .init(charging: true)).photos == 5, "charging on normal network increases balanced preparation")
        for state in [PreloadEnvironment(expensive: true), .init(constrained: true), .init(lowPower: true), .init(lowBattery: true), .init(connected: false)] {
            expect(PreloadPreset.balanced.configuration(in: state) == .init(photos: 1, videos: 0, fullSpeed: false), "balanced reduces resource use")
            expect(!PreloadPreset.balanced.allowsBackgroundNetwork(in: state), "balanced suppresses extra cloud transfers")
        }
        expect(PreloadPreset.balanced.configuration(in: .init(thermallyLimited: true)).photos == 0, "thermal pressure cancels balanced preloading")
        for connected in [false, true] {
            for constrained in [false, true] {
                for mode in PreloadPreset.allCases {
                    let state = PreloadEnvironment(connected: connected, constrained: constrained)
                    let config = mode.configuration(in: state)
                    expect((0...8).contains(config.photos) && (0...4).contains(config.videos), "all modes stay bounded")
                    if mode == .off || !connected || constrained {
                        expect(!mode.allowsBackgroundNetwork(in: state), "off, offline or low-data mode never preloads from network")
                    }
                }
            }
        }
        for mode in PreloadPreset.allCases {
            for photos in [false, true] {
                for videos in [false, true] {
                    let approved = mode.authorizedConfiguration(in: .init(), photoAllowed: photos, videoAllowed: videos)
                    expect(approved.photos == (photos ? mode.configuration.photos : 0), "photo budget follows consent")
                    expect(approved.videos == (videos ? mode.configuration.videos : 0), "video budget follows consent")
                }
            }
        }
        expect(ReleaseVersion("1.2.10")! > ReleaseVersion("1.2.9")!, "numeric version ordering")
        expect(ReleaseVersion("1.2") == ReleaseVersion("1.2.0"), "equivalent versions")
        for invalid in ["", "1..2", "1.2.3.4", "-1.2", "1.2.beta", "１.２"] {
            expect(ReleaseVersion(invalid) == nil, "invalid version rejected")
        }
        let beta = AppReleaseInfo(latestVersion: "1.2.6", latestBuild: 60)
        expect(beta.isNewer(than: "1.2.6", build: 58, channel: .beta), "same version newer beta build")
        expect(!beta.isNewer(than: "1.2.6", build: 58, channel: .store), "store ignores beta builds")
        expect(!AppReleaseInfo(latestVersion: "1.2.5", latestBuild: 9999).isNewer(than: "1.2.6", build: 58, channel: .beta), "older marketing version not newer")
        expect(AppReleaseInfo(latestVersion: "1.2.7", latestBuild: 0).isNewer(than: "1.2.6", build: 58, channel: .store), "store compares marketing version")
        expect(!AppReleaseInfo(latestVersion: "1.2.7", latestBuild: 0).isNewer(than: "1.2.6", build: 58, channel: .beta), "invalid beta build rejected")
        expect(!AppReleaseInfo(latestVersion: "1.2.7", latestBuild: 61).isNewer(than: "1.2.6", build: 58, channel: .beta), "store odd build cannot enter beta channel")
        expect(beta.identity(channel: .store) != beta.identity(channel: .beta), "channel suppression isolation")
        let bundle = "tw.chai2374.ChaiPhoto"
        for (id, link, allowed) in [(bundle, "https://apps.apple.com/tw/app/id123", true),
                                    ("synthetic.other", "https://apps.apple.com/tw/app/id123", false),
                                    (bundle, "https://apps.apple.com.evil.invalid/id123", false),
                                    (bundle, "http://apps.apple.com/id123", false),
                                    (bundle, "https://apps.apple.com/id999", false),
                                    (bundle, "https://user:pass@apps.apple.com/id123", false)] {
            let data = try JSONSerialization.data(withJSONObject: ["results": [["bundleId": id, "version": "1.2.7", "trackId": 123, "trackViewUrl": link]]])
            let result = try JSONDecoder().decode(StoreLookup.self, from: data)
            expect((result.release(bundleID: bundle) != nil) == allowed, "store identity and URL validation")
        }
        let empty = try JSONDecoder().decode(StoreLookup.self, from: Data("{\"results\":[]}".utf8))
        expect(empty.release(bundleID: bundle) == nil, "unavailable region handled")
        expect((try? JSONDecoder().decode(StoreLookup.self, from: Data("invalid-json".utf8))) == nil, "bad API payload handled")
        let items = (0..<10000).map(String.init)
        let queue = ReviewQueueOrdering.arrange(items, id: { $0 }, resumeID: "9000", priorityIDs: ["1", "2", "1", "missing"])
        expect(queue.count == items.count && Set(queue) == Set(items), "review queue does not lose records")
        expect(Array(queue.prefix(3)) == ["1", "2", "9000"], "restore priority and cursor")
        print("PASS: \(checks) executable production-policy assertions; synthetic data only.")
    }
}
