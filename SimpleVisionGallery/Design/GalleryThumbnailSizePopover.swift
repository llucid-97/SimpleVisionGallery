import SwiftUI

struct GalleryThumbnailSizePopover: View {
    @Binding var thumbnailSize: Double

    var body: some View {
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
        .galleryLightBackdrop(cornerRadius: 24)
    }
}
