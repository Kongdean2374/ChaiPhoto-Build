import Foundation
import Photos
import SwiftUI

private struct SavedAnalysis: Codable {
    let algorithm: Int
    let folderID: UUID
    let entries: [String: AnalysisEntry]
    let groups: [AnalysisGroup]
    let scannedAt: Date?
    let total: Int
    let complete: Bool
}

@MainActor
final class MediaAnalysis: ObservableObject {
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "analysis.enabled"); if !enabled { cancel() } }
    }
    @Published private(set) var running = false
    @Published private(set) var processed = 0
    @Published private(set) var total = 0
    @Published private(set) var checked = 0
    @Published private(set) var cloud = 0
    @Published private(set) var unavailable = 0
    @Published private(set) var reused = 0
    @Published private(set) var phase = ""
    @Published private(set) var complete = false
    @Published private(set) var scannedAt: Date?
    @Published private(set) var revision = 0
    @Published private(set) var groups: [AnalysisGroup] = []
    @Published private(set) var largeVideoIDs: Set<String> = []
    @Published private(set) var message: String?
    private var entries: [String: AnalysisEntry] = [:]
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var folderID = UUID()
    private let writer = DispatchQueue(label: "tw.chai2374.analysis-save", qos: .utility)
    private let url: URL
    var hasResults: Bool { scannedAt != nil }
    var duplicateGroups: [[String]] { groups.filter { !$0.video }.map(\.ids) }
    var videoDuplicateGroups: [[String]] { groups.filter(\.video).map(\.ids) }
    var duplicateIDs: Set<String> { Set(duplicateGroups.flatMap { $0 }) }
    var videoDuplicateIDs: Set<String> { Set(videoDuplicateGroups.flatMap { $0 }) }
    var coverage: String {
        L("中繼資料 \(total) 項・已取得視覺特徵 \(checked) 項・無本機預覽 \(cloud + unavailable) 項", "Metadata: \(total) · Visual features: \(checked) · No local preview: \(cloud + unavailable)")
    }
    var unavailableItems: [AnalysisMetadata] {
        entries.values.filter { $0.state == .cloud || $0.state == .unavailable }.map(\.metadata)
            .sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
    }
    func isCloudUnavailable(_ id: String) -> Bool { entries[id]?.state == .cloud }
    func evidence(for id: String) -> AnalysisEvidence? { groups.first { $0.ids.contains(id) }?.evidence }
    private var featureFolder: URL { url.deletingLastPathComponent().appendingPathComponent("analysis-features-\(folderID.uuidString)", isDirectory: true) }
    init() {
        enabled = UserDefaults.standard.bool(forKey: "analysis.enabled")
        url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("media-analysis.json")
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(SavedAnalysis.self, from: data), saved.algorithm == 3 {
            folderID = saved.folderID; entries = saved.entries; groups = saved.groups
            scannedAt = saved.scannedAt; total = saved.total; complete = saved.complete
            processed = complete ? total : entries.count
        }
        refreshCounts()
    }
    func synchronize(_ assets: [PHAsset]) {
        let current = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) })
        let valid = entries.filter { id, entry in
            guard let asset = current[id] else { return false }
            return asset.modificationDate == entry.metadata.modified
        }
        if valid.count != entries.count {
            entries = valid; complete = false
            groups = groups.compactMap { group in
                var group = group; group.ids.removeAll { valid[$0] == nil }
                return group.ids.count > 1 ? group : nil
            }
            refreshCounts(); save()
        }
    }
    func start(_ assets: [PHAsset], automatic: Bool = false) {
        guard !running, enabled else { return }
        if automatic && Self.shouldPause { return }
        synchronize(assets)
        let generation = UUID(); self.generation = generation
        let previousComplete = complete
        running = true; complete = false; processed = 0; total = assets.count; reused = 0; message = nil
        phase = L("建立中繼資料候選", "Indexing metadata candidates")
        let cached = entries, priorGroups = groups
        let store = AnalysisFeatureStore(folder: featureFolder)
        task = Task.detached(priority: .utility) { [weak self] in
            let metadata = AnalysisMetadata.collect(assets)
            guard !Task.isCancelled else { return }
            if automatic && previousComplete && metadata.count == cached.count && metadata.allSatisfy({ cached[$0.id]?.metadata == $0 }) {
                await self?.unchanged(generation); return
            }
            let plan = AnalysisCandidatePlan(metadata)
            let assetMap = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) })
            var entries: [String: AnalysisEntry] = [:]
            var pending: [PHAsset] = []
            var reused = 0
            for item in metadata {
                if Task.isCancelled { return }
                var entry = cached[item.id] ?? AnalysisEntry(metadata: item)
                if entry.metadata.modified != item.modified || entry.metadata.width != item.width || entry.metadata.height != item.height {
                    entry = AnalysisEntry(metadata: item)
                }
                entry.metadata = item
                if plan.required.contains(item.id), let asset = assetMap[item.id] {
                    let key = AnalysisFeatureStore.key(item)
                    if store.exists(key) {
                        entry.featureKey = key; entry.state = .ready; reused += 1
                    } else if !automatic || entry.state == .metadataOnly || entry.state == .ready {
                        pending.append(asset)
                    }
                }
                entries[item.id] = entry
            }
            let validPrior = priorGroups.compactMap { group -> AnalysisGroup? in
                var group = group
                group.ids.removeAll { id in cached[id]?.metadata != entries[id]?.metadata || entries[id]?.state != .ready }
                return group.ids.count > 1 ? group : nil
            }
            await self?.checkpoint(entries, groups: validPrior, generation: generation, finished: false)
            let window = AnalysisThumbnailWindow()
            defer { window.stop() }
            var processed = metadata.count - pending.count
            await self?.progress(processed, reused: reused, phase: L("辨識本機縮圖與影片封面", "Analyzing local thumbnails and posters"), generation: generation)
            do {
                for (index, asset) in pending.enumerated() {
                    try Task.checkCancellation()
                    if Self.shouldPause { break }
                    window.move(to: index, in: pending)
                    let id = asset.localIdentifier
                    guard var entry = entries[id] else { continue }
                    do {
                        let image = try await window.image(asset)
                        let key = AnalysisFeatureStore.key(entry.metadata)
                        let success = try autoreleasepool { try store.generate(image, item: entry.metadata, key: key) }
                        entry.state = success ? .ready : .lowDetail
                        entry.featureKey = success ? key : nil
                    } catch {
                        try Task.checkCancellation()
                        entry.state = (error as? AnalysisMediaError) == .cloud ? .cloud : .unavailable
                        entry.featureKey = nil
                    }
                    entries[id] = entry; processed += 1
                    if index % 50 == 0 {
                        await self?.progress(processed, reused: reused, phase: L("辨識本機縮圖與影片封面", "Analyzing local thumbnails and posters"), generation: generation)
                    }
                    if index > 0 && index % 1000 == 0 { await self?.checkpoint(entries, groups: validPrior, generation: generation, finished: false) }
                    // Bounded, sequential utility work; yield between fresh features.
                    try await Task.sleep(for: .milliseconds(10))
                }
                window.stop()
                try Task.checkCancellation()
                await self?.progress(processed, reused: reused, phase: L("比較相似候選", "Comparing visual candidates"), generation: generation)
                var groups = AnalysisGrouping.make(metadata, entries: entries, plan: plan, store: store, includeFrames: false)
                await self?.checkpoint(entries, groups: groups, generation: generation, finished: false)
                let candidateVideos = Set(groups.filter(\.video).flatMap(\.ids))
                if !Self.shouldPause {
                    await self?.progress(processed, reused: reused, phase: L("比對本機影片畫面・不下載", "Checking local video frames · no downloads"), generation: generation)
                    for id in candidateVideos.sorted() {
                        try Task.checkCancellation()
                        if Self.shouldPause { break }
                        guard var entry = entries[id], let asset = assetMap[id] else { continue }
                        if entry.framesAttempted && (automatic || entry.frameKeys.count == 5) { continue }
                        do { entry.frameKeys = try await AnalysisLocalVideo.frames(asset, item: entry.metadata, store: store) }
                        catch { try Task.checkCancellation(); entry.frameKeys = [] }
                        entry.framesAttempted = true
                        entries[id] = entry
                    }
                    groups = AnalysisGrouping.make(metadata, entries: entries, plan: plan, store: store, includeFrames: true)
                }
                try Task.checkCancellation()
                let finished = processed == metadata.count && !Self.shouldPause
                await self?.progress(processed, reused: reused, phase: finished ? L("辨識完成", "Analysis complete") : L("省電／溫度保護，已暫停", "Paused for power / temperature"), generation: generation)
                await self?.checkpoint(entries, groups: groups, generation: generation, finished: finished, stopped: true)
                let used = Set(entries.values.flatMap { ($0.featureKey.map { [$0] } ?? []) + $0.frameKeys })
                store.prune(keeping: used)
            } catch {
                // Main-actor cancellation preserves the last checkpoint; generated
                // feature files can be reused even if a checkpoint was interrupted.
            }
        }
    }
    nonisolated private static var shouldPause: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical
    }
    private func unchanged(_ generation: UUID) {
        guard self.generation == generation else { return }
        running = false; task = nil; complete = true; processed = total; reused = checked
        phase = L("已沿用既有辨識索引", "Reused existing analysis index")
    }
    private func progress(_ count: Int, reused: Int, phase: String, generation: UUID) {
        guard self.generation == generation else { return }
        processed = count; self.reused = reused; self.phase = phase
    }
    private func checkpoint(_ entries: [String: AnalysisEntry], groups: [AnalysisGroup], generation: UUID, finished: Bool, stopped: Bool = false) {
        guard self.generation == generation else { return }
        self.entries = entries; self.groups = groups; complete = finished; scannedAt = Date()
        refreshCounts(); save()
        if stopped {
            running = false; task = nil
            message = (finished ? L("辨識完成。", "Analysis complete.") : L("已保留部分結果。", "Partial results saved.")) + " " + coverage
        }
    }
    func cancel() {
        guard running else { return }
        generation = UUID(); task?.cancel(); task = nil; running = false; complete = false
        phase = L("已暫停", "Paused"); save()
    }
    func clear() {
        cancel()
        let oldFolder = featureFolder
        folderID = UUID(); entries = [:]; groups = []; scannedAt = nil
        total = 0; processed = 0; reused = 0; complete = false; message = nil; phase = ""
        refreshCounts(); save()
        writer.async { try? FileManager.default.removeItem(at: oldFolder) }
    }
    private func refreshCounts() {
        checked = entries.values.filter { $0.state == .ready }.count
        cloud = entries.values.filter { $0.state == .cloud }.count
        unavailable = entries.values.filter { $0.state == .unavailable }.count
        largeVideoIDs = Set(entries.values.filter { $0.metadata.longVideo }.map { $0.metadata.id })
        revision &+= 1
    }
    private func save() {
        let saved = SavedAnalysis(algorithm: 3, folderID: folderID, entries: entries, groups: groups, scannedAt: scannedAt, total: total, complete: complete)
        let url = url
        writer.async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(saved).write(to: url, options: .atomic)
            } catch { /* Analysis cache failure never changes sorting decisions. */ }
        }
    }
}

private enum AnalysisGrouping {
    static func make(_ metadata: [AnalysisMetadata], entries: [String: AnalysisEntry], plan: AnalysisCandidatePlan, store: AnalysisFeatureStore, includeFrames: Bool) -> [AnalysisGroup] {
        var groups: [AnalysisGroup] = []
        var membership: [String: Int] = [:]
        for item in metadata {
            if Task.isCancelled { return [] }
            guard let entry = entries[item.id], let key = entry.featureKey else { continue }
            var tried = Set<String>()
            for candidate in plan.previous[item.id, default: []] {
                let groupIndex = membership[candidate]
                let representative = groupIndex.map { groups[$0].ids[0] } ?? candidate
                guard tried.insert(representative).inserted,
                      let other = entries[representative], item.candidate(with: other.metadata),
                      let otherKey = other.featureKey,
                      var evidence = store.compare(key, otherKey, video: item.video) else { continue }
                if item.video && includeFrames, let matched = store.framesMatch(entry.frameKeys, other.frameKeys) {
                    if !matched { continue }
                    evidence = .multipleFrames
                }
                if let groupIndex {
                    groups[groupIndex].ids.append(item.id)
                    groups[groupIndex].evidence = AnalysisEvidence(rawValue: min(groups[groupIndex].evidence.rawValue, evidence.rawValue)) ?? .similar
                    membership[item.id] = groupIndex
                } else {
                    let index = groups.count
                    groups.append(AnalysisGroup(ids: [representative, item.id], evidence: evidence, video: item.video))
                    membership[representative] = index; membership[item.id] = index
                }
                break
            }
        }
        return groups
    }
}
