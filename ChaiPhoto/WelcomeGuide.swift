import Photos
import SwiftUI

struct WelcomeGuide: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: PhotoLibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var page: Int
    @State private var requestingAccess = false
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
                    Text(L("步驟 \(page + 1)／5", "Step \(page + 1) of 5"))
                        .font(.caption).foregroundStyle(.secondary)
                    pageContent
                }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 20) {
                    if page > 0 { Button(L("上一步", "Back")) { page -= 1 } }
                    Spacer()
                    Button(page == 4 ? L("完成", "Finish") : L("下一步", "Next")) {
                        if page < 4 { page += 1 }
                        else {
                            if !reviewing { OnboardingPolicy.complete(.standard) }
                            finished()
                            dismiss()
                        }
                    }.buttonStyle(.borderedProminent).disabled(requestingAccess)
                }.padding().background(.regularMaterial)
            }
            .navigationTitle(L("首次使用設定", "Getting started"))
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
            Image(systemName: "checkmark.shield.fill").font(.largeTitle).foregroundStyle(.indigo)
            Text(L("歡迎使用 ChaiPhoto", "Welcome to ChaiPhoto")).font(.title.bold())
            Text(L("滑動只做標記，不會立即刪除。請在「待刪」複查，再經 App 與 iOS 二次確認後才會真正刪除。",
                   "Swiping only marks items. Review them in Review; actual deletion requires confirmation in the app and again in iOS."))
            Text(L("接下來可設定相簿權限、iCloud 下載與預載。只有你自行修改的選項才會儲存。",
                   "Choose photo access, iCloud downloads and preloading. Only preferences you change are saved."))
        case 1:
            Text(L("選擇相簿權限", "Choose photo access")).font(.title.bold())
            Text(L("完整權限可整理整個相簿；受限權限只能整理你挑選的項目。拒絕後仍可完成設定，再到系統設定調整。",
                   "Full access lets you sort your library; limited access only includes items you select. You can finish setup after declining and change access in Settings."))
            Text(accessDescription).foregroundStyle(.secondary)
            if library.authorization == .notDetermined {
                Button(L("選擇照片存取權限", "Choose photo access")) {
                    requestingAccess = true
                    Task { await library.requestAccess(); requestingAccess = false }
                }.buttonStyle(.borderedProminent).disabled(requestingAccess)
            } else {
                Button(L("開啟系統設定", "Open system Settings")) {
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                }.buttonStyle(.bordered)
            }
            Text(L("未授權時，整理頁會保留權限入口，不會讀取尚未授權的照片。",
                   "Without access, the Sort tab provides a permission entry and cannot read unauthorized photos."))
                .font(.caption).foregroundStyle(.secondary)
        case 2:
            Text(L("iCloud 下載", "iCloud downloads")).font(.title.bold())
            Toggle(L("照片始終允許下載", "Always allow photo downloads"), isOn: $settings.allowCloudPhoto)
            Toggle(L("影片始終允許下載", "Always allow video downloads"), isOn: $settings.allowCloudVideo)
            Text(L("關閉表示需要時詢問，可選擇本次允許或拒絕。本機內容及可讀取的縮圖優先；預載強度不會代替下載同意。下載可能使用行動數據。",
                   "When off, ask when needed: allow this session or decline. Local content and available thumbnails come first. Preload intensity never grants download permission. Downloads may use cellular data."))
        case 3:
            Text(L("預載效能", "Preload performance")).font(.title.bold())
            PreloadPresetPicker()
            Text(L("平衡為新安裝預設：照片 3 張、影片 2 部。省流量減少額外預載；積極預載會提早準備更多內容及較大縮圖，增加電量與暫存空間。",
                   "New installs default to Balanced: 3 photos and 2 videos. Data saver reduces preloading; Aggressive prepares more items and larger thumbnails, using more battery and cache."))
            Text(L("三種模式皆須分別取得照片／影片下載允許；這不是網速限速器。進階數量仍可在設定調整。",
                   "All modes require separate photo/video download permission. This is not a bandwidth limiter. Advanced counts remain available in Settings."))
        default:
            Text(L("基本操作", "Basic gestures")).font(.title.bold())
            Picker(L("照片刪除方向", "Photo delete direction"), selection: $settings.deleteOnRight) {
                Text(L("左滑待刪", "Swipe left to delete")).tag(false)
                Text(L("右滑待刪", "Swipe right to delete")).tag(true)
            }.pickerStyle(.segmented)
            Text(L("照片：另一方向保留，上滑選相簿，中央雙擊切換喜好。點一下或長按預覽，雙指縮放。",
                   "Photos: swipe the other way to keep, swipe up for albums, double-tap the center for Favorite. Tap or hold to preview and pinch to zoom."))
            Text(L("影片：上滑保留並前進，下滑復原。點一下播放／暫停；左右雙擊倒退／快進 10 秒；中央雙擊切換喜好。",
                   "Videos: swipe up to keep and advance, down to undo. Tap to play/pause; double-tap left/right to seek 10 seconds, or center for Favorite."))
            Text(L("待刪頁可還原標記，真正刪除仍需二次確認。設定頁可隨時重新檢視導覽，不會重設偏好。",
                   "Restore marks in Review; deletion still requires two confirmations. Revisit this guide from Settings without resetting preferences."))
        }
    }

    private var accessDescription: String {
        switch library.authorization {
        case .authorized: return L("目前：完整存取", "Current access: full")
        case .limited: return L("目前：受限存取", "Current access: limited")
        case .denied, .restricted: return L("目前：未授權", "Current access: not allowed")
        default: return L("目前：尚未選擇", "Current access: not selected")
        }
    }
}

struct PreloadPresetPicker: View {
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        Picker(L("預載模式", "Preload mode"), selection: Binding(
            get: { settings.preloadPreset }, set: { settings.applyPreloadPreset($0) }
        )) {
            Text(L("省流量", "Data saver")).tag(PreloadPreset.economy)
            Text(L("平衡（推薦）", "Balanced (recommended)")).tag(PreloadPreset.balanced)
            Text(L("積極預載", "Aggressive")).tag(PreloadPreset.aggressive)
            if settings.preloadPreset == .custom { Text(L("自訂", "Custom")).tag(PreloadPreset.custom) }
        }
    }
}
