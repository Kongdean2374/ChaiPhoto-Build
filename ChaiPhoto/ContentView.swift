import Photos
import SwiftUI

struct PreviewSelection: Identifiable {
    let asset: PHAsset
    var id: String { asset.localIdentifier }
}

struct ContentView: View {
    @EnvironmentObject private var library: PhotoLibraryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var updateManager: AppUpdateManager
    @Environment(\.scenePhase) private var scenePhase
    // Old selectedTab.v1 is deliberately ignored, without deleting saved progress.
    @State private var selectedTab = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presentationBlocked: Bool {
        settings.showOnboarding || settings.reviewingOnboarding || scenePhase != .active || library.isDeleting ||
        library.message != nil || settings.showCloudPhotoPrompt
    }

    var body: some View {
        Group {
            if settings.showOnboarding {
                WelcomeGuide {
                    selectedTab = 0
                    settings.showOnboarding = false
                }
            } else {
                TabView(selection: $selectedTab) {
                    NavigationStack { SortView() }
                        .tabItem { Label(L("整理", "Sort"), systemImage: "rectangle.stack.fill") }.tag(0)
                    NavigationStack { ReviewView() }
                        .tabItem { Label(L("待刪", "Review"), systemImage: "trash") }
                        .badge(library.pending.count).tag(1)
                    NavigationStack { SettingsView() }
                        .tabItem { Label(L("設定", "Settings"), systemImage: "gearshape.fill") }.tag(2)
                }
            }
        }
        .overlay(alignment: .top) {
            if !settings.showOnboarding, let notice = library.successNotice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.callout).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .padding().lineLimit(4).allowsHitTesting(false)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .overlay(alignment: .top) {
            if !presentationBlocked && updateManager.showPrompt { AppUpdateBanner() }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: updateManager.showPrompt)
        .task(id: library.successNotice) {
            guard library.successNotice != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            library.successNotice = nil
        }
        .task(id: presentationBlocked) {
            updateManager.setPresentationBlocked(presentationBlocked, reason: "root")
        }
        .task(id: settings.showOnboarding) {
            guard !settings.showOnboarding else { return }
            updateManager.setPresentationBlocked(presentationBlocked, reason: "root")
            await updateManager.checkAutomaticallyOnce()
        }
        .tint(.indigo)
        .disabled(library.isDeleting)
        .alert(L("提醒", "Notice"), isPresented: Binding(
            get: { !settings.showOnboarding && !settings.reviewingOnboarding && !settings.showCloudPhotoPrompt && library.message != nil },
            set: { if !$0 { library.message = nil } }
        )) {
            Button(L("好", "OK")) { library.message = nil }
        } message: { Text(library.message ?? "") }
        .alert(L("允許載入 iCloud 照片？", "Allow iCloud photo downloads?"), isPresented: Binding(
            get: { !settings.showOnboarding && !settings.reviewingOnboarding && scenePhase == .active && !settings.cloudPhotoPromptInPreview && settings.showCloudPhotoPrompt },
            set: { settings.showCloudPhotoPrompt = $0 }
        )) {
            Button(L("暫不載入", "Not now"), role: .cancel) { settings.declineCloudPhotosForNow() }
            if settings.preloadPreset == .off {
                Button(L("只下載這張", "Download this photo")) { settings.allowCloudPhotoItem() }
            } else {
                Button(L("本次允許", "Allow this session")) { settings.allowCloudPhotosThisSession() }
                Button(L("始終允許", "Always allow")) { settings.allowCloudPhoto = true }
            }
        } message: {
            Text(settings.preloadPreset == .off
                 ? L("只下載這張照片。可到設定更改預載模式。", "Download this photo only. Change preloading in Settings.")
                 : L("允許此期間下載 iCloud 照片，可能使用行動數據。可到設定更改預載模式。", "Allow iCloud photos this session; cellular data may be used. Change preloading in Settings."))
        }
    }
}

struct AccessView: View {
    @EnvironmentObject private var library: PhotoLibraryStore
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.stack").font(.largeTitle).foregroundStyle(.indigo)
            PhotoAccessStatusView()
        }.padding(24)
    }
}

struct SortView: View {
    @EnvironmentObject private var library: PhotoLibraryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var mediaPreloader: MediaPreloader
    @EnvironmentObject private var updateManager: AppUpdateManager
    @Environment(\.scenePhase) private var scenePhase

    @State private var filter = MediaFilter.restored()
    @State private var showFilter = false
    @State private var preview: PreviewSelection?
    @State private var info: PreviewSelection?
    @State private var albumTarget: PreviewSelection?
    @State private var share: ShareFile?
    @State private var shareURL: URL?
    @State private var shareTask: Task<Void, Never>?
    @State private var shareGeneration = UUID()
    @State private var preparingShare = false
    @State private var tutorialKind: MediaTutorialKind?
    @State private var completion: SortCompletion?
    @State private var sessionIDs: Set<String> = []
    @State private var sessionFilter: MediaFilter?
    @State private var resumeAssetID: String?

    @State private var summary = SortingSummaryCache()

    private var snapshot: SortingSummaryCache {
        summary.update(library: library, filter: filter)
        return summary
    }
    private var scope: [PHAsset] { snapshot.scope }

    /// The decision flag on each PHAsset remains the source of truth. This cursor
    /// only decides where a saved photo scope resumes, so reviewing one month can
    /// never imply that another month was already reviewed.
    private var queue: [PHAsset] {
        snapshot.orderedQueue(resumeID: resumeAssetID, priorityIDs: library.reopenedIDs)
    }

    private var currentAsset: PHAsset? { queue.first }
    private var keptCount: Int { snapshot.kept }
    private var deletedCount: Int { snapshot.deleted }
    private var sortedCount: Int { max(0, scope.count - queue.count) }
    private var sortingProgress: Double {
        guard !scope.isEmpty else { return 0 }
        return Double(sortedCount) / Double(scope.count)
    }

    private var preloadScanCount: Int {
        max(
            12,
            (settings.effectivePreload.photos + settings.effectivePreload.videos) * 4
        )
    }

    private var preloadTaskKey: String {
        let ids = queue
            .prefix(preloadScanCount + 1)
            .map(\.localIdentifier)
            .joined(separator: "|")

        let counts =
            "pc:\(settings.effectivePreload.photos)|vc:\(settings.effectivePreload.videos)"
        let modes =
            "fast:\(settings.effectivePreload.fullSpeed)" +
            "|pn:\(settings.canPreloadPhotoNetwork)" +
            "|vn:\(settings.canPreloadVideoNetwork)"

        return ids + "|" + counts + "|" + modes + "|r:\(library.revision)|active:\(scenePhase == .active)"
    }

    private var preloadCandidates: [PHAsset] {
        Array(
            queue
                .dropFirst()
                .prefix(preloadScanCount)
        )
    }

    private var presentedContent: some View {
        sortRoot
            .background(
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()
            )
            .navigationTitle(L("整理", "Sort"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                Button {
                    showFilter = true
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.title3)
                }
                .accessibilityLabel(L("篩選", "Filters"))
                .disabled(!library.hasAccess)
            }
            .sheet(item: $completion) { result in
                SortCompletionView(result: result, nextMonth: filter.timeMode == "month" ? Calendar.current.date(byAdding: .month, value: 1, to: filter.start) : nil,
                    onNext: { next in
                        completion = nil
                        filter.setMonth(next); filter.resolve(); filter.persist()
                    }, onOther: {
                        completion = nil
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(350))
                            showFilter = true
                        }
                    })
            }
            .sheet(isPresented: $showFilter) {
                FilterView(filter: $filter)
            }
            .fullScreenCover(item: $preview) {
                AssetPreview(asset: $0.asset)
            }
            .fullScreenCover(item: $albumTarget) { selection in
                AlbumPickerView(
                    asset: selection.asset,
                    protectedAlbumID:
                        filter.source == "album" ? filter.albumID : nil,
                    protectedAlbumName:
                        filter.source == "album" ? filter.albumName : nil,
                    onRemovedFromProtectedAlbum: {
                        settings.feedback()
                        filter.allowedIDs?.remove(
                            selection.asset.localIdentifier
                        )
                    }
                ) { changed in
                    if changed && settings.advanceAfterAlbumAction {
                        choosePhoto(selection.asset, as: .keep)
                    }
                }
            }
            .sheet(item: $info) {
                MediaInfoView(asset: $0.asset)
            }
            .sheet(item: $share, onDismiss: cleanupShare) {
                SystemShareView(url: $0.url)
            }
            .overlay {
                tutorialOverlay
            }
    }

    var body: some View {
        presentedContent
            .onAppear {
                filter.resolve()
                resumeAssetID = filter.restoredResumeAssetID()
                sessionFilter = filter
                sessionIDs = Set(scope.map(\.localIdentifier))
                presentTutorialIfNeeded(for: currentAsset)
            }
            .onChange(of: filter) { _, value in
                resumeAssetID = value.restoredResumeAssetID()
                sessionFilter = value
                sessionIDs = Set(scope.map(\.localIdentifier))
                completion = nil
            }
            .onChange(of: queue.count) { old, new in
                if old > 0 && new == 0 && !scope.isEmpty && sessionFilter == filter && !library.isLoading {
                    completion = makeCompletion()
                }
            }
            .onChange(of: currentAsset?.localIdentifier) { _, newID in
                // A capture/restored card temporarily sits ahead of the normal
                // cursor. Showing it must not overwrite where sorting resumes.
                let isPriorityItem = newID.map { library.reopenedIDs.contains($0) } ?? false
                if !library.isLoading && library.hasAccess && !isPriorityItem {
                    resumeAssetID = newID
                    filter.persistResumeAssetID(newID)
                }
                presentTutorialIfNeeded(for: currentAsset)
            }
            .onChange(of: currentAsset?.localIdentifier) { _, _ in cancelPhotoShare() }
            .onChange(of: library.revision) { _, _ in
                filter.resolve()
                sessionIDs.formUnion(scope.map(\.localIdentifier))
            }
            .onDisappear {
                if !(showFilter || preview != nil || albumTarget != nil || info != nil || share != nil || completion != nil || tutorialKind != nil) {
                    updateManager.setPresentationBlocked(false, reason: "sort-modal")
                }
                mediaPreloader.clear()
                cancelPhotoShare()
            }
            .task(id: showFilter || preview != nil || albumTarget != nil || info != nil || share != nil || completion != nil || tutorialKind != nil) {
                updateManager.setPresentationBlocked(showFilter || preview != nil || albumTarget != nil || info != nil || share != nil || completion != nil || tutorialKind != nil, reason: "sort-modal")
            }
    }

    @ViewBuilder
    private var sortRoot: some View {
        if !library.hasAccess {
            AccessView()
        } else if library.isLoading && library.assets.isEmpty {
            ProgressView(L("載入中…", "Loading…"))
        } else {
            sortingContent
        }
    }

    private var sortingContent: some View {
        VStack(spacing: 6) {
            statsRow

            if library.authorization == .limited {
                limitedAccessRow
            }

            currentMediaSection
        }
        .padding(.top, 2)
        .task(id: preloadTaskKey) {
            guard scenePhase == .active else { mediaPreloader.clear(); return }
            mediaPreloader.prepareNext(
                preloadCandidates,
                keepingCurrentID: currentAsset?.localIdentifier,
                photoCount: settings.effectivePreload.photos,
                videoCount: settings.effectivePreload.videos,
                fullSpeed: settings.effectivePreload.fullSpeed,
                allowPhotoNetwork: settings.canPreloadPhotoNetwork,
                allowVideoNetwork: settings.canPreloadVideoNetwork
            )
        }
    }

    private var statsRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(filter.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    Text(filter.timeTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(L("\(queue.count) 未看", "\(queue.count) unseen"))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.indigo)
            }

            ProgressView(value: sortingProgress)
                .tint(.indigo)
                .controlSize(.small)

            HStack(spacing: 12) {
                compactStat(L("待刪", "Marked"), deletedCount, tint: .red)
                compactStat(L("保留", "Kept"), keptCount, tint: .green)

                Spacer(minLength: 4)

                Text("\(sortedCount) / \(scope.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            LinearGradient(colors: [Color.indigo.opacity(0.14), Color(uiColor: .secondarySystemBackground)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .padding(.horizontal, 10)
    }

    private var limitedAccessRow: some View {
        PhotoAccessStatusView().font(.caption).padding(.horizontal, 16)
    }

    @ViewBuilder
    private var currentMediaSection: some View {
        if let current = currentAsset {
            if current.mediaType == .video {
                videoSection(current)
            } else {
                photoSection(current)
            }
        } else {
            VStack(spacing: 16) {
                ContentUnavailableView(
                    scope.isEmpty ? L("此範圍沒有可整理項目", "No items in this selection") : L("這個範圍整理完了", "This selection is complete"),
                    systemImage: scope.isEmpty ? "photo.on.rectangle" : "checkmark.seal",
                    description: Text(filter.title + " · " + filter.timeTitle))
                if !scope.isEmpty || !sessionIDs.isEmpty {
                    Button(L("查看整理小結", "View summary")) { completion = makeCompletion() }.buttonStyle(.borderedProminent)
                }
                Button(L("更改篩選", "Change filters")) { showFilter = true }
            }.frame(maxHeight: .infinity)
        }
    }

    private func makeCompletion() -> SortCompletion {
        let ids = sessionIDs.union(scope.map(\.localIdentifier))
        let deleted = library.deletedIDs.intersection(ids).count
        let marked = ids.filter { library.decisions[$0] == .delete }.count
        let kept = ids.filter { library.decisions[$0] == .keep || library.decisions[$0] == .favorite }.count
        return SortCompletion(title: filter.title, time: filter.timeTitle, total: ids.count, kept: kept, marked: marked, deleted: deleted)
    }

    private func videoSection(_ current: PHAsset) -> some View {
        VideoFeedView(
            asset: current,
            currentAlbumID:
                filter.source == "album" ? filter.albumID : nil,
            currentAlbumName:
                filter.source == "album" ? filter.albumName : nil,
            onRemovedFromCurrentAlbum: {
                filter.allowedIDs?.remove(current.localIdentifier)
            },
            onPrevious: {
                let ids = Set(scope.filter { $0.mediaType == .video && $0.localIdentifier != current.localIdentifier }.map(\.localIdentifier))
                library.undo(in: ids)
            }
        )
        .id(current.localIdentifier)
    }

    private func photoSection(_ current: PHAsset) -> some View {
        VStack(spacing: 4) {
            PhotoCard(
                asset: current,
                onPreview: {
                    preview = PreviewSelection(asset: current)
                },
                onInfo: {
                    info = PreviewSelection(asset: current)
                },
                onAddToAlbum: {
                    albumTarget = PreviewSelection(asset: current)
                }
            ) { decision in
                choosePhoto(current, as: decision)
            }
            .id(current.localIdentifier)

            photoActionRow(current)
        }
    }

    private func photoActionRow(_ current: PHAsset) -> some View {
        HStack {
            roundAction(
                settings.deleteOnRight ? .keep : .delete,
                left: true,
                asset: current
            )

            Spacer()

            Button {
                sharePhoto(current)
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.title3)
                        .frame(width: 44, height: 44)

                    Text(
                        preparingShare
                            ? L("準備中", "Preparing")
                            : L("分享", "Share")
                    )
                    .font(.caption2)
                }
            }
            .disabled(preparingShare)

            Button {
                let visibleIDs = Set(scope.map(\.localIdentifier))
                if library.undo(in: visibleIDs) != nil {
                    // The restored item enters library.reopenedIDs and is
                    // presented first. Keep the normal resume cursor where it was
                    // so, after re-reviewing it, sorting continues correctly.
                    settings.feedback()
                }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.title3)
                        .frame(width: 44, height: 44)

                    Text(L("復原", "Undo"))
                        .font(.caption2)
                }
            }
            .disabled(!canUndo)

            Spacer()

            roundAction(
                settings.deleteOnRight ? .delete : .keep,
                left: false,
                asset: current
            )
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func choosePhoto(
        _ asset: PHAsset,
        as decision: PhotoDecision
    ) {
        let retryingRestoredItem =
            library.reopenedIDs.contains(asset.localIdentifier)

        let nextID: String?
        if let index = queue.firstIndex(where: {
            $0.localIdentifier == asset.localIdentifier
        }), queue.indices.contains(index + 1) {
            nextID = queue[index + 1].localIdentifier
        } else {
            nextID = nil
        }

        // Retry cards are temporarily inserted ahead of the normal cursor.
        // Reviewing them must not move that normal cursor, otherwise the app
        // forgets where it was before the batch restore.
        if !retryingRestoredItem {
            resumeAssetID = nextID
            filter.persistResumeAssetID(nextID)
        }

        mediaPreloader.cancel(assetID: asset.localIdentifier)
        settings.feedback()
        library.choose(asset, as: decision)
    }

    private var canUndo: Bool {
        let visibleIDs = Set(scope.map(\.localIdentifier))
        return library.history.contains {
            $0.undoneAt == nil &&
            !library.deletedIDs.contains($0.assetID) &&
            visibleIDs.contains($0.assetID)
        }
    }

    @ViewBuilder
    private var tutorialOverlay: some View {
        if let tutorialKind {
            InteractionTutorialView(
                kind: tutorialKind,
                deleteOnRight: settings.deleteOnRight
            ) {
                markTutorialSeen(tutorialKind)
                withAnimation(.easeInOut(duration: 0.18)) {
                    self.tutorialKind = nil
                }
            }
            .zIndex(100)
        }
    }

    private func compactStat(
        _ title: String,
        _ number: Int,
        tint: Color
    ) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)

            Text("\(title) \(number)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func roundAction(
        _ decision: PhotoDecision,
        left: Bool,
        asset: PHAsset
    ) -> some View {
        Button {
            choosePhoto(asset, as: decision)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: decision == .delete ? "trash" : "checkmark")
                    .font(.title3.bold())
                    .frame(width: 52, height: 52)
                    .background(
                        (decision == .delete ? Color.red : .green).opacity(0.13),
                        in: Circle()
                    )

                Text(
                    (left ? "← " : "") +
                    (decision == .delete ? L("待刪", "Delete") : L("保留", "Keep")) +
                    (left ? "" : " →")
                )
                .font(.caption2)
            }
            .foregroundStyle(decision == .delete ? .red : .green)
        }
    }

    private func sharePhoto(_ asset: PHAsset) {
        guard !preparingShare else { return }
        preparingShare = true
        let generation = UUID()
        shareGeneration = generation
        shareTask = Task {
            do {
                let url = try await preparePhotoShare(asset, allowNetwork: settings.canDownloadPhoto(for: asset.localIdentifier))
                guard !Task.isCancelled, generation == shareGeneration else {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                    return
                }
                shareURL = url
                share = ShareFile(url: url)
            } catch {
                guard !Task.isCancelled, generation == shareGeneration else { return }
                library.message = L("無法分享：", "Could not share: ") + error.localizedDescription
            }
            if generation == shareGeneration { preparingShare = false; shareTask = nil }
        }
    }

    private func cancelPhotoShare() {
        shareGeneration = UUID()
        shareTask?.cancel()
        shareTask = nil
        preparingShare = false
    }

    private func cleanupShare() {
        if let shareURL {
            try? FileManager.default.removeItem(
                at: shareURL.deletingLastPathComponent()
            )
        }

        shareURL = nil
    }

    private func presentTutorialIfNeeded(for asset: PHAsset?) {
        guard UserDefaults.standard.bool(forKey: "welcome.v1.2"), tutorialKind == nil, let asset else { return }

        let kind: MediaTutorialKind = asset.mediaType == .video ? .video : .photo
        let key = kind == .photo
            ? "tutorial.photo.interactions.v2"
            : "tutorial.video.interactions.v2"

        guard !UserDefaults.standard.bool(forKey: key) else { return }

        withAnimation(.easeInOut(duration: 0.18)) {
            tutorialKind = kind
        }
    }

    private func markTutorialSeen(_ kind: MediaTutorialKind) {
        let key = kind == .photo
            ? "tutorial.photo.interactions.v2"
            : "tutorial.video.interactions.v2"
        UserDefaults.standard.set(true, forKey: key)
    }
}

extension PhotoGroup {
    var title: String {
        switch self {
        case .all: return L("全部照片", "All photos")
        case .photos: return L("照片", "Photos")
        case .videos: return L("影片", "Videos")
        case .screenshots: return L("截圖", "Screenshots")
        case .live: return "Live Photo"
        }
    }
}

private struct PhotoCard: View {
    let asset: PHAsset
    let onPreview: () -> Void
    let onInfo: () -> Void
    let onAddToAlbum: () -> Void
    let onDecision: (PhotoDecision) -> Void

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: PhotoLibraryStore
    @EnvironmentObject private var updateManager: AppUpdateManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var cachedSummaryLine = ""
    @State private var offset: CGSize = .zero
    @State private var leaving = false
    @State private var favoriteWorking = false
    @State private var systemFavorite = false
    @State private var favoriteFeedback: Bool?
    @State private var favoriteFeedbackToken = UUID()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(cachedSummaryLine)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .foregroundStyle(.secondary)

                Spacer()

                if abs(offset.width) > 25 {
                    Text(isDelete(offset.width) ? L("待刪", "Delete") : L("保留", "Keep"))
                        .font(.caption.bold())
                        .foregroundStyle(isDelete(offset.width) ? .red : .green)
                } else if offset.height < -25 {
                    Label(
                        L("加入相簿", "Add to albums"),
                        systemImage: "rectangle.stack.badge.plus"
                    )
                    .font(.caption.bold())
                    .foregroundStyle(.indigo)
                }

                Button(action: onInfo) {
                    Image(systemName: "info.circle")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(L("照片資訊", "Photo information"))
            }
            .padding(.leading, 8)
            .padding(.trailing, 2)

            ZStack {
                FramedPhoto(asset: asset)

                PhotoGestureSurface(
                    onSingleTap: onPreview,
                    onDoubleTapCenter: toggleFavorite,
                    onLongPress: onPreview,
                    onDragChanged: handleDrag,
                    onSwipeLeft: { commitHorizontal(-1) },
                    onSwipeRight: { commitHorizontal(1) },
                    onSwipeUp: {
                        resetOffset()
                        onAddToAlbum()
                    },
                    onCancelDrag: resetOffset
                )

                if let favoriteFeedback {
                    VStack(spacing: 8) {
                        Image(systemName: favoriteFeedback ? "heart.fill" : "heart.slash.fill")
                            .font(.system(size: 54))
                            .foregroundStyle(favoriteFeedback ? .pink : .white)

                        Text(
                            favoriteFeedback
                                ? L("已加入喜好項目", "Added to Favorites")
                                : L("已取消喜好項目", "Removed from Favorites")
                        )
                        .font(.callout.bold())
                        .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .allowsHitTesting(false)
                }
            }
        }
        .offset(offset)
        .rotationEffect(.degrees(reduceMotion ? 0 : Double(offset.width / 45)))
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.18),
            value: favoriteFeedback
        )
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: L("保留照片", "Keep photo")) {
            commitHorizontal(settings.deleteOnRight ? -1 : 1)
        }
        .accessibilityAction(named: L("標記待刪", "Mark for deletion")) {
            commitHorizontal(settings.deleteOnRight ? 1 : -1)
        }
        .accessibilityAction(named: L("加入相簿", "Add to album")) {
            resetOffset()
            onAddToAlbum()
        }
        .accessibilityAction(named: L("預覽照片", "Preview photo")) {
            onPreview()
        }
        .onAppear {
            systemFavorite = asset.isFavorite
            cachedSummaryLine = photoSummaryLine
        }
        .onChange(of: settings.language) { _, _ in cachedSummaryLine = photoSummaryLine }
        .onChange(of: asset.isFavorite) { _, value in systemFavorite = value }
        .onDisappear {
            updateManager.setSortingInteractionActive(false)
            library.setSortingInteraction(false, assetID: asset.localIdentifier)
            library.cancelTransition(for: asset.localIdentifier)
        }
    }

    private var photoSummaryLine: String {
        let dateText: String

        if let date = asset.creationDate {
            let formatter = DateFormatter()
            if UserDefaults.standard.string(forKey: "language") == "en" {
                formatter.locale = Locale(identifier: "en_US")
                formatter.dateFormat = "MMM d, yyyy"
            } else {
                formatter.locale = Locale(identifier: "zh_Hant_TW")
                formatter.dateFormat = "yyyy年M月d日"
            }
            dateText = formatter.string(from: date)
        } else {
            dateText = L("日期不明", "Unknown date")
        }

        let resolution = "\(asset.pixelWidth)×\(asset.pixelHeight)"
        return "\(dateText) · \(resolution) · \(photoTypeLabel)"
    }

    private var photoTypeLabel: String {
        if asset.mediaSubtypes.contains(.photoScreenshot) {
            return L("截圖", "Screenshot")
        }
        if asset.mediaSubtypes.contains(.photoLive) {
            return "Live Photo"
        }
        if asset.mediaSubtypes.contains(.photoPanorama) {
            return L("全景", "Panorama")
        }
        if !(asset.burstIdentifier ?? "").isEmpty {
            return L("連拍", "Burst")
        }
        return L("照片", "Photo")
    }

    private func handleDrag(_ translation: CGSize) {
        guard !leaving else { return }
        updateManager.setSortingInteractionActive(true)
        library.setSortingInteraction(true, assetID: asset.localIdentifier)

        var transaction = Transaction()
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            if abs(translation.width) >= abs(translation.height) {
                let width = UIScreen.main.bounds.width
                let freeRange = max(180, width * 0.72)
                let rawX = translation.width
                let sign: CGFloat = rawX < 0 ? -1 : 1
                let magnitude = abs(rawX)

                let x: CGFloat
                if magnitude <= freeRange {
                    x = rawX
                } else {
                    // Keep following the finger past the normal range, but add
                    // gentle resistance instead of a hard stop.
                    let extra = (magnitude - freeRange) * 0.22
                    x = sign * (freeRange + extra)
                }

                offset = CGSize(width: x, height: 0)
            } else if translation.height < 0 {
                // Only give a small rubber-band hint for the album gesture.
                // The photo itself should stay visually anchored.
                let y = max(translation.height * 0.12, -28)
                offset = CGSize(width: 0, height: y)
            } else {
                offset = CGSize(width: 0, height: min(translation.height * 0.06, 12))
            }
        }
    }

    private func commitHorizontal(_ direction: CGFloat) {
        guard !leaving, let token = library.beginTransition(for: asset) else { return }
        leaving = true

        let decision: PhotoDecision = isDelete(direction) ? .delete : .keep
        let duration = reduceMotion ? 0 : 0.22
        let destination = UIScreen.main.bounds.width + 140

        withAnimation(.easeOut(duration: duration)) {
            offset = CGSize(
                width: direction < 0 ? -destination : destination,
                height: 0
            )
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard library.finishTransition(token) else { return }
            onDecision(decision)
            updateManager.setSortingInteractionActive(false)
            library.setSortingInteraction(false, assetID: asset.localIdentifier)
        }
    }

    private func resetOffset() {
        guard !leaving else { return }
        updateManager.setSortingInteractionActive(false)
        library.setSortingInteraction(false, assetID: asset.localIdentifier)
        if reduceMotion {
            offset = .zero
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                offset = .zero
            }
        }
    }

    private func toggleFavorite() {
        guard !favoriteWorking, !leaving else { return }
        favoriteWorking = true
        let target = !systemFavorite

        Task {
            let success = await library.setFavorite(asset, target)
            favoriteWorking = false

            if success {
                systemFavorite = target
                settings.feedback()
                showFavoriteFeedback(target)
            }
        }
    }

    private func showFavoriteFeedback(_ favorite: Bool) {
        let token = UUID()
        favoriteFeedbackToken = token
        favoriteFeedback = favorite

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            guard favoriteFeedbackToken == token else { return }
            favoriteFeedback = nil
        }
    }

    private func isDelete(_ x: CGFloat) -> Bool {
        settings.deleteOnRight ? x > 0 : x < 0
    }
}


/// Derived data is rebuilt only when the library, decisions or filter changes.
/// Animation and presentation updates reuse the same arrays and counts.
@MainActor
private final class SortingSummaryCache {
    var scope: [PHAsset] = []
    var queue: [PHAsset] = []
    var kept = 0
    var deleted = 0
    private var libraryRevision = -1
    private var decisionRevision = -1
    private var previousFilter: MediaFilter?

    private var ordered: [PHAsset] = []
    private var orderedResumeID: String?
    private var orderedPriorityIDs: [String] = []
    private var orderDirty = true

    func orderedQueue(resumeID: String?, priorityIDs: [String]) -> [PHAsset] {
        guard orderDirty || orderedResumeID != resumeID || orderedPriorityIDs != priorityIDs else { return ordered }
        ordered = ReviewQueueOrdering.arrange(queue, id: { $0.localIdentifier }, resumeID: resumeID, priorityIDs: priorityIDs)
        orderedResumeID = resumeID
        orderedPriorityIDs = priorityIDs
        orderDirty = false
        return ordered
    }

    func update(library: PhotoLibraryStore, filter: MediaFilter) {
        let scopeChanged = libraryRevision != library.revision || previousFilter != filter
        guard scopeChanged || decisionRevision != library.decisionRevision else { return }
        if scopeChanged {
            var category = filter
            category.dateEnabled = false
            let start = Calendar.current.startOfDay(for: filter.start)
            let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: filter.end)) ?? filter.end
            scope = library.assets.filter { asset in
                guard category.includes(asset) else { return false }
                guard filter.dateEnabled else { return true }
                guard let date = asset.creationDate else { return false }
                return date >= start && date < end
            }
        }
        orderDirty = true
        queue = []; queue.reserveCapacity(scope.count)
        kept = 0; deleted = 0
        for asset in scope {
            switch library.decisions[asset.localIdentifier] {
            case .none: queue.append(asset)
            case .some(.delete): deleted += 1
            case .some(.keep), .some(.favorite): kept += 1
            }
        }
        libraryRevision = library.revision
        decisionRevision = library.decisionRevision
        previousFilter = filter
    }
}

