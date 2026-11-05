import SwiftUI

/// A softly lit viewing room: photographs lead, with a warm key and cool fill on the chrome.
struct GalleryCinemaDesign: View {
    let context: GalleryDesignContext
    var photosUseOrnaments = true
    #if DEBUG
    var startsAtBottom = false
    #endif
    @ObservedObject private var vault = GalleryVaultService.shared

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.galleryLightReduceMotion) private var previewReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || previewReduceMotion }
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.galleryLightReduceTransparency) private var previewReduceTransparency
    private var reduceTransparency: Bool { systemReduceTransparency || previewReduceTransparency }
    @AppStorage("gallery.sidebar.expanded") private var sidebarExpanded = true
    @State private var albumFrames: [String: CGRect] = [:]
    @GestureState private var reorderTranslation = CGSize.zero

    var body: some View {
        GeometryReader { geometry in
            Group {
                if photosUseOrnaments && (!context.hasOpenAlbum || context.manager.librarySection == .photos)
                    && geometry.size.width >= 1040 && !dynamicTypeSize.isAccessibilitySize {
                    ornamentLibrary(width: geometry.size.width)
                } else {
                HStack(spacing: 0) {
                    navigationRail
                    Group {
                        if context.hasOpenAlbum { albumRoom }
                        else { albumLobby(width: geometry.size.width) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, geometry.size.width < 900 ? 22 : 36)
                    .padding(.vertical, 28)
                }
                }
            }
            .frame(minWidth: 840, minHeight: 620)
            .modifier(CinemaCanvasBackdrop(isAlbumLobby: !context.hasOpenAlbum, reduceTransparency: reduceTransparency))
            .foregroundStyle(CinemaPalette.primaryText)
        }
        .preferredColorScheme(.dark)
    }

    private func ornamentLibrary(width: CGFloat) -> some View {
        Group {
            if context.hasOpenAlbum {
                ScrollView {
                    context.mediaContent.frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollIndicators(.visible)
            } else {
                albumLobby(width: width, showsHeader: false)
                    .padding(8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .ornament(visibility: .visible,
            attachmentAnchor: .scene(UnitPoint3D(x: 0, y: 0.5, z: 0.5)), contentAlignment: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Gallery", systemImage: "square.stack.3d.up")
                    .font(.headline).foregroundStyle(CinemaPalette.accent)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                ornamentNavigation("Albums", symbol: "square.grid.2x2", selected: !context.hasOpenAlbum) { context.selectSection(.albums) }
                ornamentNavigation("Photos", symbol: "photo.on.rectangle", selected: context.hasOpenAlbum) { context.selectSection(.photos) }
                ornamentNavigation("Recycle Bin", symbol: "trash", selected: false) { context.selectSection(.recycleBin) }
                Divider().padding(.horizontal, 12)
                ornamentNavigation("Private Vault", symbol: "lock", selected: false, action: context.showVault)
                ornamentNavigation("Settings", symbol: "gearshape", selected: false, action: context.showSettings)
            }
            .padding(12).frame(width: 190)
            .galleryOrnamentBackdrop(cornerRadius: 24)
            .padding(.trailing, 20)
        }
        .ornament(visibility: .visible,
            attachmentAnchor: .scene(UnitPoint3D(x: 0.5, y: 0, z: 0.5)), contentAlignment: .bottom) {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.hasOpenAlbum ? "Photos" : "Albums").font(.title2.weight(.semibold))
                    if context.hasOpenAlbum {
                        Text("\(context.manager.totalAssetCount) items").font(.callout).foregroundStyle(CinemaPalette.secondaryText)
                    } else { collectionCount }
                }
                context.ornamentToolbar
            }
            .padding(12).fixedSize(horizontal: true, vertical: false)
            .galleryOrnamentBackdrop(cornerRadius: 24)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.bottom, 20)
        }
    }

    private func ornamentNavigation(_ title: String, symbol: String, selected: Bool,
        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 24)
                Text(title).font(.body.weight(selected ? .semibold : .regular))
                    .lineLimit(1).minimumScaleFactor(0.9)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).frame(minHeight: 60)
            .background {
                if selected { GalleryLightSurface(role: .control, cornerRadius: 16) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? CinemaPalette.primaryText : CinemaPalette.secondaryText)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .hoverEffect(.highlight)
    }

    private var initialScrollAnchor: UnitPoint {
        #if DEBUG
        startsAtBottom ? .bottom : .top
        #else
        .top
        #endif
    }

    private var navigationRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { sidebarExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(CinemaPalette.accent)
                    if sidebarExpanded {
                        Text("Gallery").font(.system(size: 23, weight: .semibold, design: .rounded))
                        Image(systemName: "sidebar.left").font(.system(size: 15))
                            .foregroundStyle(CinemaPalette.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 60, alignment: sidebarExpanded ? .leading : .center)
                .padding(.horizontal, sidebarExpanded ? 12 : 0)
            }
            .buttonStyle(.plain)
            .galleryHoverLabel(sidebarExpanded ? "Collapse sidebar" : "Expand sidebar")
            .accessibilityIdentifier("gallery-sidebar-toggle")
            .padding(.bottom, 28)

            sectionButton(.albums, symbol: "square.grid.2x2.fill", title: "Albums")
            sectionButton(.photos, symbol: "photo.on.rectangle", title: "Photos")
            sectionButton(.recycleBin, symbol: "trash", title: "Recycle Bin")

            if !vault.isUnlocked {
                Button(action: context.showVault) {
                    railItem(symbol: "lock", title: "Private Vault", selected: false)
                }
                .buttonStyle(.plain)
                .foregroundStyle(CinemaPalette.secondaryText)
                .help("Private Vault")
                .accessibilityLabel("Private Vault")
                .accessibilityIdentifier("gallery-private-vault")
                .hoverEffect(.highlight)
            }

            Spacer(minLength: 12)
            Button(action: context.showSettings) {
                railItem(symbol: "gearshape", title: "Settings", selected: false)
            }
            .buttonStyle(.plain)
            .foregroundStyle(CinemaPalette.secondaryText)
            .help("Settings")
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("gallery-cinema-settings")
            .hoverEffect(.highlight)
        }
        .padding(.horizontal, sidebarExpanded ? 16 : 14)
        .padding(.vertical, 18)
        .frame(width: sidebarExpanded ? 212 : 90)
        .frame(maxHeight: .infinity)
        .background { GalleryLightSurface(role: .raised, cornerRadius: 24).opacity(0.50) }
        .padding(12)
    }

    private func sectionButton(_ section: GalleryLibrarySection, symbol: String, title: String) -> some View {
        let selected = context.manager.librarySection == section || (section == .albums && context.manager.librarySection == .unfiled)
        return Button {
            context.selectSection(section)
        } label: {
            railItem(symbol: symbol, title: title, selected: selected)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? CinemaPalette.primaryText : CinemaPalette.secondaryText)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("gallery-sidebar-\(section.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .hoverEffect(.highlight)
    }

    private func railItem(symbol: String, title: String, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: selected ? .semibold : .regular))
                .frame(width: 28)
            if sidebarExpanded {
                Text(title).font(.body.weight(selected ? .semibold : .regular)).lineLimit(2)
            }
        }
        .padding(.horizontal, sidebarExpanded ? 20 : 0)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: sidebarExpanded ? .leading : .center)
        .background {
            if selected {
                GalleryLightSurface(role: .control, cornerRadius: 15)
            }
        }
        .contentShape([.interaction, .hoverEffect], RoundedRectangle(cornerRadius: 15))
    }

    private func albumLobby(width: CGFloat, showsHeader: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            if showsHeader {
            HStack(alignment: .firstTextBaseline) {
                Text("Albums").font(.system(size: 32, weight: .semibold))
                Spacer()
                collectionCount
            }
            HStack(spacing: 12) {
                GalleryDesignSearchField(query: context.query)
                    .frame(maxWidth: .infinity)
                context.actions
                    .fixedSize(horizontal: true, vertical: false)
            }
            }

            if context.manager.isLoadingAlbums && context.albums.isEmpty {
                loadingState
            } else if context.albums.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top),
                            count: dynamicTypeSize.isAccessibilitySize ? 1 : (width < 1100 ? 2 : 3)),
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(context.albums) { album in
                            albumCard(album)
                        }
                    }
                    .coordinateSpace(name: "gallery-album-grid")
                    .padding(.vertical, 4)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.visible)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var collectionCount: some View {
        Text("\(context.albums.count) collection\(context.albums.count == 1 ? "" : "s")")
            .font(.callout)
            .foregroundStyle(CinemaPalette.secondaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private var albumRoom: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(context.manager.selectedAlbum?.title ?? "Photos").font(.system(size: 32, weight: .semibold))
                Spacer()
                Text("\(context.manager.totalAssetCount) items")
                    .font(.callout).foregroundStyle(CinemaPalette.secondaryText)
            }
            context.albumToolbar
                .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView {
                context.mediaContent
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.bottom, 12)
            }
            .scrollIndicators(.visible)
            .defaultScrollAnchor(initialScrollAnchor, for: .initialOffset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(CinemaPalette.accent)
                .controlSize(.large)
            Text(context.manager.loadingMessage ?? "Finding your collections…")
                .font(.callout)
                .foregroundStyle(CinemaPalette.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(context.manager.loadingMessage ?? "Finding your collections")
    }

    private var emptyState: some View {
        Group {
            if context.query.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                context.emptyContent
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(CinemaPalette.lavender)
                    Text("No matching collections")
                        .font(.title3.weight(.semibold))
                    Text("Try a different album name.")
                        .font(.callout)
                        .foregroundStyle(CinemaPalette.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum CinemaPalette {
    static let background = Color(red: 0.055, green: 0.064, blue: 0.07)
    static let rail = Color(red: 18 / 255, green: 19 / 255, blue: 27 / 255)
    static let railSelected = Color(red: 34 / 255, green: 31 / 255, blue: 39 / 255)
    static let card = Color(red: 24 / 255, green: 25 / 255, blue: 34 / 255)
    static let cardLine = Color.white.opacity(0.12)
    static let divider = Color.white.opacity(0.08)
    static let primaryText = Color(red: 248 / 255, green: 246 / 255, blue: 242 / 255)
    static let secondaryText = Color(red: 0.79, green: 0.81, blue: 0.82)
    static var accent: Color { GalleryAppearance.accent }
    static let lavender = Color(red: 0.76, green: 0.84, blue: 0.86)
}

private extension GalleryCinemaDesign {
    func albumCard(_ album: GalleryAlbum) -> some View {
        let isSelected = context.selectedAlbumIDs.contains(album.id)
        return ZStack(alignment: .topTrailing) {
            Button {
                context.openAlbum(album)
            } label: {
                ZStack(alignment: .bottomLeading) {
                    GeometryReader { geometry in
                        context.cover(album)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                    .aspectRatio(dynamicTypeSize.isAccessibilitySize ? 16.0 / 9.0 : 1, contentMode: .fit)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(album.title)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(album.assetCount == 1 ? "1 item" : "\(album.assetCount) items")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.68))
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Label("Selected", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 11).padding(.vertical, 8)
                            .foregroundStyle(CinemaPalette.background)
                            .background(CinemaPalette.accent, in: Capsule())
                            .padding(12)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(isSelected ? CinemaPalette.accent : Color.white.opacity(0.16), lineWidth: isSelected ? 2 : 0.75)
                }
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .buttonStyle(CinemaAlbumButtonStyle(reduceMotion: reduceMotion))
            .hoverEffect(.lift)
            .contextMenu { GalleryDesignAlbumActions(context: context, album: album) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(album.title), \(album.assetCount) items\(isSelected ? ", selected" : "")")
            .accessibilityHint(context.isSelectingAlbums ? "Toggles this collection's selection." : "Opens this collection.")
            .accessibilityIdentifier("gallery-album-\(album.id)")
            .allowsHitTesting(context.reorderAlbumID != album.id)
            if context.reorderAlbumID == album.id {
                Image(systemName: "line.3.horizontal")
                    .font(.title3.weight(.semibold))
                    .frame(width: 60, height: 60)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                    .hoverEffect(.lift)
                    .padding(22)
                    .offset(reorderTranslation)
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 8, coordinateSpace: .named("gallery-album-grid"))
                            .updating($reorderTranslation) { value, state, _ in state = value.translation }
                            .onEnded { value in
                                defer { context.cancelReordering() }
                                guard let target = context.albums.first(where: {
                                    $0.id != album.id && albumFrames[$0.id]?.contains(value.location) == true
                                }), let frame = albumFrames[target.id] else { return }
                                context.reorderAlbum(album.id, target.id, value.location.y > frame.midY)
                            }
                    )
                    .accessibilityLabel("Drag to reorder \(album.title)")
                    .accessibilityIdentifier("gallery-reorder-handle")
            }
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named("gallery-album-grid"))
        } action: { frame in
            albumFrames[album.id] = frame
        }
        .frame(minHeight: 44)
    }
}

private struct CinemaCanvasBackdrop: ViewModifier {
    let isAlbumLobby: Bool
    let reduceTransparency: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if isAlbumLobby {
            content.galleryOrnamentBackdrop(cornerRadius: 28)
        } else {
            content.background {
                GalleryLightSurface(role: .canvas, cornerRadius: 28).opacity(reduceTransparency ? 1 : 0.92)
            }
        }
    }
}

private struct CinemaAlbumButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
