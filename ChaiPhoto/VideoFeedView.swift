import Photos
import SwiftUI

struct VideoFeedView: View {
    let asset: PHAsset
    var currentAlbumID: String? = nil
    var currentAlbumName: String? = nil
    var onRemovedFromCurrentAlbum: (() -> Void)? = nil
    var onPrevious: (() -> Void)? = nil

    @EnvironmentObject private var library: PhotoLibraryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var mediaPreloader: MediaPreloader
    @EnvironmentObject private var updateManager: AppUpdateManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var info = false
    @State private var share: ShareFile?
    @State private var shareURL: URL?
    @State private var shareTask: Task<Void, Never>?
    @State private var shareGeneration = UUID()
    @State private var preparing = false
    @State private var offset: CGFloat = 0
    @State private var leaving = false
    @State private var visible = true
    @State private var showAlbumPicker = false
    @State private var showAlbumContextDialog = false
    @State private var favoriteWorking = false
    @State private var systemFavorite = false
    @State private var favoriteFeedback: Bool?
    @State private var favoriteFeedbackToken = UUID()

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                LocalVideoView(
                    asset: asset,
                    active: visible && !info && share == nil && !showAlbumPicker && !leaving,
                    autoplay: settings.autoplay,
                    muted: settings.muted,
                    onFavorite: favoriteCurrent,
                    onVerticalDrag: handleVerticalDrag,
                    onSwipeUp: { advance(.keep) },
                    onSwipeDown: previousVideo
                )
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.secondary.opacity(0.4)))
                .overlay {
                    if let favoriteFeedback {
                        VStack(spacing: 8) {
                            Image(systemName: favoriteFeedback ? "heart.fill" : "heart.slash.fill")
                                .font(.system(size: 52))
                                .foregroundStyle(favoriteFeedback ? .pink : .white)
                            Text(favoriteFeedback
                                 ? L("已加入喜好項目", "Added to Favorites")
                                 : L("已取消喜好項目", "Removed from Favorites"))
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
                .offset(y: offset)

                VStack(spacing: 14) {
                    side(
                        settings.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                        settings.muted ? L("靜音", "Muted") : L("聲音", "Sound"),
                        color: .indigo
                    ) {
                        settings.muted.toggle()
                    }
                    side("rectangle.stack.badge.plus", L("相簿", "Album"), color: .indigo) {
                        openAlbumAction()
                    }
                    side("trash", L("待刪", "Delete"), color: .red) {
                        advance(.delete)
                    }
                    side("square.and.arrow.up", preparing ? L("準備中", "Preparing") : L("分享", "Share")) {
                        shareVideo()
                    }
                    side("ellipsis.circle", L("更多", "More")) {
                        info = true
                    }
                }
                .frame(width: 52)
            }
            .padding(.horizontal, 8)
            .clipped()

        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: L("保留影片並下一部", "Keep video and continue")) {
            advance(.keep)
        }
        .accessibilityAction(named: L("上一部影片", "Previous video")) {
            previousVideo()
        }
        .accessibilityAction(named: L("標記影片待刪", "Mark video for deletion")) {
            advance(.delete)
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.18),
            value: favoriteFeedback
        )
        .sheet(isPresented: $info) {
            MediaInfoView(asset: asset)
        }
        .sheet(item: $share, onDismiss: cleanupShare) {
            SystemShareView(url: $0.url)
        }
        .sheet(isPresented: $showAlbumPicker) {
            AlbumPickerView(
                asset: asset,
                protectedAlbumID: currentAlbumID
            ) { _ in }
        }
        .confirmationDialog(
            L("目前位於「\(currentAlbumName ?? L("此相簿", "this album"))」", "Currently in “\(currentAlbumName ?? L("此相簿", "this album"))”"),
            isPresented: $showAlbumContextDialog,
            titleVisibility: .visible
        ) {
            Button(L("加入其他相簿", "Add to other albums")) {
                showAlbumPicker = true
            }
            Button(L("從目前相簿移除", "Remove from current album"), role: .destructive) {
                removeFromCurrentAlbum()
            }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L(
                "可以把這部影片移出目前相簿，或保留在目前相簿並另外加入其他相簿。",
                "Remove this video from the current album, or keep it there and add it to other albums."
            ))
        }
        .onAppear {
            visible = true
            systemFavorite = asset.isFavorite
        }
        .onChange(of: asset.isFavorite) { _, value in systemFavorite = value }
        .onDisappear {
            if !(info || share != nil || showAlbumPicker || showAlbumContextDialog || preparing) {
                updateManager.setPresentationBlocked(false, reason: "video-modal")
            }
            updateManager.setSortingInteractionActive(false)
            library.setSortingInteraction(false, assetID: asset.localIdentifier)
            visible = false
            library.cancelTransition(for: asset.localIdentifier)
            cancelShare()
            cleanupShare()
        }
        .task(id: info || share != nil || showAlbumPicker || showAlbumContextDialog || preparing) {
            updateManager.setPresentationBlocked(info || share != nil || showAlbumPicker || showAlbumContextDialog || preparing, reason: "video-modal")
        }
    }

    private func side(
        _ symbol: String,
        _ label: String,
        color: Color = .primary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title2)
                Text(label)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(color)
            .frame(minHeight: 44)
        }
        .disabled(leaving || favoriteWorking)
        .accessibilityLabel(label)
        .accessibilityHint(
            label == L("待刪", "Delete")
                ? L("將目前影片標記為待刪，不會立即永久刪除。", "Marks the current video for deletion without deleting it immediately.")
                : ""
        )
    }

    private func handleVerticalDrag(_ translation: CGFloat) {
        guard !leaving else { return }
        updateManager.setSortingInteractionActive(translation != 0)
        library.setSortingInteraction(translation != 0, assetID: asset.localIdentifier)
        if translation == 0 {
            if reduceMotion {
                offset = 0
            } else {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                    offset = 0
                }
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                offset = reduceMotion ? translation * 0.12 : translation * 0.3
            }
        }
    }

    private func previousVideo() {
        guard !leaving else { return }
        cancelShare()
        mediaPreloader.cancel(assetID: asset.localIdentifier)

        if reduceMotion {
            offset = 0
            onPrevious?()
        } else {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                offset = 0
            }
            onPrevious?()
        }
    }

    private func advance(_ decision: PhotoDecision) {
        guard !leaving, let token = library.beginTransition(for: asset) else { return }
        updateManager.setSortingInteractionActive(true)
        library.setSortingInteraction(true, assetID: asset.localIdentifier)
        cancelShare()
        leaving = true
        mediaPreloader.cancel(assetID: asset.localIdentifier)
        settings.feedback()

        let duration = reduceMotion ? 0 : 0.16
        if reduceMotion {
            offset = -500
        } else {
            withAnimation(.easeOut(duration: duration)) {
                offset = -500
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard library.finishTransition(token) else { return }
            library.choose(asset, as: decision)
            updateManager.setSortingInteractionActive(false)
            library.setSortingInteraction(false, assetID: asset.localIdentifier)
        }
    }

    private func favoriteCurrent() {
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

    private func openAlbumAction() {
        if currentAlbumID != nil {
            showAlbumContextDialog = true
        } else {
            showAlbumPicker = true
        }
    }

    private func removeFromCurrentAlbum() {
        guard let currentAlbumID else { return }

        let result = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [currentAlbumID],
            options: nil
        )
        guard let album = result.firstObject else {
            library.message = L("找不到目前相簿。", "The current album is no longer available.")
            return
        }

        Task {
            let success = await library.remove(asset, from: album)
            if success {
                settings.feedback()
                onRemovedFromCurrentAlbum?()
            }
        }
    }

    private func shareVideo() {
        guard !preparing else { return }
        preparing = true
        let generation = UUID()
        shareGeneration = generation
        shareTask = Task {
            do {
                let url = try await prepareVideoShare(asset, allowNetwork: settings.canDownloadVideo(for: asset.localIdentifier))
                guard !Task.isCancelled, generation == shareGeneration else {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                    return
                }
                shareURL = url
                share = ShareFile(url: url)
            } catch {
                guard !Task.isCancelled, generation == shareGeneration else { return }
                library.message = L("無法分享：", "Could not share: ") + appErrorMessage(error)
            }
            if generation == shareGeneration { preparing = false; shareTask = nil }
        }
    }

    private func cancelShare() {
        shareGeneration = UUID()
        shareTask?.cancel()
        shareTask = nil
        preparing = false
    }

    private func cleanupShare() {
        if let shareURL {
            try? FileManager.default.removeItem(at: shareURL.deletingLastPathComponent())
        }
        shareURL = nil
    }
}

struct FavoriteVideosView: View {
    @EnvironmentObject private var library: PhotoLibraryStore
    @State private var preview: PreviewSelection?

    var body: some View {
        List(library.assets.filter { $0.mediaType == .video && $0.isFavorite }, id: \.localIdentifier) { asset in
            Button {
                preview = PreviewSelection(asset: asset)
            } label: {
                HStack {
                    AssetImage(asset: asset, targetSize: CGSize(width: 60, height: 60))
                        .frame(width: 60, height: 60)
                        .clipped()

                    Text(asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? L("影片", "Video"))
                }
            }
        }
        .navigationTitle(L("喜好影片", "Favorite videos"))
        .fullScreenCover(item: $preview) {
            AssetPreview(asset: $0.asset)
        }
    }
}

