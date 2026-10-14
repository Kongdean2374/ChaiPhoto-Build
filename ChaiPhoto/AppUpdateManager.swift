import Foundation
import SwiftUI
import UIKit

struct AppReleaseInfo: Codable, Equatable {
    let latestVersion: String
    let latestBuild: Int
}

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

#if CHAIPHOTO_TESTFLIGHT
    private static let endpoint = URL(string: "https://photo.chaihome.cc/api/app-version")!
    private static let testFlightURL = URL(string: "https://testflight.apple.com/join/vHCZ7wZp")!
#endif

    private let skippedBuildKey = "update.skippedBuild"
    private let remindAfterKey = "update.remindAfter"

    private var hasCheckedThisLaunch = false
    private var sortingInteractionActive = false
    private var bypassSuppressionForPendingPrompt = false
    private var presentationTask: Task<Void, Never>?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var currentBuild: Int {
        let value = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return Int(value) ?? 0
    }

    func checkAutomaticallyOnce() async {
        guard !hasCheckedThisLaunch else { return }
        hasCheckedThisLaunch = true
        await performCheck(manual: false)
    }

    func checkManually() async {
        await performCheck(manual: true)
    }

    func setSortingInteractionActive(_ active: Bool) {
        sortingInteractionActive = active

        if active {
            presentationTask?.cancel()
            presentationTask = nil
        } else {
            schedulePromptIfNeeded()
        }
    }

    func remindLater() {
        UserDefaults.standard.set(
            Date().addingTimeInterval(24 * 60 * 60).timeIntervalSince1970,
            forKey: remindAfterKey
        )
        bypassSuppressionForPendingPrompt = false
        presentationTask?.cancel()
        presentationTask = nil
        showPrompt = false
    }

    func skipCurrentVersion() {
        if let build = availableUpdate?.latestBuild {
            UserDefaults.standard.set(build, forKey: skippedBuildKey)
        }

        UserDefaults.standard.removeObject(forKey: remindAfterKey)
        bypassSuppressionForPendingPrompt = false
        presentationTask?.cancel()
        presentationTask = nil
        showPrompt = false
    }

    func openUpdatePage() {
        bypassSuppressionForPendingPrompt = false
        presentationTask?.cancel()
        presentationTask = nil
        showPrompt = false

#if CHAIPHOTO_TESTFLIGHT
        UIApplication.shared.open(Self.testFlightURL)
#endif
    }

#if CHAIPHOTO_APPSTORE
    private func performCheck(manual: Bool) async {
        availableUpdate = nil
        showPrompt = false
        presentationTask?.cancel()
        presentationTask = nil

        if manual {
            manualAlert = AppUpdateManualAlert(
                title: L("正式版本更新", "App Store updates"),
                message: L(
                    "正式版本更新由 App Store 提供。",
                    "Production updates are provided through the App Store."
                )
            )
        }
    }
#else
    private func performCheck(manual: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        do {
            var request = URLRequest(
                url: Self.endpoint,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: 8
            )
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieAcceptPolicy = .never
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 10

            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }

            let (data, response) = try await session.data(for: request)

            guard
                let http = response as? HTTPURLResponse,
                (200...299).contains(http.statusCode)
            else {
                throw URLError(.badServerResponse)
            }

            let release = try JSONDecoder().decode(AppReleaseInfo.self, from: data)

            guard release.latestBuild > 0, !release.latestVersion.isEmpty else {
                throw URLError(.cannotParseResponse)
            }

            if release.latestBuild > currentBuild {
                availableUpdate = release

                if manual {
                    bypassSuppressionForPendingPrompt = true
                    schedulePromptIfNeeded(ignoreSuppression: true)
                } else {
                    schedulePromptIfNeeded()
                }
            } else {
                availableUpdate = nil
                showPrompt = false
                presentationTask?.cancel()
                presentationTask = nil

                let skippedBuild = UserDefaults.standard.integer(forKey: skippedBuildKey)
                if skippedBuild > 0, currentBuild >= skippedBuild {
                    UserDefaults.standard.removeObject(forKey: skippedBuildKey)
                }

                if manual {
                    manualAlert = AppUpdateManualAlert(
                        title: L("已是最新版", "Up to date"),
                        message: L(
                            "目前版本：\(currentVersion) (\(currentBuild))",
                            "Current version: \(currentVersion) (\(currentBuild))"
                        )
                    )
                }
            }
        } catch {
            if manual {
                manualAlert = AppUpdateManualAlert(
                    title: L("無法檢查更新", "Unable to check for updates"),
                    message: L(
                        "目前無法取得最新版本資訊，請稍後再試。",
                        "The latest version information is unavailable right now. Please try again later."
                    )
                )
            }
        }
    }

#endif

    private func schedulePromptIfNeeded(ignoreSuppression: Bool = false) {
        guard let release = availableUpdate else { return }

        let bypass = ignoreSuppression || bypassSuppressionForPendingPrompt
        guard bypass || !isSuppressed(release) else { return }
        guard !sortingInteractionActive else { return }

        presentationTask?.cancel()
        presentationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard
                let self,
                !Task.isCancelled,
                !self.sortingInteractionActive,
                let latest = self.availableUpdate
            else {
                return
            }

            let stillBypassing = self.bypassSuppressionForPendingPrompt
            guard stillBypassing || !self.isSuppressed(latest) else { return }

            self.showPrompt = true
            self.bypassSuppressionForPendingPrompt = false
            self.presentationTask = nil
        }
    }

    private func isSuppressed(_ release: AppReleaseInfo) -> Bool {
        let defaults = UserDefaults.standard

        if defaults.integer(forKey: skippedBuildKey) == release.latestBuild {
            return true
        }

        let remindAfter = defaults.double(forKey: remindAfterKey)
        if remindAfter > Date().timeIntervalSince1970 {
            return true
        }

        if remindAfter > 0 {
            defaults.removeObject(forKey: remindAfterKey)
        }

        return false
    }
}

#if CHAIPHOTO_APPSTORE
struct AppUpdateBanner: View {
    var body: some View {
        EmptyView()
    }
}
#else
struct AppUpdateBanner: View {
    @EnvironmentObject private var updateManager: AppUpdateManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let release = updateManager.availableUpdate {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.indigo)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("ChaiPhoto 有新的測試版本", "A new ChaiPhoto beta is available"))
                            .font(.headline)

                        Text(
                            L(
                                "目前 \(updateManager.currentVersion) (\(updateManager.currentBuild)) · 最新 \(release.latestVersion) (\(release.latestBuild))",
                                "Current \(updateManager.currentVersion) (\(updateManager.currentBuild)) · Latest \(release.latestVersion) (\(release.latestBuild))"
                            )
                        )
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
                        systemImage: "airplane"
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

#endif
