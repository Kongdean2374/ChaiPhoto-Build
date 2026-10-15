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
            XCTAssertEqual(old.preloadPreset, .custom)
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
            XCTAssertEqual(OnboardingPolicy.page(defaults), 3)
            XCTAssertEqual(next.preloadPreset, .economy)
            XCTAssertFalse(next.canDownloadPhoto)
            XCTAssertFalse(next.canDownloadVideo)
            OnboardingPolicy.complete(defaults)
            XCTAssertFalse(AppSettings(defaults: defaults).showOnboarding)
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
        manager.setPresentationBlocked(true, reason: "guide")
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
