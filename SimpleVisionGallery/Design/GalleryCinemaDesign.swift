import SwiftUI

/// A calm, dark gallery treatment built around large album artwork and a quiet navigation rail.
struct GalleryCinemaDesign: View {
    let context: GalleryDesignContext

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("gallery.sidebar.expanded") private var sidebarExpanded = true
    @State private var albumFrames: [String: CGRect] = [:]
    @GestureState private var reorderTranslation = CGSize.zero

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                navigationRail
                Rectangle()
                    .fill(CinemaPalette.divider)
                    .frame(width: 1)
                    .padding(.vertical, 24)

                Group {
                    if context.hasOpenAlbum {
                        albumRoom
                    } else {
                        albumLobby
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, geometry.size.width < 900 ? 22 : 36)
                .padding(.vertical, 24)
            }
            .frame(minWidth: 840, minHeight: 620)
            .background(CinemaPalette.background)
            .foregroundStyle(CinemaPalette.primaryText)
        }
        .preferredColorScheme(.dark)
    }

    private var navigationRail: some View {
        VStack(spacing: 12) {
            GalleryHoverIcon(symbol: "line.3.horizontal", title: sidebarExpanded ? "Collapse sidebar" : "Expand sidebar", identifier: "gallery-sidebar-toggle") {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { sidebarExpanded.toggle() }
            }
            .foregroundStyle(CinemaPalette.secondaryText)
            .padding(.bottom, 8)

            sectionButton(.albums, symbol: "square.grid.2x2.fill", title: "Albums")
            sectionButton(.photos, symbol: "photo.on.rectangle", title: "Photos")
            sectionButton(.recycleBin, symbol: "trash", title: "Recycle Bin")

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
        .frame(width: sidebarExpanded ? 180 : 90)
        .frame(maxHeight: .infinity)
        .background(CinemaPalette.rail)
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
                Text(title).font(.callout.weight(selected ? .semibold : .regular)).lineLimit(2)
            }
        }
        .padding(.horizontal, sidebarExpanded ? 20 : 0)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: sidebarExpanded ? .leading : .center)
        .background(selected ? CinemaPalette.railSelected : .clear, in: RoundedRectangle(cornerRadius: 15))
        .overlay(alignment: .leading) {
            if selected {
                Capsule().fill(CinemaPalette.accent).frame(width: 3, height: 22).padding(.leading, 10)
            }
        }
        .contentShape([.interaction, .hoverEffect], RoundedRectangle(cornerRadius: 15))
    }

    private var albumLobby: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                GalleryDesignSearchField(query: context.query)
                    .frame(maxWidth: .infinity)
                context.actions
                    .fixedSize(horizontal: true, vertical: false)
            }
            collectionCount

            if context.manager.isLoadingAlbums && context.albums.isEmpty {
                loadingState
            } else if context.albums.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 400 : 240, maximum: 400), spacing: 22, alignment: .top)],
                        alignment: .leading,
                        spacing: 24
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
        Text("\(context.albums.count) COLLECTION\(context.albums.count == 1 ? "" : "S")")
            .font(.caption.weight(.medium))
            .tracking(1.3)
            .foregroundStyle(CinemaPalette.secondaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private var albumRoom: some View {
        VStack(alignment: .leading, spacing: 18) {
            context.albumToolbar
                .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView {
                context.mediaContent
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.bottom, 12)
            }
            .scrollIndicators(.visible)
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
    static let background = Color(red: 11 / 255, green: 12 / 255, blue: 18 / 255)
    static let rail = Color(red: 18 / 255, green: 19 / 255, blue: 27 / 255)
    static let railSelected = Color(red: 34 / 255, green: 31 / 255, blue: 39 / 255)
    static let card = Color(red: 24 / 255, green: 25 / 255, blue: 34 / 255)
    static let cardLine = Color.white.opacity(0.12)
    static let divider = Color.white.opacity(0.08)
    static let primaryText = Color(red: 248 / 255, green: 246 / 255, blue: 242 / 255)
    static let secondaryText = Color(red: 195 / 255, green: 192 / 255, blue: 204 / 255)
    static var accent: Color { GalleryAppearance.accent }
    static let lavender = Color(red: 205 / 255, green: 190 / 255, blue: 255 / 255)
}

private extension GalleryCinemaDesign {
    func albumCard(_ album: GalleryAlbum) -> some View {
        let isSelected = context.selectedAlbumIDs.contains(album.id)
        return ZStack(alignment: .topTrailing) {
            Button {
                context.openAlbum(album)
            } label: {
                VStack(alignment: .leading, spacing: 11) {
                    ZStack(alignment: .topTrailing) {
                        GeometryReader { geometry in
                            context.cover(album)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .clipped()
                        }
                        .aspectRatio(16 / 10, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))

                        if isSelected {
                            Label("Selected", systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 11)
                                .padding(.vertical, 8)
                                .foregroundStyle(CinemaPalette.background)
                                .background(CinemaPalette.accent, in: Capsule())
                                .padding(12)
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .stroke(isSelected ? CinemaPalette.accent : CinemaPalette.cardLine, lineWidth: isSelected ? 2 : 1)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(album.title)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(CinemaPalette.primaryText)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Text(album.assetCount == 1 ? "1 item" : "\(album.assetCount) items")
                        .font(.caption)
                        .foregroundStyle(CinemaPalette.secondaryText)
                }
                .padding(10)
                .background(CinemaPalette.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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

private struct CinemaAlbumButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .brightness(configuration.isPressed ? 0.06 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
