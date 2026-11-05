import SwiftUI

/// Native photos own their forward plane; a second opaque window-plane matte causes parallax fringes.
/// Flat fallbacks and video retain an aspect-fitted or full-viewport matte.
struct GalleryViewerBacking: View {
    var aspectRatio: Double?
    var yawDegrees: Double = 0
    var showsMatte = true

    var body: some View {
        Group {
            if let aspectRatio, aspectRatio.isFinite, aspectRatio > 0 {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.black.opacity(showsMatte ? 0.85 : 0))
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                RoundedRectangle(cornerRadius: 16).fill(.black.opacity(showsMatte ? 0.85 : 0))
            }
        }
        .rotation3DEffect(.degrees(yawDegrees), axis: (x: 0, y: 1, z: 0))
        .accessibilityHidden(true)
    }
}
