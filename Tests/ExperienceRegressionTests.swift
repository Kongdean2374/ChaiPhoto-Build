import Foundation
import XCTest
@testable import ChaiPhoto

private final class UpdateResponseStub: URLProtocol {
    static let lock = NSLock()
    static var response: ((URLRequest) throws -> (Int, Data))?
    static func setResponse(_ handler: @escaping (URLRequest) throws -> (Int, Data)) {
        lock.lock(); defer { lock.unlock() }; response = handler
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.response; Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.notConnectedToInternet) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class ExperienceRegressionTests: XCTestCase {
    private func isolated(_ test: (UserDefaults) throws -> Void) rethrows {
        let suite = "ChaiPhoto.SyntheticXCTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try test(defaults)
    }

    @MainActor func testSafeDefaultsAndLegacySettingsSurviveMigration() {
        isolated { defaults in
            let fresh = AppSettings(defaults: defaults)
            XCTAssertEqual(fresh.photoPreloadCount, 3)
            XCTAssertEqual(fresh.videoPreloadCount, 2)
            XCTAssertFalse(fresh.fullSpeedPreload)
            XCTAssertFalse(fresh.allowCloudPhoto)
            XCTAssertFalse(fresh.allowCloudVideo)
            XCTAssertTrue(fresh.showOnboarding)
        }
        isolated { defaults in
            defaults.set(true, forKey: "welcome.v1.2")
            defaults.set(8, forKey: "photoPreloadCount")
            defaults.set(4, forKey: "videoPreloadCount")
            defaults.set(true, forKey: "fullSpeedPreload")
            defaults.set(true, forKey: "allowCloudPhoto")
            defaults.set("en", forKey: "language")
            defaults.set("synthetic-progress", forKey: "progress-fixture")
            let old = AppSettings(defaults: defaults)
            XCTAssertFalse(old.showOnboarding)
            XCTAssertEqual(old.preloadPreset, .aggressive)
            XCTAssertEqual(old.photoPreloadCount, 8)
            XCTAssertEqual(old.videoPreloadCount, 4)
            XCTAssertTrue(old.fullSpeedPreload)
            XCTAssertTrue(old.allowCloudPhoto)
            XCTAssertEqual(old.language, "en")
            XCTAssertEqual(defaults.string(forKey: "progress-fixture"), "synthetic-progress")
        }
    }

    @MainActor func testEveryPresetHonorsSeparatePhotoAndVideoPermissions() {
        isolated { defaults in
            let settings = AppSettings(defaults: defaults)
            for preset in [PreloadPreset.economy, .balanced, .aggressive] {
                settings.applyPreloadPreset(preset)
                for photo in [false, true] {
                    for video in [false, true] {
                        settings.allowCloudPhoto = photo; settings.allowCloudVideo = video
                        XCTAssertEqual(settings.canPreloadPhotoNetwork, photo)
                        XCTAssertEqual(settings.canPreloadVideoNetwork, video)
                        settings.cloudPhotoSessionAllowed = true
                        settings.cloudSessionAllowed = true
                        XCTAssertTrue(settings.canPreloadPhotoNetwork)
                        XCTAssertTrue(settings.canPreloadVideoNetwork)
                    }
                }
            }
        }
    }

    @MainActor func testInterruptedGuideRetainsChoicesAndSessionConsentExpires() {
        isolated { defaults in
            let first = AppSettings(defaults: defaults)
            first.applyPreloadPreset(.economy)
            first.cloudPhotoSessionAllowed = true
            first.cloudSessionAllowed = true
            defaults.set(3, forKey: OnboardingPolicy.pageKey)
            let next = AppSettings(defaults: defaults)
            XCTAssertTrue(next.showOnboarding)
            XCTAssertEqual(OnboardingPolicy.page(defaults), 2)
            XCTAssertEqual(next.preloadPreset, .economy)
            XCTAssertFalse(next.canDownloadPhoto)
            XCTAssertFalse(next.canDownloadVideo)
            OnboardingPolicy.complete(defaults)
            XCTAssertFalse(AppSettings(defaults: defaults).showOnboarding)
        }
    }

    @MainActor func testOffRequiresEachAssetEvenWithSavedPermanentAndSessionConsent() {
        isolated { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.allowCloudPhoto = true; settings.allowCloudVideo = true
            settings.applyPreloadPreset(.off)
            settings.cloudPhotoSessionAllowed = true; settings.cloudSessionAllowed = true
            XCTAssertEqual(settings.effectivePreload, .init(photos: 0, videos: 0, fullSpeed: false))
            XCTAssertFalse(settings.canPreloadPhotoNetwork); XCTAssertFalse(settings.canPreloadVideoNetwork)
            XCTAssertFalse(settings.canDownloadPhoto(for: "photo-A"))
            settings.requestCloudPhotoDownloadPermission(for: "photo-A")
            XCTAssertTrue(settings.showCloudPhotoPrompt)
            settings.allowCloudPhotosThisSession() // Even a legacy caller must stay item-only in Off.
            XCTAssertTrue(settings.canDownloadPhoto(for: "photo-A"))
            XCTAssertFalse(settings.canDownloadPhoto(for: "photo-B"))
            settings.requestCloudPhotoDownloadPermission(for: "photo-B")
            XCTAssertTrue(settings.showCloudPhotoPrompt)
            settings.declineCloudPhotosForNow()
            settings.requestCloudPhotoDownloadPermission(for: "photo-C")
            XCTAssertTrue(settings.showCloudPhotoPrompt, "Declining one item must not suppress the next item")
            XCTAssertTrue(settings.shouldPromptCloudVideo(for: "video-A"))
            settings.allowCloudVideoItem("video-A")
            XCTAssertTrue(settings.canDownloadVideo(for: "video-A"))
            XCTAssertFalse(settings.canDownloadVideo(for: "video-B"))
            XCTAssertTrue(settings.shouldPromptCloudVideo(for: "video-B"))
            XCTAssertFalse(settings.canPreloadPhotoNetwork); XCTAssertFalse(settings.canPreloadVideoNetwork)
            let reopened = AppSettings(defaults: defaults)
            XCTAssertEqual(reopened.preloadPreset, .off)
            XCTAssertFalse(reopened.canDownloadPhoto(for: "photo-A"))
            XCTAssertFalse(reopened.canDownloadVideo(for: "video-A"))
            XCTAssertTrue(defaults.bool(forKey: "allowCloudPhoto"), "Saved preference retained, suspended in Off")
        }
    }

    @MainActor func testBalancedRespondsToResourceConditionsWithoutGrantingPermission() {
        isolated { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.applyPreloadPreset(.balanced)
            settings.preloadEnvironment = .init(charging: true)
            XCTAssertEqual(settings.effectivePreload.photos, 0, "No preloading before consent")
            XCTAssertFalse(settings.canPreloadPhotoNetwork)
            settings.allowCloudPhoto = true
            XCTAssertEqual(settings.effectivePreload.photos, 5)
            XCTAssertEqual(settings.effectivePreload.videos, 0)
            XCTAssertTrue(settings.canPreloadPhotoNetwork)
            settings.preloadEnvironment = .init(expensive: true)
            XCTAssertEqual(settings.effectivePreload.photos, 1)
            XCTAssertFalse(settings.canPreloadPhotoNetwork)
            XCTAssertTrue(settings.canDownloadPhoto(for: "current"), "Foreground consent is separate from background budgets")
            settings.preloadEnvironment = .init(lowBattery: true)
            XCTAssertEqual(settings.effectivePreload.videos, 0)
            settings.preloadEnvironment = .init(thermallyLimited: true)
            XCTAssertEqual(settings.effectivePreload.photos, 0)
            settings.applyPreloadPreset(.aggressive)
            XCTAssertEqual(settings.effectivePreload, .init(photos: 8, videos: 0, fullSpeed: true))
            XCTAssertFalse(settings.canPreloadVideoNetwork, "Intensity never grants video consent")
        }
    }

    @MainActor func testSessionDeclinePausesPreloadingWithoutChangingSpeedAndAsksNextProcess() {
        isolated { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.applyPreloadPreset(.aggressive)
            XCTAssertTrue(settings.needsCloudSessionDecision)
            settings.requestCloudSessionPermission()
            XCTAssertTrue(settings.showCloudSessionPrompt)
            settings.requestCloudPhotoDownloadPermission(for: "photo-A")
            XCTAssertFalse(settings.showCloudPhotoPrompt, "Do not overlap startup and item alerts")
            settings.decideCloudSession(allow: false)
            XCTAssertEqual(settings.preloadPreset, .aggressive)
            XCTAssertEqual(settings.effectivePreload.photos, 0)
            XCTAssertEqual(settings.effectivePreload.videos, 0)
            settings.requestCloudSessionPermission()
            XCTAssertFalse(settings.showCloudSessionPrompt, "Once per process")
            settings.requestCloudPhotoDownloadPermission(for: "photo-A")
            XCTAssertFalse(settings.showCloudPhotoPrompt, "After declining, download only on explicit request")
            settings.requestCloudPhotoDownloadPermission(for: "photo-A", retry: true)
            settings.allowCloudPhotoItem()
            XCTAssertTrue(settings.canDownloadPhoto(for: "photo-A"))
            XCTAssertFalse(settings.canDownloadPhoto(for: "photo-B"))
            XCTAssertEqual(settings.effectivePreload.photos, 0, "One item never resumes preload")
            settings.applyPreloadPreset(.balanced)
            XCTAssertFalse(settings.needsCloudSessionDecision, "Speed changes do not re-ask this session")
            settings.applyPreloadPreset(.aggressive)
            let next = AppSettings(defaults: defaults)
            XCTAssertEqual(next.preloadPreset, .aggressive)
            XCTAssertTrue(next.needsCloudSessionDecision)
            XCTAssertFalse(next.canDownloadPhoto(for: "photo-A"))
        }
    }

    @MainActor func testSessionGrantIsScopedAndNeverChangesPermanentFlags() {
        isolated { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.allowCloudPhoto = true
            settings.applyPreloadPreset(.aggressive)
            settings.requestCloudSessionPermission()
            XCTAssertFalse(settings.sessionRequestsPhoto)
            XCTAssertTrue(settings.sessionRequestsVideo)
            settings.decideCloudSession(allow: false)
            XCTAssertEqual(settings.effectivePreload.photos, 8)
            XCTAssertEqual(settings.effectivePreload.videos, 0)
            XCTAssertTrue(settings.allowCloudPhoto)
            XCTAssertFalse(settings.allowCloudVideo)
            let next = AppSettings(defaults: defaults)
            next.requestCloudSessionPermission()
            next.decideCloudSession(allow: true)
            XCTAssertTrue(next.cloudSessionAllowed)
            XCTAssertFalse(next.allowCloudVideo, "A session grant is never persisted as always allow")
            XCTAssertEqual(next.effectivePreload.videos, 4)
            next.applyPreloadPreset(.economy)
            XCTAssertTrue(next.cloudSessionAllowed, "Speed does not change this-session consent")
            next.applyPreloadPreset(.off)
            XCTAssertFalse(next.needsCloudSessionDecision)
            XCTAssertEqual(next.effectivePreload.photos, 0)
            XCTAssertEqual(next.effectivePreload.videos, 0)
            next.applyPreloadPreset(.balanced)
            XCTAssertTrue(next.cloudSessionAllowed)
            XCTAssertEqual(next.effectivePreload.videos, 2)
            XCTAssertFalse(AppSettings(defaults: defaults).cloudSessionAllowed)
        }
    }

    @MainActor func testOfflineAndServerErrorsNeverBlockTheApp() async {
        for status in [0, -1, 500, 200] {
            let suite = "ChaiPhoto.SyntheticUpdate." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            UpdateResponseStub.setResponse { _ in
                if status == 0 { throw URLError(.notConnectedToInternet) }
                if status == -1 { throw URLError(.timedOut) }
                return (status, Data("invalid-response".utf8))
            }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [UpdateResponseStub.self]
            let manager = AppUpdateManager(defaults: defaults, sessionConfiguration: config)
            await manager.checkManually()
            XCTAssertFalse(manager.isChecking)
            XCTAssertNil(manager.availableUpdate)
            XCTAssertNotNil(manager.manualAlert)
            XCTAssertFalse(manager.showPrompt)
        }
    }

    @MainActor func testValidUpdateWaitsForOnboardingAndUsesCorrectChannel() async throws {
        let suite = "ChaiPhoto.SyntheticUpdate." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        UpdateResponseStub.setResponse { request in
#if CHAIPHOTO_TESTFLIGHT
            XCTAssertEqual(request.url?.host, "photo.chaihome.cc")
            return (200, Data("{\"latestVersion\":\"9.9.9\",\"latestBuild\":9998}".utf8))
#else
            XCTAssertEqual(request.url?.host, "itunes.apple.com")
            let json: [String: Any] = ["results": [["bundleId": "tw.chai2374.ChaiPhoto", "version": "9.9.9",
                                                    "trackId": 123, "trackViewUrl": "https://apps.apple.com/tw/app/id123"]]]
            return (200, try JSONSerialization.data(withJSONObject: json))
#endif
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdateResponseStub.self]
        let manager = AppUpdateManager(defaults: defaults, sessionConfiguration: config)
        XCTAssertFalse(manager.hasExternalPresentationBlocker)
        manager.setPresentationBlocked(true, reason: "guide")
        XCTAssertTrue(manager.hasExternalPresentationBlocker)
        manager.setPresentationBlocked(false, reason: "root")
        await manager.checkManually()
        XCTAssertNotNil(manager.availableUpdate)
        XCTAssertFalse(manager.showPrompt)
        manager.setPresentationBlocked(false, reason: "guide")
        try await Task.sleep(for: .milliseconds(950))
        XCTAssertTrue(manager.showPrompt)
        manager.setSortingInteractionActive(true)
        XCTAssertFalse(manager.showPrompt)
        manager.setSortingInteractionActive(false)
        try await Task.sleep(for: .milliseconds(950))
        XCTAssertFalse(manager.showPrompt, "Automatic presentation must not repeat in this process")
    }
}
