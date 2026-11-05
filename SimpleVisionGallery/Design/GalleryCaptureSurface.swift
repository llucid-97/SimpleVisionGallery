import SwiftUI


#if DEBUG
enum CaptureSurfaceArgument {
    static func baseID(_ id: String) -> String {
        id.replacingOccurrences(of: "-reduced-transparency", with: "")
            .replacingOccurrences(of: "-reduced-motion", with: "")
            .replacingOccurrences(of: "-accessibility", with: "")
    }
    static func usesNativeViewer(_ id: String) -> Bool {
        id.hasPrefix("native-viewer") || id == "viewer" || id == "viewer-more-menu"
    }

    static var value: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-gallery-capture-surface"), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }
}

/// A restored fixture scene must hand non-native capture routes back to the main scene.
struct GalleryCaptureMainSceneRecovery: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    private static var hasRequestedMain = false

    var body: some View {
        Color.clear.task {
            guard !Self.hasRequestedMain else { return }
            Self.hasRequestedMain = true
            // Recreate exactly one capture main scene; its appearance retires this empty fixture.
            dismissWindow(id: "gallery-main")
            openWindow(id: "gallery-main")
        }
    }
}

struct CaptureSurface: View {
    let id: String
    let reducedTransparency: Bool
    let reducedMotion: Bool
    let accessibilityTypePreview: Bool
    @Environment(\.dynamicTypeSize) private var systemTypeSize

    init(id: String) {
        self.id = CaptureSurfaceArgument.baseID(id)
        reducedTransparency = id.contains("-reduced-transparency")
        reducedMotion = id.contains("-reduced-motion")
        accessibilityTypePreview = id.contains("-accessibility")
    }

    @StateObject private var manager = GalleryManager(observesPhotoLibrary: false)
    @State private var query = ""
    @State private var result: String?
    @State private var retries: [UUID] = []
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            switch id {
            case "albums":
                GalleryCinemaDesign(context: cinemaContext)
            case "albums-classic", "photos-classic":
                GalleryCinemaDesign(context: cinemaContext, photosUseOrnaments: false)
            case "photos-ornaments", "albums-ornaments":
                GalleryCinemaDesign(context: cinemaContext, photosUseOrnaments: true)
            case "photos-scrolled":
                GalleryCinemaDesign(context: cinemaContext, startsAtBottom: true)
            case "photos", "recycle-bin", "album-detail", "selection", "loading", "empty", "error", "toast":
                GalleryCinemaDesign(context: cinemaContext)
            case "settings", "vault", "about", "about-faq-expanded", "privacy", "licenses", "rename", "move", "thumbnail-size-popover", "album-delete", "album-delete-recovery":
                GalleryCinemaDesign(context: cinemaContext)
                    .blur(radius: 9)
                    .sheet(isPresented: .constant(true)) { overlayContent }
            case "delete-confirmation", "vault-confirmation":
                GalleryCinemaDesign(context: cinemaContext)
                    .alert(stateTitle, isPresented: .constant(true)) {
                        Button("Cancel", role: .cancel) {}
                        Button("Continue", role: .destructive) {}.disabled(true)
                    } message: { Text(stateDescription) }
            case "theme":
                GalleryThemeSamples()
            case "viewer", "viewer-more-menu", "native-viewer", "native-viewer-pair", "native-viewer-portrait", "native-viewer-last-light", "close-gallery-windows":
                Color.clear
            case "menus", "overflow-menu", "sort-menu", "filter-menu", "visibility-menu", "selection-menu", "album-actions-menu", "ornament-overflow-menu":
                simulatedMenus
            default:
                ContentUnavailableView("Unknown capture surface", systemImage: "questionmark", description: Text(id))
            }
        }
        .frame(minWidth: id.hasPrefix("native-viewer") ? (id.contains("-pair") ? 1048 : 732) : 840, minHeight: 620)
        .overlay(alignment: .bottomTrailing) {
            if id == "toast" {
                GalleryToastBanner(toast: GalleryToast(kind: .success, message: "Album order updated"))
                    .padding(24)
            }
        }
        .environment(\.galleryLightReduceTransparency, reducedTransparency)
        .environment(\.galleryLightReduceMotion, reducedMotion)
        .environment(\.dynamicTypeSize, accessibilityTypePreview ? .accessibility1 : systemTypeSize)
        .task {
            if !CaptureSurfaceArgument.usesNativeViewer(id), id != "close-gallery-windows" {
                dismissWindow(id: "gallery-native-fixture")
            }
            if id == "close-gallery-windows" {
                dismissWindow(id: GalleryViewerWindows.sceneID)
                dismissWindow(id: GalleryViewerWindows.pairSceneID)
                dismissWindow(id: "gallery-native-fixture")
                dismissWindow(id: "gallery-main")
                return
            }
            if CaptureSurfaceArgument.usesNativeViewer(id) {
                openWindow(id: "gallery-native-fixture")
                try? await Task.sleep(for: .milliseconds(600))
                dismissWindow(id: "gallery-main")
                return
            }
            if ["photos", "photos-classic", "photos-ornaments", "photos-scrolled", "recycle-bin", "album-detail", "selection"].contains(id) {
                manager.configureCapturePresentation(
                    section: id == "recycle-bin" ? .recycleBin : (id == "album-detail" ? .albums : .photos),
                    album: GalleryAlbum(id: "capture-open", title: stateTitle, assetCount: GalleryCaptureFixtures.records.count, collection: nil, coverAsset: nil)
                )
            }
            if id == "loading" { manager.isLoadingAlbums = true }
        }
    }

    @ViewBuilder private var overlayContent: some View {
        switch id {
        case "settings": GallerySettingsView(manager: manager).frame(width: 650, height: 800)
        case "vault": GalleryVaultView(resultMessage: $result, albumRetryIDs: $retries).frame(width: 580)
        case "about", "about-faq-expanded": GalleryAboutView(expandFAQ: id == "about-faq-expanded").frame(width: 650, height: 800)
        case "privacy": NavigationStack { GalleryPrivacyView() }.frame(width: 650, height: 800)
        case "licenses": NavigationStack { GalleryLicensesView() }.frame(width: 650, height: 600)
        case "thumbnail-size-popover": GalleryThumbnailSizePopover(thumbnailSize: .constant(GalleryMediaGridLayout.defaultThumbnailSize))
        case "album-delete", "album-delete-recovery":
            GalleryAlbumDeletionSheet(plan: GalleryAlbumDeletionPlan(albumID: "capture-0", title: "City at Dusk", hadPhotosAlbum: true,
                photoIDs: GalleryCaptureFixtures.records.filter { $0.scene == 0 }.map { "synthetic-\($0.index)" }, sharedPhotoCount: 0, vaultRecords: []),
                isRecoveryReview: id == "album-delete-recovery")
                .allowsHitTesting(false)
        case "rename": GalleryRenameAlbumSheet(album: syntheticAlbums[0], manager: manager)
        default: GalleryMoveSheet(manager: manager, isPresented: .constant(true), canMoveToVault: false, moveToVault: { _ in })
        }
    }

    private var syntheticAlbums: [GalleryAlbum] {
        GalleryCaptureFixtures.titles.enumerated().map { scene, title in
            let count = GalleryCaptureFixtures.records.filter { $0.scene == scene }.count
            return GalleryAlbum(id: "capture-\(scene)", title: title, assetCount: count,
                collection: nil, coverAsset: nil, photoCount: count, videoCount: 0)
        }
    }

    private var cinemaContext: GalleryDesignContext {
        GalleryDesignContext(
            manager: manager, albums: ["loading", "empty", "error"].contains(id) ? [] : syntheticAlbums, query: $query,
            isSelectingAlbums: id == "selection", selectedAlbumIDs: [],
            actions: AnyView(captureActions), albumToolbar: AnyView(captureAlbumToolbar), ornamentToolbar: AnyView(manager.selectedAlbum == nil ? AnyView(captureLobbyToolbar) : AnyView(captureAlbumToolbar)),
            mediaContent: AnyView(captureMediaGrid), emptyContent: AnyView(explicitState),
            cover: { album in AnyView(CaptureAlbumArtwork(album: album)) },
            openAlbum: { _ in }, renameAlbum: { _ in }, deleteAlbum: { _ in }, toggleVisibility: { _ in },
            moveAlbumToVault: { _ in }, restoreAlbumFromVault: { _ in }, selectSection: { _ in },
            reorderAlbumID: nil, beginReordering: { _ in }, cancelReordering: {}, reorderAlbum: { _, _, _ in },
            showSettings: {}, showVault: {}
        )
    }

    private var captureLobbyToolbar: some View {
        HStack(spacing: 12) {
            GalleryDesignSearchField(query: $query).frame(width: 300)
            Menu { ForEach(GalleryAlbumSortMode.allCases, id: \.self) { mode in Button(mode.title) {} } }
                label: { Label("Sort albums", systemImage: "arrow.up.arrow.down") }
            Button("Select", systemImage: "checkmark.circle") {}
            Menu { ForEach(GalleryMediaFilter.allCases, id: \.self) { filter in Button(filter.title) {} } }
                label: { Label("Filter", systemImage: "line.3.horizontal.decrease") }
            Menu { Button("Private Vault") {}; Button("Gallery Settings") {} }
                label: { Image(systemName: "ellipsis").frame(width: 40, height: 40) }
        }
        .buttonStyle(LensLabSecondaryButtonStyle())
    }

    private var captureAlbumToolbar: some View {
        GalleryMediaToolbar(query: $query, placeholder: "Search in \(stateTitle)",
            showsBackButton: !["photos", "photos-classic", "photos-ornaments", "photos-scrolled"].contains(id), searchMaxWidth: id == "photos-ornaments" ? 320 : nil, back: {}) {
            HStack(spacing: 12) {
                Menu { ForEach(GalleryAssetSortMode.allCases) { mode in Button(mode.title) {} } }
                    label: { Label("Sort", systemImage: "arrow.up.arrow.down").frame(minHeight: 26) }
                if id != "photos-ornaments" {
                    Button {} label: { Image(systemName: "rectangle.grid.2x2").frame(minHeight: 26) }
                }
                Button {} label: { Label("Select", systemImage: "checkmark.circle").frame(minHeight: 26) }
                Menu { ForEach(GalleryMediaFilter.allCases, id: \.self) { filter in Button(filter.title) {} } }
                    label: { Label("Filter", systemImage: "line.3.horizontal.decrease").frame(minHeight: 40) }
                Menu { Button("Private Vault") {}; Button("Gallery Settings") {} }
                    label: { Image(systemName: "ellipsis").frame(width: 40, height: 40) }
            }
            .buttonStyle(LensLabSecondaryButtonStyle())
        }
    }

    private var captureMediaGrid: some View {
        LazyVGrid(columns: GalleryMediaGridLayout.columns(thumbnailSize: GalleryMediaGridLayout.defaultThumbnailSize), spacing: GalleryMediaGridLayout.gap) {
            ForEach(GalleryCaptureFixtures.records) { record in
                CaptureMediaTile(index: record.index, isSelected: id == "selection" && record.index < 3)
            }
        }
    }

    private var captureActions: some View {
        HStack(spacing: 16) {
            Menu { ForEach(GalleryAlbumSortMode.allCases, id: \.self) { mode in Button(mode.title) {} } }
                label: { Image(systemName: "arrow.up.arrow.down").frame(minHeight: 26) }
            Button {} label: { Image(systemName: "checkmark.circle").frame(width: 40, height: 40) }
            Menu { ForEach(GalleryMediaFilter.allCases, id: \.self) { filter in Button(filter.title) {} } }
                label: { Image(systemName: "line.3.horizontal.decrease").frame(width: 40, height: 40) }
            Menu { Button("Private Vault") {}; Button("Gallery Settings") {} }
                label: { Image(systemName: "ellipsis").frame(width: 40, height: 40) }
        }
        .buttonStyle(LensLabSecondaryButtonStyle())
    }

    private var explicitState: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Synthetic capture state", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
            Text(stateTitle).font(.largeTitle.bold())
            Text(stateDescription).font(.body).foregroundStyle(.secondary)
            if id == "loading" { ProgressView("Loading library…") }
            if id == "error" {
                Label("Could not load the library", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var stateTitle: String {
        switch id {
        case "photos", "photos-classic", "photos-scrolled", "photos-ornaments": "Photos"
        case "recycle-bin": "Recycle Bin"
        case "album-detail": "All sample photos"
        case "loading": "Loading albums"
        case "empty": "No albums yet"
        case "rename": "Rename album"
        case "move": "Move to album"
        case "delete-confirmation": "Delete selected items?"
        case "vault-confirmation": "Move to Private Vault?"
        case "selection": "3 items selected"
        case "toast": "Album order updated"
        default: "Library unavailable"
        }
    }

    private var stateDescription: String {
        switch id {
        case "photos": "A synthetic native grid with sample photo tiles. No Photos library is read."
        case "recycle-bin": "Items stay in this normal Photos album until you restore or explicitly delete them. (Mock state)"
        case "album-detail": "A synthetic album detail with sample media tiles; viewer actions are not connected."
        case "loading": "Loading placeholder shown for inventory only."
        case "empty": "Your albums will appear here when the library has content. (Mock state)"
        case "rename": "Enter a new album name. (Mock sheet; save is disabled.)"
        case "move": "Choose a destination album. (Mock sheet; moving items is disabled.)"
        case "delete-confirmation": "The selected items will be moved to Recently Deleted. (Mock alert; action disabled.)"
        case "vault-confirmation": "Items will be encrypted before leaving Photos. (Mock alert; action disabled.)"
        case "selection": "Select albums or items to run a batch action. (Mock selection state.)"
        case "toast": "Transient feedback appears after a completed action. (Mock banner.)"
        default: "Photo Library access is unavailable. Check access in Settings. (Mock state)"
        }
    }

    private var simulatedMenus: some View {
        ZStack(alignment: .topTrailing) {
            GalleryCinemaDesign(context: cinemaContext)
            VStack(alignment: .leading, spacing: 14) {
                Text(menuTitle).font(.headline)
                Divider()
                ForEach(menuItems, id: \.self) { title in
                    menuRow(title, detail: title == "Visibility" ? "Albums 6 ›" : "", symbol: menuSymbol(title))
                        .foregroundStyle(title.hasPrefix("Delete") ? .red : .white)
                }
            }
            .padding(24).frame(width: 360)
            .galleryOrnamentBackdrop(cornerRadius: 24)
            .padding(.top, id == "ornament-overflow-menu" ? 0 : 100).padding(.trailing, 36)
        }
        .foregroundStyle(.white)
    }

    private func menuSymbol(_ title: String) -> String {
        switch title {
        case "Name", "All Media": "checkmark"
        case "Refresh": "arrow.clockwise"
        case "Visibility": "eye"
        case "Delete Album…": "trash"
        case "Private Vault", "Move Album to Private Vault", "Move to Private Vault": "lock"
        case "Gallery Settings": "gearshape"
        case "Share": "square.and.arrow.up"
        case "Rename Album": "pencil"
        case "Hide Album from List": "eye.slash"
        case "Select All": "checkmark.circle"
        case "Clear Selection": "xmark.circle"
        case "Move to Recycle Bin": "trash"
        default: ""
        }
    }

    private var menuTitle: String {
        switch id {
        case "sort-menu": "Sort albums"
        case "filter-menu": "Filter media"
        case "visibility-menu": "Album visibility"
        case "selection-menu": "Selected media"
        case "album-actions-menu": "Album actions"
        default: "More Gallery Actions"
        }
    }

    private var menuItems: [String] {
        switch id {
        case "sort-menu": GalleryAlbumSortMode.allCases.map(\.title)
        case "filter-menu": GalleryMediaFilter.allCases.map(\.title)
        case "visibility-menu": ["Albums · 6", "Hidden · 0"]
        case "selection-menu": ["Move to Private Vault", "Share", "Clear Selection", "Select All", "Move to Recycle Bin"]
        case "album-actions-menu": ["Delete Album…", "Sort", "Move Album to Private Vault", "Hide Album from List", "Rename Album"]
        default: ["Visibility", "Refresh", "Private Vault", "Gallery Settings"]
        }
    }

    private func menuRow(_ title: String, detail: String, symbol: String) -> some View {
        HStack { Image(systemName: symbol).frame(width: 24); Text(title); Spacer(); Text(detail).foregroundStyle(.secondary) }
            .padding(.vertical, 5)
    }
}

#if DEBUG
private struct CaptureAlbumArtwork: View {
    let album: GalleryAlbum
    private var index: Int { Int(album.id.replacingOccurrences(of: "capture-", with: "")) ?? 0 }
    var body: some View {
        CapturePhotograph(index: index)
            .aspectRatio(1, contentMode: .fill).clipped()
    }
}

private struct CaptureMediaTile: View {
    let index: Int
    var isSelected = false
    var body: some View {
        Color.clear.aspectRatio(1, contentMode: .fit)
            .overlay { CapturePhotograph(index: index) }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2).foregroundStyle(GalleryAppearance.accent)
                        .padding(8)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? GalleryAppearance.accent : .clear, lineWidth: 3)
            }
    }
}

private struct CapturePhotograph: View {
    let index: Int
    var body: some View {
        if let url = Bundle.main.url(forResource: GalleryCaptureFixtures.filename(index: index), withExtension: "jpg"),
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Color.gray.overlay { Text("Fixture unavailable").font(.caption) }
        }
    }
}

#endif
#endif
