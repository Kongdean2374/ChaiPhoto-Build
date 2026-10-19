import Photos
import SwiftUI

struct WelcomeGuide: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var page: Int
    let reviewing: Bool
    let finished: () -> Void

    init(reviewing: Bool = false, finished: @escaping () -> Void) {
        self.reviewing = reviewing
        self.finished = finished
        _page = State(initialValue: reviewing ? 0 : OnboardingPolicy.page(.standard))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(L("步驟 \(page + 1)／3", "Step \(page + 1) of 3"))
                        .font(.caption).foregroundStyle(.secondary)
                    pageContent
                }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    if page > 0 { Button(L("上一步", "Back")) { page -= 1 } }
                    Spacer()
                    Button(page == 2 ? L("完成", "Finish") : L("下一步", "Next")) {
                        if page < 2 { page += 1 }
                        else {
                            if !reviewing { OnboardingPolicy.complete(.standard) }
                            finished()
                            dismiss()
                        }
                    }.buttonStyle(.borderedProminent)
                }.padding().background(.regularMaterial)
            }
            .navigationTitle(L("快速開始", "Quick start"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
            .onChange(of: page) { _, value in
                if !reviewing { UserDefaults.standard.set(value, forKey: OnboardingPolicy.pageKey) }
            }
        }
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case 0:
            Text(L("歡迎使用 ChaiPhoto", "Welcome to ChaiPhoto")).font(.title.bold())
            Text(L("先確認照片權限，就能開始整理。", "Check photo access, then start sorting."))
            PhotoAccessStatusView()
        case 1:
            Text(L("一般", "General")).font(.title.bold()).accessibilityIdentifier("setup-general")
            Text(L("隨時可在設定更改。", "You can change these later in Settings."))
                .font(.caption).foregroundStyle(.secondary)
            CloudPreloadSettingsView()
            Divider()
            DisclosureGroup(L("顯示與語言", "Display & language")) { AppearancePreferenceFields().padding(.top, 8) }
                .accessibilityIdentifier("setup-appearance")
            DisclosureGroup(L("整理與操作", "Sorting & controls")) { SortingPreferenceFields().padding(.top, 8) }
                .accessibilityIdentifier("setup-sorting")
            DisclosureGroup(L("影片播放", "Video playback")) { VideoPlaybackPreferenceFields().padding(.top, 8) }
                .accessibilityIdentifier("setup-playback")
        default:
            Text(L("放心整理", "Sort with confidence")).font(.title.bold())
            Text(L("滑動只做標記；真正刪除前，還會在待刪頁與 iOS 再次確認。",
                   "Swipes only mark items. Actual deletion needs confirmation in Review and again in iOS."))
            Text(L("照片左右滑標記保留／待刪；刪除方向可在「一般」調整。", "Swipe photos to keep or mark for deletion; choose the direction in General."))
            Text(L("影片上滑下一部、下滑復原；點一下播放／暫停，左右雙擊快轉／倒退。",
                   "Videos: swipe up for next, down to undo; tap to play/pause, double-tap sides to seek."))
        }
    }
}

struct PhotoAccessStatusView: View {
    @EnvironmentObject private var library: PhotoLibraryStore
    @State private var requesting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if library.authorization == .authorized {
                Label(L("已取得完整照片權限", "Full photo access granted"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("photo-access-full")
            } else {
                Text(library.authorization == .limited
                     ? L("目前只有部分照片權限：只能整理你選取的項目，其他照片不會顯示。", "Limited access: only your selected items can be sorted; other photos are hidden.")
                     : L("ChaiPhoto 用於清理相簿。未開啟照片權限，將無法整理或清理相片。", "ChaiPhoto cleans up your library. Without photo access, it cannot sort or clean up photos."))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("photo-access-warning")
                Button(library.authorization == .notDetermined ? L("開啟照片權限", "Allow photo access") : L("調整照片權限", "Change photo access")) {
                    if library.authorization == .notDetermined {
                        requesting = true
                        Task { await library.requestAccess(); requesting = false }
                    } else {
                        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                    }
                }.buttonStyle(.borderedProminent).disabled(requesting)
                    .accessibilityIdentifier("photo-access-button")
            }
        }
    }
}

struct PreloadPresetPicker: View {
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(L("預載速度", "Preload speed"), selection: Binding(
                get: { settings.preloadPreset }, set: { settings.applyPreloadPreset($0) }
            )) {
                Text(L("關閉", "Off")).tag(PreloadPreset.off)
                Text(L("低速", "Low")).tag(PreloadPreset.economy)
                Text(L("平衡", "Balanced")).tag(PreloadPreset.balanced)
                Text(L("積極", "Aggressive")).tag(PreloadPreset.aggressive)
            }.pickerStyle(.segmented).accessibilityIdentifier("preload-modes")
            Label(description, systemImage: settings.preloadPreset == .off || settings.preloadPreset == .aggressive ? "exclamationmark.triangle" : "info.circle")
                .font(.caption)
                .foregroundStyle(settings.preloadPreset == .off || settings.preloadPreset == .aggressive ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("preload-speed-note")
            Text(L("使用 iCloud 相片時，可提早準備下一張；只用本機可關閉。下載仍需你的允許。",
                   "Prepares upcoming iCloud items. Local-only users can turn it off. Downloads still need your permission."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var description: String {
        switch settings.preloadPreset {
        case .off: return L("停止預載，切換可能要等待；雲端項目逐張／逐部允許下載。", "No preloading; switching may take time. Allow each cloud item individually.")
        case .economy: return L("減少預載，優先省電與省資源。", "Minimal preloading to save battery and resources.")
        case .balanced: return L("依電量與網路自動調整。", "Adapts to battery and network conditions.")
        case .aggressive: return L("最大量、最快預載，較耗電與流量。", "Maximum preloading and speed; uses more battery and data.")
        }
    }
}
