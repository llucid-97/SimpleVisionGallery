import SwiftUI

/// A calm, dark gallery treatment built around large album artwork and a quiet navigation rail.
struct GalleryCinemaDesign: View {
    let context: GalleryDesignContext

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let compactRail = geometry.size.width < 1_020 || dynamicTypeSize.isAccessibilitySize

            HStack(spacing: 0) {
                navigationRail(compact: compactRail)
                Rectangle()
                    .fill(CinemaPalette.divider)
                    .frame(width: 1)
                    .padding(.vertical, 24)

                Group {
                    if context.hasOpenAlbum {
                        albumRoom
                    } else {
                        albumLobby(stacked: dynamicTypeSize.isAccessibilitySize || geometry.size.width < 900)
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

    private func navigationRail(compact: Bool) -> some View {
        VStack(spacing: 22) {
            Image(systemName: "viewfinder")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(CinemaPalette.accent)
                .frame(width: 52, height: 52)
                .background(CinemaPalette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 17))
                .accessibilityLabel("Simple Vision Gallery")

            Button {
                context.manager.closeAlbum()
            } label: {
                railItem(symbol: "square.grid.2x2.fill", title: "Albums", selected: !context.hasOpenAlbum, compact: compact)
            }
            .buttonStyle(.plain)
            .hoverEffect(.lift)
            .accessibilityHint(context.hasOpenAlbum ? "Returns to all albums." : "Showing all albums.")

            if context.hasOpenAlbum {
                nowViewingStatus(compact: compact)
            }

            Spacer(minLength: 12)

            Button(action: context.showSettings) {
                if compact {
                    Label("Settings", systemImage: "gearshape")
                        .labelStyle(.iconOnly)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    Label("Settings", systemImage: "gearshape")
                        .labelStyle(.titleAndIcon)
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
            }
            .font(.callout.weight(.medium))
            .buttonStyle(.plain)
            .foregroundStyle(CinemaPalette.secondaryText)
            .accessibilityLabel("Open gallery settings")
            .accessibilityIdentifier("gallery-cinema-settings")
            .frame(minWidth: 60, minHeight: 60)
            .hoverEffect(.lift)
        }
        .padding(.horizontal, compact ? 12 : 18)
        .padding(.vertical, 22)
        .frame(width: compact ? 90 : 120)
        .frame(maxHeight: .infinity)
        .background(CinemaPalette.rail)
    }

    private func railItem(symbol: String, title: String, selected: Bool, compact: Bool) -> some View {
        HStack(spacing: 10) {
            if selected {
                Capsule().fill(CinemaPalette.accent).frame(width: 3, height: 22)
            } else {
                Color.clear.frame(width: 3, height: 22)
            }
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: selected ? .semibold : .regular))
                if !compact {
                    Text(title)
                        .font(.caption.weight(selected ? .semibold : .regular))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(selected ? CinemaPalette.primaryText : CinemaPalette.secondaryText)
            .frame(maxWidth: .infinity, minHeight: 60)
        }
        .padding(.horizontal, 8)
        .background(selected ? CinemaPalette.railSelected : .clear, in: RoundedRectangle(cornerRadius: 15))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func nowViewingStatus(compact: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "play.rectangle")
                .font(.system(size: 18, weight: .regular))
            if !compact {
                Text("Now Viewing")
                    .font(.caption)
                    .lineLimit(1)
                Text(context.manager.selectedAlbum?.title ?? "Album")
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(CinemaPalette.secondaryText.opacity(0.76))
            }
        }
        .foregroundStyle(CinemaPalette.secondaryText.opacity(0.82))
        .frame(maxWidth: .infinity, minHeight: 60)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Now viewing \(context.manager.selectedAlbum?.title ?? "album")")
    }

    private func albumLobby(stacked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            let heading = VStack(alignment: .leading, spacing: 5) {
                Text("THE GALLERY")
                    .font(.caption.weight(.semibold))
                    .tracking(2.4)
                    .foregroundStyle(CinemaPalette.lavender)
                Text("Choose a collection")
                    .font(.largeTitle.weight(.semibold))
                    .minimumScaleFactor(0.75)
                    .lineLimit(2)
                Text(context.isSelectingAlbums
                     ? "Selection mode · \(context.selectedAlbumIDs.count) selected"
                     : "Your media, gathered in one place")
                    .font(.callout)
                    .foregroundStyle(CinemaPalette.secondaryText)
            }
            if stacked {
                VStack(alignment: .leading, spacing: 14) {
                    heading
                    context.actions
                }
            } else {
                HStack(alignment: .center, spacing: 20) {
                    heading
                    Spacer(minLength: 8)
                    context.actions
                }
            }

            if stacked {
                VStack(alignment: .leading, spacing: 12) {
                    GalleryDesignSearchField(query: context.query)
                    collectionCount
                }
            } else {
                HStack(spacing: 18) {
                    GalleryDesignSearchField(query: context.query)
                        .frame(maxWidth: 420)
                    Spacer(minLength: 0)
                    collectionCount
                }
            }

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

    /*
     The gallery controls above remain visible at accessibility text sizes; large text changes
     the header/toolbar rows to vertical stacks instead of shrinking labels to fit.
     */
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
        return Button {
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
