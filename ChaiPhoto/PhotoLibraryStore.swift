import Foundation
import Photos
import SwiftUI

enum PhotoDecision: String, Codable {
    case keep, delete, favorite
    var label: String {
        switch self {
        case .keep: L("保留", "Kept")
        case .delete: L("待刪", "Pending deletion")
        case .favorite: L("收藏", "Favorite")
        }
    }
}

enum PhotoGroup: String, CaseIterable, Identifiable {
    case all = "全部", photos = "照片", videos = "影片", screenshots = "截圖", live = "Live Photo"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .all: "square.grid.2x2.fill"
        case .photos: "photo.fill"
        case .videos: "video.fill"
        case .screenshots: "rectangle.on.rectangle"
        case .live: "livephoto"
        }
    }
    func includes(_ asset: PHAsset) -> Bool {
        switch self {
        case .all: true
        case .photos: asset.mediaType == .image
        case .videos: asset.mediaType == .video
        case .screenshots: asset.mediaSubtypes.contains(.photoScreenshot)
        case .live: asset.mediaSubtypes.contains(.photoLive)
        }
    }
}

struct DecisionAction: Codable, Identifiable {
    let id: UUID
    let assetID: String
    let before: PhotoDecision?
    let after: PhotoDecision
    let timestamp: Date
    var undoneAt: Date? = nil
    var filename: String? = nil

    init(assetID: String, before: PhotoDecision?, after: PhotoDecision) {
        self.id = UUID()
        self.assetID = assetID
        self.before = before
        self.after = after
        self.timestamp = Date()
    }
}

struct DeletionRecord: Codable, Identifiable {
    let id: UUID
    let date: Date
    let names: [String]
    let assetIDs: [String]
}

private struct SavedChoices: Codable {
    var decisions: [String: PhotoDecision] = [:]
    var history: [DecisionAction] = []
    var exclusions: Set<String>? = nil
    var deletions: [DeletionRecord]? = nil
    var deletedIDs: Set<String>? = nil
    var reopenedIDs: [String]? = nil
}

@MainActor
final class PhotoLibraryStore: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published private(set) var authorization: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var assets: [PHAsset] = []
    @Published private(set) var decisions: [String: PhotoDecision] = [:]
    @Published private(set) var history: [DecisionAction] = []
    @Published private(set) var groupCounts: [PhotoGroup: Int] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var isDeleting = false
    @Published var message: String?
    @Published var successNotice: String?
    @Published private(set) var exclusions: Set<String> = []
    @Published private(set) var deletions: [DeletionRecord] = []
    @Published private(set) var deletedIDs: Set<String> = []
    /// Items explicitly restored from Review/History are shown before the normal
    /// resume cursor until the user reviews them again.
    @Published private(set) var reopenedIDs: [String] = []

    @Published private(set) var revision = 0
    private(set) var decisionRevision = 0
    private(set) var isSortingTransition = false
    private var transition: (id: UUID, assetID: String)?
    private let saveQueue = DispatchQueue(label: "tw.chai2374.progress-writer", qos: .utility)
    private var changeTask: Task<Void, Never>?
    private let saveURL: URL
    private var loadGeneration = 0
    private var observedFetch: PHFetchResult<PHAsset>?
    private var hasLoadedLibrary = false
    private var interactingAssetID: String?

    func setSortingInteraction(_ active: Bool, assetID: String) {
        if active { interactingAssetID = assetID }
        else if interactingAssetID == assetID { interactingAssetID = nil }
    }

    override convenience init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(saveURL: folder.appendingPathComponent("photo-choices.json"))
    }

    init(saveURL: URL) {
        self.saveURL = saveURL
        if let data = try? Data(contentsOf: saveURL), let saved = try? JSONDecoder().decode(SavedChoices.self, from: data) {
            decisions = saved.decisions
            history = saved.history
            exclusions = saved.exclusions ?? []
            deletions = saved.deletions ?? []
            deletedIDs = saved.deletedIDs ?? []
            reopenedIDs = saved.reopenedIDs ?? []
        }
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let fetch = self.observedFetch,
               changeInstance.changeDetails(for: fetch) == nil {
                // Album membership may change without changing the all-assets fetch.
                self.revision += 1
                return
            }
            self.changeTask?.cancel()
            self.changeTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled, let self else { return }
                // Do not replace the card beneath an in-flight swipe.
                while self.isSortingTransition || self.interactingAssetID != nil || self.isDeleting {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled else { return }
                }
                await self.requestCurrentStatus()
            }
        }
    }

    func beginTransition(for asset: PHAsset) -> UUID? {
        setSortingInteraction(false, assetID: asset.localIdentifier)
        guard !isDeleting, !isSortingTransition, hasAccess,
              self.asset(for: asset.localIdentifier) != nil,
              !deletedIDs.contains(asset.localIdentifier),
              decisions[asset.localIdentifier] == nil else { return nil }
        let id = UUID()
        transition = (id, asset.localIdentifier)
        isSortingTransition = true
        return id
    }

    func finishTransition(_ token: UUID) -> Bool {
        guard let pending = transition, pending.id == token else { return false }
        setSortingInteraction(false, assetID: pending.assetID)
        transition = nil
        isSortingTransition = false
        return hasAccess && !isDeleting && asset(for: pending.assetID) != nil && decisions[pending.assetID] == nil
    }

    func cancelTransition(for assetID: String) {
        setSortingInteraction(false, assetID: assetID)
        guard transition?.assetID == assetID else { return }
        transition = nil; isSortingTransition = false
    }

    func flushPendingWrites() async {
        await withCheckedContinuation { continuation in
            saveQueue.async { continuation.resume() }
        }
    }

    var hasAccess: Bool { authorization == .authorized || authorization == .limited }
    var pending: [PHAsset] { assets.filter { decisions[$0.localIdentifier] == .delete } }
    var selectedPending: Set<String> { Set(pending.map(\.localIdentifier)).subtracting(exclusions) }
    func toggleExclusion(_ id: String) {
        guard !isDeleting else { return }
        if exclusions.contains(id) { exclusions.remove(id) } else { exclusions.insert(id) }
        persist()
    }
    func selectAllPending() { guard !isDeleting else { return }; exclusions.removeAll(); persist() }
    func excludeAllPending() { guard !isDeleting else { return }; exclusions.formUnion(pending.map(\.localIdentifier)); persist() }

    var favoriteCount: Int { decisions.values.filter { $0 == .favorite }.count }

    func requestCurrentStatus() async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if authorization != status { authorization = status }
        if hasAccess { await reload() }
        else { loadGeneration += 1; assets = []; groupCounts = [:]; isLoading = false; revision += 1 }
    }

    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if hasAccess { await reload() }
    }

    func reload() async {
        guard hasAccess else { assets = []; groupCounts = [:]; return }
        loadGeneration += 1
        let generation = loadGeneration
        if !hasLoadedLibrary { isLoading = true }
        let previousIDs = Set(assets.map(\.localIdentifier))
        let result = await Task.detached(priority: .userInitiated) { () -> (PHFetchResult<PHAsset>, [PHAsset], [PhotoGroup: Int]) in
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let result = PHAsset.fetchAssets(with: options)
            var output: [PHAsset] = []
            output.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in output.append(asset) }
            var counts: [PhotoGroup: Int] = [:]
            for asset in output {
                for group in PhotoGroup.allCases where group.includes(asset) {
                    counts[group, default: 0] += 1
                }
            }
            return (result, output, counts)
        }.value
        // Explicit reload is also called inside our deletion transaction, so
        // only observer-triggered refreshes wait for isDeleting (above).
        while isSortingTransition || interactingAssetID != nil {
            try? await Task.sleep(for: .milliseconds(100))
            guard generation == loadGeneration, !Task.isCancelled else { return }
        }
        guard generation == loadGeneration, !Task.isCancelled else { return }
        let fetched = result.1
        observedFetch = result.0
        let additions = hasLoadedLibrary ? fetched.map(\.localIdentifier).filter {
            !previousIDs.contains($0) && decisions[$0] == nil && !deletedIDs.contains($0)
        } : []
        hasLoadedLibrary = true
        if !additions.isEmpty {
            // Newly captured media must bypass the saved cursor, just like a
            // restored item. Keep this priority across relaunch until reviewed.
            prependReopened(additions)
            persist()
        }
        // A successful fresh fetch can include items restored from Recently Deleted.
        // Do not resurrect items while our own deletion transaction is still finishing.
        if !isDeleting {
            let restored = deletedIDs.intersection(fetched.map(\.localIdentifier))
            if !restored.isEmpty {
                deletedIDs.subtract(restored)
                for id in restored { decisions.removeValue(forKey: id) }
                history.removeAll { restored.contains($0.assetID) }
                exclusions.subtract(restored)
                persist()
            }
        }
        assets = fetched.filter { !deletedIDs.contains($0.localIdentifier) }

        let accessible = Set(assets.map(\.localIdentifier))
        let cleanedReopened = reopenedIDs.filter {
            accessible.contains($0) &&
            decisions[$0] == nil &&
            !deletedIDs.contains($0)
        }
        if cleanedReopened != reopenedIDs {
            reopenedIDs = cleanedReopened
            persist()
        }

        var counts = result.2
        for asset in fetched where deletedIDs.contains(asset.localIdentifier) {
            for group in PhotoGroup.allCases where group.includes(asset) {
                counts[group, default: 0] -= 1
            }
        }
        if groupCounts != counts { groupCounts = counts }
        if isLoading { isLoading = false }
        revision += 1
    }

    func remaining(in group: PhotoGroup) -> [PHAsset] {
        assets.filter { group.includes($0) && decisions[$0.localIdentifier] == nil }
    }

    func count(in group: PhotoGroup) -> Int { groupCounts[group, default: 0] }

    func choose(_ asset: PHAsset, as decision: PhotoDecision) {
        guard !isDeleting, !isSortingTransition, hasAccess,
              self.asset(for: asset.localIdentifier) != nil,
              !deletedIDs.contains(asset.localIdentifier) else { return }
        let id = asset.localIdentifier
        exclusions.remove(id)
        reopenedIDs.removeAll { $0 == id }
        let prior = decisions[id]
        guard prior != decision else { return }
        var action = DecisionAction(assetID: id, before: prior, after: decision)
        action.filename = PHAssetResource.assetResources(for: asset).first?.originalFilename
        history.append(action)
        decisions[id] = decision
        persist()
    }

    @discardableResult
    func undo(in allowedIDs: Set<String>? = nil) -> String? {
        guard !isSortingTransition else { return nil }
        let accessible = Set(assets.map(\.localIdentifier))
        guard let action = history.last(where: {
            $0.undoneAt == nil &&
            !deletedIDs.contains($0.assetID) &&
            accessible.contains($0.assetID) &&
            (allowedIDs == nil || allowedIDs!.contains($0.assetID))
        }) else { return nil }

        restore(action)

        let restored = history.first(where: { $0.id == action.id })?.undoneAt != nil
        return restored ? action.assetID : nil
    }

    /// Removes the pending-deletion decision completely so the asset returns to the
    /// unsorted swipe queue instead of merely being excluded from the delete batch.
    func returnToSorting(_ asset: PHAsset) {
        guard !isDeleting else { return }
        let id = asset.localIdentifier
        guard !deletedIDs.contains(id), decisions[id] == .delete else { return }

        decisions.removeValue(forKey: id)
        exclusions.remove(id)
        prependReopened([id])

        let now = Date()
        for index in history.indices where history[index].assetID == id && history[index].undoneAt == nil {
            history[index].undoneAt = now
        }

        persist()
    }

    /// Clears the pending-deletion decision for multiple selected items so they
    /// return to the normal unreviewed sorting queue. Nothing is marked as kept.
    @discardableResult
    func returnToSorting(_ ids: Set<String>) -> Int {
        guard !isDeleting, !ids.isEmpty else { return 0 }

        let valid = ids.filter {
            !deletedIDs.contains($0) &&
            decisions[$0] == .delete &&
            asset(for: $0) != nil
        }
        guard !valid.isEmpty else { return 0 }

        let validSet = Set(valid)

        // Preserve the order in which these items were originally reviewed.
        // This makes "restore 3 items" behave like a real rewind: 1 -> 2 -> 3,
        // then continue from the card that was already next.
        let ordered = validSet.sorted { lhs, rhs in
            let leftIndex = history.lastIndex {
                $0.assetID == lhs && $0.undoneAt == nil
            } ?? Int.max
            let rightIndex = history.lastIndex {
                $0.assetID == rhs && $0.undoneAt == nil
            } ?? Int.max

            if leftIndex != rightIndex {
                return leftIndex < rightIndex
            }

            let leftAssetIndex = assets.firstIndex {
                $0.localIdentifier == lhs
            } ?? Int.max
            let rightAssetIndex = assets.firstIndex {
                $0.localIdentifier == rhs
            } ?? Int.max
            return leftAssetIndex < rightAssetIndex
        }

        for id in validSet {
            decisions.removeValue(forKey: id)
            exclusions.remove(id)
        }
        prependReopened(ordered)

        let now = Date()
        for index in history.indices
        where validSet.contains(history[index].assetID) &&
              history[index].undoneAt == nil {
            history[index].undoneAt = now
        }

        persist()
        successNotice = L(
            "已將 \(validSet.count) 項移回待審。",
            "Moved \(validSet.count) items back to review."
        )
        return validSet.count
    }

    func restore(_ requested: DecisionAction) {
        // Preview and list may hold an older snapshot after another undo.
        guard let action = history.first(where: { $0.id == requested.id }) else { return }
        guard !isDeleting, !isSortingTransition, !deletedIDs.contains(action.assetID), action.undoneAt == nil else { return }
        guard asset(for: action.assetID) != nil else {
            message = L("目前無法存取這個項目。", "This item is currently unavailable."); return
        }
        if let prior = action.before {
            decisions[action.assetID] = prior
            reopenedIDs.removeAll { $0 == action.assetID }
        } else {
            decisions.removeValue(forKey: action.assetID)
            prependReopened([action.assetID])
        }
        exclusions.remove(action.assetID)
        for index in history.indices where history[index].assetID == action.assetID && history[index].timestamp >= action.timestamp {
            history[index].undoneAt = Date()
        }
        persist()
    }

    func asset(for id: String) -> PHAsset? { assets.first { $0.localIdentifier == id } }

    func userAlbums() -> [PHAssetCollection] {
        let result = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .any,
            options: nil
        )
        var albums: [PHAssetCollection] = []
        result.enumerateObjects { collection, _, _ in
            albums.append(collection)
        }
        return albums.sorted {
            ($0.localizedTitle ?? "").localizedCaseInsensitiveCompare($1.localizedTitle ?? "") == .orderedAscending
        }
    }

    func addToFavorites(_ asset: PHAsset) async -> Bool {
        await setFavorite(asset, true)
    }

    func setFavorite(_ asset: PHAsset, _ favorite: Bool) async -> Bool {
        guard hasAccess, !isDeleting else { return false }

        do {
            try await performPhotoChange {
                let request = PHAssetChangeRequest(for: asset)
                request.isFavorite = favorite
            }
            return true
        } catch {
            message = favorite
                ? L("無法加入喜好項目：\(appErrorMessage(error))", "Could not add to Favorites: \(appErrorMessage(error))")
                : L("無法移出喜好項目：\(appErrorMessage(error))", "Could not remove from Favorites: \(appErrorMessage(error))")
            return false
        }
    }

    func add(_ asset: PHAsset, to album: PHAssetCollection) async -> Bool {
        guard hasAccess, !isDeleting else { return false }

        do {
            try await performPhotoChange {
                guard let request = PHAssetCollectionChangeRequest(for: album) else { return }
                request.addAssets([asset] as NSArray)
            }
            return true
        } catch {
            message = L(
                "無法加入相簿：\(appErrorMessage(error))",
                "Could not add to album: \(appErrorMessage(error))"
            )
            return false
        }
    }

    func createAlbum(named rawName: String, adding asset: PHAsset) async -> Bool {
        guard let album = await createEmptyAlbum(named: rawName) else { return false }
        return await add(asset, to: album)
    }

    func createEmptyAlbum(named rawName: String) async -> PHAssetCollection? {
        guard hasAccess, !isDeleting else { return nil }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        var placeholderID: String?

        do {
            try await performPhotoChange {
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
                placeholderID = request.placeholderForCreatedAssetCollection.localIdentifier
            }

            guard let placeholderID else { return nil }
            return PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [placeholderID],
                options: nil
            ).firstObject
        } catch {
            message = L(
                "無法建立相簿：\(appErrorMessage(error))",
                "Could not create album: \(appErrorMessage(error))"
            )
            return nil
        }
    }

    func albumIDs(containing asset: PHAsset, among albums: [PHAssetCollection]) -> Set<String> {
        let allowed = Set(albums.map(\.localIdentifier))
        let result = PHAssetCollection.fetchAssetCollectionsContaining(
            asset,
            with: .album,
            options: nil
        )

        var ids: Set<String> = []
        result.enumerateObjects { collection, _, _ in
            if allowed.contains(collection.localIdentifier) {
                ids.insert(collection.localIdentifier)
            }
        }
        return ids
    }

    func updateAlbumMembership(
        of asset: PHAsset,
        addTo albumsToAdd: [PHAssetCollection],
        removeFrom albumsToRemove: [PHAssetCollection]
    ) async -> Bool {
        guard hasAccess, !isDeleting else { return false }
        guard !albumsToAdd.isEmpty || !albumsToRemove.isEmpty else { return true }

        do {
            try await performPhotoChange {
                for album in albumsToAdd {
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([asset] as NSArray)
                }
                for album in albumsToRemove {
                    PHAssetCollectionChangeRequest(for: album)?.removeAssets([asset] as NSArray)
                }
            }
            return true
        } catch {
            message = L(
                "無法更新相簿：\(appErrorMessage(error))",
                "Could not update albums: \(appErrorMessage(error))"
            )
            return false
        }
    }

    func remove(_ asset: PHAsset, from album: PHAssetCollection) async -> Bool {
        await updateAlbumMembership(of: asset, addTo: [], removeFrom: [album])
    }

    private func performPhotoChange(_ changes: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges(changes) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? PhotoChangeError.failed)
                }
            }
        }
    }

    func deleteSelected(_ ids: Set<String>) async -> Bool {
        guard !isDeleting, hasAccess, !ids.isEmpty else { return false }
        let approved = ids.filter { decisions[$0] == .delete && !exclusions.contains($0) }
        guard approved.count == ids.count else {
            message = L("待刪清單已變動，請重新確認。", "The review list changed. Please review it again.")
            return false
        }
        let found = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil)
        guard found.count == ids.count else {
            message = L("有照片已不存在或目前無權存取，請重新確認。", "Some items are unavailable or no longer authorized. Please review again.")
            await reload()
            return false
        }
        let names = (0..<found.count).map { PHAssetResource.assetResources(for: found.object(at: $0)).first?.originalFilename ?? found.object(at: $0).creationDate?.description ?? "Media" }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(found)
                } completionHandler: { success, error in
                    if success { continuation.resume() }
                    else { continuation.resume(throwing: error ?? DeleteError.cancelled) }
                }
            }
            for id in ids { decisions.removeValue(forKey: id) }
            // Items that were not selected stay pending. Deleting one batch must
            // never silently convert the rest of the review queue to "keep".
            exclusions.subtract(ids)
            reopenedIDs.removeAll { ids.contains($0) }
            deletions.append(DeletionRecord(id: UUID(), date: Date(), names: names, assetIDs: Array(ids)))
            deletedIDs.formUnion(ids)
            persist()
            await flushPendingWrites()
            await reload()
            message = L("已交由系統刪除 \(ids.count) 項。", "iOS deleted \(ids.count) items.")
            return true
        } catch {
            message = L("刪除未完成，待刪標記仍保留。", "Deletion did not complete. Pending items are preserved.") + "\n\(appErrorMessage(error))"
            return false
        }
    }

    private func prependReopened(_ ids: [String]) {
        guard !ids.isEmpty else { return }

        reopenedIDs = ReviewQueueOrdering.prepending(ids, to: reopenedIDs)
    }

    private func persist() {
        decisionRevision &+= 1
        // Value snapshots and one serial writer preserve ordering without blocking gestures.
        let saved = SavedChoices(
            decisions: decisions,
            history: history,
            exclusions: exclusions,
            deletions: deletions,
            deletedIDs: deletedIDs,
            reopenedIDs: reopenedIDs
        )
        let url = saveURL
        saveQueue.async { [weak self] in
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(saved).write(to: url, options: .atomic)
            } catch {
                let details = appErrorMessage(error)
                Task { @MainActor [weak self] in
                    self?.message = L("無法保存整理進度：", "Could not save progress: ") + details
                }
            }
        }
    }

}

private enum DeleteError: LocalizedError {
    case cancelled
    var errorDescription: String? { L("系統取消或拒絕了刪除。", "iOS cancelled or refused deletion.") }
}

private enum PhotoChangeError: LocalizedError {
    case failed
    var errorDescription: String? { L("系統未完成相簿修改。", "iOS did not complete the photo-library change.") }
}


