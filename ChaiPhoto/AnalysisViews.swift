import SwiftUI
import Photos

let analysisWarningZH = "快速辨識先讀取拍攝時間、尺寸、類型與相簿關係，再用 Photos 本機已有的 384 px 縮圖與影片封面比較。所有辨識與縮圖預載都禁止網路下載；無本機預覽的項目會略過。影片僅在本機檔案可取得時抽取 5 個小畫面。結果是相似或疑似重複，不代表原檔完全一致，也不會自動刪除。主動開啟完整預覽、播放或分享仍依正常下載權限處理。可隨時停止；離開 App、省電模式或過熱會暫停。"
let analysisWarningEN = "Quick analysis indexes dates, dimensions, types and album membership, then compares existing local 384 px Photos thumbnails and video posters. Analysis and thumbnail preheating never allow network downloads. Items without local previews are skipped. Five small video frames are sampled only from an available local file. Results mean similar or possibly duplicate, not identical originals; nothing is deleted automatically. Opening full previews, playback and sharing use the normal download permissions. You can stop any time; leaving the app, Low Power Mode or excess heat pauses analysis."

struct AnalysisSettingsView: View {
    @EnvironmentObject private var analysis: MediaAnalysis
    @EnvironmentObject private var library: PhotoLibraryStore
    @State private var confirm = false
    @State private var confirmClear = false
    var body: some View {
        Form {
            Section {
                Toggle(L("自動辨識新增與修改項目", "Analyze new and changed items"), isOn: Binding(get: { analysis.enabled }, set: { value in
                    if value { confirm = true } else { analysis.enabled = false }
                }))
                Text(L(analysisWarningZH, analysisWarningEN)).font(.callout).foregroundStyle(.secondary)
            }
            Section(L("進度與涵蓋範圍", "Progress & coverage")) {
                if analysis.running {
                    Text(analysis.phase).font(.callout)
                    ProgressView(value: Double(analysis.processed), total: Double(max(1, analysis.total)))
                    Text(L("已處理 \(analysis.processed)/\(analysis.total) 項", "Processed \(analysis.processed)/\(analysis.total)"))
                    Button(L("停止並保留已完成結果", "Stop and keep partial results")) { analysis.cancel() }
                } else {
                    Button(L("開始／繼續辨識", "Start / resume analysis")) { confirm = true }
                        .disabled(!library.hasAccess || library.isLoading)
                    if !analysis.phase.isEmpty { Text(analysis.phase).font(.caption).foregroundStyle(.secondary) }
                }
                if analysis.hasResults || analysis.running {
                    Text(analysis.coverage)
                    Text(L("本次沿用 \(analysis.reused) 項特徵。沒有候選的項目僅建立中繼資料索引。", "Reused \(analysis.reused) features this scan. Items without candidates are indexed by metadata only."))
                        .font(.caption).foregroundStyle(.secondary)
                    if !analysis.complete { Text(L("部分結果；尚未檢查不等於沒有相似內容。", "Partial results; unchecked items may still have similar content.")).foregroundStyle(.secondary) }
                    if let date = analysis.scannedAt { Text(appDateTime(date)).font(.caption) }
                    if analysis.cloud + analysis.unavailable > 0 {
                        NavigationLink(L("查看無本機預覽項目（\(analysis.cloud + analysis.unavailable)）", "Items without local previews (\(analysis.cloud + analysis.unavailable))")) { AnalysisUnavailableView() }
                    }
                }
                if library.authorization == .limited {
                    Text(L("目前只有部分照片權限，辨識只涵蓋你允許存取的項目。", "Limited photo permission: analysis covers only authorized items.")).foregroundStyle(.orange)
                }
            }
            Section(L("如何判讀結果", "Understanding results")) {
                Text(L("相似照片：以時間、尺寸、類型、連拍或相簿關係縮小候選，再用 Vision 視覺特徵比對；高度相似時再參考縮圖雜湊。沒有比對原始檔案、文字細節或 Live Photo 動態部分。", "Similar photos: time, dimensions, type, burst and album metadata narrow candidates before Vision feature comparison; very close matches also use a thumbnail hash. Originals, fine text and Live Photo motion are not compared."))
                Text(L("疑似重複影片：先比時長、解析度、時間與封面；本機檔案可用時比較 0%、25%、50%、75%、90% 的畫面。封面相似不代表整部影片相同，多幀比對也不是完整內容驗證。", "Possible duplicate videos: duration, resolution, time and poster are compared first. Available local files are sampled at 0%, 25%, 50%, 75% and 90%. Similar posters do not establish matching videos; sampled frames are not a complete content verification."))
                Text(L("長片／高解析度：至少 5 分鐘，或短邊至少 2160 像素。不下載影片量測大小，也不代表一定佔用較大容量。", "Long / high-resolution videos: at least 5 minutes or a shorter edge of at least 2160 pixels. No video is downloaded to measure size; these criteria do not guarantee a large file."))
                Text(L("候選數量與預載批次有上限，因此可能漏掉跨日期、不同類型或距離很遠的相似項目。沒有本機預覽不是故障；有縮圖也不代表原檔在手機。", "Candidate counts and preheat batches are bounded, so distant dates, different types or far-apart matches may be missed. Missing local previews are expected; a thumbnail does not prove the original is local."))
                Text(L("結果位於右上角篩選 → 照片／影片 → App 辨識。手動繼續辨識也會重試先前無預覽的候選；未變動且成功的特徵直接沿用。", "Find results in Filters → Photos / Videos → App analysis. A manual resume also retries candidates without previews; successful unchanged features are reused."))
                Button(L("清除辨識結果", "Clear analysis results"), role: .destructive) { confirmClear = true }
            }
        }
        .navigationTitle(L("App 辨識", "App analysis"))
        .alert(L("啟用本機快速辨識？", "Enable local quick analysis?"), isPresented: $confirm) {
            Button(L("取消", "Cancel"), role: .cancel) {}
            Button(L("開始", "Start")) { analysis.enabled = true; analysis.start(library.assets) }
        } message: { Text(L(analysisWarningZH, analysisWarningEN)) }
        .alert(L("清除辨識結果？", "Clear analysis results?"), isPresented: $confirmClear) {
            Button(L("取消", "Cancel"), role: .cancel) {}
            Button(L("清除", "Clear"), role: .destructive) { analysis.enabled = false; analysis.clear() }
        } message: { Text(L("只清除辨識索引與特徵快取，照片、相簿、待刪標記與操作紀錄都會保留。", "Only the analysis index and feature cache are cleared. Photos, albums, deletion marks and history are preserved.")) }
    }
}

struct AnalysisLifecycle: ViewModifier {
    @EnvironmentObject private var analysis: MediaAnalysis
    @EnvironmentObject private var library: PhotoLibraryStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var phase
    func body(content: Content) -> some View {
        content
            .onChange(of: library.revision) { _, _ in analysis.cancel() }
            .onChange(of: phase) { _, value in if value != .active { analysis.cancel() } }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                if ProcessInfo.processInfo.isLowPowerModeEnabled { analysis.cancel() }
            }
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical { analysis.cancel() }
            }
            .task(id: "\(library.revision)-\(library.isLoading)-\(analysis.enabled)-\(phase == .active)-\(settings.showOnboarding)") {
                guard phase == .active, !settings.showOnboarding else { return }
                guard library.hasAccess, !library.isLoading else { return }
                analysis.synchronize(library.assets)
                guard analysis.enabled, !analysis.running else { return }
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                analysis.start(library.assets, automatic: true)
            }
    }
}

private struct AnalysisUnavailableView: View {
    @EnvironmentObject private var analysis: MediaAnalysis
    @State private var items: [AnalysisMetadata] = []
    var body: some View {
        List(items, id: \.id) { item in
            VStack(alignment: .leading, spacing: 6) {
                Label(item.created.map { appDateTime($0) } ?? L("日期不明", "Unknown date"), systemImage: item.video ? "video" : "photo")
                Text("\(item.width) × \(item.height)").font(.caption).foregroundStyle(.secondary)
                Text(analysis.isCloudUnavailable(item.id)
                     ? L("雲端項目，目前沒有本機預覽可分析", "Cloud item: no local preview available for analysis")
                     : L("目前無本機辨識資料，已略過", "No local analysis data available; skipped"))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 4)
        }
        .navigationTitle(L("無本機預覽", "No local preview"))
        .onAppear { items = analysis.unavailableItems }
    }
}

struct AnalysisComparisonView: View {
    let assets: [PHAsset]
    let evidence: AnalysisEvidence?
    let remaining: Int
    @EnvironmentObject private var library: PhotoLibraryStore
    @EnvironmentObject private var settings: AppSettings
    @State private var preview: PreviewSelection?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(evidence?.label ?? L("相似候選", "Similar candidates")).font(.headline)
                Text(L("這裡只顯示本機縮圖。點開完整預覽／播放時可能依你的設定下載 iCloud 內容；每張仍需自行確認，沒有預先勾選或自動刪除。", "Only local thumbnails appear here. Opening full previews or playback may download iCloud content according to your settings. Review each item; nothing is preselected or automatically deleted."))
                    .font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 16) {
                    ForEach(assets, id: \.localIdentifier) { asset in
                        VStack(spacing: 8) {
                            Button { preview = PreviewSelection(asset: asset) } label: {
                                ZStack(alignment: .bottomTrailing) {
                                    AnalysisGridImage(asset: asset).frame(height: 180)
                                    if asset.mediaType == .video {
                                        Label(L("播放", "Play"), systemImage: "play.circle.fill")
                                            .font(.caption).padding(6).background(.regularMaterial, in: Capsule()).padding(6)
                                    }
                                }.clipShape(RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain)
                            if let date = asset.creationDate { Text(appDateTime(date)).font(.caption).lineLimit(2) }
                            Text("\(asset.pixelWidth) × \(asset.pixelHeight)").font(.caption2).foregroundStyle(.secondary)
                            if let decision = library.decisions[asset.localIdentifier] {
                                Text(decision.label).font(.caption).foregroundStyle(decision == .delete ? .red : .green)
                            } else {
                                ViewThatFits {
                                    HStack { keep(asset); mark(asset) }
                                    VStack { keep(asset); mark(asset) }
                                }
                            }
                        }
                    }
                }
                Text(L("本組尚有 \(remaining) 項未決定", "\(remaining) undecided in this group")).font(.caption)
            }.padding()
        }
        .fullScreenCover(item: $preview) { AssetPreview(asset: $0.asset) }
    }
    private func keep(_ asset: PHAsset) -> some View {
        Button(L("保留", "Keep")) { library.choose(asset, as: .keep); settings.feedback() }.buttonStyle(.bordered)
    }
    private func mark(_ asset: PHAsset) -> some View {
        Button(L("待刪", "Mark"), role: .destructive) { library.choose(asset, as: .delete); settings.feedback() }.buttonStyle(.bordered)
    }
}

private struct AnalysisGridImage: View {
    let asset: PHAsset
    @StateObject private var loader = ThumbnailLoader()
    var body: some View {
        ZStack {
            Color.secondary.opacity(0.08)
            if let image = loader.image { Image(uiImage: image).resizable().scaledToFit() }
            else if loader.loading { ProgressView() }
            else {
                Label(L("無本機預覽", "No local preview"), systemImage: "icloud.slash").font(.caption)
            }
        }
        .task(id: "\(asset.localIdentifier)-\(asset.modificationDate?.timeIntervalSince1970 ?? 0)") {
            loader.load(asset, size: CGSize(width: 384, height: 384), mode: .aspectFit, allowNetwork: false)
        }
        .onDisappear { loader.stop() }
    }
}

struct AnalysisOnboardingControl: View {
    @EnvironmentObject private var analysis: MediaAnalysis
    @State private var confirm = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(L("辨識相似照片與影片（選用）", "Analyze similar photos and videos (optional)"), isOn: Binding(
                get: { analysis.enabled }, set: { if $0 { confirm = true } else { analysis.enabled = false } }
            ))
            Text(L("只用本機縮圖與資料，不下載 iCloud 原檔；可稍後在設定啟用。", "Uses local thumbnails and metadata without downloading iCloud originals. Enable later in Settings if preferred."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .alert(L("啟用本機快速辨識？", "Enable local quick analysis?"), isPresented: $confirm) {
            Button(L("取消", "Cancel"), role: .cancel) {}
            Button(L("啟用", "Enable")) { analysis.enabled = true }
        } message: { Text(L(analysisWarningZH, analysisWarningEN)) }
    }
}
