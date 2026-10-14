import AVFoundation
import Combine
import Photos
import UIKit

@MainActor
final class MediaPreloader: ObservableObject {
    private final class PreparedVideo {
        let player: AVPlayer
        var statusObservation: NSKeyValueObservation?

        init(player: AVPlayer) {
            self.player = player
        }

        deinit {
            statusObservation?.invalidate()
            player.cancelPendingPrerolls()
            player.pause()
        }
    }

    private let imageManager = PHImageManager.default()
    private var photoRequests: [String: PHImageRequestID] = [:]
    private var videoRequests: [String: PHImageRequestID] = [:]
    private var photoCache: [String: UIImage] = [:]
    private var videoCache: [String: PreparedVideo] = [:]
    private var wantedIDs: Set<String> = []
    private var photoTokens: [String: UUID] = [:]
    private var videoTokens: [String: UUID] = [:]
    private var networkPolicy: [Bool] = []

    func prepareNext(
        _ assets: [PHAsset],
        keepingCurrentID currentID: String?,
        photoCount: Int,
        videoCount: Int,
        allowPhotoNetwork: Bool,
        allowVideoNetwork: Bool
    ) {
        let policy = [allowPhotoNetwork, allowVideoNetwork]
        if networkPolicy != policy { clear(); networkPolicy = policy }
        var selected: [PHAsset] = []
        var selectedPhotos = 0
        var selectedVideos = 0

        let photoLimit = max(0, photoCount)
        let videoLimit = max(0, videoCount)

        for asset in assets {
            if asset.mediaType == .image, selectedPhotos < photoLimit {
                selected.append(asset)
                selectedPhotos += 1
            } else if asset.mediaType == .video, selectedVideos < videoLimit {
                selected.append(asset)
                selectedVideos += 1
            }

            if selectedPhotos >= photoLimit && selectedVideos >= videoLimit {
                break
            }
        }

        var nextWanted = Set(selected.map(\.localIdentifier))
        if let currentID {
            nextWanted.insert(currentID)
        }

        prune(keeping: nextWanted)
        wantedIDs = nextWanted

        for asset in selected {
            switch asset.mediaType {
            case .image:
                prepareImage(
                    asset,
                    allowNetwork: allowPhotoNetwork
                )

            case .video:
                // Preload both a poster and an AVPlayerItem so a video can appear
                // immediately even if playback still needs a moment to begin.
                prepareImage(
                    asset,
                    allowNetwork: allowVideoNetwork
                )
                prepareVideo(
                    asset,
                    allowNetwork: allowVideoNetwork
                )

            default:
                break
            }
        }
    }

    func cachedImage(for assetID: String) -> UIImage? {
        photoCache[assetID]
    }

    func takePreparedPlayer(for assetID: String) -> AVPlayer? {
        guard let prepared = videoCache.removeValue(forKey: assetID) else {
            return nil
        }

        prepared.statusObservation?.invalidate()
        prepared.statusObservation = nil
        videoRequests.removeValue(forKey: assetID)
        return prepared.player
    }

    func cancel(assetID: String) {
        wantedIDs.remove(assetID)
        photoTokens.removeValue(forKey: assetID)
        videoTokens.removeValue(forKey: assetID)

        if let request = photoRequests.removeValue(forKey: assetID) {
            imageManager.cancelImageRequest(request)
        }

        if let request = videoRequests.removeValue(forKey: assetID) {
            imageManager.cancelImageRequest(request)
        }

        photoCache.removeValue(forKey: assetID)
        videoCache.removeValue(forKey: assetID)
    }

    func clear() {
        photoTokens.removeAll()
        videoTokens.removeAll()
        prune(keeping: [])
        wantedIDs.removeAll()
    }

    private func prepareImage(
        _ asset: PHAsset,
        allowNetwork: Bool
    ) {
        let id = asset.localIdentifier
        guard photoCache[id] == nil, photoRequests[id] == nil else {
            return
        }

        requestImage(
            asset,
            allowNetwork: false,
            fallbackAllowNetwork: allowNetwork
        )
    }

    private func requestImage(
        _ asset: PHAsset,
        allowNetwork: Bool,
        fallbackAllowNetwork: Bool
    ) {
        let id = asset.localIdentifier
        guard wantedIDs.contains(id) else { return }

        let generation = UUID()
        photoTokens[id] = generation
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = allowNetwork

        let width = max(1, CGFloat(asset.pixelWidth))
        let height = max(1, CGFloat(asset.pixelHeight))
        let scale = min(1, 2560 / max(width, height))
        let targetSize = CGSize(
            width: width * scale,
            height: height * scale
        )

        photoRequests[id] = imageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: options
        ) { [weak self] image, info in
            DispatchQueue.main.async {
                guard let self, self.wantedIDs.contains(id), self.photoTokens[id] == generation else {
                    return
                }

                let cancelled =
                    info?[PHImageCancelledKey] as? Bool == true
                let degraded =
                    info?[PHImageResultIsDegradedKey] as? Bool == true
                let cloudOnly =
                    info?[PHImageResultIsInCloudKey] as? Bool == true

                if let image {
                    self.photoCache[id] = image
                }

                if cancelled {
                    self.photoRequests.removeValue(forKey: id)
                    return
                }

                guard !degraded else { return }

                self.photoRequests.removeValue(forKey: id)

                if image == nil,
                   cloudOnly,
                   !allowNetwork,
                   fallbackAllowNetwork,
                   self.wantedIDs.contains(id) {
                    self.requestImage(
                        asset,
                        allowNetwork: true,
                        fallbackAllowNetwork: false
                    )
                }
            }
        }
    }

    private func prepareVideo(
        _ asset: PHAsset,
        allowNetwork: Bool
    ) {
        let id = asset.localIdentifier
        guard videoCache[id] == nil, videoRequests[id] == nil else {
            return
        }

        requestVideo(
            asset,
            allowNetwork: false,
            fallbackAllowNetwork: allowNetwork
        )
    }

    private func requestVideo(
        _ asset: PHAsset,
        allowNetwork: Bool,
        fallbackAllowNetwork: Bool
    ) {
        let id = asset.localIdentifier
        guard wantedIDs.contains(id) else { return }

        let generation = UUID()
        videoTokens[id] = generation
        let options = PHVideoRequestOptions()
        options.deliveryMode = .automatic
        options.version = .current
        options.isNetworkAccessAllowed = allowNetwork

        videoRequests[id] = imageManager.requestPlayerItem(
            forVideo: asset,
            options: options
        ) { [weak self] item, info in
            DispatchQueue.main.async {
                guard let self, self.wantedIDs.contains(id), self.videoTokens[id] == generation else {
                    return
                }

                if let item {
                    let player = AVPlayer(playerItem: item)
                    player.isMuted = true
                    player.automaticallyWaitsToMinimizeStalling = false

                    let prepared = PreparedVideo(player: player)
                    prepared.statusObservation = item.observe(
                        \.status,
                        options: [.initial, .new]
                    ) { [weak prepared] item, _ in
                        guard item.status == .readyToPlay,
                              let prepared else {
                            return
                        }

                        DispatchQueue.main.async {
                            prepared.player.preroll(atRate: 1) { _ in }
                        }
                    }

                    self.videoCache[id] = prepared
                    self.videoRequests.removeValue(forKey: id)
                    return
                }

                let cloudOnly =
                    info?[PHImageResultIsInCloudKey] as? Bool == true

                self.videoRequests.removeValue(forKey: id)

                if !allowNetwork,
                   cloudOnly,
                   fallbackAllowNetwork,
                   self.wantedIDs.contains(id) {
                    self.requestVideo(
                        asset,
                        allowNetwork: true,
                        fallbackAllowNetwork: false
                    )
                }
            }
        }
    }

    private func prune(keeping ids: Set<String>) {
        let stalePhotoRequests =
            photoRequests.keys.filter { !ids.contains($0) }

        for id in stalePhotoRequests {
            photoTokens.removeValue(forKey: id)
            if let request = photoRequests.removeValue(forKey: id) {
                imageManager.cancelImageRequest(request)
            }
        }

        let staleVideoRequests =
            videoRequests.keys.filter { !ids.contains($0) }

        for id in staleVideoRequests {
            videoTokens.removeValue(forKey: id)
            if let request = videoRequests.removeValue(forKey: id) {
                imageManager.cancelImageRequest(request)
            }
        }

        let stalePhotos =
            photoCache.keys.filter { !ids.contains($0) }

        for id in stalePhotos {
            photoCache.removeValue(forKey: id)
        }

        let staleVideos =
            videoCache.keys.filter { !ids.contains($0) }

        for id in staleVideos {
            videoCache.removeValue(forKey: id)
        }
    }
}
