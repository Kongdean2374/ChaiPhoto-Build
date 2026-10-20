import SwiftUI
import Foundation
import UIKit
import Darwin
import Photos
import Network

@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults
    @Published var allowCloudPhoto: Bool {
        didSet {
            defaults.set(allowCloudPhoto, forKey: "allowCloudPhoto")
            cloudPhotoSessionAllowed = false
            cloudPhotoPromptHandled = cloudSessionDecisionHandled
            photoItemGrants.removeAll(); photoItemsPrompted.removeAll()
            showCloudPhotoPrompt = false
        }
    }
    @Published var cloudPhotoSessionAllowed = false
    @Published var showCloudPhotoPrompt = false
    var cloudPhotoPromptHandled = false
    var canDownloadPhoto: Bool { preloadPreset != .off && DownloadPolicy.allowed(permanent: allowCloudPhoto, session: cloudPhotoSessionAllowed) }

    @Published var allowCloudVideo: Bool { didSet { defaults.set(allowCloudVideo, forKey: "allowCloudVideo"); cloudSessionAllowed = false; cloudPromptHandled = cloudSessionDecisionHandled; videoItemGrants.removeAll(); videoItemsPrompted.removeAll() } }
    @Published var cloudSessionAllowed = false
    var cloudPromptHandled = false
    var canDownloadVideo: Bool { preloadPreset != .off && DownloadPolicy.allowed(permanent: allowCloudVideo, session: cloudSessionAllowed) }
    @Published var showOnboarding: Bool
    @Published var reviewingOnboarding = false

    // Retain legacy keys for upgrades; only the four-mode policy drives preloading.
    let fullSpeedPreload: Bool
    let photoPreloadCount: Int
    let videoPreloadCount: Int
    @Published private(set) var preloadPreset: PreloadPreset
    @Published var preloadEnvironment = PreloadEnvironment()
    @Published private(set) var photoItemGrants: Set<String> = []
    @Published private(set) var videoItemGrants: Set<String> = []
    @Published private(set) var cloudPhotoPromptAssetID: String?
    @Published private(set) var cloudPhotoPromptInPreview = false
    private var photoItemsPrompted: Set<String> = []
    private var videoItemsPrompted: Set<String> = []
    private let pathMonitor = NWPathMonitor()
    private var resourceObservers: [NSObjectProtocol] = []
    private var monitoringResources = false

    @Published var showCloudSessionPrompt = false
    @Published private(set) var cloudSessionDecisionHandled = false
    private(set) var sessionRequestsPhoto = false
    private(set) var sessionRequestsVideo = false
    var needsCloudSessionDecision: Bool {
        preloadPreset != .off && !cloudSessionDecisionHandled && (!canDownloadPhoto || !canDownloadVideo)
    }
    var effectivePreload: PreloadConfiguration {
        preloadPreset.authorizedConfiguration(in: preloadEnvironment, photoAllowed: canDownloadPhoto, videoAllowed: canDownloadVideo)
    }
    func requestCloudSessionPermission() {
        guard needsCloudSessionDecision, !showCloudSessionPrompt, !showCloudPhotoPrompt else { return }
        sessionRequestsPhoto = !canDownloadPhoto
        sessionRequestsVideo = !canDownloadVideo
        cloudSessionDecisionHandled = true
        cloudPhotoPromptHandled = true; cloudPromptHandled = true
        showCloudSessionPrompt = true
    }
    func decideCloudSession(allow: Bool) {
        if sessionRequestsPhoto { cloudPhotoSessionAllowed = allow }
        if sessionRequestsVideo { cloudSessionAllowed = allow }
        showCloudSessionPrompt = false
    }
    var canPreloadPhotoNetwork: Bool { canDownloadPhoto && preloadPreset.allowsBackgroundNetwork(in: preloadEnvironment) }
    var canPreloadVideoNetwork: Bool { canDownloadVideo && preloadPreset.allowsBackgroundNetwork(in: preloadEnvironment) }
    func canDownloadPhoto(for assetID: String) -> Bool { canDownloadPhoto || photoItemGrants.contains(assetID) }
    func canDownloadVideo(for assetID: String) -> Bool { canDownloadVideo || videoItemGrants.contains(assetID) }

    func applyPreloadPreset(_ preset: PreloadPreset) {
        guard preset != preloadPreset else { return }
        preloadPreset = preset
        defaults.set(preset.rawValue, forKey: "preload.mode.v3")
        // Speed changes never rewrite permanent or session download consent.
        photoItemsPrompted.removeAll(); videoItemsPrompted.removeAll()
        cloudPhotoPromptHandled = cloudSessionDecisionHandled; cloudPromptHandled = cloudSessionDecisionHandled
        showCloudPhotoPrompt = false; cloudPhotoPromptAssetID = nil
        if preset == .off { showCloudSessionPrompt = false }
    }

    func startResourceMonitoring() {
        guard !monitoringResources else { return }
        monitoringResources = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        preloadEnvironment.connected = false
        refreshPowerState()
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification,
                     Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            resourceObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshPowerState() }
            })
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let expensive = path.isExpensive, constrained = path.isConstrained
            Task { @MainActor in
                guard let self else { return }
                var state = self.preloadEnvironment
                state.connected = connected; state.expensive = expensive; state.constrained = constrained
                self.preloadEnvironment = state
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "ChaiPhoto.preload-network"))
    }
    private func refreshPowerState() {
        var state = preloadEnvironment
        let device = UIDevice.current
        state.charging = device.batteryState == .charging || device.batteryState == .full
        state.lowBattery = !state.charging && device.batteryLevel >= 0 && device.batteryLevel <= 0.2
        state.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        state.thermallyLimited = ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical
        preloadEnvironment = state
    }
    deinit {
        pathMonitor.cancel()
        for observer in resourceObservers { NotificationCenter.default.removeObserver(observer) }
    }

    @Published var textSize: String { didSet { defaults.set(textSize, forKey: "textSize") } }
    @Published private(set) var language: String
    @Published private(set) var needsLanguageConfirmation: Bool
    func previewInitialLanguage(_ value: String) {
        guard needsLanguageConfirmation, let concrete = AppLanguage(rawValue: value) else { return }
        AppLocalization.use(concrete)
        language = concrete.rawValue
    }
    func selectLanguage(_ value: String) {
        guard let concrete = AppLanguage(rawValue: value) else { return }
        LanguagePreference.confirm(concrete, defaults: defaults)
        AppLocalization.use(concrete)
        language = concrete.rawValue
        needsLanguageConfirmation = false
    }
    @Published var appearance: String { didSet { defaults.set(appearance, forKey: "appearance") } }
    @Published var deleteOnRight: Bool { didSet { defaults.set(deleteOnRight, forKey: "deleteOnRight") } }
    @Published var autoplay: Bool { didSet { defaults.set(autoplay, forKey: "autoplay") } }
    @Published var muted: Bool { didSet { defaults.set(muted, forKey: "muted") } }
    @Published var haptics: Bool { didSet { defaults.set(haptics, forKey: "haptics") } }
    @Published var autoEstimate: Bool { didSet { defaults.set(autoEstimate, forKey: "autoEstimate") } }
    @Published var advanceAfterAlbumAction: Bool { didSet { defaults.set(advanceAfterAlbumAction, forKey: "advanceAfterAlbumAction") } }
    @Published var favorites: Set<String> { didSet { defaults.set(Array(favorites), forKey: "videoFavorites") } }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let d = defaults
        let needsGuide = OnboardingPolicy.needsGuide(d)
        let initialLanguage = LanguagePreference.initial(defaults: d, preferences: Locale.preferredLanguages, existingUser: !needsGuide)
        language = initialLanguage.language.rawValue
        needsLanguageConfirmation = initialLanguage.needsConfirmation
        AppLocalization.use(initialLanguage.language)
        d.register(defaults: [
            "appearance":"system",
            "autoplay":true,
            "muted":true,
            "haptics":true,
            "autoEstimate":true,
            "fullSpeedPreload":false,
            "photoPreloadCount":3,
            "videoPreloadCount":2
        ])
        allowCloudPhoto = d.bool(forKey: "allowCloudPhoto")
        allowCloudVideo = d.bool(forKey: "allowCloudVideo")
        fullSpeedPreload = d.bool(forKey: "fullSpeedPreload")
        photoPreloadCount = max(1, d.integer(forKey: "photoPreloadCount"))
        videoPreloadCount = max(0, d.integer(forKey: "videoPreloadCount"))
        preloadPreset = d.string(forKey: "preload.mode.v3").flatMap(PreloadPreset.init(rawValue:)) ??
            PreloadPreset.migrated(fullSpeed: fullSpeedPreload, photos: photoPreloadCount, videos: videoPreloadCount)
        textSize = d.string(forKey: "textSize") ?? "system"
        appearance = d.string(forKey: "appearance") ?? "system"
        deleteOnRight = d.bool(forKey: "deleteOnRight")
        autoplay = d.bool(forKey: "autoplay"); muted = d.bool(forKey: "muted")
        haptics = d.bool(forKey: "haptics"); autoEstimate = d.bool(forKey: "autoEstimate")
        advanceAfterAlbumAction = d.bool(forKey: "advanceAfterAlbumAction")
        favorites = Set(d.stringArray(forKey: "videoFavorites") ?? [])
        showOnboarding = needsGuide
    }
    var colorScheme: ColorScheme? { appearance == "dark" ? .dark : appearance == "light" ? .light : nil }

    func requestCloudPhotoDownloadPermission(for assetID: String, inPreview: Bool = false, retry: Bool = false) {
        guard !canDownloadPhoto(for: assetID), !showCloudPhotoPrompt else { return }
        if !retry {
            if needsCloudSessionDecision || showCloudSessionPrompt { return }
            if preloadPreset == .off { guard !photoItemsPrompted.contains(assetID) else { return } }
            else { guard !cloudPhotoPromptHandled else { return } }
        }
        photoItemsPrompted.insert(assetID)
        cloudPhotoPromptHandled = true
        cloudPhotoPromptAssetID = assetID
        cloudPhotoPromptInPreview = inPreview
        showCloudPhotoPrompt = true
    }
    func allowCloudPhotoItem() {
        if let id = cloudPhotoPromptAssetID { photoItemGrants.insert(id) }
        showCloudPhotoPrompt = false
        cloudPhotoPromptAssetID = nil
    }
    func allowCloudPhotosThisSession() {
        if preloadPreset == .off { allowCloudPhotoItem(); return }
        cloudPhotoSessionAllowed = true
        showCloudPhotoPrompt = false
        cloudPhotoPromptAssetID = nil
    }
    func declineCloudPhotosForNow() {
        showCloudPhotoPrompt = false
        cloudPhotoPromptAssetID = nil
    }
    func shouldPromptCloudVideo(for assetID: String) -> Bool {
        guard !canDownloadVideo(for: assetID), !needsCloudSessionDecision, !showCloudSessionPrompt else { return false }
        if preloadPreset == .off { guard !videoItemsPrompted.contains(assetID) else { return false } }
        else { guard !cloudPromptHandled else { return false } }
        videoItemsPrompted.insert(assetID)
        cloudPromptHandled = true
        return true
    }
    func allowCloudVideoItem(_ assetID: String) { videoItemGrants.insert(assetID) }

    func successFeedback() { if haptics { UINotificationFeedbackGenerator().notificationOccurred(.success) } }

    func feedback() { if haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() } }
    func toggleFavorite(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
    }
}

private enum AppLinks {
    static let product = URL(string: "https://photo.chaihome.cc")!
    static let privacy = URL(string: "https://photo.chaihome.cc/privacy")!
    static let terms = URL(string: "https://photo.chaihome.cc/terms")!
    static let support = URL(string: "https://photo.chaihome.cc/support")!
    static let report = URL(string: "https://photo.chaihome.cc/report")!
    static let knownIssues = URL(string: "https://photo.chaihome.cc/report#issues")!

#if CHAIPHOTO_TESTFLIGHT
    static let testFlight = URL(string: "https://testflight.apple.com/join/vHCZ7wZp")!
    static let beta = URL(string: "https://photo.chaihome.cc/beta")!
#endif
}

private func hardwareModelIdentifier() -> String {
    var size = 0
    sysctlbyname("hw.machine", nil, &size, nil, 0)
    guard size > 0 else { return UIDevice.current.model }

    var machine = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.machine", &machine, &size, nil, 0) == 0 else {
        return UIDevice.current.model
    }
    return String(cString: machine)
}

struct SettingsView: View {
    var category: SettingsCategory? = nil
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: PhotoLibraryStore
    @EnvironmentObject private var updateManager: AppUpdateManager
    @State private var showDiagnosticsConfirmation = false

    private var updateCheckButton: some View {
        Button { Task { await updateManager.checkManually() } } label: {
            HStack {
                Label(L("檢查更新", "Check for updates"), systemImage: "arrow.clockwise")
                Spacer()
                if updateManager.isChecking { ProgressView().controlSize(.small) }
            }
        }.disabled(updateManager.isChecking)
    }

    private func categoryLink(_ item: SettingsCategory) -> some View {
        NavigationLink {
            SettingsView(category: item)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(item.color)
                    .frame(width: 40, height: 40)
                    .background(item.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 8)
        }.accessibilityIdentifier("settings-" + item.rawValue)
    }

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version) (Build \(build))"
    }

    private var photoAccessLabel: String {
        switch library.authorization {
        case .authorized: return "full"
        case .limited: return "limited"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not-determined"
        @unknown default: return "unknown"
        }
    }

    private var diagnosticsText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        let cloudPhoto = settings.allowCloudPhoto
            ? "enabled"
            : settings.cloudPhotoSessionAllowed ? "session" : "disabled"
        let cloudVideo = settings.allowCloudVideo
            ? "enabled"
            : settings.cloudSessionAllowed ? "session" : "disabled"

        return [
            "ChaiPhoto Diagnostics v1",
            "",
            "App-Version: \(version)",
            "Build: \(build)",
            "iOS-Version: \(UIDevice.current.systemVersion)",
            "Device-Model: \(hardwareModelIdentifier())",
            "Photo-Access: \(photoAccessLabel)",
            "Language: \(settings.language)",
            "Appearance: \(settings.appearance)",
            "Delete-Direction: \(settings.deleteOnRight ? "right" : "left")",
            "Haptics: \(settings.haptics ? "enabled" : "disabled")",
            "Cloud-Photo: \(cloudPhoto)",
            "Cloud-Video: \(cloudVideo)",
            "Preload-Mode: \(settings.preloadPreset.rawValue)",
            "Photo-Preload: \(settings.effectivePreload.photos)",
            "Video-Preload: \(settings.effectivePreload.videos)",
            "Full-Speed-Preload: \(settings.effectivePreload.fullSpeed ? "enabled" : "disabled")",
            "Low-Power-Mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "enabled" : "disabled")"
        ].joined(separator: "\n")
    }

    var body: some View {
        Form {
            if let category {
                switch category {
                case .appearance:
                    Section(L("介面", "Appearance")) { AppearancePreferenceFields() }
                case .sorting:
                    Section(L("整理操作", "Sorting")) { SortingPreferenceFields() }
                case .media:
                    Section(L("iCloud 與預載", "iCloud & preloading")) { CloudPreloadSettingsView() }
                    Section(L("影片播放", "Video playback")) { VideoPlaybackPreferenceFields() }
                case .support:
#if CHAIPHOTO_APPSTORE
                    Section(L("支援與回報", "Support & feedback")) {
                        HStack {
                            Label(
                                L("App Store 正式版本", "App Store release"),
                                systemImage: "checkmark.seal.fill"
                            )
                            .foregroundStyle(.green)

                            Spacer()

                            Text(versionLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        updateCheckButton

                        Link(destination: AppLinks.support) {
                            Label(
                                L("支援與問題回報", "Support & report a problem"),
                                systemImage: "questionmark.circle"
                            )
                        }

                        Text(L(
                            "支援頁不會自動傳送 App 版本、裝置或系統資訊。若需要，可先使用下方「複製系統資訊」，再由你自行提供。",
                            "The support page does not automatically send app, device, or system information. If needed, copy the system information below and provide it yourself."
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Section(L("分享與診斷", "Sharing & diagnostics")) {
                        ShareLink(
                            item: AppLinks.product,
                            subject: Text("ChaiPhoto"),
                            message: Text(L(
                                "ChaiPhoto 是一款專為 iPhone 設計的照片與影片整理工具，可用滑動快速整理相簿，並在待刪頁再次確認。",
                                "ChaiPhoto is an iPhone photo and video organizer that helps you sort your library with quick swipes and review items before deletion."
                            ))
                        ) {
                            Label(
                                L("分享 ChaiPhoto", "Share ChaiPhoto"),
                                systemImage: "square.and.arrow.up"
                            )
                        }

                        Button {
                            showDiagnosticsConfirmation = true
                        } label: {
                            Label(
                                L("複製系統資訊", "Copy system information"),
                                systemImage: "doc.on.doc"
                            )
                        }.accessibilityIdentifier("diagnostics-copy")

                        Text(L(
                            "系統資訊只會在你確認後複製到剪貼簿，不會自動傳送到回報網站。",
                            "System information is copied only after you confirm and is never sent to the report website automatically."
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
#else
                    Section(L("Beta 測試與回報", "Beta testing & feedback")) {
                        HStack {
                            Label(
                                L("TestFlight 測試中", "TestFlight beta"),
                                systemImage: "checkmark.seal.fill"
                            )
                            .foregroundStyle(.green)

                            Spacer()

                            Text(versionLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        updateCheckButton

                        Link(destination: AppLinks.report) {
                            Label(
                                L("回報問題（建議）", "Report a problem (recommended)"),
                                systemImage: "exclamationmark.bubble"
                            )
                        }

                        Text(L(
                            "開啟回報網站時不會自動傳送 App 版本、裝置或系統資訊。若需要，可先使用下方「複製系統資訊」，再由你自行貼到網站。",
                            "Opening the report website does not automatically send app, device, or system information. If needed, copy the system information below and paste it yourself."
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Link(destination: AppLinks.knownIssues) {
                            Label(
                                L("已知問題與處理進度", "Known issues & progress"),
                                systemImage: "list.bullet.clipboard"
                            )
                        }

                        Link(destination: AppLinks.testFlight) {
                            Label(
                                L("TestFlight 公開測試", "Public TestFlight beta"),
                                systemImage: "airplane"
                            )
                        }
                    }

                    Section(L("分享與診斷", "Sharing & diagnostics")) {
                        ShareLink(
                            item: AppLinks.beta,
                            subject: Text("ChaiPhoto"),
                            message: Text(L(
                                "ChaiPhoto 是一款用滑動快速整理 iPhone 照片與影片的 App，目前免費公開 Beta 測試中。",
                                "ChaiPhoto helps you quickly sort iPhone photos and videos with simple swipes. It is currently available as a free public beta."
                            ))
                        ) {
                            Label(
                                L("分享 ChaiPhoto", "Share ChaiPhoto"),
                                systemImage: "square.and.arrow.up"
                            )
                        }

                        Button {
                            showDiagnosticsConfirmation = true
                        } label: {
                            Label(
                                L("複製系統資訊", "Copy system information"),
                                systemImage: "doc.on.doc"
                            )
                        }.accessibilityIdentifier("diagnostics-copy")

                        Text(L(
                            "系統資訊只會在你確認後複製到剪貼簿，不會自動傳送到回報網站。",
                            "System information is copied only after you confirm and is never sent to the report website automatically."
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
#endif
                case .information:
                    Section(L("紀錄與說明", "History & information")) {
                        Button(L("重新檢視首次導覽", "Revisit getting started")) { settings.reviewingOnboarding = true }
                        NavigationLink(L("完整手勢教學", "Gesture guide")) { GestureReferenceView() }.accessibilityIdentifier("information-gestures")
                        NavigationLink(L("操作紀錄", "Activity history")) { HistoryView() }.accessibilityIdentifier("information-history")
                        Link(destination: AppLinks.privacy) {
                            HStack {
                                Text(L("隱私政策", "Privacy policy"))
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                            }
                        }
                        Link(destination: AppLinks.terms) {
                            HStack {
                                Text(L("使用政策", "Terms of use"))
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                            }
                        }
                        Link(destination: AppLinks.support) {
                            HStack {
                                Text(L("支援網站", "Support"))
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                            }
                        }
                    }
                }
            } else {
                Section {
                    HStack(spacing: 16) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 18).fill(ChaiPalette.accent.opacity(0.10)).rotationEffect(.degrees(-9))
                            RoundedRectangle(cornerRadius: 18).fill(ChaiPalette.accent.gradient)
                            Image(systemName: "photo.stack.fill").font(.system(size: 28, weight: .semibold)).foregroundStyle(.white)
                        }.frame(width: 60, height: 60).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("ChaiPhoto").font(.title2.bold())
                            Text(L("讓回憶留下，讓空間自由。", "Keep the memories. Make room."))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(versionLabel).font(.caption2.monospacedDigit().weight(.medium)).foregroundStyle(ChaiPalette.accent)
                        }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .modifier(ChaiPanel())
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("settings-brand")
                }
                Section(L("偏好設定", "Preferences")) {
                    categoryLink(.appearance)
                    categoryLink(.sorting)
                    categoryLink(.media)
                }
                Section(L("支援與資訊", "Support & information")) {
                    categoryLink(.support)
                    categoryLink(.information)
                }
            }
        }
        .navigationTitle(category?.title ?? L("設定", "Settings"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $settings.reviewingOnboarding) {
            WelcomeGuide(reviewing: true) { settings.reviewingOnboarding = false }
        }
        .task(id: settings.reviewingOnboarding || showDiagnosticsConfirmation) {
            updateManager.setPresentationBlocked(settings.reviewingOnboarding || showDiagnosticsConfirmation, reason: "settings-modal")
        }
        .onDisappear { updateManager.setPresentationBlocked(false, reason: "settings-modal") }
        .onChange(of: updateManager.manualAlert?.id) { _, _ in
            updateManager.setPresentationBlocked(settings.reviewingOnboarding || showDiagnosticsConfirmation, reason: "settings-modal")
        }
        .alert(item: Binding(
            get: { updateManager.presentationBlocked ? nil : updateManager.manualAlert },
            set: { updateManager.manualAlert = $0 }
        )) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text(L("好", "OK")))
            )
        }
        .alert(
            L("複製系統資訊？", "Copy system information?"),
            isPresented: $showDiagnosticsConfirmation
        ) {
            Button(L("取消", "Cancel"), role: .cancel) {}.accessibilityIdentifier("diagnostics-cancel")

            Button(L("確定並複製", "Copy")) {
                UIPasteboard.general.string = diagnosticsText
                settings.successFeedback()
                library.successNotice = L(
                    "系統資訊已複製到剪貼簿。",
                    "System information copied to the clipboard."
                )
            }
        } message: {
            Text(L(
                "將複製 ChaiPhoto 版本與 Build、iOS 版本、iPhone 機型識別、照片權限狀態、App 語言與部分 ChaiPhoto 設定。\n\n不包含照片、影片、檔名、相簿名稱、位置、Apple ID、電話或聯絡人，也不會自動上傳。只有你自行貼上或分享後，這些文字才會離開 App。",
                "This copies the ChaiPhoto version and build, iOS version, iPhone model identifier, Photos permission status, app language, and selected ChaiPhoto settings.\n\nIt does not include photos, videos, filenames, album names, location, Apple ID, phone number, or contacts, and nothing is uploaded automatically. The text leaves the app only if you choose to paste or share it."
            ))
        }
    }
}

// String formatting must explicitly use the app language; SwiftUI locale cannot
// localize a String that Date.formatted() has already produced.
func appDateTime(_ date: Date) -> String {
    let locale = AppLocalization.locale
    return date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
}


// Each destination owns the same settings bindings; moving rows changes no defaults.
enum SettingsCategory: String {
    case appearance, sorting, media, support, information
    var title: String {
        switch self {
        case .appearance: L("外觀與語言", "Appearance & language")
        case .sorting: L("整理與操作", "Sorting & controls")
        case .media: L("播放與 iCloud", "Playback & iCloud")
        case .support: L("回報與更新", "Feedback & updates")
        case .information: L("紀錄與關於", "History & about")
        }
    }
    var subtitle: String {
        switch self {
        case .appearance: L("顯示模式、文字大小、語言", "Theme, text size, language")
        case .sorting: L("滑動方向、觸覺、相簿操作", "Swipe direction, haptics, albums")
        case .media: L("自動播放、下載與預載", "Autoplay, downloads, preloading")
        case .support: L("問題回報、版本、系統資訊", "Report an issue, version, diagnostics")
        case .information: L("操作紀錄、手勢教學、隱私", "History, gesture guide, privacy")
        }
    }
    var symbol: String {
        switch self {
        case .appearance: "paintpalette.fill"
        case .sorting: "hand.draw.fill"
        case .media: "play.rectangle.fill"
        case .support: "bubble.left.and.bubble.right.fill"
        case .information: "info.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .appearance: .purple
        case .sorting: .indigo
        case .media: .blue
        case .support: .teal
        case .information: .gray
        }
    }
}


// Shared by Settings and the first-run General page; bindings write only on user edits.
struct AppearancePreferenceFields: View {
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(L("顯示模式", "Theme"), selection: $settings.appearance) {
                Text(L("跟隨系統", "System")).tag("system")
                Text(L("淺色", "Light")).tag("light")
                Text(L("深色", "Dark")).tag("dark")
            }
            Picker(L("文字大小", "Text size"), selection: $settings.textSize) {
                Text(L("跟隨系統", "System")).tag("system")
                Text(L("標準", "Standard")).tag("standard")
                Text(L("加大", "Large")).tag("large")
                Text(L("特大", "Extra large")).tag("extra")
            }
            LanguagePicker()
        }.pickerStyle(.menu)
    }
}

struct SortingPreferenceFields: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var direction: some View {
        Picker(L("刪除方向", "Delete direction"), selection: $settings.deleteOnRight) {
            Text(L("左滑待刪", "Delete left")).tag(false)
            Text(L("右滑待刪", "Delete right")).tag(true)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("照片刪除方向", "Photo delete direction"))
            if dynamicTypeSize >= .xxLarge || ["es", "fr"].contains(settings.language) {
                direction.pickerStyle(.inline)
            } else {
                direction.pickerStyle(.segmented)
            }
            Toggle(L("觸覺回饋", "Haptic feedback"), isOn: $settings.haptics)
            Toggle(L("自動估算待刪容量", "Estimate review size automatically"), isOn: $settings.autoEstimate)
            Toggle(L("加入相簿後自動下一張", "Advance after adding to albums"), isOn: $settings.advanceAfterAlbumAction)
            Text(settings.advanceAfterAlbumAction
                 ? L("加入相簿後會視為保留並前往下一張。", "Adding to an album marks the photo as kept and advances.")
                 : L("加入相簿後仍停留，等你滑動決定。", "Stay on the photo after album changes until you swipe."))
                .font(.caption).foregroundStyle(settings.advanceAfterAlbumAction ? Color.orange : Color.secondary)
        }
    }
}

struct VideoPlaybackPreferenceFields: View {
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(L("自動播放", "Autoplay"), isOn: $settings.autoplay).accessibilityIdentifier("autoplay-setting")
            Text(settings.autoplay ? L("影片會自動播放，可能增加耗電。", "Videos play automatically and may use more battery.")
                 : L("影片需手動播放。", "Tap to play videos manually."))
                .font(.caption).foregroundStyle(.secondary)
            Toggle(L("預設靜音", "Mute by default"), isOn: $settings.muted).accessibilityIdentifier("mute-setting")
            if !settings.muted {
                Label(L("播放影片時會發出聲音。", "Videos will play with sound."), systemImage: "speaker.wave.2.fill")
                    .font(.caption).foregroundStyle(.orange).accessibilityIdentifier("playback-sound-warning")
            }
        }
    }
}

struct CloudPreloadSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PreloadPresetPicker()
            if settings.preloadPreset != .off {
                Divider()
                Toggle(L("始終允許下載 iCloud 照片", "Always allow iCloud photo downloads"), isOn: $settings.allowCloudPhoto)
                    .accessibilityIdentifier("always-download-photos")
                downloadNote(enabled: settings.allowCloudPhoto, session: settings.cloudPhotoSessionAllowed, photo: true)
                Toggle(L("始終允許下載 iCloud 影片", "Always allow iCloud video downloads"), isOn: $settings.allowCloudVideo)
                    .accessibilityIdentifier("always-download-videos")
                downloadNote(enabled: settings.allowCloudVideo, session: settings.cloudSessionAllowed, photo: false)
                if !settings.canDownloadPhoto && !settings.canDownloadVideo {
                    Label(L("本次尚未允許自動下載，預載暫停；上方速度設定保留。", "Automatic downloads are not allowed this session. Preloading is paused; your speed setting is kept."), systemImage: "pause.circle")
                        .font(.caption).foregroundStyle(.orange)
                        .accessibilityIdentifier("preload-paused-note")
                }
            }
        }
    }
    private func downloadNote(enabled: Bool, session: Bool, photo: Bool) -> some View {
        Label(enabled
              ? L("允許自動預載，可能使用行動數據。", "Allows automatic preloading; cellular data may be used.")
              : session ? L("本次已允許；下次重開仍會詢問。", "Allowed this session; the next launch will ask again.")
              : L("每次重開詢問；本次拒絕則手動下載。", "Ask each launch; if declined, download manually."),
              systemImage: enabled ? "exclamationmark.triangle" : "info.circle")
            .font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(photo ? "photo-download-note" : "video-download-note")
    }
}

struct LanguagePicker: View {
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        Picker(L("語言", "Language"), selection: Binding(get: { settings.language }, set: { settings.selectLanguage($0) })) {
            ForEach(AppLanguage.allCases) { language in Text(language.name).tag(language.rawValue) }
        }.accessibilityIdentifier("app-language-picker")
            .accessibilityValue(AppLanguage(rawValue: settings.language)?.name ?? "English")
    }
}
