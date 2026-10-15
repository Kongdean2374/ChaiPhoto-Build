import Foundation
import SwiftUI
import UIKit

struct AppUpdateManualAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
final class AppUpdateManager: ObservableObject {
    @Published private(set) var availableUpdate: AppReleaseInfo?
    @Published private(set) var isChecking = false
    @Published var showPrompt = false
    @Published var manualAlert: AppUpdateManualAlert?
    @Published private(set) var presentationBlocked = true
#if CHAIPHOTO_TESTFLIGHT
    private static let channel: ReleaseChannel = .beta
    private static let endpoint = URL(string: "https://photo.chaihome.cc/api/app-version")!
    private static let testFlightURL = URL(string: "https://testflight.apple.com/join/vHCZ7wZp")!
#elseif CHAIPHOTO_APPSTORE
    private static let channel: ReleaseChannel = .store
#else
#error("Choose exactly one ChaiPhoto distribution flavor")
#endif
    private let defaults: UserDefaults
    private let sessionConfiguration: URLSessionConfiguration?
    init(defaults: UserDefaults = .standard, sessionConfiguration: URLSessionConfiguration? = nil) {
        self.defaults = defaults
        self.sessionConfiguration = sessionConfiguration
    }
    private let bundleID = "tw.chai2374.ChaiPhoto"
    private var skippedKey: String { "update.skippedRelease." + Self.channel.rawValue }
    private var remindKey: String { "update.remindAfter." + Self.channel.rawValue }
    private var checkedKey: String { "update.lastAutomaticCheck." + Self.channel.rawValue }
    private var hasCheckedThisLaunch = false
    private var sortingInteractionActive = false
    private var blockers: Set<String> = ["root"]
    private var presentedThisLaunch: Set<String> = []
    private var bypassSuppressionForPendingPrompt = false
    private var presentationTask: Task<Void, Never>?
    private var storeUpdateURL: URL?

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—" }
    var currentBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0 }

    func checkAutomaticallyOnce() async {
        guard !hasCheckedThisLaunch else { return }
        hasCheckedThisLaunch = true
        let last = defaults.double(forKey: checkedKey)
        guard Date().timeIntervalSince1970 - last >= 6 * 60 * 60 else { return }
        await performCheck(manual: false)
    }

    func checkManually() async { await performCheck(manual: true) }

    var hasExternalPresentationBlocker: Bool { !blockers.subtracting(["root"]).isEmpty }

    func setPresentationBlocked(_ blocked: Bool, reason: String) {
        if blocked { blockers.insert(reason) } else { blockers.remove(reason) }
        presentationBlocked = !blockers.isEmpty
        if presentationBlocked {
            presentationTask?.cancel()
            presentationTask = nil
            showPrompt = false
        } else { schedulePromptIfNeeded() }
    }

    func setSortingInteractionActive(_ active: Bool) {
        sortingInteractionActive = active
        if active {
            presentationTask?.cancel()
            presentationTask = nil
            showPrompt = false
        } else { schedulePromptIfNeeded() }
    }

    func remindLater() {
        defaults.set(Date().addingTimeInterval(24 * 60 * 60).timeIntervalSince1970, forKey: remindKey)
        dismissPrompt()
    }

    func skipCurrentVersion() {
        if let release = availableUpdate {
            defaults.set(release.identity(channel: Self.channel), forKey: skippedKey)
        }
        defaults.removeObject(forKey: remindKey)
        dismissPrompt()
    }

    private func dismissPrompt() {
        bypassSuppressionForPendingPrompt = false
        presentationTask?.cancel()
        presentationTask = nil
        showPrompt = false
    }

    func openUpdatePage() {
        dismissPrompt()
#if CHAIPHOTO_TESTFLIGHT
        UIApplication.shared.open(Self.testFlightURL)
#else
        if let storeUpdateURL { UIApplication.shared.open(storeUpdateURL) }
#endif
    }

    private func performCheck(manual: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let release: AppReleaseInfo
#if CHAIPHOTO_TESTFLIGHT
            let data = try await fetch(Self.endpoint)
            release = try JSONDecoder().decode(AppReleaseInfo.self, from: data)
            guard ReleaseVersion(release.latestVersion) != nil, release.latestBuild > 0, release.latestBuild.isMultiple(of: 2) else {
                throw URLError(.cannotParseResponse)
            }
#else
            var components = URLComponents(string: "https://itunes.apple.com/lookup")!
            let region = Locale.current.region?.identifier.lowercased() ?? "tw"
            let country = region.count == 2 && region.unicodeScalars.allSatisfy({ (97...122).contains($0.value) }) ? region : "tw"
            components.queryItems = [
                URLQueryItem(name: "bundleId", value: bundleID),
                URLQueryItem(name: "country", value: country),
                URLQueryItem(name: "entity", value: "software")
            ]
            guard let url = components.url else { throw URLError(.badURL) }
            let data = try await fetch(url)
            let result = try JSONDecoder().decode(StoreLookup.self, from: data)
            guard let (found, storeURL) = result.release(bundleID: bundleID) else { throw URLError(.cannotParseResponse) }
            release = found
            storeUpdateURL = storeURL
#endif
            if !manual { defaults.set(Date().timeIntervalSince1970, forKey: checkedKey) }
            if release.isNewer(than: currentVersion, build: currentBuild, channel: Self.channel) {
                availableUpdate = release
                bypassSuppressionForPendingPrompt = manual
                schedulePromptIfNeeded()
            } else {
                availableUpdate = nil
                dismissPrompt()
                if manual {
                    manualAlert = AppUpdateManualAlert(title: L("已是最新版", "Up to date"),
                        message: L("目前版本：\(currentVersion) (\(currentBuild))", "Current version: \(currentVersion) (\(currentBuild))"))
                }
            }
        } catch {
            if manual {
                manualAlert = AppUpdateManualAlert(title: L("無法檢查更新", "Unable to check for updates"),
                    message: L("目前無法取得此地區的最新版本，請稍後再試。你仍可繼續整理。",
                               "The latest release for this region is unavailable right now. Try again later; sorting is still available."))
            }
        }
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let configuration = (sessionConfiguration?.copy() as? URLSessionConfiguration) ?? URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              http.url?.host == url.host, data.count <= 1_048_576 else { throw URLError(.badServerResponse) }
        return data
    }

    private func schedulePromptIfNeeded() {
        guard let release = availableUpdate, !sortingInteractionActive,
              !presentationBlocked, manualAlert == nil else { return }
        let bypass = bypassSuppressionForPendingPrompt
        guard bypass || (!isSuppressed(release) && !presentedThisLaunch.contains(release.identity(channel: Self.channel))) else { return }
        presentationTask?.cancel()
        presentationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, !Task.isCancelled, !self.sortingInteractionActive,
                  !self.presentationBlocked, self.manualAlert == nil, let latest = self.availableUpdate else { return }
            let bypass = self.bypassSuppressionForPendingPrompt
            guard bypass || (!self.isSuppressed(latest) && !self.presentedThisLaunch.contains(latest.identity(channel: Self.channel))) else { return }
            self.showPrompt = true
            self.presentedThisLaunch.insert(latest.identity(channel: Self.channel))
            self.bypassSuppressionForPendingPrompt = false
            self.presentationTask = nil
        }
    }

    private func isSuppressed(_ release: AppReleaseInfo) -> Bool {
        let defaults = self.defaults
        if defaults.string(forKey: skippedKey) == release.identity(channel: Self.channel) { return true }
        if Self.channel == .beta && ReleaseVersion(release.latestVersion) == ReleaseVersion(currentVersion) && defaults.integer(forKey: "update.skippedBuild") == release.latestBuild { return true }
        let legacy = Self.channel == .beta ? defaults.double(forKey: "update.remindAfter") : 0
        return max(defaults.double(forKey: remindKey), legacy) > Date().timeIntervalSince1970
    }
}

struct AppUpdateBanner: View {
    @EnvironmentObject private var updateManager: AppUpdateManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var updateTitle: String {
#if CHAIPHOTO_TESTFLIGHT
        L("ChaiPhoto 有新的測試版本", "A new ChaiPhoto beta is available")
#else
        L("ChaiPhoto 有新的正式版本", "A new ChaiPhoto release is available")
#endif
    }
    private func versionText(_ release: AppReleaseInfo) -> String {
#if CHAIPHOTO_TESTFLIGHT
        L("目前 \(updateManager.currentVersion) (\(updateManager.currentBuild)) · 最新 \(release.latestVersion) (\(release.latestBuild))",
          "Current \(updateManager.currentVersion) (\(updateManager.currentBuild)) · Latest \(release.latestVersion) (\(release.latestBuild))")
#else
        L("目前 \(updateManager.currentVersion) · 最新 \(release.latestVersion)",
          "Current \(updateManager.currentVersion) · Latest \(release.latestVersion)")
#endif
    }

    var body: some View {
        if let release = updateManager.availableUpdate {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.indigo)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(updateTitle)
                            .font(.headline)

                        Text(versionText(release))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                }

                Button {
                    updateManager.openUpdatePage()
                } label: {
                    Label(
                        L("立即更新", "Update now"),
                        systemImage: "arrow.down.circle"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                HStack(spacing: 10) {
                    Button(L("稍後提醒", "Remind me later")) {
                        updateManager.remindLater()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)

                    Button(L("略過此版本", "Skip this version")) {
                        updateManager.skipCurrentVersion()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                }
                .font(.callout)
            }
            .padding(16)
            .frame(maxWidth: 480)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(Color.secondary.opacity(0.18))
            )
            .shadow(radius: reduceMotion ? 0 : 12, y: 5)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .transition(
                reduceMotion
                    ? .opacity
                    : .opacity.combined(with: .move(edge: .top))
            )
            .accessibilityElement(children: .contain)
        }
    }
}
