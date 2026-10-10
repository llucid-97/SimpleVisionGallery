//
//  GalleryView.swift
//  simple_vision_tools
//
//  Created by Codex Vector on 24/05/2026.
//

@preconcurrency import Photos
import SwiftUI

private enum GalleryAlbumVisibility: String, CaseIterable, Identifiable {
    case visible
    case hidden

    var id: String { rawValue }
}

private struct GalleryVisibilityMenu: View {
    @Binding var selection: GalleryAlbumVisibility
    let visibleCount: Int
    let hiddenCount: Int

    var body: some View {
        Menu {
            Picker("Album visibility", selection: $selection) {
                Text("Albums (\(visibleCount))").tag(GalleryAlbumVisibility.visible)
                Text("Hidden (\(hiddenCount))").tag(GalleryAlbumVisibility.hidden)
            }
            .pickerStyle(.inline)
        } label: {
            Label("Visibility", systemImage: selection == .visible ? "eye" : "eye.slash")
                .frame(minHeight: 26)
        }
        .buttonStyle(LensLabSecondaryButtonStyle())
        .accessibilityLabel("Album Visibility")
        .accessibilityIdentifier("svt-gallery-visibility")
        .help("Show albums or hidden albums")
    }
}

struct GalleryView: View {
    @Binding var isPresented: Bool
    @StateObject private var manager = GalleryManager()
    @State private var showingMoveSheet = false
    @State private var showingSettings = false
    @State private var showingThumbnailSize = false
    @State private var albumVisibility: GalleryAlbumVisibility = .visible
    @State private var isSelectingAlbums = false
    @State private var selectedAlbumIDs: Set<String> = []
    @State private var deletionReview: GalleryDeletionPlan?
    @AppStorage("gallery.thumbnailSize.v1") private var thumbnailSize = 112.0
    #if os(visionOS)
        @Environment(\.openWindow) private var openWindow
        @State private var isSelectingMedia = false
    #endif

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content

            if let toast = manager.toast {
                GalleryToastBanner(toast: toast)
                    .padding(20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .sheet(isPresented: $showingMoveSheet) {
            GalleryMoveSheet(manager: manager, isPresented: $showingMoveSheet)
        }
        .sheet(isPresented: $showingSettings) {
            GallerySettingsView(manager: manager)
        }
        .alert(item: $deletionReview) { review in
            Alert(
                title: Text("Delete \(review.totalCount) item\(review.totalCount == 1 ? "" : "s") from Photos?"),
                message: Text(deletionConfirmationMessage(for: review)),
                primaryButton: .destructive(Text("Continue to Photos")) {
                    Task {
                        await manager.deleteSelectionFromLibrary(review: review)
                    }
                },
                secondaryButton: .cancel()
            )
        }
        .sensoryFeedback(.selection, trigger: manager.selectionFeedbackSignal)
        .sensoryFeedback(.success, trigger: manager.successFeedbackSignal)
        .sensoryFeedback(.warning, trigger: manager.warningFeedbackSignal)
        .sensoryFeedback(.error, trigger: manager.errorFeedbackSignal)
        .animation(.easeInOut(duration: 0.18), value: manager.toast)
        .task {
            if manager.hasPhotoAccess && manager.albums.isEmpty {
                await manager.loadAlbums()
            }
        }
        .onChange(of: albumVisibility) {
            clearAlbumSelection()
        }
        .onChange(of: manager.selectedAlbum?.id) {
            showingThumbnailSize = false
            #if os(visionOS)
                isSelectingMedia = false
            #endif
        }
        .onChange(of: displayedAlbums.map(\.id)) {
            selectedAlbumIDs.formIntersection(Set(displayedAlbums.map(\.id)))
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            pageHeader
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 12) {
                    switch manager.authorizationStatus {
                    case .notDetermined:
                        requestAccessView
                    case .authorized, .limited:
                        mainContent
                    case .denied, .restricted:
                        deniedAccessView
                    @unknown default:
                        deniedAccessView
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .accessibilityIdentifier("svt-gallery")
    }

    private var pageHeader: some View {
        ViewThatFits(in: .horizontal) {
            headerContents(compact: false)
            headerContents(compact: true)
        }
        .padding(12)
        .lensLabCard()
        .popover(isPresented: $showingThumbnailSize, arrowEdge: .top) {
            thumbnailSizePopover
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityIdentifier("svt-gallery-toolbar")
    }

    private func headerContents(compact: Bool) -> some View {
        HStack(spacing: 10) {
            if manager.selectedAlbum != nil {
                Button {
                    manager.closeAlbum()
                } label: {
                    if compact {
                        Image(systemName: "chevron.left")
                            .frame(minHeight: 26)
                    } else {
                        Label("Albums", systemImage: "chevron.left")
                            .frame(minHeight: 26)
                    }
                }
                .buttonStyle(LensLabSecondaryButtonStyle())
                .accessibilityLabel("Back to Albums")
                .accessibilityIdentifier("svt-gallery-back-to-albums")
                .help("Back to Albums")
            } else {
                Image(systemName: "square.grid.3x3")
                    .font(.title2)
                    .foregroundStyle(LensLabTheme.cyan)
                    .frame(width: 36, height: 36)
                    .background(LensLabTheme.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(manager.selectedAlbum?.title ?? "Simple Vision Gallery")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(LensLabTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(toolbarSubtitle)
                    .font(.caption)
                    .foregroundStyle(LensLabTheme.mutedInk)
                    .lineLimit(1)
            }
            .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)

            if manager.isLoadingAlbums || manager.isLoadingAlbum || manager.isSortingAssets || manager.isPerformingOperation {
                ProgressView()
                    .controlSize(.small)
            }

            HStack(spacing: 8) {
                if manager.hasPhotoAccess && !compact {
                    if manager.selectedAlbum != nil {
                        sortMenu
                        thumbnailSizeButton
                        #if os(visionOS)
                            mediaSelectionButton
                        #endif
                        if manager.selectedCount > 0 {
                            moveSelectionButton
                        }
                    } else {
                        visibilityMenu
                        albumSelectionButton
                        if isSelectingAlbums {
                            albumVisibilityAction
                        }
                    }
                }
                overflowMenu(compact: compact)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var toolbarSubtitle: String {
        guard manager.hasPhotoAccess else { return pageStatus }
        if manager.isPerformingOperation, let message = manager.operationMessage {
            return message
        }
        if manager.isSortingAssets {
            return manager.sortingMessage ?? "Sorting media..."
        }
        if manager.isLoadingAlbum || manager.isLoadingAlbums {
            return manager.loadingMessage ?? pageStatus
        }
        if manager.selectedAlbum != nil {
            let loaded = "\(manager.visibleAssetCount) of \(manager.totalAssetCount) loaded"
            if manager.selectedCount > 0 {
                if let anchor = manager.rangeAnchorIndex {
                    return "\(manager.selectedCount) selected · Range starts at item \(anchor + 1)"
                }
                return "\(manager.selectedCount) selected · \(loaded)"
            }
            return "\(loaded) · \(mediaInteractionHint)"
        }
        return isSelectingAlbums
            ? "\(selectedAlbumIDs.count) selected · \(pageStatus)"
            : "\(pageStatus) · \(albumsSubtitle)"
    }

    private var visibilityMenu: some View {
        GalleryVisibilityMenu(
            selection: $albumVisibility,
            visibleCount: manager.visibleAlbums.count,
            hiddenCount: manager.hiddenAlbums.count
        )
    }

    private var albumSelectionButton: some View {
        Button {
            if isSelectingAlbums {
                clearAlbumSelection()
            } else {
                isSelectingAlbums = true
            }
        } label: {
            Label(isSelectingAlbums ? "Cancel" : "Select", systemImage: isSelectingAlbums ? "xmark" : "checkmark.circle")
                .frame(minHeight: 26)
        }
        .buttonStyle(LensLabSecondaryButtonStyle())
        .disabled(displayedAlbums.isEmpty && !isSelectingAlbums)
        .accessibilityIdentifier("svt-gallery-select-albums")
    }

    private var albumVisibilityAction: some View {
        Button {
            applyAlbumVisibilityChange()
        } label: {
            Label(
                albumVisibility == .visible ? "Hide Selected" : "Unhide Selected",
                systemImage: albumVisibility == .visible ? "eye.slash" : "eye"
            )
            .frame(minHeight: 26)
        }
        .buttonStyle(LensLabPrimaryButtonStyle())
        .disabled(selectedAlbumIDs.isEmpty)
    }

    private var sortMenu: some View {
        Menu {
            sortMenuOptions
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
                .frame(minHeight: 26)
        }
        .buttonStyle(LensLabSecondaryButtonStyle())
        .disabled(manager.isSortingAssets || manager.isPerformingOperation)
        .accessibilityIdentifier("svt-gallery-sort")
        .help("Sort media")
    }

    @ViewBuilder
    private var sortMenuOptions: some View {
        Picker(
            "Sort by",
            selection: Binding(
                get: { manager.assetSortMode },
                set: { mode in
                    Task { await manager.setAssetSortMode(mode) }
                }
            )
        ) {
            ForEach(GalleryAssetSortMode.allCases) { mode in
                Label(mode.title, systemImage: mode.systemImage).tag(mode)
            }
        }
        .pickerStyle(.inline)

        if manager.supportsAssetSortDirection {
            Divider()
            Picker(
                "Direction",
                selection: Binding(
                    get: { manager.assetSortAscending },
                    set: { ascending in
                        if ascending != manager.assetSortAscending {
                            Task { await manager.toggleAssetSortDirection() }
                        }
                    }
                )
            ) {
                Text(manager.assetSortMode == .name ? "A to Z" : "Oldest First").tag(true)
                Text(manager.assetSortMode == .name ? "Z to A" : "Newest First").tag(false)
            }
            .pickerStyle(.inline)
        } else if manager.assetSortMode == .random {
            Divider()
            Button("Reshuffle", systemImage: "shuffle") {
                manager.reshuffleAssets()
            }
        }
    }

    private var thumbnailSizeButton: some View {
        Button {
            showingThumbnailSize = true
        } label: {
            Label("Size", systemImage: "rectangle.grid.2x2")
                .frame(minHeight: 26)
        }
        .buttonStyle(LensLabSecondaryButtonStyle())
        .accessibilityLabel("Thumbnail Size")
        .accessibilityIdentifier("svt-gallery-thumbnail-size")
        .help("Thumbnail Size")
    }

    private var thumbnailSizePopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Thumbnail Size")
                    .font(.headline)
                Spacer()
                Text("\(Int(thumbnailSize))")
                    .font(.callout.monospacedDigit())
            }
            HStack(spacing: 10) {
                Image(systemName: "square.grid.3x3")
                    .accessibilityHidden(true)
                Slider(value: $thumbnailSize, in: 88...240, step: 8)
                    .tint(LensLabTheme.cyan)
                    .accessibilityLabel("Gallery thumbnail size")
                    .accessibilityValue("\(Int(thumbnailSize)) points")
                Image(systemName: "square.grid.2x2")
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(LensLabTheme.ink)
        .padding(20)
        .frame(width: 320)
        .background(LensLabTheme.card)
    }

    #if os(visionOS)
        private var mediaSelectionButton: some View {
            Button {
                if isSelectingMedia || manager.isSelectionMode {
                    isSelectingMedia = false
                    manager.clearSelection()
                } else {
                    isSelectingMedia = true
                }
            } label: {
                Label(isSelectingMedia || manager.isSelectionMode ? "Done" : "Select", systemImage: "checkmark.circle")
                    .frame(minHeight: 26)
            }
            .buttonStyle(LensLabSecondaryButtonStyle())
            .disabled(manager.isPerformingOperation)
        }
    #endif

    private var moveSelectionButton: some View {
        Button {
            showingMoveSheet = true
        } label: {
            Label("Move", systemImage: "arrowshape.turn.up.right")
                .frame(minHeight: 26)
        }
        .buttonStyle(LensLabPrimaryButtonStyle())
        .disabled(manager.isPerformingOperation)
    }

    private func overflowMenu(compact: Bool) -> some View {
        Menu {
            if manager.hasPhotoAccess {
                if compact {
                    if manager.selectedAlbum != nil {
                        sortMenu
                        thumbnailSizeButton
                        #if os(visionOS)
                            mediaSelectionButton
                        #endif
                        if manager.selectedCount > 0 { moveSelectionButton }
                    } else {
                        visibilityMenu
                        albumSelectionButton
                        if isSelectingAlbums { albumVisibilityAction }
                    }
                    Divider()
                }
                if manager.selectedCount > 0 {
                    selectionMenuOptions
                    Divider()
                }
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await manager.loadAlbums() }
                }
                .disabled(manager.isLoadingAlbums || manager.isPerformingOperation)
                Divider()
            }
            Button("Gallery Settings", systemImage: "gearshape") {
                showingSettings = true
            }
            .accessibilityIdentifier("svt-gallery-open-settings")
        } label: {
            Image(systemName: "ellipsis")
                .frame(minWidth: 16, minHeight: 26)
        }
        .buttonStyle(LensLabSecondaryButtonStyle())
        .accessibilityLabel("More Gallery Actions")
        .accessibilityIdentifier("svt-gallery-more")
        .help("More Gallery Actions")
    }

    private var selectionMenuOptions: some View {
        Group {
            Button("Clear Selection", systemImage: "xmark.circle") {
                manager.clearSelection()
            }
            Button(role: .destructive) {
                Task { await manager.removeSelectionFromCurrentAlbum() }
            } label: {
                Label("Remove from Album", systemImage: "rectangle.stack.badge.minus")
            }
            Button(role: .destructive) {
                deletionReview = manager.prepareDeletionReview()
            } label: {
                Label("Delete from Library", systemImage: "trash")
            }
        }
        .disabled(manager.isPerformingOperation)
    }

    private var pageStatus: String {
        switch manager.authorizationStatus {
        case .authorized, .limited:
            if manager.isLoadingAlbums {
                return manager.totalAlbumCount > 0
                    ? "\(manager.loadedAlbumCount)/\(manager.totalAlbumCount) albums"
                    : "Loading"
            }
            if manager.isLoadingAlbum {
                return "Opening album"
            }
            if manager.selectedAlbum != nil {
                let assetCount = manager.totalAssetCount
                return "\(assetCount) item\(assetCount == 1 ? "" : "s")"
            }
            let albumCount = displayedAlbums.count
            if albumVisibility == .hidden {
                return "\(albumCount) hidden"
            }
            return "\(albumCount) album\(albumCount == 1 ? "" : "s")"
        case .notDetermined:
            return "Access needed"
        case .denied, .restricted:
            return "Access blocked"
        @unknown default:
            return "Access unknown"
        }
    }

    private var requestAccessView: some View {
        LensLabSection(
            title: "Photo Library Access", subtitle: "Grant full access before browsing and moving album media."
        ) {
            HStack(spacing: 14) {
                GalleryPromptIcon(systemName: "photo.on.rectangle.angled", tint: LensLabTheme.cyan)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Access required")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(LensLabTheme.ink)

                    Text(
                        "Gallery needs read/write access to browse albums, create destination albums, and update selected items."
                    )
                    .font(.callout)
                    .foregroundStyle(LensLabTheme.mutedInk)
                }

                Spacer(minLength: 12)

                Button {
                    Task {
                        await manager.requestAuthorization()
                    }
                } label: {
                    Label("Grant Access", systemImage: "lock.open")
                }
                .buttonStyle(LensLabPrimaryButtonStyle())
            }
        }
    }

    private var deniedAccessView: some View {
        LensLabSection(title: "Photo Library Access", subtitle: "Enable Photos access in Settings to use Gallery.") {
            HStack(spacing: 14) {
                GalleryPromptIcon(systemName: "photo.badge.exclamationmark", tint: LensLabTheme.red)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Access denied")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(LensLabTheme.ink)

                    Text("Gallery cannot browse or modify albums until Photos access is enabled.")
                        .font(.callout)
                        .foregroundStyle(LensLabTheme.mutedInk)
                }

                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if manager.isLoadingAlbums && manager.albums.isEmpty {
            GalleryLoadingCard(title: manager.loadingMessage ?? "Loading albums...")
        } else if manager.selectedAlbum != nil {
            albumDetailView
        } else {
            albumGridView
        }
    }

    private var albumGridView: some View {
        VStack(spacing: 14) {
            if displayedAlbums.isEmpty {
                albumEmptyState
            } else {
                Group {
                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 180, maximum: 250), spacing: 12, alignment: .top)
                        ], spacing: 12
                    ) {
                        ForEach(displayedAlbums) { album in
                            GalleryAlbumCard(
                                id: album.id,
                                title: album.title,
                                assetCount: album.assetCount,
                                isSelectionMode: isSelectingAlbums,
                                isSelected: selectedAlbumIDs.contains(album.id),
                                isHidden: albumVisibility == .hidden,
                                cover: {
                                    GalleryAlbumCover(album: album, manager: manager)
                                },
                                action: {
                                    if isSelectingAlbums {
                                        toggleAlbumSelection(album.id)
                                    } else {
                                        Task {
                                            await manager.openAlbum(album)
                                        }
                                    }
                                }
                            )
                            .frame(maxWidth: .infinity, alignment: .top)
                            .contextMenu {
                                if manager.isAlbumHidden(album) {
                                    Button {
                                        manager.unhideAlbums(withIDs: [album.id])
                                    } label: {
                                        Label("Unhide Album", systemImage: "eye")
                                    }
                                } else {
                                    Button {
                                        manager.hideAlbums(withIDs: [album.id])
                                    } label: {
                                        Label("Hide Album", systemImage: "eye.slash")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var displayedAlbums: [GalleryAlbum] {
        switch albumVisibility {
        case .visible:
            return manager.visibleAlbums
        case .hidden:
            return manager.hiddenAlbums
        }
    }

    @ViewBuilder
    private var albumEmptyState: some View {
        if albumVisibility == .hidden {
            GalleryEmptyCard(
                icon: "eye.slash",
                title: "No Hidden Albums",
                message: "Albums you hide appear here, along with empty albums when auto-hide is on."
            )
        } else if manager.albums.isEmpty {
            GalleryEmptyCard(
                icon: "rectangle.stack.badge.plus",
                title: "No User Albums Found",
                message: "Create regular albums in Photos to browse them here."
            )
        } else {
            GalleryEmptyCard(
                icon: "eye.slash",
                title: "All Albums Hidden",
                message: "Open Visibility in the toolbar and choose Hidden to restore albums."
            )
        }
    }

    private var albumsSubtitle: String {
        if manager.isLoadingAlbums {
            return manager.loadingMessage ?? "Indexing albums..."
        }

        if isSelectingAlbums {
            return albumVisibility == .visible
                ? "Select albums to remove from the main Gallery grid."
                : "Select albums to restore to the main Gallery grid."
        }

        if albumVisibility == .hidden {
            return "Hidden albums stay in Photos. Unhide an empty album to keep it visible."
        }

        #if os(macOS)
            return "Open an album to view media. Right-click an album for Hide options."
        #else
            return "Open an album to view media. Pinch and hold an album for Hide options."
        #endif
    }

    private func toggleAlbumSelection(_ albumID: String) {
        if selectedAlbumIDs.contains(albumID) {
            selectedAlbumIDs.remove(albumID)
        } else {
            selectedAlbumIDs.insert(albumID)
        }
        manager.selectionFeedbackSignal += 1
    }

    private func applyAlbumVisibilityChange() {
        if albumVisibility == .visible {
            manager.hideAlbums(withIDs: selectedAlbumIDs)
        } else {
            manager.unhideAlbums(withIDs: selectedAlbumIDs)
        }
        clearAlbumSelection()
    }

    private func clearAlbumSelection() {
        selectedAlbumIDs.removeAll()
        isSelectingAlbums = false
    }

    private var albumDetailView: some View {
        VStack(spacing: 12) {
            if let errorMessage = manager.errorMessage {
                GalleryMessageBanner(
                    message: errorMessage, tint: LensLabTheme.red, icon: "exclamationmark.triangle.fill")
            }

            if manager.isLoadingAlbum {
                GalleryLoadingCard(title: manager.loadingMessage ?? "Loading media...")
            } else if manager.totalAssetCount == 0 {
                GalleryEmptyCard(
                    icon: "photo",
                    title: "Album Is Empty",
                    message: "There are no photos or videos in this album."
                )
            } else {
                GalleryAssetGrid(
                    manager: manager,
                    thumbnailSize: CGFloat(thumbnailSize),
                    onOpen: openMedia
                )
                .allowsHitTesting(!manager.isSortingAssets && !manager.isPerformingOperation)
                .opacity(manager.isSortingAssets ? 0.72 : 1)
            }
        }
    }

    private var mediaInteractionHint: String {
        #if os(visionOS)
            return isSelectingMedia || manager.isSelectionMode
                ? "Tap to select. Long pinch the first and last items to select a range."
                : "Tap to open a slideshow. Long pinch to select items for batch actions."
        #else
            return "Click to select. Press and hold the first and last items to select a range."
        #endif
    }

    private func openMedia(at index: Int) {
        #if os(visionOS)
            if isSelectingMedia || manager.isSelectionMode {
                manager.handleShortTap(index: index)
                return
            }
            guard let sessionID = GalleryViewerStore.shared.createSession(from: manager, at: index) else { return }
            let value = GalleryViewerWindows.shared.makeWindow(sessionIDs: [sessionID])
            openWindow(id: GalleryViewerWindows.sceneID, value: value)
        #else
            manager.handleShortTap(index: index)
        #endif
    }

    private func deletionConfirmationMessage(for review: GalleryDeletionPlan) -> String {
        "This is not Remove from Album. Gallery will ask Photos to delete exactly "
            + "\(review.totalCount) selected item\(review.totalCount == 1 ? "" : "s") "
            + "(\(review.mediaBreakdown)) from the full Photos library. No unselected item is included. "
            + "With iCloud Photos, the deletion syncs to your other devices. Photos normally moves deleted "
            + "items to Recently Deleted and will show its own final confirmation."
    }
}

private struct GalleryAssetGrid: View {
    @ObservedObject var manager: GalleryManager
    let thumbnailSize: CGFloat
    let onOpen: (Int) -> Void

    private var columns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: thumbnailSize, maximum: thumbnailSize * 1.08),
                spacing: 8,
                alignment: .top
            )
        ]
    }

    var body: some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(0..<manager.visibleAssetCount, id: \.self) { index in
                    if let asset = manager.asset(at: index) {
                        GalleryAssetCell(
                            asset: asset,
                            index: index,
                            isSelected: manager.selectedIndexes.contains(index),
                            hasRangeAnchor: manager.rangeAnchorIndex == index,
                            manager: manager,
                            onTap: {
                                onOpen(index)
                            },
                            onLongPinch: {
                                manager.handleLongPinch(index: index)
                            }
                        )
                        .onAppear {
                            manager.assetDidAppear(index: index)
                            manager.loadMoreIfNeeded(appearingIndex: index)
                        }
                        .onDisappear {
                            manager.assetDidDisappear(index: index)
                        }
                    }
                }
            }

            if manager.visibleAssetCount < manager.totalAssetCount {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading more media...")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LensLabTheme.mutedInk)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            } else {
                Text("\(manager.totalAssetCount) item\(manager.totalAssetCount == 1 ? "" : "s")")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LensLabTheme.mutedInk)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        }
    }
}

private struct GalleryAssetCell: View {
    let asset: PHAsset
    let index: Int
    let isSelected: Bool
    let hasRangeAnchor: Bool
    let manager: GalleryManager
    let onTap: () -> Void
    let onLongPinch: () -> Void

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ZStack(alignment: .topLeading) {
                    GalleryThumbnail(asset: asset, manager: manager)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if asset.mediaType == .video {
                        GalleryAssetBadge(
                            text: GalleryAssetCell.videoDurationText(asset.duration),
                            icon: "video.fill",
                            tint: LensLabTheme.previewSurface.opacity(0.82)
                        )
                        .padding(6)
                    }

                    if isSelected {
                        ZStack {
                            Circle()
                                .fill(LensLabTheme.cyan)
                                .frame(width: 28, height: 28)
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(6)
                    }

                    if hasRangeAnchor {
                        GalleryAssetBadge(text: "Range start", icon: "flag.fill", tint: LensLabTheme.orange)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                            .padding(6)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(selectionStrokeColor, lineWidth: isSelected || hasRangeAnchor ? 3 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .gesture(selectionGesture)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(mediaTapHint)
            .accessibilityIdentifier("gallery-asset-\(index)")
            .accessibilityAction {
                onTap()
            }
            .accessibilityAction(named: "Set Range Endpoint") {
                onLongPinch()
            }
    }

    private var selectionGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.55, maximumDistance: 32)
            .exclusively(before: TapGesture())
            .onEnded { result in
                switch result {
                case .first(true):
                    onLongPinch()
                case .second:
                    onTap()
                default:
                    break
                }
            }
    }

    private var mediaTapHint: String {
        #if os(visionOS)
            return "Tap to open, or toggle selection in Select mode. Long pinch to set a range endpoint."
        #else
            return "Short pinch to toggle selection. Long pinch to set a range endpoint."
        #endif
    }

    private var selectionStrokeColor: Color {
        if hasRangeAnchor {
            return LensLabTheme.orange
        }
        if isSelected {
            return LensLabTheme.cyan
        }
        return LensLabTheme.cardLine.opacity(0.65)
    }

    private var accessibilityLabel: String {
        let mediaName = asset.mediaType == .video ? "Video" : "Photo"
        return "\(mediaName) \(index + 1)\(isSelected ? ", selected" : "")"
    }

    private static func videoDurationText(_ duration: TimeInterval) -> String {
        guard duration.isFinite, duration > 0 else {
            return "Video"
        }

        let totalSeconds = Int(duration.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }
}

private struct GalleryAlbumCover: View {
    let album: GalleryAlbum
    let manager: GalleryManager

    @State private var coverAsset: PHAsset?

    var body: some View {
        Group {
            if let coverAsset = coverAsset ?? album.coverAsset {
                GalleryThumbnail(asset: coverAsset, manager: manager)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LensLabTheme.cyan.opacity(0.12))
                    .overlay {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(LensLabTheme.cyan)
                    }
            }
        }
        .task(id: album.id) {
            coverAsset = nil
            coverAsset = manager.coverAsset(for: album.collection)
        }
    }
}

private struct GalleryAlbumCard<Cover: View>: View {
    let id: String
    let title: String
    let assetCount: Int
    let isSelectionMode: Bool
    let isSelected: Bool
    let isHidden: Bool
    @ViewBuilder let cover: Cover
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Color.clear
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .overlay {
                        ZStack {
                            cover

                            if isSelected {
                                ZStack {
                                    Circle()
                                        .fill(LensLabTheme.cyan)
                                        .frame(width: 30, height: 30)
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.white)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                .padding(8)
                            } else if isHidden {
                                GalleryAssetBadge(
                                    text: "Hidden", icon: "eye.slash.fill",
                                    tint: LensLabTheme.previewSurface.opacity(0.82)
                                )
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .padding(8)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(LensLabTheme.cardLine.opacity(0.65), lineWidth: 1)
                    }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(LensLabTheme.ink)
                            .lineLimit(1)

                        Text("\(assetCount) item\(assetCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(LensLabTheme.mutedInk)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: trailingIcon)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(isSelected ? LensLabTheme.cyan : LensLabTheme.mutedInk.opacity(0.7))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .top)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.46 : 0.32))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(cardStrokeColor, lineWidth: isSelected ? 2 : 1)
                    }
                    .shadow(
                        color: LensLabTheme.shellShadow.opacity(isHovering ? 0.12 : 0.06), radius: isHovering ? 12 : 6,
                        y: 4)
            }
            .scaleEffect(isHovering ? 1.01 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHovering)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .top)
        .onHover { hovering in
            isHovering = hovering
        }
        .accessibilityLabel("\(title), \(assetCount) items\(isSelected ? ", selected" : "")")
        .accessibilityHint(isSelectionMode ? "Pinch to toggle album selection." : "Pinch to open album.")
        .accessibilityIdentifier("svt-gallery-album-\(id)")
    }

    private var trailingIcon: String {
        if isSelectionMode {
            return isSelected ? "checkmark.circle.fill" : "circle"
        }
        return "chevron.right"
    }

    private var cardStrokeColor: Color {
        if isSelected {
            return LensLabTheme.cyan
        }
        if isHovering {
            return LensLabTheme.cyan.opacity(0.55)
        }
        return LensLabTheme.cardLine.opacity(0.7)
    }
}

private struct GalleryMoveSheet: View {
    @ObservedObject var manager: GalleryManager
    @Binding var isPresented: Bool
    @State private var newAlbumName = ""
    @State private var albumFilter = ""

    private var destinationAlbums: [GalleryAlbum] {
        let availableAlbums = manager.albums.filter { $0.id != manager.selectedAlbum?.id }
        let query = albumFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return availableAlbums
        }
        return availableAlbums.filter { album in
            album.title.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Move Selected Items")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(LensLabTheme.ink)

                    Text("\(manager.selectedCount) selected")
                        .font(.caption)
                        .foregroundStyle(LensLabTheme.mutedInk)
                }

                Spacer()

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(LensLabSecondaryButtonStyle())
            }

            LensLabSection(
                title: "New Album", subtitle: "Create a destination album and move the selected media there."
            ) {
                HStack(spacing: 10) {
                    TextField("Album name", text: $newAlbumName)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        let name = newAlbumName
                        isPresented = false
                        Task {
                            await manager.moveSelectionToNewAlbum(named: name)
                        }
                    } label: {
                        Label("Create & Move", systemImage: "rectangle.stack.badge.plus")
                    }
                    .buttonStyle(LensLabPrimaryButtonStyle())
                    .disabled(
                        newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || manager.isPerformingOperation)
                }
            }

            LensLabSection(title: "Existing Albums", subtitle: "Filter by album name, then choose a destination.") {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(LensLabTheme.mutedInk)

                    TextField("Filter albums", text: $albumFilter)
                        .textFieldStyle(.roundedBorder)

                    if !albumFilter.isEmpty {
                        Button {
                            albumFilter = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(LensLabTheme.mutedInk)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear album filter")
                    }
                }

                if destinationAlbums.isEmpty {
                    Text(
                        albumFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "No other albums are available."
                            : "No albums match that filter."
                    )
                    .font(.callout)
                    .foregroundStyle(LensLabTheme.mutedInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 8) {
                            ForEach(destinationAlbums) { album in
                                Button {
                                    isPresented = false
                                    Task {
                                        await manager.moveSelection(to: album)
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "rectangle.stack")
                                            .font(.callout.weight(.semibold))
                                            .foregroundStyle(LensLabTheme.cyan)
                                            .frame(width: 26)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(album.title)
                                                .font(.callout.weight(.semibold))
                                                .foregroundStyle(LensLabTheme.ink)
                                                .lineLimit(1)

                                            Text("\(album.assetCount) item\(album.assetCount == 1 ? "" : "s")")
                                                .font(.caption)
                                                .foregroundStyle(LensLabTheme.mutedInk)
                                        }

                                        Spacer()

                                        Image(systemName: "arrow.right")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(LensLabTheme.mutedInk)
                                    }
                                    .padding(10)
                                    .background(
                                        .white.opacity(0.36), in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    )
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(LensLabTheme.cardLine.opacity(0.66), lineWidth: 1)
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(manager.isPerformingOperation)
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                }
            }
        }
        .padding(18)
        .frame(width: 580, height: 680)
        .background(LensLabTheme.card)
    }
}

private struct GalleryToastBanner: View {
    let toast: GalleryToast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.callout.weight(.bold))
                .foregroundStyle(tint)

            Text(toast.message)
                .font(.callout.weight(.semibold))
                .foregroundStyle(LensLabTheme.ink)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tint.opacity(0.42), lineWidth: 1)
        }
    }

    private var icon: String {
        switch toast.kind {
        case .info:
            return "info.circle.fill"
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch toast.kind {
        case .info:
            return LensLabTheme.cyan
        case .success:
            return LensLabTheme.green
        case .warning:
            return LensLabTheme.orange
        case .error:
            return LensLabTheme.red
        }
    }
}

private struct GalleryPromptIcon: View {
    let systemName: String
    let tint: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 42, height: 42)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct GalleryMessageBanner: View {
    let message: String
    let tint: Color
    let icon: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(message)
                .font(.callout)
                .foregroundStyle(LensLabTheme.ink)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tint.opacity(0.24), lineWidth: 1)
        }
    }
}

private struct GalleryLoadingCard: View {
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(LensLabTheme.mutedInk)
        }
        .frame(maxWidth: .infinity)
        .padding(36)
        .lensLabCard()
    }
}

private struct GalleryEmptyCard: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(LensLabTheme.mutedInk.opacity(0.68))

            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(LensLabTheme.ink)

            Text(message)
                .font(.callout)
                .foregroundStyle(LensLabTheme.mutedInk)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(38)
        .lensLabCard()
    }
}

private struct GalleryAssetBadge: View {
    let text: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
            Text(text)
                .font(.caption2.weight(.bold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(tint, in: Capsule())
    }
}

private struct GalleryDestructiveButtonStyle: ButtonStyle {
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(isEnabled ? tint : LensLabTheme.mutedInk)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(isEnabled ? 0.12 : 0.05))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(tint.opacity(isEnabled ? 0.45 : 0.18), lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.62)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#if DEBUG
    struct GalleryLayoutDebugView: View {
        private struct Sample: Identifiable {
            let id: String
            let title: String
            let itemCount: Int
            let tint: Color
        }

        private let samples = [
            Sample(id: "city", title: "Misc", itemCount: 16, tint: LensLabTheme.orange),
            Sample(id: "reframe", title: "Spatial Reframe RPA Demo Source", itemCount: 2, tint: LensLabTheme.blue),
            Sample(
                id: "proof", title: "Spatial Reframe Video — proof-source-3s — fd80a90d", itemCount: 0,
                tint: LensLabTheme.cyan),
            Sample(id: "vacation", title: "SVT Proxy — Vacation", itemCount: 3, tint: LensLabTheme.green),
            Sample(id: "family", title: "SVT Proxy — Family", itemCount: 3, tint: LensLabTheme.red),
            Sample(id: "screens", title: "SVT Proxy — Screenshots", itemCount: 2, tint: LensLabTheme.blue),
            Sample(id: "duplicates", title: "SVT Proxy — Duplicates", itemCount: 2, tint: LensLabTheme.orange),
        ]
        @State private var albumVisibility: GalleryAlbumVisibility = .visible

        var body: some View {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 14) {
                    LensLabToolHeader(
                        title: "Gallery Layout",
                        subtitle: "Deterministic desktop fixture for card geometry and contrast checks.",
                        icon: "square.grid.3x3",
                        tint: LensLabTheme.cyan,
                        status: "\(samples.count) fixtures"
                    )

                    HStack(spacing: 12) {
                        Text("Album visibility")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(LensLabTheme.ink)

                        GalleryVisibilityMenu(
                            selection: $albumVisibility,
                            visibleCount: samples.count,
                            hiddenCount: 0
                        )

                        Spacer(minLength: 12)

                        Button("Select") {}
                            .buttonStyle(LensLabSecondaryButtonStyle())
                        Button("Refresh") {}
                            .buttonStyle(LensLabSecondaryButtonStyle())
                    }
                    .padding(14)
                    .lensLabCard()

                    LensLabSection(
                        title: "Albums",
                        subtitle: "Cards must remain inside their grid cells at every supported window width."
                    ) {
                        LazyVGrid(
                            columns: [
                                GridItem(.adaptive(minimum: 180, maximum: 250), spacing: 12, alignment: .top)
                            ], spacing: 12
                        ) {
                            ForEach(Array(samples.enumerated()), id: \.element.id) { index, sample in
                                GalleryAlbumCard(
                                    id: sample.id,
                                    title: sample.title,
                                    assetCount: sample.itemCount,
                                    isSelectionMode: false,
                                    isSelected: index == 1,
                                    isHidden: false,
                                    cover: {
                                        GalleryLayoutDebugCover(index: index, tint: sample.tint)
                                    },
                                    action: {}
                                )
                                .frame(maxWidth: .infinity, alignment: .top)
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .accessibilityIdentifier("svt-gallery-layout-debug")
        }
    }

    private struct GalleryLayoutDebugCover: View {
        let index: Int
        let tint: Color

        var body: some View {
            ZStack {
                LinearGradient(
                    colors: [tint.opacity(0.72), LensLabTheme.previewSurface.opacity(0.90)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Image(systemName: index.isMultiple(of: 3) ? "building.2.crop.circle" : "photo.stack")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
            }
        }
    }
#endif

#Preview {
    GalleryView(isPresented: .constant(true))
}
