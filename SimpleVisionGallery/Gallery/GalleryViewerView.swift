#if os(visionOS)
import AVKit
@preconcurrency import Photos
import RealityKit
import SwiftUI
import UIKit

struct GalleryViewerWindowRoot: View {
    let value: GalleryViewerWindowValue?
    @ObservedObject private var store = GalleryViewerStore.shared
    @ObservedObject private var windows = GalleryViewerWindows.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.pushWindow) private var pushWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var moveTarget: GalleryViewerMoveTarget?

    private var paired: Bool { value?.sessionIDs.count == 2 }
    private var paneWidth: CGFloat { paired ? 500 : 700 }
    private var minimumMediaHeight: CGFloat { paired ? 450 : 540 }
    private var windowWidth: CGFloat { paired ? 1048 : 732 }

    private var preferredWindowHeight: CGFloat {
        let mediaHeight = value?.sessionIDs.compactMap { store.session($0)?.currentAsset }
            .map { asset -> CGFloat in
                guard asset.pixelWidth > 0, asset.pixelHeight > 0 else { return minimumMediaHeight }
                // Spatial videos also need room for their transport controls.
                let transport: CGFloat = asset.mediaType == .video ? 160 : 0
                return max(minimumMediaHeight, paneWidth * CGFloat(asset.pixelHeight) / CGFloat(asset.pixelWidth) + transport)
            }.max() ?? minimumMediaHeight
        return min(mediaHeight + 300, 1800)
    }

    var body: some View {
        Group {
            if let value {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(value.sessionIDs, id: \.self) { sessionID in
                        if let session = store.session(sessionID) {
                            GalleryViewerPane(
                                session: session,
                                moveTarget: $moveTarget,
                                width: paneWidth,
                                minimumMediaHeight: minimumMediaHeight,
                                backingYaw: value.sessionIDs.count == 2
                                    ? (sessionID == value.sessionIDs.first ? 10 : -10) : 0,
                                ornamentAnchor: value.sessionIDs.count == 2
                                    ? UnitPoint3D(x: sessionID == value.sessionIDs.first ? 0.25 : 0.75, y: 1, z: 0.5)
                                    : .bottom,
                                canArrange: windows.canArrange(value),
                                arrange: {
                                    if let pair = windows.arrange(value) {
                                        // Inherit this visible window's center; new-window placement
                                        // otherwise offsets a wide pair past the existing slideshows.
                                        pushWindow(id: GalleryViewerWindows.pairSceneID, value: pair)
                                    }
                                },
                                duplicate: {
                                    // New session retains the same album order with its own cursor.
                                    if let copy = store.duplicateSession(sessionID) {
                                        let window = windows.makeWindow(sessionIDs: [copy])
                                        openWindow(id: GalleryViewerWindows.sceneID, value: window)
                                    }
                                }
                            )
                        } else {
                            unavailableView
                                .frame(width: 500, height: 450)
                        }
                    }
                }
                .padding(16)
                // A fixed horizontal range keeps arranged slideshows aligned;
                // height remains resizable for portrait photos and videos.
                .frame(minWidth: windowWidth, idealWidth: windowWidth, maxWidth: windowWidth,
                    minHeight: minimumMediaHeight + 300, idealHeight: preferredWindowHeight, maxHeight: 1800,
                    alignment: .top)
                .background(GalleryViewerSceneAnchor(
                    initialSize: CGSize(width: windowWidth, height: preferredWindowHeight),
                    minimumSize: CGSize(width: windowWidth, height: minimumMediaHeight + 300),
                    maximumSize: CGSize(width: windowWidth, height: 1800)
                ) { scene in windows.attach(value, to: scene) })
                .onAppear {
                    guard value.sessionIDs.contains(where: { store.session($0) != nil }) else {
                        dismissWindow(id: GalleryViewerWindows.sceneID(for: value), value: value)
                        windows.closed(value)
                        return
                    }
                    windows.register(value)
                    for old in windows.takeReplacements(for: value) {
                        dismissWindow(id: GalleryViewerWindows.sceneID(for: old), value: old)
                        windows.closed(old)
                    }
                }
            } else {
                unavailableView.frame(width: 500, height: 450)
            }
        }
        .sheet(item: $moveTarget) { target in
            GalleryViewerMoveSheet(sessionID: target.sessionID, assetID: target.assetID)
        }
        .persistentSystemOverlays(.visible)
    }

    private var unavailableView: some View {
        ContentUnavailableView("Open an album to start", systemImage: "photo.on.rectangle.angled",
            description: Text("This slideshow is no longer open. Choose a photo or video in Gallery."))
    }
}

private struct GalleryViewerSceneAnchor: UIViewRepresentable {
    let initialSize: CGSize
    let minimumSize: CGSize
    let maximumSize: CGSize
    let attach: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> AnchorView { AnchorView() }

    func updateUIView(_ view: AnchorView, context: Context) {
        view.initialSize = initialSize
        view.minimumSize = minimumSize
        view.maximumSize = maximumSize
        view.attach = attach
        view.attachToScene()
    }

    final class AnchorView: UIView {
        var initialSize = CGSize.zero
        var minimumSize = CGSize.zero
        var maximumSize = CGSize.zero
        var attach: ((UIWindowScene) -> Void)?
        private weak var configuredScene: UIWindowScene?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachToScene()
        }

        func attachToScene() {
            guard let scene = window?.windowScene else { return }
            attach?(scene)
            guard configuredScene !== scene, initialSize.width > 0 else { return }
            configuredScene = scene
            // Configure once: later swipes and layout updates must preserve the
            // height the user chose with the resize handle.
            scene.requestGeometryUpdate(.Vision(size: initialSize,
                minimumSize: minimumSize, maximumSize: maximumSize,
                resizingRestrictions: .freeform)) { [weak self] error in
                // A scene that is still opening can reject an early request.
                // Allow a later attachment update to retry instead of marking
                // that scene as permanently configured.
                self?.configuredScene = nil
                print("Gallery window resize unavailable: \(error.localizedDescription)")
            }
        }
    }
}

private struct GalleryViewerLoadKey: Equatable {
    let assetID: String?
    let modified: Date?
    let spatial: Bool
}

private struct GalleryViewerPane: View {
    @ObservedObject var session: GalleryViewerSession
    @Binding var moveTarget: GalleryViewerMoveTarget?
    let width: CGFloat
    let minimumMediaHeight: CGFloat
    let backingYaw: Double
    let ornamentAnchor: UnitPoint3D
    let canArrange: Bool
    let arrange: () -> Void
    let duplicate: () -> Void
    @ObservedObject private var store = GalleryViewerStore.shared
    @State private var media = GalleryViewerMedia()
    @State private var spatialEnabled = true
    @State private var actionError: String?
    @State private var pendingDelete: GalleryViewerDeleteTarget?
    @State private var isDeletingFromPhotos = false
    @State private var loadedKey: GalleryViewerLoadKey?
    @AppStorage(GalleryViewerPreferences.prefetchWindowKey)
    private var prefetchWindow = GalleryViewerPreferences.defaultPrefetchWindow
    @AppStorage(GalleryViewerPreferences.backwardPrefetchWindowKey)
    private var backwardPrefetchWindow = GalleryViewerPreferences.defaultBackwardPrefetchWindow
    @AppStorage(GalleryViewerPreferences.loopVideosKey) private var loopVideos = false
    @Environment(\.scenePhase) private var scenePhase

    private var loadKey: GalleryViewerLoadKey {
        GalleryViewerLoadKey(assetID: session.currentAsset?.localIdentifier,
            modified: session.currentAsset?.modificationDate, spatial: spatialEnabled)
    }

    private var upcomingAssets: [PHAsset] {
        session.upcomingAssets(limit: GalleryViewerPreferences.boundedPrefetchWindow(prefetchWindow))
    }

    private var precedingAssets: [PHAsset] {
        session.precedingAssets(limit: min(GalleryViewerPreferences.backwardPrefetchWindowRange.upperBound,
            max(GalleryViewerPreferences.backwardPrefetchWindowRange.lowerBound, backwardPrefetchWindow)))
    }

    private var prefetchAssets: [PHAsset] { upcomingAssets + precedingAssets }

    private var prefetchKeys: [GalleryViewerLoadKey] {
        prefetchAssets.map {
            GalleryViewerLoadKey(assetID: $0.localIdentifier, modified: $0.modificationDate, spatial: true)
        }
    }

    private func refreshPrefetch() {
        guard moveTarget == nil else {
            media.pausePrefetch(true)
            return
        }
        guard scenePhase == .active else {
            return
        }
        // Keep a matching in-flight lookahead alive until load promotes it.
        guard loadedKey == loadKey, !media.isLoading else { return }
        media.prefetch(assets: prefetchAssets)
    }

    private var preferredMediaHeight: CGFloat {
        let asset = session.currentAsset
        let assetRatio = asset.flatMap { item -> Double? in
            guard item.pixelWidth > 0, item.pixelHeight > 0 else { return nil }
            return Double(item.pixelWidth) / Double(item.pixelHeight)
        }
        guard let ratio = media.aspectRatio ?? assetRatio, ratio.isFinite, ratio > 0 else { return minimumMediaHeight }
        return min(1500, max(minimumMediaHeight, width / ratio + (media.isSpatialVideo ? 160 : 0)))
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.albumTitle).font(.headline).lineLimit(1)
                    Text(session.count == 0 ? "Album is empty" : "\(session.position) of \(session.count)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: duplicate) {
                    Label("Open another slideshow", systemImage: "rectangle.on.rectangle")
                }
                .labelStyle(.iconOnly)
                .disabled(session.currentAsset == nil)
                .accessibilityIdentifier("gallery-viewer-duplicate")
                Button(action: arrange) {
                    Label("Arrange side by side", systemImage: "rectangle.split.2x1")
                }
                .labelStyle(.iconOnly)
                .disabled(!canArrange)
                .accessibilityIdentifier("gallery-viewer-arrange")
            }
            .padding(.horizontal, 8)

            GeometryReader { geometry in
                mediaStage(height: geometry.size.height)
                    .frame(width: width, height: geometry.size.height)
                    .background {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(.black.opacity(0.85))
                            .rotation3DEffect(.degrees(backingYaw), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .contentShape(Rectangle())
                    .simultaneousGesture(DragGesture(minimumDistance: 45).onEnded { drag in
                        if session.currentAsset?.mediaType == .video && drag.startLocation.y > geometry.size.height - 100 { return }
                        guard abs(drag.translation.width) > abs(drag.translation.height) * 1.4 else { return }
                        actionError = nil
                        if drag.translation.width < 0 { store.next(session.id) }
                        else { store.previous(session.id) }
                    })
                    .accessibilityIdentifier("gallery-viewer-media")
            }
            .frame(minHeight: minimumMediaHeight, idealHeight: preferredMediaHeight, maxHeight: .infinity)
            // Spatial content projects forward from the window. Leave clearance
            // for the header and bottom ornament even at a portrait aspect ratio.
            .padding(.vertical, 96)

            if let actionError {
                Text(actionError).font(.caption).foregroundStyle(.red).lineLimit(2)
            } else if let message = media.status {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .ornament(attachmentAnchor: .scene(ornamentAnchor), contentAlignment: .top) {
            controls.padding(12).glassBackgroundEffect()
        }
        .task(id: loadKey) {
            let requestedKey = loadKey
            loadedKey = nil
            media.prefetch(assets: prefetchAssets, excludingCurrent: session.currentAsset,
                preserving: session.currentAsset)
            if let asset = session.currentAsset {
                await media.load(asset: asset, spatialEnabled: spatialEnabled)
            } else { media.cancel() }
            guard !Task.isCancelled, requestedKey == loadKey else { return }
            loadedKey = requestedKey
            refreshPrefetch()
        }
        .onDisappear {
            loadedKey = nil
            media.cancel()
            if moveTarget?.sessionID == session.id { moveTarget = nil }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            media.setSceneActive(phase == .active && moveTarget == nil)
            refreshPrefetch()
        }
        .onChange(of: loopVideos, initial: true) { _, enabled in
            media.setVideoLooping(enabled)
        }
        .onChange(of: moveTarget?.id) { _, targetID in
            media.pausePrefetch(targetID != nil)
            media.setSceneActive(scenePhase == .active && targetID == nil)
            refreshPrefetch()
        }
        .onChange(of: pendingDelete?.assetID) { _, targetID in
            if targetID == nil, !isDeletingFromPhotos {
                media.setSceneActive(scenePhase == .active && moveTarget == nil)
                media.pausePrefetch(moveTarget != nil)
            }
        }
        .onChange(of: prefetchKeys) { _, _ in refreshPrefetch() }
        .onChange(of: session.currentAsset?.localIdentifier) { _, newID in
            if let target = moveTarget, target.sessionID == session.id,
               target.assetID != newID { moveTarget = nil }
        }
        .alert(item: $pendingDelete) { target in
            Alert(title: Text("Delete permanently from Photos?"),
                message: Text("This item will be removed from the Photos library and cannot be recovered from the Recycle Bin."),
                primaryButton: .destructive(Text("Delete Permanently")) {
                    performPermanentDelete(assetID: target.assetID)
                },
                secondaryButton: .cancel())
        }
    }

    @ViewBuilder
    private func mediaStage(height: CGFloat) -> some View {
        if moveTarget != nil || pendingDelete != nil || isDeletingFromPhotos {
            // A move sheet belongs to the whole window: either raised surface
            // could occlude it. Keep both prepared scenes for dismissal.
            Color.clear
        } else if session.currentAsset == nil {
            ContentUnavailableView("No items left", systemImage: "photo",
                description: Text("Moved items stay in their destination album."))
        } else if media.isLoading {
            ProgressView("\(session.currentAsset?.mediaType == .video ? "Loading video" : "Preparing photo")…")
                .tint(.white).foregroundStyle(.white)
        } else if let player = media.player, media.error == nil {
            if media.isSpatialVideo {
                GallerySpatialVideoView(player: player, initialYawDegrees: Float(backingYaw))
            } else {
                GalleryNativeVideoPlayer(player: player)
            }
        } else if let image = media.fallbackImage {
            Image(uiImage: image).resizable().scaledToFit()
                .frame(width: width, height: height)
        } else if let entity = media.imageEntity {
            GalleryRealityImage(entity: entity, initialYawDegrees: Float(backingYaw))
        } else {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text(media.error ?? "Unable to load this item.")
                    .multilineTextAlignment(.center).font(.callout)
                Button("Retry") {
                    Task {
                        if let asset = session.currentAsset {
                            await media.load(asset: asset, spatialEnabled: spatialEnabled)
                        }
                    }
                }
            }
            .padding(24).foregroundStyle(.white)
        }
    }

    private var controls: some View {
        HStack(spacing: 52) {
            Button {
                actionError = nil
                store.previous(session.id)
            } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .disabled(!session.canGoPrevious)
            .accessibilityIdentifier("gallery-viewer-previous")

            if session.currentAsset?.mediaType == .image {
                Button { spatialEnabled.toggle() } label: {
                    Label(spatialEnabled ? "Show Original" : "Spatial Scene",
                        systemImage: spatialEnabled ? "photo" : "cube")
                }
                .accessibilityIdentifier("gallery-viewer-spatial")
                .accessibilityValue(media.isShowingSpatial ? "Spatial" : "2D")
            }

            if session.currentAsset?.mediaType == .video {
                Button { loopVideos.toggle() } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "repeat")
                            .font(.system(size: 21, weight: .semibold))
                        Text(loopVideos ? "ON" : "OFF")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .frame(width: 52, height: 56)
                    .foregroundStyle(loopVideos ? Color.black : Color.white)
                    .background(loopVideos ? Color.white : Color.black.opacity(0.25),
                        in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.white.opacity(loopVideos ? 1 : 0.45), lineWidth: 1)
                    }
                }
                .accessibilityLabel("Loop video")
                .accessibilityIdentifier("gallery-viewer-loop")
                .accessibilityValue(loopVideos ? "On" : "Off")
                .accessibilityAddTraits(loopVideos ? .isSelected : [])
            }

            Button {
                if let assetID = session.currentAsset?.localIdentifier {
                    actionError = nil
                    // Capture playback intent before dismantling the media surface.
                    media.pausePrefetch(true)
                    media.setSceneActive(false)
                    moveTarget = GalleryViewerMoveTarget(sessionID: session.id, assetID: assetID)
                }
            } label: { Label("Move", systemImage: "arrowshape.turn.up.right") }
            .disabled(session.currentAsset == nil || store.isPerformingOperation)
            .accessibilityIdentifier("gallery-viewer-move")

            Button {
                guard let targetID = session.currentAsset?.localIdentifier else { return }
                actionError = nil
                if isInRecycleBin {
                    media.pausePrefetch(true)
                    media.setSceneActive(false)
                    pendingDelete = GalleryViewerDeleteTarget(assetID: targetID)
                    return
                }
                Task {
                    do { try await store.recycle(session.id, expectedAssetID: targetID) }
                    catch { actionError = error.localizedDescription }
                }
            } label: {
                Label(isInRecycleBin ? "Delete Permanently" : "Move to Recycle Bin",
                    systemImage: isInRecycleBin ? "trash.slash" : "trash")
            }
            .disabled(session.currentAsset == nil || store.isPerformingOperation)
            .accessibilityIdentifier("gallery-viewer-recycle")
            .accessibilityHint(isInRecycleBin ? "Permanently deletes this item from Photos after confirmation." : "Moves this item to the Recycle Bin album.")

            Button {
                actionError = nil
                store.next(session.id)
            } label: {
                Label("Next", systemImage: "chevron.right")
            }
            .disabled(!session.canGoNext)
            .accessibilityIdentifier("gallery-viewer-next")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.large)
        .padding(.top, 18)
    }

    private var isInRecycleBin: Bool {
        GalleryRecycleBin.isRecycleBinTitle(session.albumTitle)
    }

    private func performPermanentDelete(assetID: String) {
        isDeletingFromPhotos = true
        media.pausePrefetch(true)
        media.setSceneActive(false)
        Task {
            do { try await store.recycle(session.id, expectedAssetID: assetID) }
            catch { actionError = error.localizedDescription }
            isDeletingFromPhotos = false
            pendingDelete = nil
            media.setSceneActive(scenePhase == .active && moveTarget == nil)
            media.pausePrefetch(moveTarget != nil)
        }
    }
}

private struct GalleryViewerMoveTarget: Identifiable {
    let sessionID: UUID
    let assetID: String
    var id: String { "\(sessionID.uuidString):\(assetID)" }
}

private struct GalleryViewerDeleteTarget: Identifiable {
    let assetID: String
    var id: String { assetID }
}

private struct GalleryViewerMoveSheet: View {
    let sessionID: UUID
    let assetID: String
    @ObservedObject private var store = GalleryViewerStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var newAlbumName = ""
    @State private var error: String?

    private var destinations: [GalleryAlbum] {
        let recentIDs = Set(query.isEmpty ? recentDestinations.map(\.id) : [])
        return GalleryAlbumSearch.filter(store.albums.filter {
            $0.id != store.session(sessionID)?.albumID
                && $0.collection?.canPerform(.addContent) == true
                && !GalleryRecycleBin.isRecycleBin($0)
                && !recentIDs.contains($0.id)
        }, query: query)
    }

    private var recentDestinations: [GalleryAlbum] {
        GalleryMoveHistory.shared.recentAlbums(from: store.albums,
            excluding: store.session(sessionID)?.albumID)
            .filter { !GalleryRecycleBin.isRecycleBin($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Create an album") {
                    TextField("Album name", text: $newAlbumName)
                    Button("Create and Move") {
                        performMove { try await store.move(sessionID, toNewAlbumNamed: newAlbumName, expectedAssetID: assetID) }
                    }
                    .disabled(newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isPerformingOperation)
                }
                if query.isEmpty, !recentDestinations.isEmpty {
                    Section("Recent destinations") {
                        ForEach(recentDestinations) { album in
                            Button(album.title) {
                                performMove { try await store.move(sessionID, to: album, expectedAssetID: assetID) }
                            }
                            .disabled(store.isPerformingOperation)
                        }
                    }
                }
                Section("Move to album") {
                    ForEach(destinations) { album in
                        Button(album.title) {
                            performMove { try await store.move(sessionID, to: album, expectedAssetID: assetID) }
                        }
                        .disabled(store.isPerformingOperation)
                    }
                }
                Section("Current album") {
                    Button("Remove from Album", systemImage: "minus.circle") {
                        performMove {
                            try await store.removeFromSourceAlbum(sessionID: sessionID, expectedAssetID: assetID)
                        }
                    }
                    .disabled(!canRemoveFromSource || store.isPerformingOperation)
                    .accessibilityIdentifier("gallery-viewer-remove-from-album")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .searchable(text: $query, prompt: "Find an album")
            .navigationTitle("Move Item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .overlay { if store.isPerformingOperation { ProgressView("Moving…").padding(24).glassBackgroundEffect() } }
        }
        .frame(width: 500, height: 550)
        .task { await store.refreshAlbums() }
    }

    private func performMove(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await action(); dismiss() }
            catch let failure { self.error = failure.localizedDescription }
        }
    }

    private var canRemoveFromSource: Bool {
        store.session(sessionID)?.canRemoveFromSourceAlbum == true
    }
}

private struct GalleryNativeVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.videoGravity = .resizeAspect
        controller.showsPlaybackControls = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player?.pause()
        controller.player = nil
    }
}

private struct GalleryRealityImage: View {
    let entity: Entity
    var initialYawDegrees: Float = 0

    var body: some View {
        GeometryReader3D { geometry in
            RealityView { content in
                // Set the inward angle once when this surface is attached.
                // Billboarding would erase the parallax when the viewer moves.
                entity.components.remove(BillboardComponent.self)
                entity.orientation = simd_quatf(angle: initialYawDegrees * .pi / 180, axis: [0, 1, 0])
                content.add(entity)
                fit(content: content, geometry: geometry)
            } update: { content in
                fit(content: content, geometry: geometry)
            }
            .id(entity.id)
        }
        // A surrounding 2D GeometryReader proposes zero depth. Retain the
        // native media volume so its surface stays in front of the backing.
        .frame(depth: 540)
        .onDisappear { entity.removeFromParent() }
    }

    private func fit(content: RealityViewContent, geometry: GeometryProxy3D) {
        guard let screen = entity.observable.components[ImagePresentationComponent.self]?.presentationScreenSize,
            screen.x > 0, screen.y > 0 else { return }
        let bounds = content.convert(geometry.frame(in: .local), from: .local, to: content)
        let scale = min(bounds.extents.x / screen.x, bounds.extents.y / screen.y)
        entity.scale = SIMD3<Float>(scale, scale, 1)
        // Content coordinates avoid applying the pane offset twice and retain
        // the native surface's forward depth above the window backing.
        entity.position = SIMD3<Float>(bounds.center.x, bounds.center.y, 0)
    }
}
#endif
