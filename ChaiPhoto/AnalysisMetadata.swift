import Foundation
import Photos

struct AnalysisMetadata: Codable, Equatable {
    let id: String
    let created: Date?
    let modified: Date?
    let width: Int
    let height: Int
    let type: Int
    let subtypes: UInt
    let favorite: Bool
    let burst: String?
    let duration: Double
    let albums: [String]
    var video: Bool { type == PHAssetMediaType.video.rawValue }
    var aspect: Double { Double(max(1, width)) / Double(max(1, height)) }
    var longVideo: Bool { video && (duration >= 300 || min(width, height) >= 2160) }
    var family: String {
        if video { return "video" }
        let flags = PHAssetMediaSubtype(rawValue: subtypes)
        if flags.contains(.photoScreenshot) { return "screenshot" }
        if flags.contains(.photoPanorama) { return "panorama" }
        return flags.contains(.photoLive) ? "live" : "photo"
    }
    init(_ asset: PHAsset, albums: [String]) {
        id = asset.localIdentifier; created = asset.creationDate; modified = asset.modificationDate
        width = asset.pixelWidth; height = asset.pixelHeight; type = asset.mediaType.rawValue
        subtypes = asset.mediaSubtypes.rawValue; favorite = asset.isFavorite
        burst = asset.burstIdentifier
        duration = asset.duration.isFinite ? max(0, asset.duration) : 0
        self.albums = albums
    }
    func candidate(with other: AnalysisMetadata) -> Bool {
        guard family == other.family, abs(aspect / other.aspect - 1) <= 0.04 else { return false }
        if video {
            guard duration > 0, other.duration > 0, width > 0, height > 0 else { return false }
            let tolerance = max(0.25, min(1, duration * 0.002))
            guard width == other.width, height == other.height, abs(duration - other.duration) <= tolerance else { return false }
        } else {
            let ratio = Double(max(1, width)) / Double(max(1, other.width))
            guard ratio >= 0.5, ratio <= 2 else { return false }
        }
        if let burst, !burst.isEmpty, burst == other.burst { return true }
        if let created, let date = other.created {
            if abs(created.timeIntervalSince(date)) <= 90 { return true }
            if Calendar.current.isDate(created, inSameDayAs: date), width == other.width, height == other.height { return true }
        }
        return width == other.width && height == other.height && !Set(albums).isDisjoint(with: other.albums)
    }
    static func collect(_ assets: [PHAsset]) -> [AnalysisMetadata] {
        let ids = Set(assets.map(\.localIdentifier))
        var memberships: [String: [String]] = [:]
        // Read album membership through PhotoKit; no image/resource requests.
        let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        albums.enumerateObjects { album, _, stop in
            if Task.isCancelled { stop.pointee = true; return }
            PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { asset, _, innerStop in
                if Task.isCancelled { innerStop.pointee = true; return }
                if ids.contains(asset.localIdentifier) { memberships[asset.localIdentifier, default: []].append(album.localIdentifier) }
            }
        }
        return assets.map { AnalysisMetadata($0, albums: memberships[$0.localIdentifier, default: []].sorted()) }
            .sorted {
                let a = $0.created ?? .distantPast, b = $1.created ?? .distantPast
                return a == b ? $0.id < $1.id : a < b
            }
    }
}

struct AnalysisCandidatePlan {
    let previous: [String: [String]]
    let required: Set<String>
    init(_ metadata: [AnalysisMetadata]) {
        var buckets: [String: [Int]] = [:]
        var previous: [String: [String]] = [:]
        var required = Set<String>()
        for (i, item) in metadata.enumerated() {
            if Task.isCancelled { break }
            var keys = ["recent:\(item.family)"]
            let size = "\(item.width)x\(item.height)"
            if let date = item.created {
                let day = Int(Calendar.current.startOfDay(for: date).timeIntervalSince1970)
                keys.append("day:\(item.family):\(day):\(size)")
            }
            if let burst = item.burst { keys.append("burst:\(burst)") }
            // Bound album expansion as well as comparisons for very large libraries.
            keys += item.albums.prefix(8).map { "album:\($0):\(item.family):\(size)" }
            var indices = Set<Int>()
            for key in keys { indices.formUnion(buckets[key, default: []]) }
            let candidates = indices.sorted(by: >).filter { item.candidate(with: metadata[$0]) }.prefix(32)
            if !candidates.isEmpty {
                previous[item.id] = candidates.map { metadata[$0].id }
                required.insert(item.id)
                required.formUnion(previous[item.id]!)
            }
            for key in keys {
                var items = buckets[key, default: []]
                items.append(i)
                if items.count > 32 { items.removeFirst(items.count - 32) }
                buckets[key] = items
            }
        }
        self.previous = previous; self.required = required
    }
}

enum AnalysisPreviewState: String, Codable { case metadataOnly, ready, cloud, unavailable, lowDetail }
struct AnalysisEntry: Codable {
    var metadata: AnalysisMetadata
    var state: AnalysisPreviewState = .metadataOnly
    var featureKey: String?
    var frameKeys: [String] = []
    var framesAttempted = false
}
enum AnalysisEvidence: Int, Codable {
    case similar = 0, highlySimilar = 1, poster = 2, multipleFrames = 3
    var label: String {
        switch self {
        case .similar: return L("相似照片", "Similar photos")
        case .highlySimilar: return L("高度疑似重複・非原檔比對", "Highly similar · originals not compared")
        case .poster: return L("疑似重複影片・僅封面與資料", "Possible duplicate videos · poster and metadata only")
        case .multipleFrames: return L("疑似重複影片・已比對 5 個本機畫面", "Possible duplicate videos · 5 local frames compared")
        }
    }
}
struct AnalysisGroup: Codable {
    var ids: [String]
    var evidence: AnalysisEvidence
    var video: Bool
}
