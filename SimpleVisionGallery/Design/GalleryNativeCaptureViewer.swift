#if DEBUG && os(visionOS)
import ImageIO
import RealityKit
import SwiftUI
import UIKit

/// Read-only mono fixture on the production native renderer and viewer geometry.
/// It bypasses PhotoKit and does not claim to exercise viewer sessions or spatial generation.
struct GalleryNativeCaptureViewer: View {
    let paired: Bool
    var portrait = false
    var lastLight = false
    var showsMoreMenu = false
    @State private var entities: [Entity] = []
    @State private var menuPreviews: [UIImage] = []
    @State private var failure: String?

    private var paneWidth: CGFloat { paired ? 500 : 700 }
    private var mediaHeight: CGFloat { portrait ? paneWidth * 1.5 : (paired ? 450 : 540) }
    private var windowWidth: CGFloat { paired ? 1048 : 732 }
    private var aspectRatio: Double { portrait ? 2.0 / 3.0 : 1200.0 / 850.0 }
    private var verticalClearance: CGFloat { GalleryViewerLayout.clearance(aspectRatio: aspectRatio) }

    private func viewerDetails(index: Int) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(index == 0 ? "Coastal Walk" : "Journeys").font(.title3.weight(.semibold))
                Text("2 of \(GalleryCaptureFixtures.records.count)").font(.subheadline.monospacedDigit()).foregroundStyle(LensLabTheme.mutedInk)
            }
            Spacer()
            Button {} label: {
                GalleryViewerActionLabel(title: "Albums", symbol: "square.grid.2x2")
            }
            .buttonStyle(.plain)
            .galleryHoverLabel("Open albums")
            .accessibilityIdentifier("gallery-viewer-albums")
            Button {} label: { Image(systemName: "ellipsis") }
                .popover(isPresented: .constant(showsMoreMenu)) {
                    VStack(alignment: .leading, spacing: 12) {
                        Button("Shuffle", systemImage: "shuffle") {}
                        Button("Move to Private Vault", systemImage: "lock") {}
                        Button("Private Vault", systemImage: "lock") {}
                        Button("Share", systemImage: "square.and.arrow.up") {}
                    }
                    .labelStyle(.titleAndIcon)
                    .padding(20).galleryLightBackdrop(cornerRadius: 24)
                }
            Button {} label: { GalleryViewerActionLabel(title: "New", symbol: "rectangle.on.rectangle") }
                .buttonStyle(.plain)
            Button {} label: { GalleryViewerActionLabel(title: "Pair", symbol: "rectangle.split.2x1") }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(0..<(paired ? 2 : 1), id: \.self) { index in
                VStack(spacing: 10) {
                    GeometryReader { geometry in
                        Group {
                            if showsMoreMenu {
                                if menuPreviews.indices.contains(index) {
                                    GalleryViewerMenuPreview(image: menuPreviews[index])
                                } else { Color.clear }
                            } else if entities.indices.contains(index) {
                                GalleryRealityImage(entity: entities[index],
                                    initialYawDegrees: paired ? (index == 0 ? 10 : -10) : 0)
                            } else if let failure {
                                Text(failure).foregroundStyle(.red)
                            } else {
                                ProgressView("Preparing photo…")
                            }
                        }
                        .frame(width: paneWidth, height: geometry.size.height)
                        .background {
                            GalleryViewerBacking(aspectRatio: portrait ? 2.0 / 3.0 : 1200.0 / 850.0,
                                yawDegrees: paired ? (index == 0 ? 10 : -10) : 0,
                                showsMatte: !entities.indices.contains(index))
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .padding(.top, verticalClearance)
                    .padding(.bottom, verticalClearance + GalleryViewerLayout.bottomClearance)
                }
                .frame(width: paneWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .ornament(attachmentAnchor: .scene(paired
                    ? UnitPoint3D(x: index == 0 ? 0.25 : 0.75, y: 1, z: 0.5) : .bottom), contentAlignment: .top) {
                    GalleryViewerDock(width: paneWidth) {
                        GalleryViewerControlBar(presentsBackdrop: false) {
                            Button {} label: { Label("Previous", systemImage: "chevron.left") }
                            Button {} label: { GalleryViewerActionLabel(title: "Original", symbol: "photo") }
                            Button {} label: { Label("Move", systemImage: "arrowshape.turn.up.right") }
                            Button {} label: { Label("Recycle", systemImage: "trash") }
                            Button {} label: { Label("Next", systemImage: "chevron.right") }
                        }
                    } details: {
                        viewerDetails(index: index)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: windowWidth, height: mediaHeight + GalleryViewerLayout.chromeHeight(aspectRatio: aspectRatio))
        .foregroundStyle(.white)
        .task {
            guard entities.isEmpty else { return }
            do {
                var loaded: [Entity] = []
                var previews: [UIImage] = []
                for index in 0..<(paired ? 2 : 1) {
                    guard let url = Bundle.main.url(forResource: GalleryCaptureFixtures.filename(index: lastLight ? 5 : (portrait ? 6 : (index == 0 ? 1 : 3))), withExtension: "jpg"),
                          let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                        failure = "Native fixture image is unavailable."
                        return
                    }
                    var component = try await ImagePresentationComponent(imageSource: source)
                    component.desiredViewingMode = .mono
                    let entity = Entity()
                    entity.components.set(component)
                    loaded.append(entity)
                    if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 512
                    ] as CFDictionary) {
                        previews.append(UIImage(cgImage: image))
                    }
                }
                menuPreviews = previews
                entities = loaded
            } catch { failure = error.localizedDescription }
        }
    }
}
#endif
