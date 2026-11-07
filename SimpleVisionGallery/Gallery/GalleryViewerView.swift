import CryptoKit

#if os(visionOS)
import AVKit
import OSLog
@preconcurrency import Photos
import RealityKit
import SwiftUI
import UIKit

enum GalleryViewerLayout {
    static let outerInsets: CGFloat = 32
    static let maximumMediaHeight: CGFloat = 1500
    // Keep the lower window edge and dock clear of forward-projected spatial media.
    static let bottomClearance: CGFloat = 64
    static let maximumWindowHeight: CGFloat = maximumMediaHeight + 2 * 160 + outerInsets + bottomClearance

    static func clearance(aspectRatio: Double?, isVideo: Bool = false) -> CGFloat {
        // Portraits and uncertain/video surfaces keep room for forward projection and transport.
        guard !isVideo, let aspectRatio, aspectRatio.isFinite, aspectRatio >= 1 else { return 160 }
        return 64
    }

    static func chromeHeight(aspectRatio: Double?, isVideo: Bool = false) -> CGFloat {
        2 * clearance(aspectRatio: aspectRatio, isVideo: isVideo) + outerInsets + bottomClearance
    }
}

/// The current pane owns one preview; changing media or cancelling drops the old image and identity.
struct GalleryMenuPreviewState<Image> {
    private(set) var image: Image?
    private(set) var itemKey: String?

    mutating func set(_ image: Image?, for key: String) {
        self.image = image
        itemKey = image == nil ? nil : key
    }

    mutating func clear() {
        image = nil
        itemKey = nil
    }
}

enum GalleryMorePreviewPolicy {
    static func canShow(sessionID: UUID, moreSessionID: UUID?, previewItemKey: String?,
        currentItemKey: String?, privacyCovered: Bool) -> Bool {
        guard !privacyCovered, moreSessionID == sessionID,
              let currentItemKey, let previewItemKey else { return false }
        return previewItemKey == currentItemKey
    }
}

struct GalleryViewerMenuPreview: View {
    let image: UIImage
    var body: some View {
        Image(uiImage: image).resizable().scaledToFit()
            .blur(radius: 10).brightness(-0.16)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct GalleryViewerWindowRoot: View {
    let value: GalleryViewerWindowValue?
    @ObservedObject private var store = GalleryViewerStore.shared
    @ObservedObject private var windows = GalleryViewerWindows.shared
    @ObservedObject private var vault = GalleryVaultService.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.pushWindow) private var pushWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var moreSessionID: UUID?
    @State private var morePopoverCovered = false
    @State private var moveTarget: GalleryViewerMoveTarget?
    @State private var pendingVaultMove: GalleryVaultTransferRequest?
    @State private var vaultTransfer: GalleryVaultTransferRequest?
    @State private var showingVault = false
    @State private var vaultSheetCovered = false
    @State private var vaultMessage: String?
    @State private var vaultAlbumRetryIDs: [UUID] = []

    private var privacyCovered: Bool {
        vault.isReviewingAlbumDeletion || vaultTransfer != nil || showingVault || vaultSheetCovered || pendingVaultMove != nil
    }
    private var paired: Bool { value?.sessionIDs.count == 2 }
    private var paneWidth: CGFloat { paired ? 500 : 700 }
    private var minimumMediaHeight: CGFloat { paired ? 450 : 540 }
    private var windowWidth: CGFloat { paired ? 1048 : 732 }

    private var currentItems: [GalleryMediaItem] {
        value?.sessionIDs.compactMap { store.session($0)?.currentItem } ?? []
    }

    private func itemAspect(_ item: GalleryMediaItem) -> Double? {
        guard item.pixelWidth > 0, item.pixelHeight > 0 else { return nil }
        return Double(item.pixelWidth) / Double(item.pixelHeight)
    }

    private var minimumWindowHeight: CGFloat {
        let chrome = currentItems.map {
            GalleryViewerLayout.chromeHeight(aspectRatio: itemAspect($0), isVideo: $0.mediaType == .video)
        }.max() ?? GalleryViewerLayout.chromeHeight(aspectRatio: nil)
        return minimumMediaHeight + chrome
    }

    private var preferredWindowHeight: CGFloat {
        let height = currentItems.map { item -> CGFloat in
            let ratio = itemAspect(item)
            let transport: CGFloat = item.mediaType == .video ? 160 : 0
            let mediaHeight = max(minimumMediaHeight, ratio.map { paneWidth / $0 + transport } ?? minimumMediaHeight)
            return mediaHeight + GalleryViewerLayout.chromeHeight(aspectRatio: ratio, isVideo: item.mediaType == .video)
        }.max() ?? minimumWindowHeight
        return min(height, GalleryViewerLayout.maximumWindowHeight)
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
                                moreSessionID: $moreSessionID,
                                morePopoverCovered: $morePopoverCovered,
                                vaultTransfer: $vaultTransfer,
                                showingVault: $showingVault,
                                vaultMessage: $vaultMessage,
                                vaultAlbumRetryIDs: $vaultAlbumRetryIDs,
                                vaultCovered: privacyCovered || moreSessionID != nil || morePopoverCovered,
                                privacyCovered: privacyCovered,
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
                    minHeight: minimumWindowHeight,
                    idealHeight: preferredWindowHeight, maxHeight: GalleryViewerLayout.maximumWindowHeight,
                    alignment: .top)
                .background(GalleryViewerSceneAnchor(
                    initialSize: CGSize(width: windowWidth, height: preferredWindowHeight),
                    minimumSize: CGSize(width: windowWidth, height: minimumWindowHeight),
                    maximumSize: CGSize(width: windowWidth, height: GalleryViewerLayout.maximumWindowHeight)
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
        .sheet(item: $moveTarget, onDismiss: {
            if let pending = pendingVaultMove, vault.isUnlocked { vaultTransfer = pending }
            pendingVaultMove = nil
        }) { target in
            GalleryViewerMoveSheet(sessionID: target.sessionID, assetID: target.assetID,
                vaultRecordID: target.vaultRecordID, sourceAlbumID: target.sourceAlbumID) { request in
                pendingVaultMove = request
            }
        }
        .onChange(of: vault.isUnlocked) { _, unlocked in
            if !unlocked { pendingVaultMove = nil; vaultTransfer = nil }
        }
        .sheet(isPresented: $showingVault, onDismiss: { vaultSheetCovered = false }) {
            GalleryVaultView(resultMessage: $vaultMessage, albumRetryIDs: $vaultAlbumRetryIDs)
        }
        .onChange(of: showingVault) { _, showing in
            if showing { vaultSheetCovered = true }
        }
        .modifier(GalleryVaultConfirmation(request: $vaultTransfer, showingVault: $showingVault, resultMessage: $vaultMessage))
        .onReceive(NotificationCenter.default.publisher(for: .galleryViewerAlbumDeleted)) { notification in
            guard let value, let ids = notification.userInfo?["sessionIDs"] as? Set<UUID>,
                  value.sessionIDs.allSatisfy({ ids.contains($0) || store.session($0) == nil }) else { return }
            dismissWindow(id: GalleryViewerWindows.sceneID(for: value), value: value)
            windows.closed(value)
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
                let error = error as NSError
                Logger(subsystem: "com.llucid.simplevisiongallery", category: "Gallery")
                    .error("Gallery window resize unavailable: domain=\(GalleryLogRedaction.token(error.domain), privacy: .private) code=\(error.code, privacy: .public)")
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
    @Binding var moreSessionID: UUID?
    @Binding var morePopoverCovered: Bool
    @Binding var vaultTransfer: GalleryVaultTransferRequest?
    @Binding var showingVault: Bool
    @Binding var vaultMessage: String?
    @Binding var vaultAlbumRetryIDs: [UUID]
    let vaultCovered: Bool
    let privacyCovered: Bool
    let width: CGFloat
    let minimumMediaHeight: CGFloat
    let backingYaw: Double
    let ornamentAnchor: UnitPoint3D
    let canArrange: Bool
    let arrange: () -> Void
    let duplicate: () -> Void
    @ObservedObject private var store = GalleryViewerStore.shared
    @ObservedObject private var vault = GalleryVaultService.shared
    @ObservedObject private var deleteQueue = GalleryDeleteQueue.shared
    @State private var media = GalleryViewerMedia()
    @State private var spatialEnabled = true
    @State private var actionError: String?
    @StateObject private var sharing = GalleryShareController()
    @State private var pendingDelete: GalleryViewerDeleteTarget?
    @State private var loadedKey: GalleryViewerLoadKey?
    @AppStorage(GalleryViewerPreferences.prefetchWindowKey)
    private var prefetchWindow = GalleryViewerPreferences.defaultPrefetchWindow
    @AppStorage(GalleryViewerPreferences.backwardPrefetchWindowKey)
    private var backwardPrefetchWindow = GalleryViewerPreferences.defaultBackwardPrefetchWindow
    @AppStorage(GalleryViewerPreferences.loopVideosKey) private var loopVideos = false
    @Environment(\.scenePhase) private var scenePhase

    private var loadKey: GalleryViewerLoadKey {
        GalleryViewerLoadKey(assetID: session.currentItem?.localIdentifier,
            modified: session.currentItem?.modificationDate, spatial: spatialEnabled)
    }

    private var upcomingAssets: [GalleryMediaItem] {
        session.upcomingItems(limit: GalleryViewerPreferences.boundedPrefetchWindow(prefetchWindow))
    }

    private var precedingAssets: [GalleryMediaItem] {
        session.precedingItems(limit: min(GalleryViewerPreferences.backwardPrefetchWindowRange.upperBound,
            max(GalleryViewerPreferences.backwardPrefetchWindowRange.lowerBound, backwardPrefetchWindow)))
    }

    private var prefetchAssets: [GalleryMediaItem] { upcomingAssets + precedingAssets }

    private var prefetchKeys: [GalleryViewerLoadKey] {
        prefetchAssets.map {
            GalleryViewerLoadKey(assetID: $0.localIdentifier, modified: $0.modificationDate, spatial: true)
        }
    }

    private func refreshPrefetch() {
        guard scenePhase == .active else {
            return
        }
        // Keep a matching in-flight lookahead alive until load promotes it.
        guard loadedKey == loadKey, !media.isLoading else { return }
        media.prefetch(items: prefetchAssets)
    }

    private var mediaAspectRatio: Double? {
        let assetRatio = session.currentItem.flatMap { item -> Double? in
            guard item.pixelWidth > 0, item.pixelHeight > 0 else { return nil }
            return Double(item.pixelWidth) / Double(item.pixelHeight)
        }
        return media.aspectRatio ?? assetRatio
    }

    private var verticalClearance: CGFloat {
        GalleryViewerLayout.clearance(aspectRatio: mediaAspectRatio, isVideo: session.currentItem?.mediaType == .video)
    }

    private var preferredMediaHeight: CGFloat {
        guard let ratio = mediaAspectRatio, ratio.isFinite, ratio > 0 else { return minimumMediaHeight }
        return min(GalleryViewerLayout.maximumMediaHeight,
            max(minimumMediaHeight, width / ratio + (media.isSpatialVideo ? 160 : 0)))
    }

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geometry in
                mediaStage(height: geometry.size.height)
                    .frame(width: width, height: geometry.size.height)
                    .background {
                        GalleryViewerBacking(aspectRatio: media.player == nil ? media.aspectRatio : nil,
                            yawDegrees: backingYaw, showsMatte: media.imageEntity == nil)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .contentShape(Rectangle())
                    .simultaneousGesture(DragGesture(minimumDistance: 45).onEnded { drag in
                        if session.currentItem?.mediaType == .video && drag.startLocation.y > geometry.size.height - 100 { return }
                        guard abs(drag.translation.width) > abs(drag.translation.height) * 1.4 else { return }
                        actionError = nil
                        if drag.translation.width < 0 { store.next(session.id) }
                        else { store.previous(session.id) }
                    })
                    .accessibilityIdentifier("gallery-viewer-media")
            }
            .frame(minHeight: minimumMediaHeight, idealHeight: preferredMediaHeight, maxHeight: .infinity)
            // The matching window budget preserves media size while keeping projection clearance.
            .padding(.top, verticalClearance)
            .padding(.bottom, verticalClearance + GalleryViewerLayout.bottomClearance)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .gallerySharing(sharing)
        .ornament(attachmentAnchor: .scene(ornamentAnchor), contentAlignment: .top) {
            GalleryViewerDock(width: width) {
                controls
            } details: {
                VStack(alignment: .leading, spacing: 4) {
                    viewerDetails
                    if deleteQueue.pendingCount > 0 {
                        Text("\(deleteQueue.pendingCount) pending")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("gallery-viewer-delete-pending-count")
                    }
                    if deleteQueue.photosUnresponsive || store.pendingPhotosSessionID == session.id {
                        Text("Photos hasn’t responded yet. The operation remains pending.")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("gallery-viewer-photos-pending")
                    }
                    if let actionError {
                        Text(actionError).font(.caption).foregroundStyle(.red).lineLimit(2)
                    } else if let errorMessage = deleteQueue.errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.red).lineLimit(2)
                    } else if let message = media.status {
                        Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
        .task(id: loadKey) {
            let requestedKey = loadKey
            loadedKey = nil
            media.prefetch(items: prefetchAssets, excludingCurrent: session.currentItem,
                preserving: session.currentItem)
            if let item = session.currentItem {
                await media.load(item: item, spatialEnabled: spatialEnabled)
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
            media.setSceneActive(phase == .active)
            refreshPrefetch()
        }
        .onChange(of: loopVideos, initial: true) { _, enabled in
            media.setVideoLooping(enabled)
        }
        .onChange(of: moveTarget != nil || pendingDelete != nil || vaultCovered, initial: true) { _, covered in
            media.setPresentationCovered(covered)
        }
        .onChange(of: vault.isUnlocked) { _, unlocked in
            if !unlocked {
                if moveTarget?.vaultRecordID != nil { moveTarget = nil }
                if let target = pendingDelete, case .vault = target.item { pendingDelete = nil }
                sharing.tearDown()
                vaultMessage = nil
                vaultAlbumRetryIDs = []
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .galleryPhotosAccessDidRevoke)) { _ in
            sharing.tearDown()
        }
        .onChange(of: prefetchKeys) { _, _ in refreshPrefetch() }
        .onChange(of: session.currentItem?.localIdentifier) { _, newID in
            if let target = moveTarget, target.sessionID == session.id,
               target.assetID != newID { moveTarget = nil }
        }
        .alert(item: $pendingDelete) { target in
            switch target.item {
            case let .photos(asset):
                return Alert(title: Text("Delete permanently from Photos?"),
                    message: Text("This item will be removed from the Photos library and cannot be recovered from the Recycle Bin."),
                    primaryButton: .destructive(Text("Delete Permanently")) {
                        deleteQueue.enqueuePermanentPhotosDelete(asset: asset,
                            sourceAlbumID: target.sourceAlbumID, sessionID: target.sessionID)
                        pendingDelete = nil
                    },
                    secondaryButton: .cancel())
            case let .vault(recordID):
                return Alert(title: Text("Delete permanently from Private Vault Recycle Bin?"),
                    message: Text("This item will be permanently deleted and cannot be undone."),
                    primaryButton: .destructive(Text("Delete Permanently")) {
                        deleteQueue.enqueuePermanentVaultDelete(recordID: recordID, sessionID: target.sessionID)
                        pendingDelete = nil
                    },
                    secondaryButton: .cancel())
            }
        }
    }

    private var viewerDetails: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.albumTitle).font(.title3.weight(.semibold)).lineLimit(1)
                Text(session.count == 0 ? "Album is empty" : "\(session.position) of \(session.count)")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(LensLabTheme.mutedInk)
            }
            Spacer()
            GalleryVaultSessionButton()
            Button {
                // Raised native media can cover even an ordinary SwiftUI menu.
                media.setPresentationCovered(true)
                morePopoverCovered = true
                moreSessionID = session.id
            } label: {
                Label("More slideshow actions", systemImage: "ellipsis")
            }
            .labelStyle(.iconOnly)
            .galleryHoverLabel("More")
            .accessibilityIdentifier("gallery-viewer-more")
            .popover(isPresented: Binding(
                get: { moreSessionID == session.id },
                set: { if !$0 { moreSessionID = nil } }
            )) {
                VStack(alignment: .leading, spacing: 12) {
                    Button("Shuffle", systemImage: "shuffle") {
                        store.shuffle(session.id)
                        moreSessionID = nil
                    }
                    .disabled(session.count < 2)
                    if let asset = session.currentAsset {
                        Button("Move to Private Vault", systemImage: "lock") {
                            guard !store.isPerformingOperation, !vault.isBusy else { return }
                            moreSessionID = nil
                            vaultTransfer = .items([asset])
                        }
                        .disabled(store.isPerformingOperation || vault.isBusy)
                    }
                    if let record = session.currentItem?.vaultRecord {
                        if GalleryVaultRecycleBin.contains(record) {
                            Button("Put Back", systemImage: "arrow.uturn.backward") {
                                moreSessionID = nil
                                performVaultPutBack(recordID: record.id)
                            }
                        }
                        Button("Restore to Photos", systemImage: "lock.open") {
                            moreSessionID = nil
                            let id = record.id
                            showingVault = true
                            vaultMessage = nil
                            vaultAlbumRetryIDs = []
                            Task { @MainActor in
                                do {
                                    try await vault.restore(recordID: id)
                                    vaultMessage = "Restored to Photos."
                                } catch {
                                    if vault.isUnlocked {
                                        vaultMessage = error.localizedDescription
                                        if let failure = error as? GalleryVaultTransferError,
                                           case .albumUnavailable = failure { vaultAlbumRetryIDs = [id] }
                                    }
                                }
                            }
                        }
                        .disabled(vault.isBusy)
                    }
                    Button("Private Vault", systemImage: "lock") { moreSessionID = nil; showingVault = true }
                    Button("Share", systemImage: "square.and.arrow.up") {
                        moreSessionID = nil
                        if let asset = session.currentAsset { sharing.start(assets: [asset]) }
                    }
                    .disabled(session.currentAsset == nil || sharing.isPreparing)
                }
                .labelStyle(.titleAndIcon)
                .padding(20)
                .galleryLightBackdrop(cornerRadius: 24)
                .onDisappear { morePopoverCovered = false }
            }
            Button(action: duplicate) {
                GalleryViewerActionLabel(title: "New", symbol: "rectangle.on.rectangle")
            }
            .labelStyle(.iconOnly)
            .disabled(session.currentItem == nil)
            .buttonStyle(.plain)
            .accessibilityLabel("Open another slideshow")
            .galleryHoverLabel("Open another slideshow")
            .accessibilityIdentifier("gallery-viewer-duplicate")
            Button(action: arrange) {
                GalleryViewerActionLabel(title: "Pair", symbol: "rectangle.split.2x1")
            }
            .labelStyle(.iconOnly)
            .disabled(!canArrange)
            .buttonStyle(.plain)
            .accessibilityLabel("Arrange side by side")
            .galleryHoverLabel("Arrange side by side")
            .accessibilityIdentifier("gallery-viewer-arrange")
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func mediaStage(height: CGFloat) -> some View {
        if moveTarget != nil || pendingDelete != nil || vaultCovered {
            // Only More may retain flat context; privacy and mutation covers always stay blank.
            if GalleryMorePreviewPolicy.canShow(sessionID: session.id, moreSessionID: moreSessionID,
                previewItemKey: media.menuPreviewKey, currentItemKey: session.currentItem?.cacheKey,
                privacyCovered: privacyCovered || moveTarget != nil || pendingDelete != nil),
               let preview = media.menuPreview {
                GalleryViewerMenuPreview(image: preview)
            } else { Color.clear }
        } else if session.currentItem == nil {
            ContentUnavailableView("No items left", systemImage: "photo",
                description: Text("Moved items stay in their destination album."))
        } else if media.isLoading {
            ProgressView("\(session.currentItem?.mediaType == .video ? "Loading video" : "Preparing photo")…")
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
                        if let item = session.currentItem {
                            await media.load(item: item, spatialEnabled: spatialEnabled)
                        }
                    }
                }
            }
            .padding(24).foregroundStyle(.white)
        }
    }

    private var controls: some View {
        return GalleryViewerControlBar(presentsBackdrop: false) {
            Button {
                actionError = nil
                store.previous(session.id)
            } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .disabled(!session.canGoPrevious)
            .accessibilityIdentifier("gallery-viewer-previous")

            if session.currentItem?.mediaType == .image {
                Button { spatialEnabled.toggle() } label: {
                    GalleryViewerActionLabel(title: spatialEnabled ? "Original" : "Spatial",
                        symbol: spatialEnabled ? "photo" : "cube")
                }
                .accessibilityLabel(spatialEnabled ? "Show original" : "Show spatial scene")
                .accessibilityIdentifier("gallery-viewer-spatial")
                .accessibilityValue(media.isShowingSpatial ? "Spatial" : "2D")
            }

            if session.currentItem?.mediaType == .video {
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

            if !isVaultItemInRecycleBin {
                Button {
                    if let record = session.currentItem?.vaultRecord {
                        actionError = nil
                        media.setPresentationCovered(true)
                        moveTarget = GalleryViewerMoveTarget(sessionID: session.id,
                            assetID: session.currentItem?.localIdentifier ?? "vault:\(record.id.uuidString)",
                            vaultRecordID: record.id, sourceAlbumID: session.sourceAlbumID)
                    } else if let assetID = session.currentAsset?.localIdentifier {
                        actionError = nil
                        // Capture playback intent before dismantling the media surface.
                        media.setPresentationCovered(true)
                        moveTarget = GalleryViewerMoveTarget(sessionID: session.id, assetID: assetID,
                            sourceAlbumID: session.sourceAlbumID)
                    }
                } label: { Label("Move", systemImage: "arrowshape.turn.up.right") }
                .disabled(session.currentItem == nil || store.isPerformingOperation || (isVaultItem && vault.isBusy))
                .accessibilityIdentifier("gallery-viewer-move")
            }

            Button {
                actionError = nil
                if let record = session.currentItem?.vaultRecord {
                    if GalleryVaultRecycleBin.contains(record) {
                        media.setPresentationCovered(true)
                        pendingDelete = GalleryViewerDeleteTarget(item: .vault(record.id), sessionID: session.id)
                    } else {
                        deleteQueue.enqueueVaultRecycle(recordID: record.id, sessionID: session.id)
                    }
                    return
                }
                guard let item = session.currentItem, let asset = item.photosAsset else { return }
                if isInRecycleBin {
                    media.setPresentationCovered(true)
                    pendingDelete = GalleryViewerDeleteTarget(item: .photos(asset),
                        sessionID: session.id, sourceAlbumID: session.albumID)
                    return
                }
                deleteQueue.enqueueRecycle(item: item, sourceAlbumID: session.sourceAlbumID, sessionID: session.id)
            } label: {
                Label(isPermanentDelete ? "Delete Permanently" : "Move to Recycle Bin",
                    systemImage: isPermanentDelete ? "trash.slash" : "trash")
            }
            .disabled(session.currentItem == nil)
            .accessibilityLabel(isPermanentDelete ? "Delete Permanently" : "Move to Recycle Bin")
            .accessibilityIdentifier("gallery-viewer-recycle")
            .accessibilityHint(isPermanentDelete ? "Permanently deletes this item after confirmation." : "Moves this item to the Recycle Bin.")

            Button {
                actionError = nil
                store.next(session.id)
            } label: {
                Label("Next", systemImage: "chevron.right")
            }
            .disabled(session.currentItem == nil)
            .accessibilityIdentifier("gallery-viewer-next")
        }

    }

    private var isInRecycleBin: Bool {
        GalleryRecycleBin.isRecycleBinTitle(session.albumTitle)
    }

    private var isVaultItem: Bool { session.currentItem?.vaultRecord != nil }
    private var isVaultItemInRecycleBin: Bool {
        session.currentItem?.vaultRecord.map(GalleryVaultRecycleBin.contains) ?? false
    }
    private var isPermanentDelete: Bool { isVaultItem ? isVaultItemInRecycleBin : isInRecycleBin }

    private func performVaultPutBack(recordID: UUID) {
        deleteQueue.enqueueVaultPutBack(recordID: recordID, sessionID: session.id)
    }
}

private struct GalleryViewerMoveTarget: Identifiable {
    let sessionID: UUID
    let assetID: String
    var vaultRecordID: UUID? = nil
    var sourceAlbumID: String? = nil
    var id: String { "\(sessionID.uuidString):\(assetID)" }
}

private struct GalleryViewerDeleteTarget: Identifiable {
    enum Item {
        case photos(PHAsset)
        case vault(UUID)
    }
    let item: Item
    let sessionID: UUID
    var sourceAlbumID: String? = nil
    var id: String {
        switch item {
        case let .photos(asset): asset.localIdentifier
        case let .vault(id): "vault:\(id.uuidString)"
        }
    }
}

private struct GalleryViewerMoveSheet: View {
    let sessionID: UUID
    let assetID: String
    let vaultRecordID: UUID?
    let sourceAlbumID: String?
    let moveToVault: (GalleryVaultTransferRequest) -> Void
    @ObservedObject private var store = GalleryViewerStore.shared
    @ObservedObject private var albumEmptiness = GalleryVirtualLibraryIndex.shared
    @ObservedObject private var vault = GalleryVaultService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var vaultAlbums = false
    @State private var vaultDestinations: [GalleryVaultAlbum] = []
    @State private var newAlbumName = ""
    @State private var error: String?

    private var availableAlbums: [GalleryAlbum] {
        store.albums.filter { vault.isUnlocked || $0.visibleWithLockedVault(emptyAlbumIDs: albumEmptiness.emptyAlbumIDs) }
    }

    private var isMovingVaultItem: Bool { vaultRecordID != nil }
    private var showingVaultDestinations: Bool { isMovingVaultItem || vaultAlbums }

    private var destinations: [GalleryAlbum] {
        let recentIDs = Set(query.isEmpty ? recentDestinations.map(\.id) : [])
        return GalleryAlbumSearch.filter(availableAlbums.filter {
            $0.id != store.session(sessionID)?.albumID
                && $0.collection?.canPerform(.addContent) == true
                && !GalleryRecycleBin.isRecycleBin($0)
                && !recentIDs.contains($0.id)
        }, query: query)
    }

    private var recentDestinations: [GalleryAlbum] {
        GalleryMoveHistory.shared.recentAlbums(from: availableAlbums,
            excluding: store.session(sessionID)?.albumID)
            .filter { !GalleryRecycleBin.isRecycleBin($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !isMovingVaultItem { GalleryVaultAlbumsToggle(isOn: $vaultAlbums) }
                Section(isMovingVaultItem ? "Create a Private Vault album" : "Create an album") {
                    TextField("Album name", text: $newAlbumName)
                    Button("Create and Move") {
                        let name = newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if showingVaultDestinations {
                            chooseVaultAlbum(vaultDestinations.first { $0.title == name }
                                ?? GalleryVaultAlbum(id: "vault-album:" + UUID().uuidString, title: name, position: nil))
                        } else {
                            performMove { try await store.move(sessionID, toNewAlbumNamed: name, expectedAssetID: assetID) }
                        }
                    }
                    .accessibilityIdentifier("gallery-viewer-create-vault-album")
                    .disabled(newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isPerformingOperation
                        || (showingVaultDestinations && vault.isBusy)
                        || (showingVaultDestinations && GalleryRecycleBin.isRecycleBinTitle(newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines))))
                }
                if !showingVaultDestinations, query.isEmpty, !recentDestinations.isEmpty {
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
                    if showingVaultDestinations {
                        if vault.isUnlocked {
                            ForEach(vaultDestinations.filter { query.isEmpty || $0.title.localizedStandardContains(query) }, id: \.id) { album in
                                Button { chooseVaultAlbum(album) } label: { Label(album.title, systemImage: "lock.fill") }
                                    .accessibilityIdentifier("gallery-viewer-move-vault-destination-" + album.id)
                                    .disabled(vault.isBusy)
                            }
                            if vaultDestinations.isEmpty { Text("Create a Private Vault album above.") }
                        } else {
                            Text("Unlock Private Vault to choose a destination.")
                        }
                    } else { ForEach(destinations) { album in
                        Button(album.title) {
                            performMove { try await store.move(sessionID, to: album, expectedAssetID: assetID) }
                        }
                        .disabled(store.isPerformingOperation)
                    }
                }
                }
                if !showingVaultDestinations { Section("Current album") {
                    Button("Remove from Album", systemImage: "minus.circle") {
                        performMove {
                            try await store.removeFromSourceAlbum(sessionID: sessionID, expectedAssetID: assetID)
                        }
                    }
                    .disabled(!canRemoveFromSource || store.isPerformingOperation)
                    .accessibilityIdentifier("gallery-viewer-remove-from-album")
                }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .searchable(text: $query, prompt: "Find an album")
            .navigationTitle("Move Item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .overlay {
                if store.isPerformingOperation {
                    VStack(spacing: 12) {
                        ProgressView("Moving…")
                        if store.pendingPhotosSessionID == sessionID {
                            Text("Photos hasn’t responded yet. This operation is still pending.")
                                .accessibilityIdentifier("gallery-viewer-photos-pending")
                        }
                    }.padding(24).glassBackgroundEffect()
                }
            }
        }
        .frame(width: 500, height: 550)
        .task { await store.refreshAlbums() }
        .task(id: vault.isUnlocked && !vault.isBusy) {
            guard vault.isUnlocked, !vault.isBusy else { return }
            let destinations = await vault.albumDestinations()
            guard vault.isUnlocked, !Task.isCancelled else { return }
            vaultDestinations = destinations
        }
        .onChange(of: vault.isUnlocked) { _, unlocked in
            if !unlocked { vaultDestinations = []; vaultAlbums = false; query = ""; newAlbumName = ""; error = nil }
        }
    }

    private func chooseVaultAlbum(_ album: GalleryVaultAlbum) {
        if let vaultRecordID {
            guard vault.isUnlocked else { return }
            performMove { try await vault.move(recordID: vaultRecordID, from: sourceAlbumID, to: album) }
            return
        }
        guard vault.isUnlocked, let session = store.session(sessionID),
              let asset = session.currentAsset, asset.localIdentifier == assetID else { return }
        moveToVault(.items([asset], destination: album, sourceAlbumID: session.sourceAlbumID))
        dismiss()
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

struct GalleryRealityImage: View {
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

enum GalleryLogRedaction {
    private static let salt = SymmetricKey(size: .bits256)

    static func token(_ value: String) -> String {
        let saltBytes = salt.withUnsafeBytes { Array($0) }
        let digest = SHA256.hash(data: Data(saltBytes) + Data(value.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
