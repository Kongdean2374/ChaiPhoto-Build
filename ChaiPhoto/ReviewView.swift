import Photos
import SwiftUI

struct ReviewView: View {
    @EnvironmentObject private var library: PhotoLibraryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var updateManager: AppUpdateManager
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var estimator = SizeEstimator()
    @State private var preview: PreviewSelection?
    @State private var restoreTarget: PreviewSelection?
    @State private var deleteSnapshot: Set<String> = []
    @State private var showDeleteConfirmation = false
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
    var body: some View {
        Group {
            if !library.hasAccess { AccessView() }
            else if library.pending.isEmpty {
                ContentUnavailableView(L("沒有待刪項目", "Nothing to delete"), systemImage: "checkmark.shield", description: Text(L("向待刪方向滑動後，項目會出現在這裡。", "Items you mark for deletion will appear here.")))
            } else {
                GeometryReader { geometry in
                    if dynamicTypeSize >= .xxLarge && geometry.size.height < 700 {
                        ScrollView { reviewContent(compact: true) }
                    } else {
                        reviewContent(compact: false)
                    }
                }
            }
        }
        .navigationTitle(L("待刪複查", "Review deletion"))
        .toolbarTitleDisplayMode(.inline)
        .fullScreenCover(item: $preview) { AssetPreview(asset: $0.asset) }
        .confirmationDialog(
            L("如何還原這個項目？", "How would you like to restore this item?"),
            isPresented: Binding(
                get: { restoreTarget != nil },
                set: { if !$0 { restoreTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("回到滑卡重新整理", "Return to swipe sorting")) {
                if let asset = restoreTarget?.asset {
                    library.returnToSorting(asset)
                }
                restoreTarget = nil
            }
            Button(L("直接改為保留", "Mark as kept")) {
                if let asset = restoreTarget?.asset {
                    library.choose(asset, as: .keep)
                }
                restoreTarget = nil
            }
            Button(L("取消", "Cancel"), role: .cancel) {
                restoreTarget = nil
            }
        } message: {
            Text(L(
                "「回到滑卡」會撤銷這張的整理結果；「直接改為保留」則視為已看過並保留，不再出現在滑卡。",
                "Return to swipe sorting clears this item's decision. Mark as kept treats it as already reviewed and keeps it out of the swipe queue."
            ))
        }
        .alert(
            L("確認刪除？", "Confirm deletion?"),
            isPresented: $showDeleteConfirmation
        ) {
            Button(L("取消", "Cancel"), role: .cancel) {
                deleteSnapshot.removeAll()
            }.accessibilityIdentifier("review-cancel-delete")

            Button(
                L("繼續刪除", "Continue deleting"),
                role: .destructive
            ) {
                let snapshot = deleteSnapshot
                deleteSnapshot.removeAll()

                Task {
                    if await library.deleteSelected(snapshot) {
                        settings.successFeedback()
                    }
                }
            }
        } message: {
            Text(L(
                "即將要求 iOS 刪除 \(deleteSnapshot.count) 項。下一步仍會由 iOS 顯示系統確認；一般刪除後會進入「最近刪除」。",
                "The app is about to ask iOS to delete \(deleteSnapshot.count) items. iOS will still show its system confirmation; deleted items normally go to Recently Deleted."
            ))
        }
        .task(id: library.pending.map(\.localIdentifier)) { if settings.autoEstimate { estimator.start(library.pending) } }
        .task(id: showDeleteConfirmation || preview != nil || restoreTarget != nil) {
            updateManager.setPresentationBlocked(showDeleteConfirmation || preview != nil || restoreTarget != nil, reason: "review-modal")
        }
        .onDisappear {
            estimator.stop()
            if !(showDeleteConfirmation || preview != nil || restoreTarget != nil) {
                updateManager.setPresentationBlocked(false, reason: "review-modal")
            }
        }
    }
    private func reviewContent(compact: Bool) -> some View {
                VStack(spacing: 8) {
                    VStack(spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L(
                                    "待刪 \(library.pending.count) 項",
                                    "\(library.pending.count) marked for deletion"
                                ))
                                .font(.headline)

                                Text(L(
                                    "目前選取 \(library.selectedPending.count) 項準備刪除",
                                    "\(library.selectedPending.count) selected for deletion"
                                ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Menu {
                                Button(L("全部選取", "Select all")) {
                                    library.selectAllPending()
                                }

                                Button(L("全部取消選取", "Deselect all")) {
                                    library.excludeAllPending()
                                }
                            } label: {
                                Label(
                                    L("選取", "Select"),
                                    systemImage: "checkmark.circle"
                                )
                                .labelStyle(.iconOnly)
                                .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel(L("選取選項", "Selection options"))
                        }

                        Text(L(
                            "點一下切換是否刪除 · 長按預覽 · 左上 ↶ 可還原",
                            "Tap to include/exclude · Hold to preview · Use ↶ to restore"
                        ))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(14)
                    .modifier(ChaiPanel(tint: .red))
                    .padding(.horizontal, 14)

                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(library.pending, id: \.localIdentifier) { asset in
                                GeometryReader { g in
                                    ZStack(alignment: .bottomTrailing) {
                                        AssetImage(asset: asset, targetSize: g.size).frame(width: g.size.width, height: g.size.height).clipped()
                                        if library.exclusions.contains(asset.localIdentifier) { Color.black.opacity(0.32) }
                                        Image(systemName: library.exclusions.contains(asset.localIdentifier) ? "circle" : "checkmark.circle.fill")
                                            .font(.title3).symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .indigo).padding(7)
                                            .background(.black.opacity(0.15), in: Circle())
                                        if asset.mediaType == .video {
                                            Text(String(format: "%d:%02d", Int(asset.duration) / 60, Int(asset.duration) % 60))
                                                .font(.caption2.bold()).foregroundStyle(.white).padding(5).background(.black.opacity(0.6), in: Capsule())
                                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(5)
                                        }
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 12).strokeBorder(
                                            library.exclusions.contains(asset.localIdentifier) ? Color.clear : ChaiPalette.accent.opacity(0.75), lineWidth: 1.5)
                                    }
                                    .contentShape(Rectangle())
                                    .gesture(LongPressGesture(minimumDuration: 0.35).exclusively(before: TapGesture()).onEnded { result in
                                        switch result {
                                        case .first: preview = PreviewSelection(asset: asset)
                                        case .second: library.toggleExclusion(asset.localIdentifier)
                                        }
                                    })
                                    .accessibilityLabel(L("待刪項目", "Review item"))
                                    .accessibilityValue(library.exclusions.contains(asset.localIdentifier) ? L("未選取", "Not selected") : L("已選取", "Selected"))
                                    .accessibilityAction { library.toggleExclusion(asset.localIdentifier) }
                                    .accessibilityAction(named: L("預覽", "Preview")) { preview = PreviewSelection(asset: asset) }
                                    .overlay(alignment: .topLeading) {
                                        Button {
                                            restoreTarget = PreviewSelection(asset: asset)
                                        } label: {
                                            Image(systemName: "arrow.uturn.backward.circle.fill")
                                                .font(.title3)
                                                .symbolRenderingMode(.palette)
                                                .foregroundStyle(.white, .indigo)
                                                .padding(7)
                                                .background(.black.opacity(0.15), in: Circle())
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(L("還原待刪項目", "Restore pending item"))
                                    }
                                }.aspectRatio(1, contentMode: .fit)
                            }
                        }.padding(.horizontal, 12)
                    }.frame(height: compact ? 180 : nil)
                    footer
                }
    }
    private var footer: some View {
        let ids = library.selectedPending
        let summary = estimator.summary(ids)
        let actionLayout = dynamicTypeSize >= .xxLarge
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L(
                        "準備刪除 \(ids.count) 項",
                        "Ready to delete \(ids.count) items"
                    ))
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                    Text(L(
                        "待刪清單共 \(library.pending.count) 項",
                        "\(library.pending.count) items are marked"
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if estimator.running {
                    Button(L("停止估算", "Stop estimate")) {
                        estimator.stop()
                    }
                    .font(.caption)
                    .fixedSize(horizontal: true, vertical: false)
                } else {
                    Button(L("估算容量", "Estimate size")) {
                        estimator.start(library.pending)
                    }
                    .font(.caption)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                    .foregroundStyle(.secondary)

                Text(
                    L("估計容量：", "Estimated size: ") +
                    byteText(summary.0) +
                    (summary.1 > 0
                        ? L(" ＋ \(summary.1) 項未知", " + \(summary.1) unknown")
                        : "")
                )
                .font(.subheadline)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            }

            if estimator.running {
                ProgressView(
                    value: Double(estimator.progress),
                    total: Double(max(1, library.pending.count))
                )
            }

            Text(L(
                "容量只依目前可讀取的本機資源估算，實際釋放空間可能不同。",
                "Size is estimated from currently readable local resources; actual recovered space may differ."
            ))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            actionLayout {
                Button {
                    estimator.stop()
                    let restored = library.returnToSorting(ids)
                    if restored > 0 {
                        settings.successFeedback()
                    }
                } label: {
                    Label(
                        L("復原 \(ids.count) 項", "Restore \(ids.count) items"),
                        systemImage: "arrow.uturn.backward.circle"
                    )
                    .lineLimit(nil)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .accessibilityIdentifier("review-restore-selected")
                .disabled(ids.isEmpty || library.isDeleting)
                .accessibilityHint(L(
                    "清除所選項目的待刪標記，讓它們重新回到未審整理佇列。",
                    "Clears the pending-deletion decision so the selected items return to the unreviewed sorting queue."
                ))

                Button(role: .destructive) {
                    deleteSnapshot = library.selectedPending
                    estimator.stop()
                    showDeleteConfirmation = !deleteSnapshot.isEmpty
                } label: {
                    Label(
                        L("刪除 \(ids.count) 項", "Delete \(ids.count) items"),
                        systemImage: "trash"
                    )
                    .lineLimit(nil)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .accessibilityIdentifier("review-delete-selected")
                .disabled(ids.isEmpty || library.isDeleting)
            }

            Text(L(
                "綠色會把所選項目移回待審；紅色才會交由 iOS 確認刪除。",
                "Green returns the selected items to the unreviewed queue; red asks iOS to confirm deletion."
            ))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }.padding(14).background(ChaiPalette.surface)
    }
}

struct HistoryView: View {
    @EnvironmentObject private var library: PhotoLibraryStore
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        List {
            NavigationLink { SwipeHistoryView() } label: {
                Label(L("整理操作（\(library.history.count)）", "Sorting actions (\(library.history.count))"), systemImage: "hand.draw")
            }.accessibilityIdentifier("history-sorting")
            NavigationLink { DeletionHistoryView() } label: {
                Label(L("實際刪除（\(library.deletions.count) 批）", "Deleted batches (\(library.deletions.count))"), systemImage: "trash")
            }
        }.navigationTitle(L("操作紀錄", "History"))
    }
}
struct SwipeHistoryView: View {
    @EnvironmentObject private var library: PhotoLibraryStore
    @EnvironmentObject private var settings: AppSettings
    @State private var filter = "all"
    @State private var dateEnabled = false
    @State private var start = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
    @State private var end = Date()
    @State private var showFilter = false
    @State private var previewAction: DecisionAction?
    private var rows: [DecisionAction] {
        let first = Calendar.current.startOfDay(for: start)
        let last = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: end)) ?? end
        return library.history.reversed().filter { action in
            (filter == "all" || (filter == "delete" ? action.after == .delete : action.after != .delete)) && (!dateEnabled || (action.timestamp >= first && action.timestamp < last))
        }
    }
    var body: some View {
        let assets = Dictionary(uniqueKeysWithValues: library.assets.map { ($0.localIdentifier, $0) })
        List(rows) { action in
            HistoryActionRow(action: action, asset: assets[action.assetID],
                             systemDeleted: library.deletedIDs.contains(action.assetID),
                             busy: library.isDeleting || library.isSortingTransition,
                             preview: { previewAction = action },
                             restore: { undo(action) })
        }
        .navigationTitle(L("整理操作", "Sorting actions"))
        .toolbar { Button { showFilter = true } label: { Image(systemName: "line.3.horizontal.decrease.circle") }.accessibilityLabel(L("篩選", "Filter")).accessibilityIdentifier("history-filter") }
        .fullScreenCover(item: $previewAction) { action in
            HistoryActionPreview(actionID: action.id, assetID: action.assetID)
        }
        .sheet(isPresented: $showFilter) {
            NavigationStack {
                Form {
                    Picker(L("動作", "Action"), selection: $filter) {
                        Text(L("全部", "All")).tag("all"); Text(L("待刪", "Delete")).tag("delete"); Text(L("保留", "Keep")).tag("keep")
                    }
                    Toggle(L("限定日期", "Date range"), isOn: $dateEnabled)
                    if dateEnabled { DatePicker(L("開始", "From"), selection: $start, displayedComponents: .date); DatePicker(L("結束", "To"), selection: $end, in: start..., displayedComponents: .date) }
                }.navigationTitle(L("篩選紀錄", "Filter history"))
                    .onChange(of: start) { _, value in if end < value { end = value } }
                    .toolbar { Button(L("完成", "Done")) { showFilter = false }.accessibilityIdentifier("history-filter-done") }
            }
        }
    }

    private func undo(_ action: DecisionAction) {
        library.restore(action)
        if library.history.first(where: { $0.id == action.id })?.undoneAt != nil {
            settings.successFeedback()
        }
    }
}

private struct HistoryActionRow: View {
    let action: DecisionAction
    let asset: PHAsset?
    let systemDeleted: Bool
    let busy: Bool
    let preview: () -> Void
    let restore: () -> Void

    private var status: String {
        if systemDeleted { return L("已系統刪除", "Deleted") }
        if action.undoneAt != nil { return L("已復原", "Undone") }
        if asset == nil { return L("無法存取", "Unavailable") }
        return action.after.label
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: preview) {
                HStack(spacing: 12) {
                    ZStack(alignment: .bottomTrailing) {
                        if let asset {
                            AssetImage(asset: asset, targetSize: CGSize(width: 144, height: 144))
                                .frame(width: 56, height: 56).clipped()
                        } else {
                            Image(systemName: "photo.badge.exclamationmark")
                                .frame(width: 56, height: 56)
                                .background(Color.secondary.opacity(0.12))
                        }
                        Image(systemName: action.after == .delete ? "trash.fill" : "checkmark")
                            .font(.caption2.bold()).foregroundStyle(.white)
                            .padding(4).background(action.after == .delete ? Color.red : Color.green, in: Circle())
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(appDateTime(action.timestamp))
                            .font(.subheadline).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                        Text(action.filename ?? L("未命名項目", "Unnamed item"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(asset == nil)
            .accessibilityLabel(L("預覽", "Preview") + " " + (action.filename ?? action.after.label))

            VStack(spacing: 2) {
                Button(action: restore) {
                    Image(systemName: "arrow.uturn.backward")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .disabled(busy || asset == nil || systemDeleted || action.undoneAt != nil)
                .accessibilityLabel(L("復原此動作", "Undo this action"))
                Text(status).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct HistoryActionPreview: View {
    let actionID: UUID
    let assetID: String
    @EnvironmentObject private var library: PhotoLibraryStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    private var action: DecisionAction? { library.history.first { $0.id == actionID } }
    private var canUndo: Bool {
        action?.undoneAt == nil && action != nil && !library.deletedIDs.contains(assetID)
        && !library.isDeleting && !library.isSortingTransition && library.asset(for: assetID) != nil
    }

    var body: some View {
        Group {
            if let asset = library.asset(for: assetID) {
                AssetPreview(asset: asset)
            } else {
                VStack(spacing: 20) {
                    ContentUnavailableView(L("目前無法存取此項目", "This item is unavailable"), systemImage: "photo.badge.exclamationmark")
                    Button(L("關閉", "Close")) { dismiss() }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                guard let action, canUndo else { return }
                library.restore(action)
                if library.history.first(where: { $0.id == actionID })?.undoneAt != nil {
                    settings.successFeedback()
                }
            } label: {
                Label(action?.undoneAt != nil ? L("已復原", "Undone") : L("復原此動作", "Undo this action"),
                      systemImage: action?.undoneAt != nil ? "checkmark.circle.fill" : "arrow.uturn.backward")
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canUndo)
            .padding().background(.regularMaterial)
        }
    }
}
struct DeletionHistoryView: View {
    @EnvironmentObject private var library: PhotoLibraryStore
    @EnvironmentObject private var settings: AppSettings
    @State private var showFilter = false
    @State private var dateEnabled = false
    @State private var start = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
    @State private var end = Date()
    private var rows: [DeletionRecord] {
        library.deletions.reversed().filter { record in
            !dateEnabled || (record.date >= Calendar.current.startOfDay(for: start) && record.date < (Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: end)) ?? end))
        }
    }
    var body: some View {
        List(rows) { record in
            NavigationLink {
                List {
                    Section { Text(L("已交給 iOS 刪除。復原請查看系統相簿的「最近刪除」，是否能復原由系統決定。", "Deleted by iOS. Check Recently Deleted in Photos for recovery, subject to system availability.")) }
                    Section(L("項目名稱", "Item names")) { ForEach(Array(record.names.enumerated()), id: \.offset) { _, name in Text(name) } }
                }.navigationTitle(L("刪除明細", "Deleted items"))
            } label: {
                HStack { Text(appDateTime(record.date)); Spacer(); Text(L("\(record.names.count) 項", "\(record.names.count) items")) }
            }
        }.navigationTitle(L("實際刪除", "Deleted batches"))
        .toolbar { Button { showFilter = true } label: { Image(systemName: "line.3.horizontal.decrease.circle") } }
        .sheet(isPresented: $showFilter) {
            NavigationStack {
                Form {
                    Toggle(L("限定日期", "Date range"), isOn: $dateEnabled)
                    if dateEnabled {
                        DatePicker(L("開始", "From"), selection: $start, displayedComponents: .date)
                        DatePicker(L("結束", "To"), selection: $end, in: start..., displayedComponents: .date)
                    }
                }.navigationTitle(L("篩選紀錄", "Filter history"))
                    .onChange(of: start) { _, value in if end < value { end = value } }
                    .toolbar { Button(L("完成", "Done")) { showFilter = false }.accessibilityIdentifier("history-filter-done") }
            }
        }
    }
}

