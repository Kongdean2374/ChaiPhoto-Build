import Photos
import SwiftUI

struct AlbumPickerView: View {
    let asset: PHAsset
    var protectedAlbumID: String? = nil
    var protectedAlbumName: String? = nil
    var onRemovedFromProtectedAlbum: (() -> Void)? = nil
    let onCompleted: (Bool) -> Void

    @EnvironmentObject private var library: PhotoLibraryStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var albums: [PHAssetCollection] = []
    @State private var initialSelection: Set<String> = []
    @State private var selection: Set<String> = []
    @State private var creatingAlbum = false
    @State private var newAlbumName = ""
    @State private var working = false
    @State private var searchText = ""

    private var filteredAlbums: [PHAssetCollection] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return albums
        }

        return albums.filter {
            ($0.localizedTitle ?? "")
                .localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(L(
                        "可同時勾選多個相簿。只有按「完成」後才會一次套用變更。",
                        "Select multiple albums. Changes are applied together only after tapping Done."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if let protectedAlbumID {
                    Section(L("目前相簿", "Current Album")) {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.indigo)

                            Text(
                                protectedAlbumName ??
                                albumName(for: protectedAlbumID) ??
                                L("目前相簿", "Current Album")
                            )
                            .foregroundStyle(.primary)

                            Spacer()

                            if onRemovedFromProtectedAlbum != nil {
                                Button(role: .destructive) {
                                    removeFromProtectedAlbum(protectedAlbumID)
                                } label: {
                                    Text(L("移出", "Remove"))
                                }
                                .disabled(working)
                            }
                        }
                    }
                }

                Section(L("相簿", "Albums")) {
                    if filteredAlbums.isEmpty {
                        Text(
                            searchText.isEmpty
                                ? L("還沒有相簿", "No albums yet")
                                : L("找不到符合的相簿", "No matching albums")
                        )
                        .foregroundStyle(.secondary)
                    }

                    ForEach(filteredAlbums, id: \.localIdentifier) { album in
                        if album.localIdentifier != protectedAlbumID {
                            albumRow(album)
                        }
                    }
                }
            }
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: L("搜尋相簿", "Search albums")
            )
            .navigationTitle(L("加入相簿", "Add to Albums"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消", "Cancel")) {
                        dismiss()
                    }
                    .disabled(working).accessibilityIdentifier("album-picker-cancel")
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        newAlbumName = ""
                        creatingAlbum = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(L("新增相簿", "New album")).accessibilityIdentifier("album-picker-new")
                    .disabled(working)

                    Button(L("完成", "Done")) {
                        applySelection()
                    }
                    .fontWeight(.semibold)
                    .disabled(working)
                }
            }
            .alert(L("新增相簿", "New Album"), isPresented: $creatingAlbum) {
                TextField(L("相簿名稱", "Album Name"), text: $newAlbumName)

                Button(L("取消", "Cancel"), role: .cancel) {
                    newAlbumName = ""
                }.accessibilityIdentifier("album-new-cancel")

                Button(L("建立", "Create")) {
                    createAlbum()
                }
                .disabled(
                    newAlbumName
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                )
            } message: {
                Text(L(
                    "相簿會立即建立並先勾選。若之後取消勾選，空相簿仍會保留。",
                    "The album is created immediately and selected. If you uncheck it later, the empty album remains."
                ))
            }
            .task(id: asset.localIdentifier) {
                loadAlbums()
            }
        }
    }

    private func albumRow(_ album: PHAssetCollection) -> some View {
        let id = album.localIdentifier
        let selected = selection.contains(id)

        return Button {
            toggle(id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.indigo : Color.secondary)

                Text(album.localizedTitle ?? L("未命名相簿", "Untitled Album"))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .disabled(working)
    }

    private func loadAlbums() {
        let list = library.userAlbums()
        albums = list

        let containing = library.albumIDs(containing: asset, among: list)
        initialSelection = containing
        selection = containing

        if let protectedAlbumID {
            initialSelection.insert(protectedAlbumID)
            selection.insert(protectedAlbumID)
        }
    }

    private func toggle(_ id: String) {
        guard !working, protectedAlbumID != id else { return }

        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private func createAlbum() {
        let name = newAlbumName
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty, !working else { return }

        working = true

        Task {
            let album = await library.createEmptyAlbum(named: name)
            working = false
            newAlbumName = ""

            guard let album else { return }

            albums = library.userAlbums()
            selection.insert(album.localIdentifier)
        }
    }

    private func applySelection() {
        guard !working else { return }

        let protectedIDs = protectedAlbumID.map { Set([$0]) } ?? []
        let addIDs = selection.subtracting(initialSelection)
        let removeIDs = initialSelection
            .subtracting(selection)
            .subtracting(protectedIDs)

        let albumsByID = Dictionary(
            uniqueKeysWithValues: albums.map {
                ($0.localIdentifier, $0)
            }
        )

        let additions = addIDs.compactMap { albumsByID[$0] }
        let removals = removeIDs.compactMap { albumsByID[$0] }
        let changed = !additions.isEmpty || !removals.isEmpty

        guard changed else {
            onCompleted(false)
            dismiss()
            return
        }

        working = true

        Task {
            let success = await library.updateAlbumMembership(
                of: asset,
                addTo: additions,
                removeFrom: removals
            )
            working = false

            if success {
                settings.successFeedback()
                let names = additions.map { $0.localizedTitle ?? L("未命名相簿", "Untitled album") }.sorted().joined(separator: "、")
                if additions.isEmpty {
                    library.successNotice = L("已更新相簿內容", "Album membership updated")
                } else {
                    let item = asset.mediaType == .video ? L("影片", "video") : L("照片", "photo")
                    library.successNotice = L("已將此\(item)加入「\(names)」", "Added this \(item) to “\(names)”")
                }
                onCompleted(true)
                dismiss()
            }
        }
    }

    private func removeFromProtectedAlbum(_ albumID: String) {
        guard !working else { return }

        let result = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumID],
            options: nil
        )

        guard let album = result.firstObject else {
            library.message = L(
                "找不到目前相簿。",
                "The current album is no longer available."
            )
            return
        }

        working = true

        Task {
            let success = await library.remove(asset, from: album)
            working = false

            if success {
                onRemovedFromProtectedAlbum?()
                dismiss()
            }
        }
    }

    private func albumName(for albumID: String) -> String? {
        albums
            .first(where: { $0.localIdentifier == albumID })?
            .localizedTitle
    }
}

