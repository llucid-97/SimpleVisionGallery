@preconcurrency import Photos
import SwiftUI

/// A presentation-only adapter; GalleryManager keeps all Photos and selection logic.
struct GalleryDesignContext {
    let manager: GalleryManager
    let albums: [GalleryAlbum]
    let query: Binding<String>
    let isSelectingAlbums: Bool
    let selectedAlbumIDs: Set<String>
    let actions: AnyView
    let albumToolbar: AnyView
    let mediaContent: AnyView
    let emptyContent: AnyView
    let cover: (GalleryAlbum) -> AnyView
    let openAlbum: (GalleryAlbum) -> Void
    let renameAlbum: (GalleryAlbum) -> Void
    let toggleVisibility: (GalleryAlbum) -> Void
    let selectSection: (GalleryLibrarySection) -> Void
    let reorderAlbumID: String?
    let beginReordering: (GalleryAlbum) -> Void
    let cancelReordering: () -> Void
    let reorderAlbum: (String, String, Bool) -> Void
    let showSettings: () -> Void

    var hasOpenAlbum: Bool { manager.selectedAlbum != nil }
}

struct GalleryDesignAlbumActions: View {
    let context: GalleryDesignContext
    let album: GalleryAlbum
    var body: some View {
        Button("Sort", systemImage: "arrow.up.arrow.down") { context.beginReordering(album) }
        if album.collection != nil {
            Button(context.manager.isAlbumHidden(album) ? "Unhide Album" : "Hide Album",
                systemImage: context.manager.isAlbumHidden(album) ? "eye" : "eye.slash") {
                context.toggleVisibility(album)
            }
            if album.collection?.canPerform(.rename) == true {
                Button("Rename Album", systemImage: "pencil") { context.renameAlbum(album) }
            }
        }
    }
}

struct GalleryDesignSearchField: View {
    @Binding var query: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find an album", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("gallery-album-search")
            if !query.isEmpty {
                Button("Clear Search", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .frame(width: 60, height: 60)
            }
        }
        .font(.body)
        .padding(.horizontal, 16)
        .frame(minHeight: 68)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}
