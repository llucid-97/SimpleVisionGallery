#if os(visionOS)
import SwiftUI
import UIKit

/// An album index that borrows its structure from contact prints and photo sleeves.
/// All Photos access and selection state remain in the injected gallery context.
struct GalleryArchiveDesign: View {
    let context: GalleryDesignContext

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var selectedAlbum: GalleryAlbum? { context.manager.selectedAlbum }

    var body: some View {
        Group {
            if let album = selectedAlbum {
                albumPage(album)
            } else {
                albumIndex
            }
        }
        .background(GalleryArchivePalette.window.ignoresSafeArea())
        .tint(GalleryArchivePalette.blue)
    }

    private var albumIndex: some View {
        VStack(alignment: .leading, spacing: 18) {
            indexHeader
            searchField

            if context.albums.isEmpty {
                context.emptyContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(context.albums) { album in
                            albumRow(album)
                        }
                    }
                    .padding(.top, 2)
                    .padding(.bottom, 20)
                }
                .scrollIndicators(.visible)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gallery-archive-index")
    }

    private var indexHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    indexTitle
                    HStack { Spacer(minLength: 0); context.actions.frame(minHeight: 60) }
                }
            } else {
                HStack(alignment: .center, spacing: 16) {
                    indexTitle
                    Spacer(minLength: 12)
                    context.actions
                        .frame(minHeight: 60, alignment: .trailing)
                }
            }

            Rectangle()
                .fill(GalleryArchivePalette.blue)
                .frame(width: 46, height: 3)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var indexTitle: some View {
        Text("Albums")
            .font(.largeTitle.weight(.semibold))
            .foregroundStyle(GalleryArchivePalette.ink)
            .accessibilityAddTraits(.isHeader)
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.medium))
                .foregroundStyle(GalleryArchivePalette.mutedInk)
                .accessibilityHidden(true)

            TextField(
                "Search albums",
                text: context.query,
                prompt: Text("Search albums").foregroundColor(GalleryArchivePalette.mutedInk)
            )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body)
                .foregroundStyle(GalleryArchivePalette.ink)
                .accessibilityLabel("Search albums")
                .accessibilityIdentifier("gallery-archive-search")

            if !context.query.wrappedValue.isEmpty {
                Button {
                    context.query.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(GalleryArchivePalette.mutedInk)
                        .frame(width: 60, height: 60)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 6)
        .frame(minHeight: 68)
        .background(GalleryArchivePalette.sheet, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func albumRow(_ album: GalleryAlbum) -> some View {
        let isSelected = context.selectedAlbumIDs.contains(album.id)

        return Button {
            context.openAlbum(album)
        } label: {
            HStack(alignment: .center, spacing: 16) {
                contactPrint(album)

                VStack(alignment: .leading, spacing: 7) {
                    Text(album.title)
                        .font(.headline)
                        .foregroundStyle(GalleryArchivePalette.ink)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("\(album.assetCount) item\(album.assetCount == 1 ? "" : "s")")
                        .font(.body)
                        .foregroundStyle(GalleryArchivePalette.mutedInk)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if context.isSelectingAlbums {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isSelected ? GalleryArchivePalette.blue : GalleryArchivePalette.mutedInk)
                        .frame(width: 60, height: 60)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(GalleryArchivePalette.mutedInk)
                        .frame(width: 60, height: 60)
                        .accessibilityHidden(true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 124, alignment: .leading)
            .background(GalleryArchivePalette.sheet, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isSelected ? GalleryArchivePalette.blue : GalleryArchivePalette.rule,
                                  lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel("\(album.title), \(album.assetCount) item\(album.assetCount == 1 ? "" : "s")")
        .accessibilityValue(context.isSelectingAlbums ? (isSelected ? "Selected" : "Not selected") : "")
        .accessibilityHint(context.isSelectingAlbums ? "Select this album" : "Open this album")
        .accessibilityIdentifier("gallery-archive-album-\(album.id)")
        .contextMenu {
            GalleryDesignAlbumActions(context: context, album: album)
        }
    }

    private func contactPrint(_ album: GalleryAlbum) -> some View {
        VStack(spacing: 5) {
            context.cover(album)
                .frame(width: 78, height: 78)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

            HStack(spacing: 4) {
                Capsule().fill(GalleryArchivePalette.blue).frame(width: 24, height: 2)
                Rectangle().fill(GalleryArchivePalette.rule).frame(width: 18, height: 2)
            }
            .accessibilityHidden(true)
        }
        .padding(6)
        .background(GalleryArchivePalette.window, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(GalleryArchivePalette.rule, lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private func albumPage(_ album: GalleryAlbum) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            context.albumToolbar
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)

            ScrollView {
                context.mediaContent
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 20)
            }
            .scrollIndicators(.visible)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("gallery-archive-album")
    }

    private var columns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible(), spacing: 14)]
        }
        return [GridItem(.adaptive(minimum: 330, maximum: 480), spacing: 14)]
    }

}

private enum GalleryArchivePalette {
    static let window = adaptive(light: 0xF3F7FA, dark: 0x131B22)
    static let sheet = adaptive(light: 0xFFFFFF, dark: 0x202A33)
    static let ink = adaptive(light: 0x17212B, dark: 0xF4F7FA)
    static let mutedInk = adaptive(light: 0x4B5B68, dark: 0xB7C4CF)
    static let rule = adaptive(light: 0xCBD7E1, dark: 0x3E4C58)
    static let blue = adaptive(light: 0x15577D, dark: 0x82C6EC)

    private static func adaptive(light: UInt, dark: UInt) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}
#endif
