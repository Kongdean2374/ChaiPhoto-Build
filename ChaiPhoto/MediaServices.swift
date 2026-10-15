import Photos
import AVFoundation
import SwiftUI

struct ResourceSize {
    let bytes: Int64
    let complete: Bool
}

/// Counts streamed chunks without retaining photo/video bytes or downloading cloud data.
private final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0
    private var request: PHAssetResourceDataRequestID?
    private var cancelled = false
    func add(_ count: Int) { lock.lock(); bytes += Int64(count); lock.unlock() }
    func value() -> Int64 { lock.lock(); defer { lock.unlock() }; return bytes }
    func set(_ id: PHAssetResourceDataRequestID) {
        lock.lock(); request = id; let cancel = cancelled; lock.unlock()
        if cancel { PHAssetResourceManager.default().cancelDataRequest(id) }
    }
    func cancel() {
        lock.lock(); cancelled = true; let id = request; lock.unlock()
        if let id { PHAssetResourceManager.default().cancelDataRequest(id) }
    }
}

actor ResourceSizer {
    static let shared = ResourceSizer()
    private var cache: [String: ResourceSize] = [:]
    func measure(_ asset: PHAsset) async -> ResourceSize {
        let key = asset.localIdentifier + String(asset.modificationDate?.timeIntervalSince1970 ?? 0)
        if let cached = cache[key] { return cached }
        let resources = PHAssetResource.assetResources(for: asset)
        var total: Int64 = 0
        var complete = !resources.isEmpty
        for resource in resources {
            if Task.isCancelled { return ResourceSize(bytes: total, complete: false) }
            let counter = ByteCounter()
            let result: ResourceSize = await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { continuation in
                    let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = false
                    let id = PHAssetResourceManager.default().requestData(for: resource, options: options, dataReceivedHandler: { data in counter.add(data.count) }, completionHandler: { error in
                        continuation.resume(returning: ResourceSize(bytes: error == nil ? counter.value() : 0, complete: error == nil))
                    })
                    counter.set(id)
                }
            }, onCancel: { counter.cancel() })
            total += result.bytes; complete = complete && result.complete
        }
        let result = ResourceSize(bytes: total, complete: complete)
        if !Task.isCancelled && complete { cache[key] = result }
        return result
    }
}

@MainActor
final class SizeEstimator: ObservableObject {
    @Published var values: [String: ResourceSize] = [:]
    @Published var running = false
    @Published var progress = 0
    private var task: Task<Void, Never>?
    private var generation = UUID()
    func start(_ assets: [PHAsset]) {
        stop(); progress = 0; running = true
        let token = generation
        task = Task {
            for asset in assets {
                guard !Task.isCancelled, token == generation else { return }
                let size = await ResourceSizer.shared.measure(asset)
                guard !Task.isCancelled, token == generation else { return }
                values[asset.localIdentifier] = size; progress += 1
            }
            if token == generation { running = false }
        }
    }
    func stop() { generation = UUID(); task?.cancel(); task = nil; running = false }
    func summary(_ ids: Set<String>) -> (Int64, Int) {
        var bytes: Int64 = 0; var unknown = 0
        for id in ids {
            if let size = values[id] { bytes += size.bytes; if !size.complete { unknown += 1 } }
            else { unknown += 1 }
        }
        return (bytes, unknown)
    }
}
func byteText(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal) }

struct MediaInfoView: View {
    let asset: PHAsset
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings
    @State private var size: ResourceSize?
    @State private var fps: Float?
    var body: some View {
        NavigationStack {
            Form {
                Section(L("基本資訊", "Media information")) {
                    ForEach(Array(PHAssetResource.assetResources(for: asset).enumerated()), id: \.offset) { _, resource in
                        LabeledContent(L("檔案", "File"), value: resource.originalFilename)
                        LabeledContent(L("格式", "Format"), value: resource.uniformTypeIdentifier)
                    }
                    LabeledContent(L("解析度", "Resolution"), value: "\(asset.pixelWidth) × \(asset.pixelHeight)")
                    LabeledContent(L("總像素", "Megapixels"), value: String(format: "%.2f MP", Double(asset.pixelWidth) * Double(asset.pixelHeight) / 1_000_000))
                    if let date = asset.creationDate { LabeledContent(L("拍攝日期", "Captured"), value: appDateTime(date)) }
                    if let date = asset.modificationDate { LabeledContent(L("修改日期", "Modified"), value: appDateTime(date)) }
                    if asset.mediaType == .video {
                        LabeledContent(L("長度", "Duration"), value: String(format: "%.1f s", asset.duration))
                        LabeledContent(L("影格率", "Frame rate"), value: fps.map { String(format: "%.2f fps", $0) } ?? L("不可用", "Unavailable"))
                    }
                    if let location = asset.location {
                        LabeledContent(L("緯度", "Latitude"), value: String(format: "%.6f", location.coordinate.latitude))
                        LabeledContent(L("經度", "Longitude"), value: String(format: "%.6f", location.coordinate.longitude))
                    } else { Text(L("未提供位置資訊", "No location metadata")) }
                    Text(L("像素密度與街道地址未由相簿直接提供；不以螢幕密度或推測地址代替。", "Pixel density and street addresses are not directly supplied by the library; display density and guessed addresses are not substituted."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L("容量", "Size")) {
                    if let size {
                        LabeledContent(L("可讀取本機資源", "Readable local resources"), value: byteText(size.bytes))
                        if !size.complete { Text(L("部分資源不可讀取；完整大小未知。", "Some resources are unavailable; total size is unknown.")) }
                    } else { ProgressView(L("估算中…", "Estimating…")) }
                    Text(L("本機資源大小不等於立即釋放容量。iCloud 上傳狀態與雲端佔用量無法精確取得。", "Local resource size is not immediate free space. Exact iCloud upload status and cloud usage are unavailable.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(L("詳細資訊", "Details"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel(L("關閉", "Close")) } }
            .task {
                size = await ResourceSizer.shared.measure(asset)
                if asset.mediaType == .video {
                    let avAsset: AVAsset? = await withCheckedContinuation { continuation in
                        let options = PHVideoRequestOptions(); options.isNetworkAccessAllowed = false
                        PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { av, _, _ in continuation.resume(returning: av) }
                    }
                    if let avAsset, let track = try? await avAsset.loadTracks(withMediaType: .video).first { fps = try? await track.load(.nominalFrameRate) }
                }
            }
        }
    }
}

struct ShareFile: Identifiable { let id = UUID(); let url: URL }
struct SystemShareView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
func prepareVideoShare(_ asset: PHAsset, allowNetwork: Bool) async throws -> URL {
    let resources = PHAssetResource.assetResources(for: asset)
    guard let resource =
        resources.first(where: { $0.type == .fullSizeVideo }) ??
        resources.first(where: { $0.type == .video }) else {
        throw NSError(
            domain: "ChaiPhoto",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: L("找不到影片資源", "Video resource unavailable")
            ]
        )
    }

    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("share-" + UUID().uuidString)
    try FileManager.default.createDirectory(
        at: folder,
        withIntermediateDirectories: true
    )

    let name = URL(fileURLWithPath: resource.originalFilename).lastPathComponent
    let url = folder.appendingPathComponent(name)

    do {
        try await exportShareResource(resource, to: url, allowNetwork: allowNetwork)
        try Task.checkCancellation()

        return url
    } catch {
        try? FileManager.default.removeItem(at: folder)

        throw NSError(
            domain: "ChaiPhoto.Share",
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey: L(
                    "無法準備可分享的影片。若影片在 iCloud，請確認目前有網路連線後再試一次。",
                    "Could not prepare the video for sharing. If it is stored in iCloud, check your network connection and try again."
                ),
                NSUnderlyingErrorKey: error
            ]
        )
    }
}


func preparePhotoShare(_ asset: PHAsset, allowNetwork: Bool) async throws -> URL {
    let resources = PHAssetResource.assetResources(for: asset)
    guard let resource =
        resources.first(where: { $0.type == .fullSizePhoto }) ??
        resources.first(where: { $0.type == .photo }) else {
        throw NSError(
            domain: "ChaiPhoto",
            code: 3,
            userInfo: [
                NSLocalizedDescriptionKey: L("找不到照片資源", "Photo resource unavailable")
            ]
        )
    }

    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("share-" + UUID().uuidString)

    try FileManager.default.createDirectory(
        at: folder,
        withIntermediateDirectories: true
    )

    let name = URL(fileURLWithPath: resource.originalFilename).lastPathComponent
    let url = folder.appendingPathComponent(name)

    do {
        try await exportShareResource(resource, to: url, allowNetwork: allowNetwork)
        try Task.checkCancellation()

        return url
    } catch {
        try? FileManager.default.removeItem(at: folder)

        throw NSError(
            domain: "ChaiPhoto.Share",
            code: 4,
            userInfo: [
                NSLocalizedDescriptionKey: L(
                    "無法準備可分享的照片。若照片在 iCloud，請確認目前有網路連線後再試一次。",
                    "Could not prepare the photo for sharing. If it is stored in iCloud, check your network connection and try again."
                ),
                NSUnderlyingErrorKey: error
            ]
        )
    }
}

// Serializes streaming writes with cancellation; no full-size video is held in RAM.
private final class ShareResourceExport: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    private var request: PHAssetResourceDataRequestID?
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false
    private var cancelled = false

    private let allowNetwork: Bool
    init(url: URL, allowNetwork: Bool) throws {
        self.allowNetwork = allowNetwork
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    func start(_ resource: PHAssetResource, continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        lock.unlock()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        let id = PHAssetResourceManager.default().requestData(for: resource, options: options) { [self] data in
            lock.lock()
            guard !finished else { lock.unlock(); return }
            do { try handle?.write(contentsOf: data); lock.unlock() }
            catch { lock.unlock(); finish(error) }
        } completionHandler: { [self] error in finish(error) }
        lock.lock()
        request = id
        let shouldCancel = finished || cancelled
        lock.unlock()
        if shouldCancel { PHAssetResourceManager.default().cancelDataRequest(id) }
    }

    func cancel() {
        lock.lock(); cancelled = true; let id = request; lock.unlock()
        finish(CancellationError())
        if let id { PHAssetResourceManager.default().cancelDataRequest(id) }
    }

    private func finish(_ error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        var resultError = error
        do { try handle?.close() } catch { if resultError == nil { resultError = error } }
        handle = nil
        let callback = continuation; continuation = nil
        lock.unlock()
        if let resultError { callback?.resume(throwing: resultError) }
        else { callback?.resume() }
    }
}

private func exportShareResource(_ resource: PHAssetResource, to url: URL, allowNetwork: Bool) async throws {
    let export = try ShareResourceExport(url: url, allowNetwork: allowNetwork)
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { export.start(resource, continuation: $0) }
    } onCancel: { export.cancel() }
}
