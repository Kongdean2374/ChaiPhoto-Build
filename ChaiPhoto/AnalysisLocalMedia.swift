import Photos
import AVFoundation
import UIKit

// This manager is exclusively for analysis. Playback/network preferences never enter it.
final class AnalysisThumbnailWindow {
    let manager = PHCachingImageManager()
    let size = CGSize(width: 384, height: 384)
    let options: PHImageRequestOptions
    private var warmed: [PHAsset] = []
    init() {
        options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        manager.allowsCachingHighQualityImages = false
    }
    func move(to index: Int, in assets: [PHAsset]) {
        // Keep the current 100 plus the next 100; retire everything behind them.
        if index % 100 != 0 { return }
        let next = Array(assets[index..<min(assets.count, index + 200)])
        let ids = Set(next.map(\.localIdentifier))
        let previous = Set(warmed.map(\.localIdentifier))
        let retired = warmed.filter { !ids.contains($0.localIdentifier) }
        let incoming = next.filter { !previous.contains($0.localIdentifier) }
        manager.stopCachingImages(for: retired, targetSize: size, contentMode: .aspectFit, options: options)
        manager.startCachingImages(for: incoming, targetSize: size, contentMode: .aspectFit, options: options)
        warmed = next
    }
    func stop() { manager.stopCachingImagesForAllAssets(); warmed.removeAll() }
    func image(_ asset: PHAsset) async throws -> UIImage {
        try await AnalysisMediaRequest<UIImage>().run(timeout: 5) { complete in
            let id = self.manager.requestImage(for: asset, targetSize: self.size, contentMode: .aspectFit, options: self.options) { image, info in
                // A usable local image wins even if the original is marked in-cloud.
                if let image { complete(.success(image)) }
                else if info?[PHImageResultIsInCloudKey] as? Bool == true { complete(.failure(AnalysisMediaError.cloud)) }
                else if info?[PHImageCancelledKey] as? Bool == true { complete(.failure(CancellationError())) }
                else { complete(.failure(AnalysisMediaError.unavailable)) }
            }
            return { self.manager.cancelImageRequest(id) }
        }
    }
}

enum AnalysisMediaError: Error { case cloud, unavailable }

// Bridges PhotoKit/AVFoundation with one-shot completion, cancellation and a deadline.
private final class AnalysisMediaRequest<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var cancelRequest: (() -> Void)?
    private var timer: DispatchWorkItem?
    private var cancelled = false
    private var finished = false
    func run(timeout: Double, begin: @escaping (@escaping (Result<Value, Error>) -> Void) -> (() -> Void)) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.start(continuation, timeout: timeout, begin: begin)
            }
        } onCancel: { self.cancel() }
    }
    private func start(_ continuation: CheckedContinuation<Value, Error>, timeout: Double, begin: (@escaping (Result<Value, Error>) -> Void) -> (() -> Void)) {
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let timer = DispatchWorkItem { [weak self] in self?.finish(.failure(AnalysisMediaError.unavailable), stop: true) }
        self.timer = timer; lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
        let cancel = begin { [self] in finish($0, stop: false) }
        lock.lock(); cancelRequest = cancel; let stop = finished || cancelled; lock.unlock()
        if stop { cancel() }
    }
    private func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        finish(.failure(CancellationError()), stop: true)
    }
    private func finish(_ result: Result<Value, Error>, stop: Bool) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; timer?.cancel(); timer = nil
        let continuation = continuation; self.continuation = nil
        let cancel = cancelRequest; cancelRequest = nil
        lock.unlock()
        if stop { cancel?() }
        continuation?.resume(with: result)
    }
}

enum AnalysisLocalVideo {
    static func frames(_ asset: PHAsset, item: AnalysisMetadata, store: AnalysisFeatureStore) async throws -> [String] {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .fastFormat
        options.version = .current
        let video: AVAsset = try await AnalysisMediaRequest<AVAsset>().run(timeout: 6) { complete in
            let manager = PHImageManager.default()
            let id = manager.requestAVAsset(forVideo: asset, options: options) { value, _, info in
                // A local file URL is required; uncertain/composed assets stay poster-only.
                if let value = value as? AVURLAsset, value.url.isFileURL { complete(.success(value)) }
                else if info?[PHImageResultIsInCloudKey] as? Bool == true { complete(.failure(AnalysisMediaError.cloud)) }
                else { complete(.failure(AnalysisMediaError.unavailable)) }
            }
            return { manager.cancelImageRequest(id) }
        }
        let duration = try await video.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw AnalysisMediaError.unavailable }
        let generator = AVAssetImageGenerator(asset: video)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 384, height: 384)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        defer { generator.cancelAllCGImageGeneration() }
        var keys: [String] = []
        for (index, fraction) in [0.0, 0.25, 0.5, 0.75, 0.9].enumerated() {
            try Task.checkCancellation()
            let key = AnalysisFeatureStore.key(item, suffix: "frame-\(index)")
            if store.exists(key) { keys.append(key); continue }
            let time = CMTime(seconds: duration * fraction, preferredTimescale: 600)
            let image: CGImage = try await AnalysisMediaRequest<CGImage>().run(timeout: 8) { complete in
                generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, _, _ in
                    if let image { complete(.success(image)) } else { complete(.failure(AnalysisMediaError.unavailable)) }
                }
                return { generator.cancelAllCGImageGeneration() }
            }
            let generated = try autoreleasepool { try store.generate(UIImage(cgImage: image), item: item, key: key) }
            guard generated else { throw AnalysisMediaError.unavailable }
            keys.append(key)
        }
        return keys
    }
}
