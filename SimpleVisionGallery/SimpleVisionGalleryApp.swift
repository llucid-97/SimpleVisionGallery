import SwiftUI

@main
struct SimpleVisionGalleryApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup("Simple Vision Gallery", id: "gallery-main") {
            GalleryView(isPresented: .constant(true))
                .frame(minWidth: 840, minHeight: 620)
        }
        .defaultSize(width: 1320, height: 920)
        .onChange(of: scenePhase) { _, phase in
            // App-level phase covers every window and also cancels an unfinished unlock.
            if phase == .background { GalleryVaultService.shared.lock() }
        }

        WindowGroup("Photo Viewer", id: GalleryViewerWindows.sceneID, for: GalleryViewerWindowValue.self) { value in
            GalleryViewerWindowRoot(value: value.wrappedValue)
        }
        .windowResizability(.contentSize)
        .defaultWindowPlacement { _, context in
            if let existing = context.windows.last(where: { $0.id == GalleryViewerWindows.sceneID }) {
                return WindowPlacement(.trailing(existing))
            }
            return WindowPlacement(nil)
        }

        WindowGroup("Side by Side", id: GalleryViewerWindows.pairSceneID, for: GalleryViewerWindowValue.self) { value in
            GalleryViewerWindowRoot(value: value.wrappedValue)
        }
        .windowResizability(.contentSize)
        .defaultWindowPlacement { _, _ in WindowPlacement(nil) }
    }
}
