import SwiftUI

/// A bright, photo-first presentation for the shared gallery context.
struct GalleryPrismDesign: View {
    let context: GalleryDesignContext

    var body: some View {
        Group {
            if context.hasOpenAlbum {
                albumView
            } else {
                homeView
            }
        }
        .frame(minWidth: 840, minHeight: 620)
        .tint(GalleryPrismPalette.teal)
    }

    private var homeView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                homeHeader

                HStack(spacing: 20) {
                    GalleryDesignSearchField(query: context.query)
                        .frame(maxWidth: 560)

                    Spacer(minLength: 0)

                    if context.manager.isLoadingAlbums {
                        ProgressView("Loading albums")
                            .controlSize(.regular)
                            .fixedSize()
                    }
                }

                albumContent
            }
            .frame(maxWidth: 1_240, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.hidden)
    }

    private var homeHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 24) {
                headerTitle
                Spacer(minLength: 16)
                context.actions
            }

            VStack(alignment: .leading, spacing: 18) {
                headerTitle
                context.actions
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Albums")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(.primary)

            Text(selectionSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var selectionSummary: String {
        if context.isSelectingAlbums {
            return "\(context.selectedAlbumIDs.count) selected"
        }
        let count = context.albums.count
        return "\(count) album\(count == 1 ? "" : "s")"
    }

    @ViewBuilder
    private var albumContent: some View {
        if context.albums.isEmpty {
            if context.manager.isLoadingAlbums {
                ContentUnavailableView {
                    ProgressView()
                } description: {
                    Text("Your albums will appear here.")
                }
                .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                context.emptyContent
                    .frame(maxWidth: .infinity, minHeight: 260)
            }
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 260, maximum: 390), spacing: 24, alignment: .top)],
                alignment: .leading,
                spacing: 24
            ) {
                ForEach(context.albums) { album in
                    albumCard(album)
                }
            }
        }
    }

    private func albumCard(_ album: GalleryAlbum) -> some View {
        let isSelected = context.selectedAlbumIDs.contains(album.id)
        let isHidden = context.manager.isAlbumHidden(album)

        return Button {
            context.openAlbum(album)
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                offsetCoverStack(for: album, isSelected: isSelected, isHidden: isHidden)

                VStack(alignment: .leading, spacing: 4) {
                    Text(album.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(itemCountDescription(for: album.assetCount))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(
                        isSelected ? GalleryPrismPalette.teal : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel("\(album.title), \(itemCountDescription(for: album.assetCount))")
        .accessibilityValue(
            context.isSelectingAlbums
                ? (isSelected ? "Selected" : "Not selected")
                : (isHidden ? "Hidden album" : "Album")
        )
        .accessibilityHint("Opens this album")
        .contextMenu {
            GalleryDesignAlbumActions(context: context, album: album)
        }
    }

    private func offsetCoverStack(
        for album: GalleryAlbum,
        isSelected: Bool,
        isHidden: Bool
    ) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.thinMaterial)
                .offset(x: 12, y: 12)

            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)
                .offset(x: 6, y: 6)

            context.cover(album)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.72), lineWidth: 1)
                }
                .accessibilityHidden(true)
        }
        .aspectRatio(4 / 3, contentMode: .fit)
        .padding(.trailing, 12)
        .padding(.bottom, 12)
        .overlay(alignment: .topTrailing) {
            if context.isSelectingAlbums {
                selectionIndicator(isSelected: isSelected)
                    .padding(8)
            }
        }
        .overlay(alignment: .topLeading) {
            if isHidden {
                Label("Hidden", systemImage: "eye.slash")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 36)
                    .background(.regularMaterial, in: Capsule())
                    .padding(12)
            }
        }
    }

    private func selectionIndicator(isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(isSelected ? GalleryPrismPalette.teal : Color.white.opacity(0.88))

            Image(systemName: isSelected ? "checkmark" : "circle")
                .font(.title3.weight(.semibold))
                .foregroundStyle(isSelected ? Color.white : GalleryPrismPalette.teal)
        }
        .frame(width: 60, height: 60)
        .accessibilityHidden(true)
    }

    private var albumView: some View {
        VStack(spacing: 16) {
            context.albumToolbar

            ScrollView {
                context.mediaContent
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
            }
            .scrollIndicators(.hidden)
        }
        .padding(24)
    }

    private func itemCountDescription(for count: Int) -> String {
        "\(count) item\(count == 1 ? "" : "s")"
    }
}

private enum GalleryPrismPalette {
    // Kept for selection state and the view tint, rather than broad decoration.
    static let teal = Color(red: 10 / 255, green: 111 / 255, blue: 103 / 255)
}
