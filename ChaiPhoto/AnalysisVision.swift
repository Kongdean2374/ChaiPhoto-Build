import Foundation
import Photos
import UIKit
import Vision
import CryptoKit
import ImageIO

struct ThumbnailSignature: Codable {
    let hash: UInt64
    let samples: Data
    let aspect: Double

    static func make(_ image: UIImage, aspect: Double) -> ThumbnailSignature? {
        guard image.size.width * image.scale >= 32, image.size.height * image.scale >= 32 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true; format.preferredRange = .standard
        let small = UIGraphicsImageRenderer(size: CGSize(width: 9, height: 8), format: format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 9, height: 8))
            image.draw(in: CGRect(x: 0, y: 0, width: 9, height: 8))
        }
        guard let cg = small.cgImage else { return nil }
        var rgba = [UInt8](repeating: 0, count: 9 * 8 * 4)
        let ok = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 9, height: 8, bitsPerComponent: 8, bytesPerRow: 36, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: 9, height: 8)); return true
        }
        guard ok else { return nil }
        var luminance = [Int]()
        luminance.reserveCapacity(72)
        for i in 0..<72 {
            let offset = i * 4
            let red = Int(rgba[offset]) * 299
            let green = Int(rgba[offset + 1]) * 587
            let blue = Int(rgba[offset + 2]) * 114
            luminance.append((red + green + blue) / 1000)
        }
        // Blank/low-detail images are too ambiguous for safe visual grouping.
        guard (luminance.max() ?? 0) - (luminance.min() ?? 0) >= 24 else { return nil }
        var hash: UInt64 = 0
        for y in 0..<8 { for x in 0..<8 {
            if luminance[y * 9 + x] > luminance[y * 9 + x + 1] { hash |= UInt64(1) << (y * 8 + x) }
        } }
        var samples = Data()
        samples.reserveCapacity(216)
        for i in 0..<72 {
            let offset = i * 4
            samples.append(rgba[offset])
            samples.append(rgba[offset + 1])
            samples.append(rgba[offset + 2])
        }
        return ThumbnailSignature(hash: hash, samples: samples, aspect: aspect)
    }
    func resembles(_ other: ThumbnailSignature) -> Bool {
        guard abs(aspect / other.aspect - 1) <= 0.03,
              (hash ^ other.hash).nonzeroBitCount <= 5,
              samples.count == 216, other.samples.count == 216 else { return false }
        let difference = zip(samples, other.samples).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return difference <= samples.count * 10
    }
}

private struct StoredVisionFeature: Codable {
    let observation: Data
    let signature: ThumbnailSignature
}
private final class CachedVisionFeature: NSObject {
    let observation: VNFeaturePrintObservation
    let signature: ThumbnailSignature
    init(_ observation: VNFeaturePrintObservation, _ signature: ThumbnailSignature) {
        self.observation = observation; self.signature = signature
    }
}

// Feature blobs are individual files, not a giant JSON rewritten after every photo.
// Decoded observations are bounded in memory; keys include the algorithm revision.
final class AnalysisFeatureStore: @unchecked Sendable {
    let folder: URL
    private let cache = NSCache<NSString, CachedVisionFeature>()
    init(folder: URL) {
        self.folder = folder
        cache.countLimit = 192; cache.totalCostLimit = 12 * 1024 * 1024
    }
    static func key(_ item: AnalysisMetadata, suffix: String = "preview") -> String {
        let text = "v3-vision2-384|\(item.id)|\(item.modified?.timeIntervalSince1970 ?? 0)|\(item.width)x\(item.height)|\(suffix)"
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func exists(_ key: String) -> Bool { read(key) != nil }
    private func read(_ key: String) -> CachedVisionFeature? {
        if let cached = cache.object(forKey: key as NSString) { return cached }
        guard key.count == 64, key.allSatisfy({ $0.isHexDigit }),
              let data = try? Data(contentsOf: folder.appendingPathComponent(key)),
              let stored = try? PropertyListDecoder().decode(StoredVisionFeature.self, from: data),
              let observation = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: stored.observation),
              observation.requestRevision == VNGenerateImageFeaturePrintRequestRevision2 else { return nil }
        let value = CachedVisionFeature(observation, stored.signature)
        cache.setObject(value, forKey: key as NSString, cost: stored.observation.count)
        return value
    }
    func generate(_ image: UIImage, item: AnalysisMetadata, key: String) throws -> Bool {
        if exists(key) { return true }
        try Task.checkCancellation()
        let image = Self.bounded(image)
        guard let cg = image.cgImage, let signature = ThumbnailSignature.make(image, aspect: item.aspect) else { return false }
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        request.preferBackgroundProcessing = true
        request.imageCropAndScaleOption = .scaleFit
        let handler = VNImageRequestHandler(cgImage: cg, orientation: image.imageOrientation.visionOrientation, options: [:])
        try handler.perform([request])
        try Task.checkCancellation()
        guard let observation = request.results?.first else { return false }
        let data = try NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
        let stored = StoredVisionFeature(observation: data, signature: signature)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        try encoder.encode(stored).write(to: folder.appendingPathComponent(key), options: .atomic)
        cache.setObject(CachedVisionFeature(observation, signature), forKey: key as NSString, cost: data.count)
        return true
    }
    private static func bounded(_ image: UIImage) -> UIImage {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let factor = min(1, 384 / max(1, max(pixels.width, pixels.height)))
        let size = CGSize(width: max(1, pixels.width * factor), height: max(1, pixels.height * factor))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true; format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
    func compare(_ a: String, _ b: String, video: Bool) -> AnalysisEvidence? {
        guard let first = read(a), let second = read(b) else { return nil }
        var distance: Float = 0
        do { try first.observation.computeDistance(&distance, to: second.observation) } catch { return nil }
        guard distance.isFinite else { return nil }
        let veryClose = first.signature.resembles(second.signature)
        // Conservative heuristics for Vision revision 2, not a certainty/probability.
        if video { return distance <= 0.10 && veryClose ? .poster : nil }
        if distance <= 0.10 && veryClose { return .highlySimilar }
        return distance <= 0.20 ? .similar : nil
    }
    func framesMatch(_ a: [String], _ b: [String]) -> Bool? {
        guard a.count == 5, b.count == 5 else { return nil }
        for (firstKey, secondKey) in zip(a, b) {
            guard let first = read(firstKey), let second = read(secondKey) else { return nil }
            var distance: Float = 0
            do { try first.observation.computeDistance(&distance, to: second.observation) } catch { return nil }
            if !distance.isFinite || distance > 0.12 { return false }
        }
        return true
    }
    func prune(keeping keys: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files {
            if Task.isCancelled { return }
            if !keys.contains(file.lastPathComponent) { try? FileManager.default.removeItem(at: file) }
        }
    }
}

private extension UIImage.Orientation {
    var visionOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
