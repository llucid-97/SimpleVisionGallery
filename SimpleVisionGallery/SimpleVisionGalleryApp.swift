import SwiftUI

@main
struct SimpleVisionGalleryApp: App {
    var body: some Scene {
        WindowGroup("Simple Vision Gallery", id: GalleryMainWindow.sceneID, for: String.self) { _ in
            galleryContent
        } defaultValue: {
            GalleryMainWindow.value
        }
        #if DEBUG
        .windowResizability(CaptureSurfaceArgument.value?.hasPrefix("native-viewer") == true ? .contentSize : .automatic)
        #endif
        .defaultSize(width: 1320, height: 920)

        #if DEBUG
        WindowGroup("Native Viewer Fixture", id: "gallery-native-fixture") {
            if let capture = CaptureSurfaceArgument.value {
                if CaptureSurfaceArgument.usesNativeViewer(capture) {
                    GalleryNativeCaptureViewer(paired: capture.contains("-pair"),
                        portrait: capture.contains("-portrait"), lastLight: capture.contains("-last-light"),
                        showsMoreMenu: capture.contains("more-menu"))
                        .environment(\.galleryLightReduceTransparency, capture.contains("-reduced-transparency"))
                        .environment(\.galleryLightReduceMotion, capture.contains("-reduced-motion"))
                } else if capture != "close-gallery-windows" {
                    GalleryCaptureMainSceneRecovery()
                }
            }
        }
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .defaultWindowPlacement { _, _ in WindowPlacement(nil) }
        #endif


        WindowGroup("Photo Viewer", id: GalleryViewerWindows.sceneID, for: GalleryViewerWindowValue.self) { value in
            #if DEBUG
            if CaptureSurfaceArgument.value == nil {
                GalleryViewerWindowRoot(value: value.wrappedValue)
            }
            #else
            GalleryViewerWindowRoot(value: value.wrappedValue)
            #endif
        }
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .defaultWindowPlacement { _, context in
            if let existing = context.windows.last(where: { $0.id == GalleryViewerWindows.sceneID }) {
                return WindowPlacement(.trailing(existing))
            }
            return WindowPlacement(nil)
        }

        WindowGroup("Side by Side", id: GalleryViewerWindows.pairSceneID, for: GalleryViewerWindowValue.self) { value in
            #if DEBUG
            if CaptureSurfaceArgument.value == nil {
                GalleryViewerWindowRoot(value: value.wrappedValue)
            }
            #else
            GalleryViewerWindowRoot(value: value.wrappedValue)
            #endif
        }
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .defaultWindowPlacement { _, _ in WindowPlacement(nil) }
    }

    @ViewBuilder private var galleryContent: some View {
        #if DEBUG
        if let capture = CaptureSurfaceArgument.value {
            CaptureSurface(id: capture)
        } else {
            GalleryView(isPresented: .constant(true)).frame(minWidth: 840, minHeight: 620)
        }
        #else
        GalleryView(isPresented: .constant(true)).frame(minWidth: 840, minHeight: 620)
        #endif
    }

}
