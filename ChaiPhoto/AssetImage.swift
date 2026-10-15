import AVKit
import Photos
import SwiftUI

@MainActor
final class ThumbnailLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var loading = true
    @Published var inCloud = false
    @Published var downloading = false
    @Published var progress: Double = 0

    private var request: PHImageRequestID?
    private var token = UUID()
    private var assetID = ""

    func seed(_ image: UIImage?, for asset: PHAsset) {
        guard let image else { return }
        assetID = asset.localIdentifier
        self.image = image
        loading = false
    }

    func load(_ asset: PHAsset, size: CGSize, mode: PHImageContentMode, allowNetwork: Bool) {
        let sameAsset = assetID == asset.localIdentifier
        stop()
        assetID = asset.localIdentifier
        if !sameAsset { image = nil }
        loading = true
        inCloud = false
        downloading = false
        progress = 0

        let generation = token
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = allowNetwork
        options.progressHandler = { [weak self] value, _, _, _ in
            DispatchQueue.main.async {
                guard let self, self.token == generation else { return }
                if !self.downloading { self.downloading = true }
                let value = min(max(value, 0), 1)
                if abs(self.progress - value) >= 0.01 || value == 1 { self.progress = value }
            }
        }

        request = PHImageManager.default().requestImage(
            for: asset,
            targetSize: size,
            contentMode: mode,
            options: options
        ) { [weak self] image, info in
            DispatchQueue.main.async {
                guard let self, self.token == generation else { return }

                let degraded = info?[PHImageResultIsDegradedKey] as? Bool == true
                let cloudOnly = info?[PHImageResultIsInCloudKey] as? Bool == true
                let cancelled = info?[PHImageCancelledKey] as? Bool == true

                if cloudOnly { self.inCloud = true }
                if let image {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        self.image = image
                    }
                }

                if !degraded {
                    self.loading = false
                    self.downloading = false
                } else if !allowNetwork && cloudOnly {
                    self.loading = false
                }

                if cancelled {
                    self.loading = false
                    self.downloading = false
                }
            }
        }
    }

    func stop() {
        token = UUID()
        if let request { PHImageManager.default().cancelImageRequest(request) }
        request = nil
        downloading = false
    }
}

struct AssetImage: View {
    let asset: PHAsset
    let targetSize: CGSize
    var contentMode: PHImageContentMode = .aspectFill
    var asksForCloudPhoto = false

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var mediaPreloader: MediaPreloader
    @StateObject private var loader = ThumbnailLoader()

    private var allowNetwork: Bool {
        asset.mediaType == .video ? settings.canDownloadVideo(for: asset.localIdentifier) : settings.canDownloadPhoto(for: asset.localIdentifier)
    }

    var body: some View {
        ZStack {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode == .aspectFill ? .fill : .fit)
            } else {
                Color.secondary.opacity(0.15)

                if loader.loading || loader.downloading {
                    ProgressView()
                } else if loader.inCloud {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(L("照片需要從 iCloud 下載", "Photo needs to be downloaded from iCloud"))
                } else {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(L("照片預覽不可用", "Photo preview unavailable"))
                }
            }

            if loader.downloading {
                VStack {
                    Spacer()
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Image(systemName: "icloud.and.arrow.down")
                        if loader.progress > 0 {
                            Text("\(Int(loader.progress * 100))%")
                        }
                    }
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundStyle(.primary)
                    .padding(8)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
        }
        .task(id: "\(asset.localIdentifier)-\(Int(targetSize.width))-\(Int(targetSize.height))-\(allowNetwork)") {
            let seeded = mediaPreloader.cachedImage(for: asset.localIdentifier)
            loader.seed(seeded, for: asset)
            mediaPreloader.cancel(assetID: asset.localIdentifier)

            loader.load(
                asset,
                size: CGSize(
                    width: max(1, targetSize.width) * UIScreen.main.scale,
                    height: max(1, targetSize.height) * UIScreen.main.scale
                ),
                mode: contentMode,
                allowNetwork: allowNetwork
            )
        }
        .onChange(of: loader.inCloud) { _, cloud in
            if cloud && !allowNetwork && asksForCloudPhoto && asset.mediaType == .image {
                settings.requestCloudPhotoDownloadPermission(for: asset.localIdentifier)
            }
        }
        .overlay(alignment: .bottom) {
            if asksForCloudPhoto && loader.inCloud && !allowNetwork && !loader.downloading {
                Button(L("下載這張照片", "Download this photo")) {
                    settings.requestCloudPhotoDownloadPermission(for: asset.localIdentifier, retry: true)
                }.buttonStyle(.borderedProminent).padding(8)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: loader.downloading)
        .onDisappear { loader.stop() }
        .clipped()
    }
}

/// The border follows the actual full image, not the surrounding card.
struct FramedPhoto: View {
    let asset: PHAsset
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        GeometryReader { g in
            let width = max(1, g.size.width - 12)
            let height = max(1, g.size.height - 12)
            let ratio = CGFloat(max(1, asset.pixelWidth)) / CGFloat(max(1, asset.pixelHeight))
            let fittedWidth = min(width, height * ratio)
            let fittedHeight = fittedWidth / ratio
            ZStack {
                Color.clear
                AssetImage(asset: asset, targetSize: CGSize(width: fittedWidth, height: fittedHeight), contentMode: .aspectFit, asksForCloudPhoto: true)
                    .frame(width: fittedWidth, height: fittedHeight)
                    .background(.black)
                    .overlay(Rectangle().strokeBorder(colorScheme == .dark ? Color.white.opacity(0.8) : Color.black.opacity(0.7), lineWidth: 1))
            }.frame(width: g.size.width, height: g.size.height).clipped()
        }
    }
}

struct AssetPreview: View {
    let asset: PHAsset
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var showInfo = false
    @State private var cloudPhotoUnavailable = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(asset.mediaType == .video ? L("影片預覽", "Video preview") : L("完整照片", "Full photo")).font(.headline)
                Spacer()
                Button { showInfo = true } label: { Image(systemName: "info.circle").frame(width: 44, height: 44) }
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2).frame(width: 44, height: 44) }
                    .accessibilityLabel(L("關閉", "Close"))
            }.padding(.horizontal, 16)
            if asset.mediaType == .video {
                LocalVideoView(asset: asset, active: true, autoplay: settings.autoplay, muted: settings.muted)
            } else {
                NativePhotoZoom(asset: asset, onCloudUnavailable: {
                    cloudPhotoUnavailable = true
                    settings.requestCloudPhotoDownloadPermission(for: asset.localIdentifier, inPreview: true)
                })

            }
            if cloudPhotoUnavailable && !settings.canDownloadPhoto(for: asset.localIdentifier) {
                Button(L("下載這張照片", "Download this photo")) {
                    settings.requestCloudPhotoDownloadPermission(for: asset.localIdentifier, inPreview: true, retry: true)
                }.buttonStyle(.borderedProminent)
            }
            Text(asset.creationDate.map { appDateTime($0) } ?? L("日期不明", "Unknown date"))
                .font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .sheet(isPresented: $showInfo) { MediaInfoView(asset: asset) }
        .alert(L("下載 iCloud 照片？", "Download iCloud photo?"), isPresented: Binding(
            get: { settings.showCloudPhotoPrompt && settings.cloudPhotoPromptInPreview && !showInfo },
            set: { settings.showCloudPhotoPrompt = $0 }
        )) {
            Button(L("暫不載入", "Not now"), role: .cancel) { settings.declineCloudPhotosForNow() }
            Button(L("只下載這張", "Download this photo")) { settings.allowCloudPhotoItem() }
        } message: {
            Text(L("只下載這張照片。可在設定調整預載與始終下載允許。", "Download this photo only. Adjust preloading and always-allow permissions in Settings."))
        }
        .onDisappear {
            if settings.cloudPhotoPromptInPreview { settings.declineCloudPhotosForNow() }
        }
    }
}

@MainActor
final class VideoLoader: ObservableObject {
    enum Phase {
        case probingLocal
        case downloading
        case preparing
        case ready
        case unavailable
    }

    @Published var player: AVPlayer?
    @Published var poster: UIImage?
    @Published var inCloud = false
    @Published var progress: Double = 0
    @Published var readyToPlay = false
    @Published var renderReady = false
    @Published var playbackStarted = false
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var ended = false
    @Published var phase: Phase = .probingLocal

    private var request: PHImageRequestID?
    private var posterRequest: PHImageRequestID?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var token = UUID()
    private var assetID = ""
    private var wantsAutoplay = false
    private var muted = true
    private var isSceneActive = true
    private var manuallyPaused = false
    private var isVisible = true

    deinit {
        statusObservation?.invalidate()
        timeControlObservation?.invalidate()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let request {
            PHImageManager.default().cancelImageRequest(request)
        }
        if let posterRequest {
            PHImageManager.default().cancelImageRequest(posterRequest)
        }
    }

    func load(
        _ asset: PHAsset,
        autoplay: Bool,
        muted: Bool,
        allowNetwork: Bool,
        sceneActive: Bool,
        preparedPlayer: AVPlayer?,
        preparedPoster: UIImage?
    ) {
        let sameAsset = assetID == asset.localIdentifier
        stop(clearPoster: !sameAsset)

        assetID = asset.localIdentifier
        wantsAutoplay = autoplay
        self.muted = muted
        isSceneActive = sceneActive
        manuallyPaused = !autoplay
        inCloud = false
        progress = 0
        readyToPlay = false
        renderReady = false
        playbackStarted = false
        isPlaying = false
        currentTime = 0
        duration = max(0, asset.duration)
        ended = false
        phase = .probingLocal

        if let preparedPoster {
            poster = preparedPoster
        }

        let generation = token
        loadPoster(asset, generation: generation)

        if let preparedPlayer, let item = preparedPlayer.currentItem {
            phase = .preparing
            preparedPlayer.isMuted = muted
            self.player = preparedPlayer
            observe(item: item, player: preparedPlayer, generation: generation)
            observePlaybackState(player: preparedPlayer, generation: generation)
        } else {
            requestPlayerItem(
                asset,
                generation: generation,
                allowNetwork: false,
                fallbackAllowNetwork: allowNetwork
            )
        }
    }

    private func requestPlayerItem(
        _ asset: PHAsset,
        generation: UUID,
        allowNetwork: Bool,
        fallbackAllowNetwork: Bool
    ) {
        let options = PHVideoRequestOptions()
        options.deliveryMode = .automatic
        options.version = .current
        options.isNetworkAccessAllowed = allowNetwork

        if allowNetwork {
            options.progressHandler = { [weak self] value, _, _, _ in
                DispatchQueue.main.async {
                    guard let self, self.token == generation else { return }
                    let clamped = min(max(value, 0), 1)
                    if abs(self.progress - clamped) >= 0.01 || clamped == 1 { self.progress = clamped }
                    let phase: Phase = clamped >= 0.995 ? .preparing : .downloading
                    if self.phase != phase { self.phase = phase }
                }
            }
        }

        request = PHImageManager.default().requestPlayerItem(
            forVideo: asset,
            options: options
        ) { [weak self] item, info in
            DispatchQueue.main.async {
                guard let self, self.token == generation else { return }

                if let item {
                    self.phase = .preparing
                    self.attachPlayer(
                        item: item,
                        generation: generation,
                        localPlayback: !allowNetwork
                    )
                    return
                }

                let cloudOnly = info?[PHImageResultIsInCloudKey] as? Bool == true
                self.inCloud = cloudOnly

                if !allowNetwork && cloudOnly && fallbackAllowNetwork {
                    self.progress = 0
                    self.phase = .downloading
                    self.requestPlayerItem(
                        asset,
                        generation: generation,
                        allowNetwork: true,
                        fallbackAllowNetwork: false
                    )
                } else {
                    self.phase = .unavailable
                }
            }
        }
    }

    private func attachPlayer(
        item: AVPlayerItem,
        generation: UUID,
        localPlayback: Bool
    ) {
        let player = AVPlayer(playerItem: item)
        player.isMuted = muted
        player.automaticallyWaitsToMinimizeStalling = !localPlayback
        self.player = player
        observe(item: item, player: player, generation: generation)
        observePlaybackState(player: player, generation: generation)
    }

    private func loadPoster(_ asset: PHAsset, generation: UUID) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = false

        let maxPosterSide: CGFloat = 2560
        let width = max(1, CGFloat(asset.pixelWidth))
        let height = max(1, CGFloat(asset.pixelHeight))
        let scale = min(1, maxPosterSide / max(width, height))
        let target = CGSize(width: width * scale, height: height * scale)

        posterRequest = PHImageManager.default().requestImage(
            for: asset,
            targetSize: target,
            contentMode: .aspectFit,
            options: options
        ) { [weak self] image, _ in
            DispatchQueue.main.async {
                guard let self, self.token == generation, let image else { return }
                withAnimation(.easeInOut(duration: 0.12)) {
                    self.poster = image
                }
            }
        }
    }

    private func observe(
        item: AVPlayerItem,
        player: AVPlayer,
        generation: UUID
    ) {
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak player] item, _ in
            DispatchQueue.main.async {
                guard let self, self.token == generation else { return }

                switch item.status {
                case .readyToPlay:
                    self.readyToPlay = true
                    let itemDuration = item.duration.seconds
                    if itemDuration.isFinite && itemDuration > 0 {
                        self.duration = itemDuration
                    }
                    self.phase = self.renderReady ? .ready : .preparing

                    if self.wantsAutoplay &&
                       self.isSceneActive && self.isVisible &&
                       !self.manuallyPaused &&
                       !self.ended {
                        player?.playImmediately(atRate: 1)
                    }

                case .failed:
                    self.readyToPlay = false
                    self.phase = .unavailable

                case .unknown:
                    self.phase = .preparing

                @unknown default:
                    self.phase = .preparing
                }
            }
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak player] time in
            Task { @MainActor in
            guard let self, self.token == generation else { return }

            let seconds = time.seconds
            if seconds.isFinite {
                let next = max(0, seconds)
                if abs(self.currentTime - next) >= 0.05 { self.currentTime = next }

                if seconds > 0.01 && !self.playbackStarted {
                    self.playbackStarted = true
                }
            }

            let itemDuration = player?.currentItem?.duration.seconds ?? .nan
            if itemDuration.isFinite && itemDuration > 0 && abs(self.duration - itemDuration) > 0.01 {
                self.duration = itemDuration
            }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak player] _ in
            DispatchQueue.main.async {
                guard let self, self.token == generation else { return }
                self.ended = true
                self.isPlaying = false
                self.manuallyPaused = true
                self.wantsAutoplay = false
                self.currentTime = self.duration
                player?.pause()
            }
        }
    }

    private func observePlaybackState(
        player: AVPlayer,
        generation: UUID
    ) {
        timeControlObservation = player.observe(
            \.timeControlStatus,
            options: [.initial, .new]
        ) { [weak self] player, _ in
            DispatchQueue.main.async {
                guard let self, self.token == generation else { return }

                switch player.timeControlStatus {
                case .playing, .waitingToPlayAtSpecifiedRate:
                    if !self.isPlaying { self.isPlaying = true }
                case .paused:
                    if self.isPlaying { self.isPlaying = false }
                @unknown default:
                    self.isPlaying = player.rate > 0
                }
            }
        }
    }

    func setRenderReady(_ ready: Bool) {
        guard renderReady != ready else { return }
        renderReady = ready

        if ready && readyToPlay {
            phase = .ready
        } else if readyToPlay {
            phase = .preparing
        }
    }

    func togglePlayback() {
        guard let player, readyToPlay else { return }

        if isPlaying || player.rate > 0 ||
            player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            manuallyPaused = true
            wantsAutoplay = false
            player.pause()
            return
        }

        manuallyPaused = false
        wantsAutoplay = true

        guard isSceneActive, isVisible else { return }

        if ended || (duration > 0 && currentTime >= duration - 0.08) {
            seekToStartAndPlay()
        } else {
            player.playImmediately(atRate: 1)
        }
    }

    private func seekToStartAndPlay() {
        guard let player else { return }

        let generation = token
        ended = false
        currentTime = 0
        player.seek(
            to: .zero,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self, weak player] finished in
            DispatchQueue.main.async {
                guard let self, finished, self.token == generation, self.isSceneActive, self.isVisible, !self.manuallyPaused else { return }
                self.manuallyPaused = false
                self.wantsAutoplay = true
                player?.playImmediately(atRate: 1)
            }
        }
    }

    func seek(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func seek(to seconds: Double) {
        guard let player else { return }

        var target = max(0, seconds)
        if duration > 0 {
            target = min(target, duration)
        }

        let shouldResume =
            !manuallyPaused &&
            !ended &&
            (isPlaying ||
             player.rate > 0 ||
             player.timeControlStatus == .waitingToPlayAtSpecifiedRate)

        if duration > 0 && target < duration - 0.08 {
            ended = false
        }

        currentTime = target
        let generation = token

        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self, weak player] finished in
            DispatchQueue.main.async {
                guard let self, finished, self.token == generation else { return }

                if shouldResume && self.isSceneActive && self.isVisible && !self.manuallyPaused {
                    player?.playImmediately(atRate: 1)
                }
            }
        }
    }

    func play() {
        manuallyPaused = false
        wantsAutoplay = true

        guard readyToPlay, isSceneActive, isVisible else { return }

        if ended {
            seekToStartAndPlay()
        } else {
            player?.playImmediately(atRate: 1)
        }
    }

    func setAutoplay(_ enabled: Bool) {
        wantsAutoplay = enabled

        if enabled {
            manuallyPaused = false
            if readyToPlay && isSceneActive && isVisible && !ended {
                player?.playImmediately(atRate: 1)
            }
        } else {
            manuallyPaused = true
            player?.pause()
        }
    }

    func setSceneActive(_ active: Bool) {
        isSceneActive = active
        if !active {
            // Returning from the background requires an explicit play action.
            manuallyPaused = true
            wantsAutoplay = false
        }
        resumeIfWanted()
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        resumeIfWanted()
    }

    private func resumeIfWanted() {
        if isSceneActive && isVisible && wantsAutoplay && readyToPlay && !manuallyPaused && !ended {
            player?.playImmediately(atRate: 1)
        } else {
            player?.pause()
        }
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
        player?.isMuted = muted
    }

    func stop(clearPoster: Bool = true) {
        token = UUID()

        statusObservation?.invalidate()
        statusObservation = nil

        timeControlObservation?.invalidate()
        timeControlObservation = nil

        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil

        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil

        if let request {
            PHImageManager.default().cancelImageRequest(request)
        }
        request = nil

        if let posterRequest {
            PHImageManager.default().cancelImageRequest(posterRequest)
        }
        posterRequest = nil

        readyToPlay = false
        renderReady = false
        playbackStarted = false
        isPlaying = false
        currentTime = 0
        duration = 0
        ended = false
        progress = 0

        if clearPoster {
            poster = nil
            assetID = ""
        }
    }
}

struct LocalVideoView: View {
    let asset: PHAsset
    var active: Bool
    var autoplay: Bool
    var muted: Bool
    var onFavorite: (() -> Void)? = nil
    var onVerticalDrag: ((CGFloat) -> Void)? = nil
    var onSwipeUp: (() -> Void)? = nil
    var onSwipeDown: (() -> Void)? = nil

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var mediaPreloader: MediaPreloader
    @EnvironmentObject private var updateManager: AppUpdateManager
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var loader = VideoLoader()
    @State private var askCloud = false
    @State private var seekFeedback: Int?
    @State private var seekFeedbackToken = UUID()
    @State private var showFullscreen = false
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        ZStack {
            Color.black

            if !showFullscreen {
                playerSurface(loader.player)
            }

            if !(loader.renderReady && loader.playbackStarted),
               let poster = loader.poster {
                Image(uiImage: poster)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            phaseOverlay

            if let seekFeedback {
                seekFeedbackView(seekFeedback)
            }

            VStack {
                HStack {
                    Button {
                        showFullscreen = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .padding(10)
                            .background(.black.opacity(0.55), in: Circle())
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel(L("全螢幕", "Full screen"))

                    Spacer()
                }
                .padding(8)

                Spacer()

                if loader.duration > 0 {
                    progressControls
                }
            }
        }
        .animation(.easeInOut(duration: 0.14), value: loader.renderReady)
        .animation(.easeInOut(duration: 0.14), value: loader.isPlaying)
        .animation(.easeInOut(duration: 0.14), value: seekFeedback)
        .task(id: asset.localIdentifier) {
            if loader.player == nil { reload() }
            loader.setVisible(active || showFullscreen)
        }
        .onChange(of: settings.canDownloadVideo(for: asset.localIdentifier)) { _, _ in
            // Revoke/cancel an in-flight cloud request as well as granting access.
            reload()
        }
        .onChange(of: active) { _, value in
            loader.setVisible(value || showFullscreen)
        }
        .onChange(of: showFullscreen) { _, value in
            loader.setVisible(active || value)
        }
        .onAppear { loader.setVisible(active || showFullscreen) }
        .onChange(of: loader.inCloud) { _, cloud in
            if cloud &&
               active &&
               !settings.canDownloadVideo(for: asset.localIdentifier) &&
               settings.shouldPromptCloudVideo(for: asset.localIdentifier) {
                askCloud = true
            }
        }
        .alert(
            L("允許載入 iCloud 影片？", "Allow iCloud video downloads?"),
            isPresented: $askCloud
        ) {
            Button(L("暫不載入", "Not now"), role: .cancel) {
                settings.cloudPromptHandled = true
            }

            Button(L("只下載這部", "Download this video")) { settings.allowCloudVideoItem(asset.localIdentifier) }
        } message: {
            Text(L("只下載這部影片。可在設定調整預載與始終下載允許。", "Download this video only. Adjust preloading and always-allow permissions in Settings."))
        }
        .fullScreenCover(isPresented: $showFullscreen) {
            SharedVideoFullscreenView(
                loader: loader,
                muted: Binding(
                    get: { settings.muted },
                    set: { settings.muted = $0 }
                ),
                onFavorite: onFavorite,
                onRetry: { reload() }
            )
        }
        .onChange(of: muted) { _, value in
            loader.setMuted(value)
        }
        .onChange(of: autoplay) { _, enabled in
            loader.setAutoplay(enabled)
        }
        .onChange(of: scenePhase) { _, phase in
            loader.setSceneActive(phase == .active)
        }
        .onDisappear {
            if !showFullscreen { loader.setVisible(false) }
            if !(askCloud || showFullscreen || scrubbing) {
                updateManager.setPresentationBlocked(false, reason: "video-player-modal")
            }
        }
        .task(id: askCloud || showFullscreen || scrubbing) {
            updateManager.setPresentationBlocked(askCloud || showFullscreen || scrubbing, reason: "video-player-modal")
        }
    }

    @ViewBuilder
    private func playerSurface(_ player: AVPlayer?) -> some View {
        PlayerSurface(
            player: player,
            onReadyForDisplay: { loader.setRenderReady($0) },
            onSingleTap: { loader.togglePlayback() },
            onDoubleTapLeft: {
                loader.seek(by: -10)
                showSeekFeedback(-10)
            },
            onDoubleTapCenter: {
                onFavorite?()
            },
            onDoubleTapRight: {
                loader.seek(by: 10)
                showSeekFeedback(10)
            },
            onVerticalDrag: onVerticalDrag,
            onSwipeUp: onSwipeUp,
            onSwipeDown: onSwipeDown
        )
    }

    @ViewBuilder
    private var phaseOverlay: some View {
        switch loader.phase {
        case .probingLocal:
            loadingOverlay

        case .downloading:
            cloudDownloadOverlay

        case .preparing:
            preparingOverlay

        case .ready:
            if !loader.isPlaying {
                Image(systemName: "play.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(22)
                    .background(.black.opacity(0.28), in: Circle())
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

        case .unavailable:
            cloudUnavailableOverlay
        }
    }

    private var progressControls: some View {
        HStack(spacing: 8) {
            Text(timeText(scrubbing ? scrubValue : loader.currentTime))
                .frame(width: 42, alignment: .trailing)

            Slider(
                value: Binding(
                    get: {
                        scrubbing ? scrubValue : loader.currentTime
                    },
                    set: { value in
                        scrubValue = value
                    }
                ),
                in: 0...max(loader.duration, 0.1),
                onEditingChanged: { editing in
                    if editing {
                        scrubbing = true
                        scrubValue = loader.currentTime
                    } else {
                        loader.seek(to: scrubValue)
                        scrubbing = false
                    }
                }
            )
            .tint(.white)

            Text(timeText(loader.duration))
                .frame(width: 42, alignment: .leading)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.black.opacity(0.5), in: Capsule())
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var loadingOverlay: some View {
        HStack(spacing: 8) {
            ProgressView().tint(.white)
            Text(L("正在開啟影片…", "Opening video…"))
        }
        .font(.caption)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.46), in: Capsule())
        .allowsHitTesting(false)
    }

    private var preparingOverlay: some View {
        HStack(spacing: 8) {
            ProgressView().tint(.white)
            Text(L("正在準備第一幀…", "Preparing first frame…"))
        }
        .font(.caption)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.46), in: Capsule())
        .allowsHitTesting(false)
    }

    private var cloudDownloadOverlay: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                ProgressView()
                    .tint(.white)
                    .controlSize(.small)
                Image(systemName: "icloud.and.arrow.down")
                Text(L("正在從 iCloud 下載", "Downloading from iCloud"))
            }
            .font(.callout.weight(.medium))

            ProgressView(value: loader.progress)
                .tint(.white)
                .frame(maxWidth: 220)

            if loader.progress < 0.995 {
                Text("\(Int(loader.progress * 100))%")
                    .font(.caption.monospacedDigit())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
        .allowsHitTesting(false)
    }

    private var cloudUnavailableOverlay: some View {
        VStack(spacing: 12) {
            Image(
                systemName: loader.inCloud
                    ? "icloud.and.arrow.down"
                    : "exclamationmark.triangle"
            )
            .font(.largeTitle)

            Text(
                loader.inCloud
                    ? L("影片在 iCloud 中", "This video is in iCloud")
                    : L("抓取或下載影片失敗", "Could not fetch or download this video")
            )

            Button(L("嘗試重試", "Try again")) {
                if !loader.inCloud || settings.canDownloadVideo(for: asset.localIdentifier) {
                    reload()
                } else {
                    askCloud = true
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .padding(22)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
        .padding()
    }

    private func seekFeedbackView(_ value: Int) -> some View {
        HStack(spacing: 7) {
            Image(systemName: value < 0 ? "gobackward.10" : "goforward.10")
            Text(
                value < 0
                    ? L("倒退 10 秒", "Back 10 seconds")
                    : L("快轉 10 秒", "Forward 10 seconds")
            )
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.55), in: Capsule())
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
        .allowsHitTesting(false)
    }

    private func showSeekFeedback(_ value: Int) {
        let token = UUID()
        seekFeedbackToken = token
        seekFeedback = value

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            guard seekFeedbackToken == token else { return }
            seekFeedback = nil
        }
    }

    private func reload() {
        let preparedPlayer =
            mediaPreloader.takePreparedPlayer(for: asset.localIdentifier, allowNetwork: settings.canDownloadVideo(for: asset.localIdentifier))
        let preparedPoster =
            mediaPreloader.cachedImage(for: asset.localIdentifier)

        mediaPreloader.cancel(assetID: asset.localIdentifier)

        loader.load(
            asset,
            autoplay: autoplay,
            muted: muted,
            allowNetwork: settings.canDownloadVideo(for: asset.localIdentifier),
            sceneActive: scenePhase == .active,
            preparedPlayer: preparedPlayer,
            preparedPoster: preparedPoster
        )
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }

        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct SharedVideoFullscreenView: View {
    @ObservedObject var loader: VideoLoader
    @Binding var muted: Bool
    let onFavorite: (() -> Void)?
    let onRetry: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var seekFeedback: Int?
    @State private var seekFeedbackToken = UUID()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player = loader.player {
                PlayerSurface(
                    player: player,
                    onReadyForDisplay: { loader.setRenderReady($0) },
                    onSingleTap: { loader.togglePlayback() },
                    onDoubleTapLeft: {
                        loader.seek(by: -10)
                        showSeekFeedback(-10)
                    },
                    onDoubleTapCenter: {
                        onFavorite?()
                    },
                    onDoubleTapRight: {
                        loader.seek(by: 10)
                        showSeekFeedback(10)
                    },
                    onVerticalDrag: nil,
                    onSwipeUp: nil,
                    onSwipeDown: nil
                )
                .ignoresSafeArea()
            }

            if !loader.renderReady {
                VStack(spacing: 12) {
                    if loader.phase == .unavailable {
                        Image(systemName: "exclamationmark.icloud").font(.largeTitle)
                        Text(L("抓取或下載影片失敗", "Could not fetch or download this video"))
                        Button(L("嘗試重試", "Try again"), action: onRetry).buttonStyle(.borderedProminent)
                    } else {
                        ProgressView().tint(.white)
                        Text(loader.inCloud
                            ? L("正在從 iCloud 下載影片…", "Downloading video from iCloud…")
                            : L("正在載入影片…", "Loading video…"))
                    }
                }
                .foregroundStyle(.white)
                .padding()
                .allowsHitTesting(loader.phase == .unavailable)
            }

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title3.bold())
                            .padding(12)
                            .background(.black.opacity(0.55), in: Circle())
                            .foregroundStyle(.white)
                    }

                    Spacer()

                    Button {
                        muted.toggle()
                        loader.setMuted(muted)
                    } label: {
                        Image(
                            systemName: muted
                                ? "speaker.slash.fill"
                                : "speaker.wave.2.fill"
                        )
                        .font(.title3)
                        .padding(12)
                        .background(.black.opacity(0.55), in: Circle())
                        .foregroundStyle(.white)
                    }
                }
                .padding()

                Spacer()

                if loader.duration > 0 {
                    HStack(spacing: 8) {
                        Text(timeText(scrubbing ? scrubValue : loader.currentTime))
                            .frame(width: 46, alignment: .trailing)

                        Slider(
                            value: Binding(
                                get: {
                                    scrubbing ? scrubValue : loader.currentTime
                                },
                                set: { value in
                                    scrubValue = value
                                }
                            ),
                            in: 0...max(loader.duration, 0.1),
                            onEditingChanged: { editing in
                                if editing {
                                    scrubbing = true
                                    scrubValue = loader.currentTime
                                } else {
                                    loader.seek(to: scrubValue)
                                    scrubbing = false
                                }
                            }
                        )
                        .tint(.white)

                        Text(timeText(loader.duration))
                            .frame(width: 46, alignment: .leading)
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding()
                }
            }

            if !loader.isPlaying && loader.phase == .ready {
                Image(systemName: "play.fill")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(24)
                    .background(.black.opacity(0.3), in: Circle())
                    .allowsHitTesting(false)
            }

            if let seekFeedback {
                HStack(spacing: 7) {
                    Image(
                        systemName: seekFeedback < 0
                            ? "gobackward.10"
                            : "goforward.10"
                    )
                    Text(
                        seekFeedback < 0
                            ? L("倒退 10 秒", "Back 10 seconds")
                            : L("快轉 10 秒", "Forward 10 seconds")
                    )
                }
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.black.opacity(0.55), in: Capsule())
                .allowsHitTesting(false)
            }
        }
    }

    private func showSeekFeedback(_ value: Int) {
        let token = UUID()
        seekFeedbackToken = token
        seekFeedback = value

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            guard seekFeedbackToken == token else { return }
            seekFeedback = nil
        }
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }

        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}


