import SwiftUI

#if DEBUG
/// Reusable native samples for checking the shared palette and surface hierarchy.
struct GalleryThemeSamples: View {
    @State private var query = ""
    @State private var enabled = true
    @State private var amount = 0.6

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Gallery").font(.system(size: 32, weight: .semibold))
                    Text("Native materials and controls").foregroundStyle(LensLabTheme.mutedInk)
                }
                Spacer()
                Image(systemName: "square.stack.3d.up").font(.system(size: 38, weight: .light))
                    .foregroundStyle(GalleryAppearance.accent)
            }
            GalleryDesignSearchField(query: $query)
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Viewing room").font(.title2.weight(.semibold))
                    Text("A warm key meets a cool fill. Photos and text keep their own colors.")
                        .foregroundStyle(LensLabTheme.mutedInk)
                    Toggle("Prepare spatial scenes", isOn: $enabled)
                    Slider(value: $amount) { Text("Thumbnail size") }
                    HStack {
                        Button("Cancel") {}.buttonStyle(LensLabSecondaryButtonStyle())
                        Button("Open album") {}.buttonStyle(LensLabPrimaryButtonStyle())
                    }
                }
                .padding(26).galleryLightSurface(cornerRadius: 24)
                VStack(alignment: .leading, spacing: 18) {
                    Label("Album actions", systemImage: "ellipsis").font(.headline)
                    Label("Rename Album", systemImage: "pencil")
                    Divider()
                    Label("Hide Album from List", systemImage: "eye.slash")
                    Label("Move to Private Vault", systemImage: "lock")
                }
                .padding(26).galleryLightBackdrop(cornerRadius: 24)
            }
            Spacer(minLength: 0)
        }
        .padding(40)
        .foregroundStyle(.white)
        .background { GalleryLightSurface(role: .canvas, cornerRadius: 28) }
        .preferredColorScheme(.dark)
        .tint(GalleryAppearance.accent)
    }
}
#endif
