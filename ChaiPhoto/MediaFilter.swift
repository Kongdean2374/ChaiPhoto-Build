import SwiftUI
import Photos

private struct PersistedMediaFilter: Codable {
    let source: String
    let kind: String
    let albumID: String
    let albumName: String
    let timeMode: String?
    let dateEnabled: Bool
    let start: Date
    let end: Date
}

struct MediaFilter: Equatable {
    var source = "photos"
    var kind = "all"
    var albumID = ""
    var albumName = ""
    var timeMode = "all"
    var dateEnabled = false
    var start = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
    var end = Date()
    var allowedIDs: Set<String>?

    private static let persistedPhotoFilterKey = "lastPhotoMediaFilter.v1"
    private static let persistedFilterKey = "lastMediaFilter.v2"
    private static let legacyFilterKey = "lastMediaFilter"

    /// Persist identifiers and resolve live Photos objects after restoration.
    static func restored() -> MediaFilter {
        let defaults = UserDefaults.standard
        let data =
            defaults.data(forKey: persistedFilterKey) ??
            defaults.data(forKey: persistedPhotoFilterKey) ??
            defaults.data(forKey: legacyFilterKey)

        guard
            let data,
            let saved = try? JSONDecoder().decode(PersistedMediaFilter.self, from: data),
            ["photos", "videos", "album"].contains(saved.source)
        else {
            return MediaFilter()
        }

        let validKinds: Set<String> = saved.source == "videos" ? ["all", "slow", "timelapse", "favorites"] : [
            "all", "screenshots", "live", "selfies",
            "panoramas", "bursts", "favorites"
        ]
        let restoredKind = validKinds.contains(saved.kind) ? saved.kind : "all"

        var filter = MediaFilter(
            source: saved.source,
            kind: restoredKind,
            albumID: saved.source == "album" ? saved.albumID : "",
            albumName: saved.source == "album" ? saved.albumName : "",
            timeMode: saved.timeMode ?? (saved.dateEnabled ? "range" : "all"),
            dateEnabled: saved.dateEnabled,
            start: saved.start,
            end: max(saved.start, saved.end),
            allowedIDs: nil
        )

        filter.resolve()
        // Build 66 could persist an analysis-only scope. Normalize just its kind;
        // keep the media source, date range, decisions and normal resume cursors.
        if restoredKind != saved.kind { filter.persist() }
        return filter
    }

    func persist() {
        let saved = PersistedMediaFilter(
            source: source,
            kind: kind,
            albumID: albumID,
            albumName: albumName,
            timeMode: timeMode,
            dateEnabled: dateEnabled,
            start: start,
            end: end
        )

        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(
                data,
                forKey: Self.persistedFilterKey
            )
        }
    }

    private var resumeStorageKey: String {
        let calendar = Calendar.current
        let datePart: String
        if dateEnabled {
            let from = Int(calendar.startOfDay(for: start).timeIntervalSince1970)
            let to = Int(calendar.startOfDay(for: end).timeIntervalSince1970)
            datePart = "\(timeMode)|\(from)|\(to)"
        } else {
            datePart = "all"
        }

        return "sorting.resume.v1|\(source)|\(source == "album" ? albumID + "|" : "")\(kind)|\(datePart)"
    }

    func restoredResumeAssetID() -> String? {
        return UserDefaults.standard.string(forKey: resumeStorageKey)
    }

    func persistResumeAssetID(_ assetID: String?) {
        if let assetID, !assetID.isEmpty {
            UserDefaults.standard.set(assetID, forKey: resumeStorageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: resumeStorageKey)
        }
    }

    func includes(_ asset: PHAsset) -> Bool {
        if source == "photos" && asset.mediaType != .image { return false }
        if source == "videos" && asset.mediaType != .video { return false }
        if source == "videos" {
            if kind == "slow" && !asset.mediaSubtypes.contains(.videoHighFrameRate) { return false }
            if kind == "timelapse" && !asset.mediaSubtypes.contains(.videoTimelapse) { return false }
            if kind == "favorites" && !asset.isFavorite { return false }
        }
        if let allowedIDs, !allowedIDs.contains(asset.localIdentifier) { return false }
        if source == "album" && albumID.isEmpty { return false }
        if dateEnabled {
            guard let date = asset.creationDate else { return false }
            let beginning = Calendar.current.startOfDay(for: start)
            let afterEnd = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: end)) ?? end
            if date < beginning || date >= afterEnd { return false }
        }
        return true
    }
    var title: String {
        if source == "album" { return L("相簿", "Album") + " · " + (albumName.isEmpty ? L("未選擇", "Not selected") : albumName) }
        if source == "videos" { return L("影片", "Videos") + " · " + videoKindTitle(kind) }
        return L("照片", "Photos") + " · " + kindTitle(kind)
    }
    var timeTitle: String {
        if !dateEnabled { return L("全部時間", "All dates") }
        if timeMode == "month" { return monthLabel(start) }
        let style = Date.FormatStyle(date: .numeric, time: .omitted).locale(Locale(identifier: UserDefaults.standard.string(forKey: "language") == "en" ? "en_US" : "zh_TW"))
        return L("指定日期：", "Date range: ") + start.formatted(style) + " – " + end.formatted(style)
    }
    mutating func setMonth(_ date: Date) {
        let calendar = Calendar.current
        start = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        end = calendar.date(byAdding: .day, value: -1, to: calendar.date(byAdding: .month, value: 1, to: start) ?? start) ?? start
        timeMode = "month"; dateEnabled = true
    }
    func kindTitle(_ kind: String) -> String {
        switch kind {
        case "screenshots": return L("截圖", "Screenshots")
        case "live": return "Live Photo"
        case "selfies": return L("自拍", "Selfies")
        case "panoramas": return L("全景", "Panoramas")
        case "bursts": return L("連拍", "Bursts")
        case "favorites": return L("系統喜愛項目", "System favorites")
        default: return L("全部照片", "All photos")
        }
    }
    func videoKindTitle(_ kind: String) -> String {
        switch kind {
        case "slow": return L("慢動作", "Slow motion")
        case "timelapse": return L("縮時攝影", "Time-lapse")
        case "favorites": return L("喜愛影片", "Favorite videos")
        default: return L("全部影片", "All videos")
        }
    }
    mutating func resolve() {
        allowedIDs = nil
        var collection: PHAssetCollection?
        if source == "album" {
            collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject
            if collection == nil { allowedIDs = [] }
        } else if source == "photos" && kind != "all" {
            let subtype: PHAssetCollectionSubtype
            switch kind {
            case "screenshots": subtype = .smartAlbumScreenshots
            case "live": subtype = .smartAlbumLivePhotos
            case "selfies": subtype = .smartAlbumSelfPortraits
            case "panoramas": subtype = .smartAlbumPanoramas
            case "bursts": subtype = .smartAlbumBursts
            default: subtype = .smartAlbumFavorites
            }
            collection = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil).firstObject
            if collection == nil { allowedIDs = [] }
        }
        if let collection {
            var ids: Set<String> = []
            PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
            allowedIDs = ids
        }
    }
}

// Only retired analysis artifacts in our app container are eligible for removal.
// Photos, sorting-state files and all other application data are left untouched.
enum RetiredAnalysisMigration {
    static func removeCache(in support: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: support.path) else { return }
        let files = try manager.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)
        let prefix = "analysis-features-"
        for file in files {
            let name = file.lastPathComponent
            let featureFolder = name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
            if name == "media-analysis.json" || featureFolder {
                try manager.removeItem(at: file)
            }
        }
    }
}

struct FilterView: View {
    @Binding var filter: MediaFilter
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings
    @State private var draft = MediaFilter()
    @State private var albums: [PHAssetCollection] = []
    @State private var initialized = false
    var body: some View {
        NavigationStack {
            Form {
                Section(L("主分類", "Source")) {
                    categoryLink("photos", L("照片", "Photos"), "photo")
                    categoryLink("videos", L("影片", "Videos"), "video")
                    categoryLink("album", L("相簿", "Albums"), "rectangle.stack")
                }
                Section(L("拍攝日期", "Capture date")) {
                    Picker(L("時間", "Time"), selection: $draft.timeMode) {
                        Text(L("全部", "All")).tag("all")
                        Text(L("月份", "Month")).tag("month")
                        Text(L("指定日期", "Date range")).tag("range")
                    }
                    if draft.timeMode == "month" {
                        MonthPicker(date: $draft.start)
                    } else if draft.timeMode == "range" {
                        DatePicker(L("開始", "From"), selection: $draft.start, displayedComponents: .date)
                        DatePicker(L("結束", "To"), selection: $draft.end, in: draft.start..., displayedComponents: .date)
                    }
                }
            }
            .navigationTitle(L("整理篩選", "Sort filters"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("取消", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("套用日期", "Apply Date")) {
                        var next = filter
                        next.timeMode = draft.timeMode
                        next.dateEnabled = draft.timeMode != "all"
                        next.start = draft.start
                        next.end = max(draft.start, draft.end)
                        if draft.timeMode == "month" { next.setMonth(draft.start) }
                        next.resolve()
                        filter = next
                        filter.persist()
                        dismiss()
                    }
                }
            }
            .onAppear {
                guard !initialized else { return }
                initialized = true
                draft = filter
                var list: [PHAssetCollection] = []
                PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil).enumerateObjects { a, _, _ in list.append(a) }
                albums = list.sorted { ($0.localizedTitle ?? "") < ($1.localizedTitle ?? "") }
            }
            .onChange(of: draft.start) { _, start in if draft.end < start { draft.end = start } }
        }
    }
    private func applyCategoryImmediately(_ selected: MediaFilter) {
        // Category selection dismisses this sheet immediately. Apply the current
        // date draft at the same time instead of falling back to the previously
        // committed date range.
        //
        // Example: Photos / September -> change Time to All -> choose Videos.
        // Videos must open at All dates, not resurrect September.
        if filter.source == "photos" {
            var photoSnapshot = filter
            photoSnapshot.timeMode = selected.timeMode
            photoSnapshot.dateEnabled = selected.timeMode != "all"
            photoSnapshot.start = selected.start
            photoSnapshot.end = max(selected.start, selected.end)
            if selected.timeMode == "month" {
                photoSnapshot.setMonth(selected.start)
            }
            photoSnapshot.resolve()
            photoSnapshot.persist()
        }

        var next = selected
        next.dateEnabled = selected.timeMode != "all"
        next.end = max(selected.start, selected.end)
        if selected.timeMode == "month" {
            next.setMonth(selected.start)
        }
        next.resolve()

        filter = next
        filter.persist()
        dismiss()
    }

    private func categoryLink(_ source: String, _ title: String, _ symbol: String) -> some View {
        NavigationLink {
            FilterSubcategoryView(
                draft: $draft,
                source: source,
                albums: albums,
                onSelect: applyCategoryImmediately
            )
        } label: {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                if draft.source == source {
                    Text(draft.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }

}


private struct FilterSubcategoryView: View {
    @Binding var draft: MediaFilter
    let source: String
    let albums: [PHAssetCollection]
    let onSelect: (MediaFilter) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            if source == "album" {
                if albums.isEmpty { Text(L("沒有可選的相簿", "No albums available")) }
                ForEach(albums, id: \.localIdentifier) { album in
                    Button {
                        draft.source = "album"
                        draft.kind = "all"
                        draft.albumID = album.localIdentifier
                        draft.albumName = album.localizedTitle ?? L("未命名", "Untitled")
                        onSelect(draft)
                    } label: {
                        row(album.localizedTitle ?? L("未命名", "Untitled"), selected: draft.source == source && draft.albumID == album.localIdentifier)
                    }
                }
            } else {
                ForEach(source == "photos" ? ["all", "screenshots", "live", "selfies", "panoramas", "bursts", "favorites"] : ["all", "slow", "timelapse", "favorites"], id: \.self) { kind in
                    Button {
                        draft.source = source
                        draft.kind = kind
                        draft.albumID = ""
                        draft.albumName = ""
                        onSelect(draft)
                    } label: {
                        row(source == "photos" ? draft.kindTitle(kind) : draft.videoKindTitle(kind), selected: draft.source == source && draft.kind == kind)
                    }
                }
            }
        }
        .navigationTitle(source == "photos" ? L("照片類型", "Photo type") : source == "videos" ? L("影片類型", "Video type") : L("選擇相簿", "Choose album"))
    }
    private func row(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(.indigo) }
        }.contentShape(Rectangle())
    }
}



func monthLabel(_ date: Date) -> String {
    let locale = Locale(identifier: UserDefaults.standard.string(forKey: "language") == "en" ? "en_US" : "zh_TW")
    return date.formatted(Date.FormatStyle().year().month(.wide).locale(locale))
}

private struct MonthPicker: View {
    @Binding var date: Date
    @EnvironmentObject private var library: PhotoLibraryStore
    private var years: [Int] {
        let current = Calendar.current.component(.year, from: Date())
        let selected = Calendar.current.component(.year, from: date)
        let assetYears = library.assets.compactMap(\.creationDate).map { Calendar.current.component(.year, from: $0) }
        return Array(min(assetYears.min() ?? current, selected)...max(assetYears.max() ?? current, current, selected)).reversed()
    }
    var body: some View {
        Picker(L("年份", "Year"), selection: Binding(get: { Calendar.current.component(.year, from: date) }, set: { update(year: $0, month: Calendar.current.component(.month, from: date)) })) {
            ForEach(years, id: \.self) { Text(String($0)).tag($0) }
        }
        Picker(L("月份", "Month"), selection: Binding(get: { Calendar.current.component(.month, from: date) }, set: { update(year: Calendar.current.component(.year, from: date), month: $0) })) {
            ForEach(1...12, id: \.self) { value in Text(L("\(value) 月", "\(value)")).tag(value) }
        }
    }
    private func update(year: Int, month: Int) {
        date = Calendar.current.date(from: DateComponents(year: year, month: month, day: 1)) ?? date
    }
}
