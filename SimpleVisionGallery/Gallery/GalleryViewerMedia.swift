#if os(visionOS)
import AVFoundation
import ImageIO
import Observation
@preconcurrency import Photos
import RealityKit
import UIKit
import UniformTypeIdentifiers

/// Each window owns playback and presentation; expensive generated images are shared.
@MainActor @Observable
final class GalleryViewerMedia {
    private(set) var imageEntity: Entity?
    private(set) var fallbackImage: UIImage?
    private var menuPreviewState = GalleryMenuPreviewState<UIImage>()
    var menuPreview: UIImage? { menuPreviewState.image }
    var menuPreviewKey: String? { menuPreviewState.itemKey }
    private(set) var player: AVPlayer?
    private(set) var isSpatialVideo = false
    private(set) var aspectRatio: Double?
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var status: String?
    private(set) var spatialAvailable = false
    private(set) var isShowingSpatial = false
    private var generation = UUID()
    private var activeLoad: Task<Void, Never>?
    private var desiredPrefetchAssets: [GalleryMediaItem] = []
    private var requestedPrefetchAssets: [GalleryMediaItem] = []
    private var requestedExcludingCurrent: GalleryMediaItem?
    private var requestedPreserving: GalleryMediaItem?
    private var prefetched: Set<String> = []
    private let prefetchOwnerID = UUID()
    private var prefetchFailures: Set<String> = []
    private var prefetchVideoSlotFailures: Set<String> = []
    private var attemptedVideoPrerolls: Set<String> = []
    private var deferredVideoPrerolls: Set<String> = []
    private var prefetchCoordinator: Task<Void, Never>?
    private var prefetchTask: Task<GalleryPrefetchedMedia, Error>?
    private var prefetchKey: String?
    private var prefetchPriority: GalleryPrefetchPriority?
    private var prefetchGeneration = UUID()
    private var videoPrerollSlotGeneration: UInt64 = 0
    private var lastPrefetchOwnerCount = 1
    private var memoryWarningObserver: GalleryNotificationToken?
    private var prefetchOwnersObserver: GalleryNotificationToken?
    private var prefetchVideoSlotObserver: GalleryNotificationToken?
    private var currentKey: String?
    private var playerObservation: NSKeyValueObservation?
    private var playerEndObserver: GalleryNotificationToken?
    private var videoLooping = false
    private var prepared: GalleryPreparedImage?
    private var currentVideo: GalleryPreparedVideo?
    private var vaultLockObserver: GalleryNotificationToken?
    private var vaultHideObserver: GalleryNotificationToken?
    private var photosAccessObserver: GalleryNotificationToken?
    private var preparedKey: String?
    private var isSceneActive = true
    private var isPresentationCovered = false
    private var resumePlaybackWhenActive = false

    init() {
        vaultLockObserver = GalleryNotificationToken(NotificationCenter.default.addObserver(
            forName: .galleryVaultWillLock, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.vaultWillLock() }
        })
        vaultHideObserver = GalleryNotificationToken(NotificationCenter.default.addObserver(
            forName: .galleryVaultDidHideItems, object: nil, queue: nil
        ) { [weak self] note in
            let ids = note.userInfo?["sourceIdentifierSet"] as? Set<String>
                ?? Set(note.userInfo?["sourceIdentifiers"] as? [String] ?? [])
            MainActor.assumeIsolated { self?.didHideItems(ids) }
        })
        photosAccessObserver = GalleryNotificationToken(NotificationCenter.default.addObserver(
            forName: .galleryPhotosAccessDidRevoke, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.photosAccessDidRevoke() }
        })
        memoryWarningObserver = GalleryNotificationToken(NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.prefetch(assets: [])
                GallerySceneCache.shared.clearSpeculativeVideoPreroll()
            }
        })
        prefetchOwnersObserver = GalleryNotificationToken(NotificationCenter.default.addObserver(
            forName: GallerySceneCache.prefetchOwnersDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.prefetchOwnersDidChange() }
        })
        prefetchVideoSlotObserver = GalleryNotificationToken(NotificationCenter.default.addObserver(
            forName: GallerySceneCache.prefetchVideoSlotDidChange, object: nil, queue: nil
        ) { [weak self] note in
            let consumedKey = note.userInfo?["consumedKey"] as? String
            Task { @MainActor [weak self] in self?.prefetchVideoSlotDidChange(consumedKey: consumedKey) }
        })
    }

    deinit {
        let owner = prefetchOwnerID
        Task { @MainActor in
            GallerySceneCache.shared.updatePrefetchDemand(owner: owner, orderedKeys: [])
        }
    }

    func load(asset: PHAsset, spatialEnabled: Bool) async {
        await load(item: .photos(asset), spatialEnabled: spatialEnabled)
    }

    func load(item asset: GalleryMediaItem, spatialEnabled: Bool) async {
        guard !Task.isCancelled else { return }
        guard asset.vaultRecord == nil || GalleryVaultStorage.shared.isUnlocked else {
            cancel()
            return
        }
        let requestedKey = GallerySceneCache.key(for: asset)
        if currentKey != requestedKey { aspectRatio = nil }
        if let oldKey = currentKey, desiredPrefetchAssets.contains(where: { GallerySceneCache.key(for: $0) == oldKey }) {
            if let prepared, preparedKey == oldKey {
                if GallerySceneCache.shared.retainPrefetched(.image(prepared), key: oldKey, owner: prefetchOwnerID) {
                    prefetched.insert(oldKey)
                }
            } else if let oldVideo = currentVideo {
                if GallerySceneCache.shared.retainPrefetched(.video(oldVideo), key: oldKey, owner: prefetchOwnerID) {
                    prefetched.insert(oldKey)
                }
            }
        }
        // Keep the speculative consumer alive until the foreground consumer joins.
        let warmed = GallerySceneCache.shared.takePrefetched(key: requestedKey, owner: prefetchOwnerID)
        prefetched.remove(requestedKey)
        let promoted = prefetchKey == requestedKey ? prefetchTask : nil
        if promoted != nil {
            prefetchPriority?.foreground = true
            prefetchPriority = nil
            prefetchTask = nil
            prefetchKey = nil
        }
        cancelCurrent(releaseImage: preparedKey != requestedKey)
        // A promoted request becomes foreground work; detach its old coordinator.
        // Otherwise keep preparing the still-wanted following scene while a warm
        // current scene is presented. Demand changes already cancel obsolete work.
        if promoted != nil { cancelPrefetchWork() }
        desiredPrefetchAssets.removeAll { GallerySceneCache.key(for: $0) == requestedKey }
        currentKey = requestedKey
        GallerySceneCache.shared.promote(asset: asset)
        let token = generation
        isLoading = true
        error = nil
        status = nil
        // A completed reservation is already safe to present on this actor.
        // Avoid a second task hop, which can miss a display frame under load.
        if asset.mediaType == .video {
            let ready: GalleryPreparedVideo?
            if case .video(let video) = warmed { ready = video }
            else { ready = GallerySceneCache.shared.preparedVideo(for: asset, foreground: true) }
            if let ready {
                promoted?.cancel()
                presentVideo(ready, token: token)
                isLoading = false
                startPrefetchIfNeeded()
                return
            }
        }
        if asset.mediaType != .video {
            let ready: GalleryPreparedImage?
            if case .image(let image) = warmed, !spatialEnabled || image.attemptedSpatial {
                ready = image
            } else if preparedKey == requestedKey, let image = prepared,
                      !spatialEnabled || image.attemptedSpatial {
                ready = image
            } else if let image = GallerySceneCache.shared.preparedImage(for: asset, spatial: spatialEnabled) {
                ready = image
            } else {
                ready = nil
            }
            if let ready {
                promoted?.cancel()
                presentImage(ready, key: requestedKey, spatialEnabled: spatialEnabled)
                isLoading = false
                startPrefetchIfNeeded()
                return
            }
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { promoted?.cancel(); return }
            defer { promoted?.cancel() }
            do {
                if asset.mediaType == .video {
                    self.prepared = nil
                    self.preparedKey = nil
                    let video: GalleryPreparedVideo
                    if let promoted {
                        do {
                            guard case .video(let warmed) = try await GalleryMediaRequest.value(of: promoted) else {
                                throw GalleryMediaError.missingMedia
                            }
                            video = warmed
                        } catch is CancellationError { throw CancellationError() }
                        catch { video = try await GallerySceneCache.shared.video(for: asset, foreground: true) }
                    } else {
                        video = try await GallerySceneCache.shared.video(for: asset, foreground: true)
                    }
                    try Task.checkCancellation()
                    guard self.generation == token else { return }
                    self.presentVideo(video, token: token)
                } else {
                    let key = GallerySceneCache.key(for: asset)
                    let image: GalleryPreparedImage
                    if let promoted {
                        do {
                            guard case .image(let retained) = try await GalleryMediaRequest.value(of: promoted) else {
                                throw GalleryMediaError.missingMedia
                            }
                            image = !spatialEnabled || retained.attemptedSpatial
                                ? retained
                                : try await GallerySceneCache.shared.image(for: asset, spatial: true)
                        } catch is CancellationError { throw CancellationError() }
                        catch { image = try await GallerySceneCache.shared.image(for: asset, spatial: spatialEnabled) }
                    } else if self.preparedKey == key, let retained = self.prepared,
                       !spatialEnabled || retained.attemptedSpatial {
                        image = retained
                    } else {
                        image = try await GallerySceneCache.shared.image(for: asset, spatial: spatialEnabled)
                    }
                    try Task.checkCancellation()
                    guard self.generation == token else { return }
                    self.presentImage(image, key: key, spatialEnabled: spatialEnabled)
                }
            } catch is CancellationError {
                // A swipe or a closed window superseded this request.
            } catch {
                guard self.generation == token else { return }
                self.error = error.localizedDescription
            }
            if self.generation == token {
                self.isLoading = false
                self.startPrefetchIfNeeded()
            }
        }
        activeLoad = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // Attach one viewer-owned player using metadata already loaded during preparation.
    private func presentVideo(_ video: GalleryPreparedVideo, token: UUID) {
        video.promote()
        self.prepared = nil
        self.preparedKey = nil
        let avAsset = video.asset
        let spatialVideo = video.isSpatialVideo
        let videoAspectRatio = video.aspectRatio
        self.currentVideo = video
        self.aspectRatio = videoAspectRatio
        self.isSpatialVideo = spatialVideo
        #if targetEnvironment(simulator)
        if spatialVideo { self.status = "Showing a 2D preview in Simulator. Spatial video needs Apple Vision Pro." }
        #endif
        // The first foreground consumer takes the warmed player; sibling windows make independent players.
        let preparedPlayer = video.takePrerolledPlayer()
        let item = preparedPlayer?.currentItem ?? AVPlayerItem(asset: avAsset)
        self.player = preparedPlayer ?? AVPlayer(playerItem: item)
        self.player?.actionAtItemEnd = self.videoLooping ? .none : .pause
        self.playerEndObserver = GalleryNotificationToken(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.generation == token,
                      self.videoLooping, self.isSceneActive, !self.isPresentationCovered,
                      let player = self.player, player.currentItem === item,
                      player.rate > 0 else { return }
                // With .none, reaching the end does not pause the player.
                // A manual/background pause before this callback wins.
                // Play before the seek completes so no delayed completion
                // can restart a player the user pauses during the seek.
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                player.play()
            }
        })
        self.playerObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "This video could not be played."
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.error = message
            }
        }
        if self.isSceneActive && !self.isPresentationCovered { self.player?.play() }
        else { self.resumePlaybackWhenActive = true }
    }

    // Present completed media inline so a warm navigation does not wait on another task.
    private func presentImage(_ image: GalleryPreparedImage, key: String, spatialEnabled: Bool) {
        self.prepared = image
        self.preparedKey = key
        self.menuPreviewState.set(image.menuPreview, for: key)
        self.aspectRatio = image.aspectRatio
        self.spatialAvailable = image.supportsSpatial
        self.status = spatialEnabled ? image.status : nil
        // A fresh entity can attach the shared prepared component in this window.
        if var component = image.component {
            component.desiredViewingMode = spatialEnabled ? image.spatialMode : .mono
            let entity = Entity()
            entity.components.set(component)
            self.imageEntity = entity
            self.isShowingSpatial = spatialEnabled && image.spatialMode != .mono
        } else {
            self.fallbackImage = image.fallback
        }
    }

    fileprivate static func videoAspectRatio(_ asset: AVAsset) async -> Double? {
        // Metadata failure must not prevent playback. The window can fall back to
        // PhotoKit dimensions until an oriented presentation ratio is available.
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let oriented = CGRect(origin: .zero, size: size).applying(transform).size
        guard oriented.width.isFinite, oriented.height.isFinite,
              oriented.width > 0, oriented.height > 0 else { return nil }
        return Double(oriented.width / oriented.height)
    }

    /// Applies to this and future videos without replacing the current player/item.
    func setVideoLooping(_ enabled: Bool) {
        videoLooping = enabled
        player?.actionAtItemEnd = enabled ? .none : .pause
    }

    /// A small, ordered lookahead window. Each viewer prepares one item at a time.
    func prefetch(assets: [PHAsset], excludingCurrent: PHAsset? = nil, preserving: PHAsset? = nil) {
        prefetch(items: assets.map(GalleryMediaItem.photos),
                 excludingCurrent: excludingCurrent.map(GalleryMediaItem.photos),
                 preserving: preserving.map(GalleryMediaItem.photos))
    }

    /// Recompute this window's ordered demand so retained media follows its current share of the shared budget.
    func prefetch(items assets: [GalleryMediaItem], excludingCurrent: GalleryMediaItem? = nil, preserving: GalleryMediaItem? = nil) {
        requestedPrefetchAssets = assets
        requestedExcludingCurrent = excludingCurrent
        requestedPreserving = preserving
        var seen: Set<String> = []
        lastPrefetchOwnerCount = GallerySceneCache.shared.prefetchOwnerCount
        let itemShare = max(1, GalleryViewerPreferences.globalPrefetchItemBudget / lastPrefetchOwnerCount)
        let currentAssetKey = excludingCurrent.map(GallerySceneCache.key(for:)) ?? currentKey
        var hasNextVideo = false
        desiredPrefetchAssets = Array(assets.prefix(itemShare)).filter {
            let key = GallerySceneCache.key(for: $0)
            guard key != currentAssetKey, seen.insert(key).inserted else { return false }
            guard $0.mediaType == .video else { return true }
            guard !hasNextVideo else { return false }
            hasNextVideo = true
            return true
        }
        let orderedKeys = desiredPrefetchAssets.map(GallerySceneCache.key(for:))
        let preservedKey = preserving.map(GallerySceneCache.key(for:))
        let wanted = Set(orderedKeys).union(preservedKey.map { [$0] } ?? [])
        prefetched.formIntersection(wanted)
        GallerySceneCache.shared.updatePrefetchDemand(owner: prefetchOwnerID,
            orderedKeys: isSceneActive ? (preservedKey.map { [$0] + orderedKeys } ?? orderedKeys) : [])
        // Each external demand refresh is one new chance after a transient failure.
        prefetchFailures.removeAll()
        prefetchVideoSlotFailures.removeAll()
        attemptedVideoPrerolls.removeAll()
        deferredVideoPrerolls.removeAll()
        if let prefetchKey, !wanted.contains(prefetchKey) { cancelPrefetchWork() }
        if wanted.isEmpty { cancelPrefetchWork() }
        startPrefetchIfNeeded()
    }

    private func prefetchOwnersDidChange() {
        // A different owner count changes this viewer's item and pixel budgets.
        guard isSceneActive, GallerySceneCache.shared.prefetchOwnerCount != lastPrefetchOwnerCount else { return }
        cancelPrefetchWork()
        prefetchFailures.removeAll()
        prefetchVideoSlotFailures.removeAll()
        attemptedVideoPrerolls.removeAll()
        deferredVideoPrerolls.removeAll()
        prefetch(items: requestedPrefetchAssets, excludingCurrent: requestedExcludingCurrent,
                 preserving: requestedPreserving)
    }

    private func prefetchVideoSlotDidChange(consumedKey: String? = nil) {
        videoPrerollSlotGeneration &+= 1
        if let consumedKey { attemptedVideoPrerolls.remove(consumedKey) }
        prefetchFailures.subtract(prefetchVideoSlotFailures)
        prefetchVideoSlotFailures.removeAll()
        deferredVideoPrerolls.removeAll()
        // Revisit cached videos when another window frees the single decoder slot.
        startPrefetchIfNeeded()
    }

    /// Start one ordered preparation worker so one window does not flood the shared budget.
    private func startPrefetchIfNeeded() {
        guard isSceneActive, !isLoading, prefetchCoordinator == nil,
              !desiredPrefetchAssets.isEmpty else { return }
        let token = prefetchGeneration
        let slotGeneration = videoPrerollSlotGeneration
        prefetchCoordinator = Task(priority: .utility) { @MainActor [weak self] in
            // Keep processing wanted media until cancellation or the current demand is satisfied.
            while !Task.isCancelled {
                self?.upgradeNearestVideoPreroll()
                guard let (key, task) = self?.nextPrefetchRequest() else { break }
                do {
                    let result = try await task.value
                    try Task.checkCancellation()
                    guard let self, self.prefetchGeneration == token else { return }
                    self.prefetchTask = nil
                    self.prefetchKey = nil
                    self.prefetchPriority = nil
                    if GallerySceneCache.shared.retainPrefetched(result, key: key, owner: self.prefetchOwnerID) {
                        self.prefetched.insert(key)
                        if case .video(let video) = result,
                           self.isNearestVideo(key), !self.attemptedVideoPrerolls.contains(key) {
                            let outcome = GallerySceneCache.shared.scheduleVideoPreroll(video, key: key)
                            self.recordVideoPrerollOutcome(outcome, key: key)
                        }
                    } else {
                        self.prefetchFailures.insert(key)
                    }
                } catch {
                    guard let self, self.prefetchGeneration == token else { return }
                    self.prefetchTask = nil
                    self.prefetchKey = nil
                    self.prefetchPriority = nil
                    if case GalleryMediaError.prefetchVideoSlotUnavailable = error {
                        if !GallerySceneCache.shared.vaultVideoSlotAvailable {
                            self.prefetchFailures.insert(key)
                            self.prefetchVideoSlotFailures.insert(key)
                        }
                    } else {
                        self.prefetchFailures.insert(key)
                    }
                }
            }
            if let self, self.prefetchGeneration == token {
                self.prefetchCoordinator = nil
                if self.videoPrerollSlotGeneration != slotGeneration,
                   GallerySceneCache.shared.videoPrerollSlotAvailable {
                    self.startPrefetchIfNeeded()
                }
            }
        }
    }

    /// Upgrade metadata-only video when it becomes this window's nearest video and the global slot opens.
    private func upgradeNearestVideoPreroll() {
        guard let asset = desiredPrefetchAssets.first(where: { $0.mediaType == .video }) else { return }
        let key = GallerySceneCache.key(for: asset)
        guard !attemptedVideoPrerolls.contains(key),
              !deferredVideoPrerolls.contains(key),
              GallerySceneCache.shared.hasPrefetched(key, owner: prefetchOwnerID),
              let video = GallerySceneCache.shared.prefetchedVideo(key: key, owner: prefetchOwnerID),
              !video.hasPrerolledPlayer else { return }
        let outcome = GallerySceneCache.shared.scheduleVideoPreroll(video, key: key)
        recordVideoPrerollOutcome(outcome, key: key)
    }

    /// Only a reservation this window schedules counts as its attempt; a sibling may own the warm player.
    private func recordVideoPrerollOutcome(_ outcome: GallerySceneCache.GalleryVideoPrerollOutcome, key: String) {
        switch outcome {
        case .scheduled:
            attemptedVideoPrerolls.insert(key)
        case .alreadyPrepared:
            break
        case .slotUnavailable:
            deferredVideoPrerolls.insert(key)
        }
    }

    private func isNearestVideo(_ key: String) -> Bool {
        desiredPrefetchAssets.first(where: { $0.mediaType == .video })
            .map { GallerySceneCache.key(for: $0) == key } ?? false
    }

    private func nextPrefetchRequest() -> (String, Task<GalleryPrefetchedMedia, Error>)? {
        guard isSceneActive, !isLoading else { return nil }
        let usedPixels = GallerySceneCache.shared.retainedPixels(owner: prefetchOwnerID)
        for asset in desiredPrefetchAssets {
            let key = GallerySceneCache.key(for: asset)
            guard !GallerySceneCache.shared.hasPrefetched(key, owner: prefetchOwnerID),
                  !prefetchFailures.contains(key) else { continue }
            // Later videos already have library metadata; avoid opening their assets until they become next.
            if asset.mediaType == .video, !isNearestVideo(key) {
                prefetchFailures.insert(key)
                continue
            }
            // Still images use one eye bounded to 2560px; undersized photos may
            // be upscaled to the local 320px short-edge generation heuristic.
            let width = Double(asset.pixelWidth), height = Double(asset.pixelHeight)
            var sourceScale = min(1, 2560 / max(1, max(width, height)))
            let aspect = width / max(1, height)
            let shortEdge = min(width, height) * sourceScale
            if shortEdge < 320,
               aspect >= 1.0 / 3.0, aspect <= 3.0 {
                sourceScale *= 320 / max(1, shortEdge)
            }
            let pixelEstimate = asset.mediaType == .image
                ? width * height * sourceScale * sourceScale : 0
            guard pixelEstimate <= Double(pixelBudgetPerViewer - usedPixels) else { continue }
            let remainingPixels = pixelBudgetPerViewer - usedPixels
            let priority = GalleryPrefetchPriority()
            let task = Task(priority: .utility) { @MainActor in
                try Task.checkCancellation()
                if asset.mediaType == .video {
                    // Warming never creates a player or starts playback.
                    return GalleryPrefetchedMedia.video(try await GallerySceneCache.shared.video(for: asset, foreground: priority.foreground))
                }
                return GalleryPrefetchedMedia.image(
                    try await GallerySceneCache.shared.image(
                        for: asset, spatial: true, foreground: priority.foreground, pixelBudget: remainingPixels
                    )
                )
            }
            prefetchTask = task
            prefetchKey = key
            prefetchPriority = priority
            return (key, task)
        }
        return nil
    }

    private var pixelBudgetPerViewer: Int {
        max(1, GalleryViewerPreferences.globalPrefetchPixelBudget / GallerySceneCache.shared.prefetchOwnerCount)
    }

    /// Hiding a raised surface must not cancel the next scene's conversion.
    func setPresentationCovered(_ covered: Bool) {
        guard covered != isPresentationCovered else { return }
        isPresentationCovered = covered
        if covered {
            resumePlaybackWhenActive = resumePlaybackWhenActive || (player.map { $0.timeControlStatus != .paused } ?? false)
            player?.pause()
        } else if isSceneActive {
            if resumePlaybackWhenActive { player?.play() }
            resumePlaybackWhenActive = false
        }
    }

    private func didHideItems(_ ids: Set<String>) {
        if currentKey.flatMap(GalleryMediaItem.sourceIdentifier(forCacheKey:)).map(ids.contains) == true {
            cancel()
        } else {
            prefetch(items: requestedPrefetchAssets.filter { !ids.contains($0.localIdentifier) })
        }
    }

    private func photosAccessDidRevoke() {
        if let currentKey, !currentKey.hasPrefix("vault:") {
            cancel()
        } else {
            prefetch(items: requestedPrefetchAssets.filter { $0.vaultRecord != nil })
        }
    }

    private func vaultWillLock() {
        // This runs synchronously before the storage removes plaintext leases.
        let showingPrivate = currentKey?.hasPrefix("vault:") == true
        if showingPrivate { cancel() }
        else { prefetch(items: requestedPrefetchAssets.filter { $0.vaultRecord == nil }) }
    }

    private func cancelPrefetchWork() {
        prefetchGeneration = UUID()
        prefetchCoordinator?.cancel()
        prefetchCoordinator = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchKey = nil
        prefetchPriority = nil
    }

    /// Pushed windows can hide a viewer without removing its view hierarchy.
    func setSceneActive(_ active: Bool) {
        guard active != isSceneActive else { return }
        isSceneActive = active
        if active {
            prefetchFailures.removeAll()
            prefetchVideoSlotFailures.removeAll()
            if !isPresentationCovered {
                if resumePlaybackWhenActive { player?.play() }
                resumePlaybackWhenActive = false
            }
            prefetch(items: requestedPrefetchAssets, excludingCurrent: requestedExcludingCurrent,
                     preserving: requestedPreserving)
        } else {
            cancelPrefetchWork()
            // Remove this window's demand; the cache keeps shared media wanted by an active sibling.
            GallerySceneCache.shared.updatePrefetchDemand(owner: prefetchOwnerID, orderedKeys: [])
            attemptedVideoPrerolls.removeAll()
            deferredVideoPrerolls.removeAll()
            resumePlaybackWhenActive = resumePlaybackWhenActive || (player.map { $0.timeControlStatus != .paused } ?? false)
            player?.pause()
        }
    }

    func cancel(releaseImage: Bool = true) {
        prefetch(assets: [])
        currentKey = nil
        aspectRatio = nil
        cancelCurrent(releaseImage: releaseImage)
    }

    private func cancelCurrent(releaseImage: Bool) {
        generation = UUID()
        activeLoad?.cancel()
        activeLoad = nil
        playerEndObserver = nil
        playerObservation?.invalidate()
        playerObservation = nil
        if releaseImage { prepared = nil; preparedKey = nil }
        resumePlaybackWhenActive = false
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        currentVideo = nil
        isSpatialVideo = false
        imageEntity = nil
        fallbackImage = nil
        menuPreviewState.clear()
        spatialAvailable = false
        isShowingSpatial = false
        isLoading = false
    }
}

private nonisolated final class GalleryNotificationToken: @unchecked Sendable {
    private let observer: NSObjectProtocol
    init(_ observer: NSObjectProtocol) { self.observer = observer }
    deinit { NotificationCenter.default.removeObserver(observer) }
}

@MainActor
private final class GalleryPrefetchPriority {
    var foreground = false
}

/// Reuse the decode already needed by native preparation; never fetch media for a menu.
enum GalleryMenuPreview {
    static func make(from image: UIImage) -> UIImage {
        let scale = min(1, 512 / max(image.size.width, image.size.height))
        let size = CGSize(width: max(1, floor(image.size.width * scale)), height: max(1, floor(image.size.height * scale)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

private enum GalleryPrefetchedMedia {
    case image(GalleryPreparedImage)
    case video(GalleryPreparedVideo)

    var pixelCost: Int {
        if case .image(let image) = self { return image.pixelCost }
        return 0
    }
}

/// Bound speculative plaintext independently of the in-memory image budget.
private enum GalleryVaultVideoBudget {
    static let maxBytes: Int64 = 256 * 1024 * 1024
    static let freeReserve: Int64 = 512 * 1024 * 1024

    static func permits(encryptedBytes: Int64, availableBytes: Int64) -> Bool {
        encryptedBytes > 0 && encryptedBytes <= maxBytes
            && availableBytes >= freeReserve && encryptedBytes <= availableBytes - freeReserve
    }
}

private struct GalleryPreparedImage {
    var component: ImagePresentationComponent?
    var fallback: UIImage?
    var menuPreview: UIImage?
    var spatialMode: ImagePresentationComponent.ViewingMode = .mono
    var supportsSpatial = false
    var attemptedSpatial = false
    var status: String?
    var aspectRatio: Double
    var pixelCost: Int
}

/// Keeps generated objects alive between views. Spatial3DImage has no direct file API;
/// whole-Entity export dropped ImagePresentationComponent in the simulator probe.
@MainActor
private final class GallerySceneCache {
    static let shared = GallerySceneCache()
    static let prefetchOwnersDidChange = Notification.Name("GalleryPrefetchOwnersDidChange")
    static let prefetchVideoSlotDidChange = Notification.Name("GalleryPrefetchVideoSlotDidChange")
    private struct Entry {
        var image: GalleryPreparedImage
        var access: UInt64
    }
    private struct Pending {
        var id: UUID
        var task: Task<GalleryPreparedImage, Error>
        var consumers: Set<UUID>
        var foreground: Bool
    }
    private struct PendingVideo {
        var task: Task<GalleryPreparedVideo, Error>
        var consumers: Set<UUID>
        var foreground: Bool
    }
    private final class WeakVideo {
        weak var video: GalleryPreparedVideo?
        var access: UInt64
        init(_ video: GalleryPreparedVideo, access: UInt64) { self.video = video; self.access = access }
    }
    private var entries: [String: Entry] = [:]
    private var pending: [String: Pending] = [:]
    private var pendingVideos: [String: PendingVideo] = [:]
    private var completedVideos: [String: WeakVideo] = [:]
    private struct RetainedPrefetch {
        var media: GalleryPrefetchedMedia
        var owners: Set<UUID>
        var access: UInt64
    }
    private struct VideoPrerollReservation {
        var key: String
        var id: UUID
        var video: GalleryPreparedVideo
        var task: Task<Void, Never>
        var isReady: Bool
    }
    private var retainedPrefetch: [String: RetainedPrefetch] = [:]
    private var demands: [UUID: [String]] = [:]
    private var clock: UInt64 = 0
    private var warningObserver: NSObjectProtocol?
    private var vaultLockObserver: NSObjectProtocol?
    private var vaultHideObserver: NSObjectProtocol?
    private var photosAccessObserver: NSObjectProtocol?
    private var vaultGeneration = UUID()
    private var photosGeneration = UUID()
    private var hiddenSourceGenerations: [String: UUID] = [:]
    private var vaultVideoReservation: (key: String, id: UUID)?
    private var videoPrerollReservation: VideoPrerollReservation?
    var vaultVideoSlotAvailable: Bool { vaultVideoReservation == nil }
    var videoPrerollSlotAvailable: Bool { videoPrerollReservation == nil }
    private let generationGate = GalleryGenerationGate()

    private init() {
        vaultLockObserver = NotificationCenter.default.addObserver(
            forName: .galleryVaultWillLock, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearVault() }
        }
        vaultHideObserver = NotificationCenter.default.addObserver(
            forName: .galleryVaultDidHideItems, object: nil, queue: nil
        ) { [weak self] note in
            let ids = note.userInfo?["sourceIdentifierSet"] as? Set<String>
                ?? Set(note.userInfo?["sourceIdentifiers"] as? [String] ?? [])
            MainActor.assumeIsolated { self?.clearSources(ids) }
        }
        photosAccessObserver = NotificationCenter.default.addObserver(
            forName: .galleryPhotosAccessDidRevoke, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearPhotos() }
        }
        warningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.entries.removeAll()
                self?.completedVideos.removeAll()
                self?.clearSpeculativeVideoPreroll()
            }
        }
    }

    private func clearSources(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        func matches(_ key: String) -> Bool {
            GalleryMediaItem.sourceIdentifier(forCacheKey: key).map(ids.contains) ?? false
        }
        // Only in-flight operations need epochs; do not keep one entry per
        // photo when the user vaults a 100k-item album.
        let inFlight = Set(pending.keys.compactMap(GalleryMediaItem.sourceIdentifier(forCacheKey:)))
            .union(pendingVideos.keys.compactMap(GalleryMediaItem.sourceIdentifier(forCacheKey:)))
        for id in inFlight.intersection(ids) { hiddenSourceGenerations[id] = UUID() }
        for (key, value) in pending where matches(key) { value.task.cancel() }
        for (key, value) in pendingVideos where matches(key) { value.task.cancel() }
        if let key = videoPrerollReservation?.key, matches(key) { clearSpeculativeVideoPreroll() }
        pending = pending.filter { !matches($0.key) }
        pendingVideos = pendingVideos.filter { !matches($0.key) }
        entries = entries.filter { !matches($0.key) }
        completedVideos = completedVideos.filter { !matches($0.key) }
        retainedPrefetch = retainedPrefetch.filter { !matches($0.key) }
        removeDemandKeys(where: matches)
    }

    private func clearPhotos() {
        photosGeneration = UUID()
        for (key, value) in pending where !key.hasPrefix("vault:") { value.task.cancel() }
        for (key, value) in pendingVideos where !key.hasPrefix("vault:") { value.task.cancel() }
        if let key = videoPrerollReservation?.key, !key.hasPrefix("vault:") { clearSpeculativeVideoPreroll() }
        pending = pending.filter { $0.key.hasPrefix("vault:") }
        pendingVideos = pendingVideos.filter { $0.key.hasPrefix("vault:") }
        entries = entries.filter { $0.key.hasPrefix("vault:") }
        completedVideos = completedVideos.filter { $0.key.hasPrefix("vault:") }
        retainedPrefetch = retainedPrefetch.filter { $0.key.hasPrefix("vault:") }
        removeDemandKeys { !$0.hasPrefix("vault:") }
        hiddenSourceGenerations.removeAll()
    }

    private func clearVault() {
        vaultGeneration = UUID()
        if let key = vaultVideoReservation?.key { releaseVaultVideoReservation(key: key) }
        if videoPrerollReservation?.key.hasPrefix("vault:") == true { clearSpeculativeVideoPreroll() }
        for (key, value) in pending where key.hasPrefix("vault:") { value.task.cancel() }
        for (key, value) in pendingVideos where key.hasPrefix("vault:") { value.task.cancel() }
        pending = pending.filter { !$0.key.hasPrefix("vault:") }
        pendingVideos = pendingVideos.filter { !$0.key.hasPrefix("vault:") }
        entries = entries.filter { !$0.key.hasPrefix("vault:") }
        completedVideos = completedVideos.filter { !$0.key.hasPrefix("vault:") }
        retainedPrefetch = retainedPrefetch.filter { !$0.key.hasPrefix("vault:") }
        removeDemandKeys { $0.hasPrefix("vault:") }
    }

    private func removeDemandKeys(where shouldRemove: (String) -> Bool) {
        let previousOwnerCount = demands.count
        for (owner, keys) in demands {
            let remaining = keys.filter { !shouldRemove($0) }
            if remaining.isEmpty { demands.removeValue(forKey: owner) }
            else { demands[owner] = remaining }
        }
        if max(1, demands.count) != max(1, previousOwnerCount) {
            NotificationCenter.default.post(name: Self.prefetchOwnersDidChange, object: nil)
        }
    }

    static func key(for asset: GalleryMediaItem) -> String { asset.cacheKey }

    func promote(asset: GalleryMediaItem) {
        for suffix in [":scene", ":original"] {
            let key = Self.key(for: asset) + suffix
            if var item = pending[key] {
                item.foreground = true
                pending[key] = item
                generationGate.promote(key: key)
            }
        }
        let videoKey = Self.key(for: asset) + ":video"
        if var item = pendingVideos[videoKey] {
            item.foreground = true
            pendingVideos[videoKey] = item
            generationGate.promote(key: videoKey)
            releaseVaultVideoReservation(key: videoKey)
        }
    }

    private func releaseVaultVideoReservation(key: String, id: UUID? = nil) {
        guard let reservation = vaultVideoReservation, reservation.key == key,
              id == nil || reservation.id == id else { return }
        vaultVideoReservation = nil
        NotificationCenter.default.post(name: Self.prefetchVideoSlotDidChange, object: nil)
    }

    /// Schedule the only speculative AVPlayer across Photos and vault without blocking photo lookahead.
    func scheduleVideoPreroll(_ video: GalleryPreparedVideo, key: String) -> GalleryVideoPrerollOutcome {
        if video.hasPrerolledPlayer { return .alreadyPrepared }
        guard videoPrerollReservation == nil else { return .slotUnavailable }
        let id = UUID()
        video.onPrerollPromotion = { [weak self] in self?.cancelVideoPrerollForPromotion(key: key, id: id) }
        let task = Task { @MainActor [weak self, weak video] in
            guard let video else { return }
            do {
                try await video.preparePreroll(id: id)
                try Task.checkCancellation()
                guard let self, self.videoPrerollReservation?.id == id else {
                    video.discardPrerolledPlayer(expectedID: id)
                    return
                }
                video.onPrerollRelease = { [weak self] in self?.releaseVideoPreroll(key: key, id: id) }
                video.onPrerollConsumed = { [weak self] in self?.releaseVideoPreroll(key: key, id: id, consumed: true) }
                if var reservation = self.videoPrerollReservation {
                    reservation.isReady = true
                    self.videoPrerollReservation = reservation
                }
            } catch {
                guard let self else { video.discardPrerolledPlayer(expectedID: id); return }
                self.releaseVideoPreroll(key: key, id: id)
                video.discardPrerolledPlayer(expectedID: id)
            }
        }
        videoPrerollReservation = VideoPrerollReservation(key: key, id: id, video: video,
            task: task, isReady: false)
        return .scheduled
    }

    private func releaseVideoPreroll(key: String, id: UUID, consumed: Bool = false) {
        guard let reservation = videoPrerollReservation,
              reservation.key == key, reservation.id == id else { return }
        videoPrerollReservation = nil
        NotificationCenter.default.post(name: Self.prefetchVideoSlotDidChange, object: nil,
            userInfo: consumed ? ["consumedKey": key] : nil)
    }

    private func cancelVideoPrerollForPromotion(key: String, id: UUID) {
        guard let reservation = videoPrerollReservation,
              reservation.key == key, reservation.id == id,
              !reservation.isReady else { return }
        videoPrerollReservation = nil
        reservation.task.cancel()
        reservation.video.discardPrerolledPlayer(expectedID: id)
        NotificationCenter.default.post(name: Self.prefetchVideoSlotDidChange, object: nil)
    }

    /// Drop speculative decode work while leaving a foreground viewer's player alone.
    func clearSpeculativeVideoPreroll() {
        guard let reservation = videoPrerollReservation else { return }
        videoPrerollReservation = nil
        reservation.task.cancel()
        reservation.video.discardPrerolledPlayer(expectedID: reservation.id)
        NotificationCenter.default.post(name: Self.prefetchVideoSlotDidChange, object: nil)
    }

    func prefetchedVideo(key: String, owner: UUID) -> GalleryPreparedVideo? {
        guard let value = retainedPrefetch[key], value.owners.contains(owner),
              case .video(let video) = value.media else { return nil }
        return video
    }

    enum GalleryVideoPrerollOutcome: Equatable {
        case scheduled
        case alreadyPrepared
        case slotUnavailable
    }

    /// Borrow completed media without extending the lifetime of another window's private lease.
    func preparedVideo(for asset: GalleryMediaItem, foreground: Bool) -> GalleryPreparedVideo? {
        let assetKey = Self.key(for: asset)
        if var retained = retainedPrefetch[assetKey], case .video(let video) = retained.media,
           asset.vaultRecord == nil || GalleryVaultStorage.shared.isUnlocked {
            clock &+= 1
            retained.access = clock
            if foreground && video.isVault {
                retainedPrefetch.removeValue(forKey: assetKey)
                video.promote()
            } else {
                retainedPrefetch[assetKey] = retained
                if foreground { video.promote() }
            }
            return video
        }
        guard asset.vaultRecord == nil || GalleryVaultStorage.shared.isUnlocked else { return nil }
        guard let entry = completedVideos[assetKey], let video = entry.video else {
            completedVideos.removeValue(forKey: assetKey)
            return nil
        }
        clock &+= 1
        entry.access = clock
        if foreground { video.promote() }
        return video
    }

    private func rememberVideo(_ video: GalleryPreparedVideo, key: String) {
        completedVideos = completedVideos.filter { $0.value.video != nil }
        clock &+= 1
        completedVideos[key] = WeakVideo(video, access: clock)
        while completedVideos.count > GalleryViewerPreferences.globalPrefetchItemBudget {
            guard let oldest = completedVideos.min(by: { $0.value.access < $1.value.access })?.key else { break }
            completedVideos.removeValue(forKey: oldest)
        }
    }

    /// Share in-flight work while bounding speculative leases and keeping independent consumers.
    func video(for asset: GalleryMediaItem, foreground: Bool) async throws -> GalleryPreparedVideo {
        let assetKey = Self.key(for: asset)
        if let ready = preparedVideo(for: asset, foreground: foreground) { return ready }
        let expectedVaultGeneration = vaultGeneration
        let expectedPhotosGeneration = photosGeneration
        let expectedSourceGeneration = hiddenSourceGenerations[asset.localIdentifier]
        let key = assetKey + ":video"
        let consumer = UUID()
        let task: Task<GalleryPreparedVideo, Error>
        // Join a live task or start a new one so cancelled work cannot poison the next foreground request.
        if var existing = pendingVideos[key], !existing.task.isCancelled {
            existing.consumers.insert(consumer)
            existing.foreground = existing.foreground || foreground
            if foreground {
                generationGate.promote(key: key)
                releaseVaultVideoReservation(key: key)
            }
            pendingVideos[key] = existing
            task = existing.task
        } else {
            task = Task(priority: foreground ? .userInitiated : .utility) { @MainActor [self] in
                try await generationGate.acquire(key: key, foreground: pendingVideos[key]?.foreground ?? foreground)
                defer { generationGate.release() }
                try Task.checkCancellation()
                var reservationID: UUID?
                // Reserve only a safe amount of temporary plaintext before decrypting a speculative video.
                if let record = asset.vaultRecord, pendingVideos[key]?.foreground != true {
                    guard vaultVideoReservation == nil else { throw GalleryMediaError.prefetchVideoSlotUnavailable }
                    guard let resource = GalleryVaultResourceSelection.displayResource(for: record)
                    else { throw GalleryMediaError.missingMedia }
                    let id = UUID()
                    vaultVideoReservation = (key, id)
                    reservationID = id
                    do {
                        let (bytes, available) = try await GalleryVaultStorage.shared.speculativeResourceSpace(
                            recordID: record.id, resourceID: resource.id)
                        try Task.checkCancellation()
                        guard GalleryVaultVideoBudget.permits(encryptedBytes: bytes, availableBytes: available)
                            || pendingVideos[key]?.foreground == true else {
                            throw GalleryMediaError.prefetchBudgetExceeded
                        }
                    } catch {
                        releaseVaultVideoReservation(key: key, id: id)
                        throw error
                    }
                }
                // Transfer the reservation to the resulting lease so cleanup controls when the slot is reusable.
                var videoProduced = false
                do {
                    let video = try await GalleryVaultMediaRequest.video(asset)
                    videoProduced = true
                    if pendingVideos[key]?.foreground == true { video.promote() }
                    if let reservationID, vaultVideoReservation?.id == reservationID {
                        video.onPrefetchRelease = { [weak self] in
                            self?.releaseVaultVideoReservation(key: key, id: reservationID)
                        }
                    }
                    try Task.checkCancellation()
                    return video
                } catch {
                    // Keep the slot until a failed temporary-file cleanup can be retried.
                    if !videoProduced, let reservationID, GalleryVaultStorage.shared.cleanupWarning == nil {
                        releaseVaultVideoReservation(key: key, id: reservationID)
                    }
                    throw error
                }
            }
            pendingVideos[key] = PendingVideo(task: task, consumers: [consumer], foreground: foreground)
        }
        return try await withTaskCancellationHandler {
            defer { releaseVideo(key: key, consumer: consumer) }
            let result = try await GalleryMediaRequest.value(of: task)
            try Task.checkCancellation()
            guard (asset.vaultRecord == nil || (vaultGeneration == expectedVaultGeneration && GalleryVaultStorage.shared.isUnlocked)),
                  (asset.vaultRecord != nil || photosGeneration == expectedPhotosGeneration),
                  hiddenSourceGenerations[asset.localIdentifier] == expectedSourceGeneration else {
                throw CancellationError()
            }
            rememberVideo(result, key: assetKey)
            return result
        } onCancel: {
            Task { @MainActor in self.releaseVideo(key: key, consumer: consumer) }
        }
    }

    private func releaseVideo(key: String, consumer: UUID) {
        guard var item = pendingVideos[key], item.consumers.remove(consumer) != nil else { return }
        if item.consumers.isEmpty {
            item.task.cancel()
            pendingVideos.removeValue(forKey: key)
        } else {
            pendingVideos[key] = item
        }
    }

    /// Release reservations no longer wanted by this window and rebalance the shared cache.
    func updatePrefetchDemand(owner: UUID, orderedKeys: [String]) {
        let previousOwnerCount = demands.count
        if orderedKeys.isEmpty { demands.removeValue(forKey: owner) }
        else { demands[owner] = orderedKeys }
        for key in Array(retainedPrefetch.keys) where !orderedKeys.contains(key) {
            guard var value = retainedPrefetch[key] else { continue }
            value.owners.remove(owner)
            if value.owners.isEmpty { retainedPrefetch.removeValue(forKey: key) }
            else { retainedPrefetch[key] = value }
        }
        trimPrefetchRetentions()
        if max(1, demands.count) != max(1, previousOwnerCount) {
            NotificationCenter.default.post(name: Self.prefetchOwnersDidChange, object: nil)
        }
    }

    var prefetchOwnerCount: Int { max(1, demands.count) }

    func hasPrefetched(_ key: String, owner: UUID) -> Bool {
        retainedPrefetch[key]?.owners.contains(owner) == true
    }

    func retainedPixels(owner: UUID) -> Int {
        retainedPrefetch.values.filter { $0.owners.contains(owner) }
            .reduce(0) { $0 + $1.media.pixelCost }
    }

    func retainPrefetched(_ media: GalleryPrefetchedMedia, key: String, owner: UUID) -> Bool {
        guard demands[owner]?.contains(key) == true else { return false }
        // A promoted vault lease must not outlive its foreground viewer as speculation.
        if case .video(let video) = media, video.isVault && video.isForeground { return false }
        let ownerCount = max(1, demands.count)
        let itemShare = max(1, GalleryViewerPreferences.globalPrefetchItemBudget / ownerCount)
        let pixelShare = max(1, GalleryViewerPreferences.globalPrefetchPixelBudget / ownerCount)
        let ownerItems = retainedPrefetch.values.filter { $0.owners.contains(owner) }
        let alreadyOwns = retainedPrefetch[key]?.owners.contains(owner) == true
        guard alreadyOwns || (ownerItems.count < itemShare
            && ownerItems.reduce(0, { $0 + $1.media.pixelCost }) + media.pixelCost <= pixelShare) else { return false }
        if var existing = retainedPrefetch[key] {
            existing.owners.insert(owner)
            existing.access = clock
            retainedPrefetch[key] = existing
            return true
        }
        let ownerPixels = ownerItems.reduce(0) { $0 + $1.media.pixelCost }
        let prepared = uniquePreparedResults()
        let resultKey = retainedResultKey(key, media: media)
        let addsUniqueResult = prepared[resultKey] == nil
        let globalPixels = prepared.values.reduce(0, +)
        guard ownerItems.count < itemShare, ownerPixels + media.pixelCost <= pixelShare,
              prepared.count + (addsUniqueResult ? 1 : 0) <= GalleryViewerPreferences.globalPrefetchItemBudget,
              globalPixels + (addsUniqueResult ? media.pixelCost : 0) <= GalleryViewerPreferences.globalPrefetchPixelBudget else { return false }
        retainedPrefetch[key] = RetainedPrefetch(media: media, owners: [owner], access: clock)
        return true
    }

    func takePrefetched(key: String, owner: UUID) -> GalleryPrefetchedMedia? {
        guard var value = retainedPrefetch[key], value.owners.remove(owner) != nil else { return nil }
        let result = value.media
        if case .video(let video) = result, video.isVault {
            video.promote()
            retainedPrefetch.removeValue(forKey: key)
        } else if value.owners.isEmpty { retainedPrefetch.removeValue(forKey: key) }
        else { retainedPrefetch[key] = value }
        return result
    }

    private func trimPrefetchRetentions() {
        if let reservation = videoPrerollReservation,
           !demands.values.contains(where: { $0.contains(reservation.key) }) {
            clearSpeculativeVideoPreroll()
        }
        let ownerCount = max(1, demands.count)
        let itemShare = max(1, GalleryViewerPreferences.globalPrefetchItemBudget / ownerCount)
        let pixelShare = max(1, GalleryViewerPreferences.globalPrefetchPixelBudget / ownerCount)
        for (owner, orderedKeys) in demands {
            var usedItems = 0
            var usedPixels = 0
            var allowed: Set<String> = []
            for key in orderedKeys {
                guard let value = retainedPrefetch[key], value.owners.contains(owner),
                      usedItems < itemShare, usedPixels + value.media.pixelCost <= pixelShare else { continue }
                usedItems += 1
                usedPixels += value.media.pixelCost
                allowed.insert(key)
            }
            for key in orderedKeys where !allowed.contains(key) {
                guard var value = retainedPrefetch[key], value.owners.remove(owner) != nil else { continue }
                if value.owners.isEmpty { retainedPrefetch.removeValue(forKey: key) }
                else { retainedPrefetch[key] = value }
            }
        }
        trimGlobalPreparedResults()
    }

    private func retainedResultKey(_ key: String, media: GalleryPrefetchedMedia) -> String {
        if case .image(let image) = media {
            return key + (image.attemptedSpatial ? ":scene" : ":original")
        }
        return key + ":video"
    }

    /// Count a prepared image once when both the active LRU and a viewer's
    /// speculative reservation point to the same component.
    private func uniquePreparedResults() -> [String: Int] {
        var result = entries.mapValues { $0.image.pixelCost }
        for (key, retained) in retainedPrefetch {
            let resultKey = retainedResultKey(key, media: retained.media)
            if result[resultKey] == nil { result[resultKey] = retained.media.pixelCost }
        }
        return result
    }

    private func trimGlobalPreparedResults() {
        func overBudget() -> Bool {
            let results = uniquePreparedResults()
            return results.count > GalleryViewerPreferences.globalPrefetchItemBudget
                || results.values.reduce(0, +) > GalleryViewerPreferences.globalPrefetchPixelBudget
        }
        while overBudget() {
            // Visible images already have an owner. Evict unreserved LRU entries
            // before discarding a playlist's prepared next scene.
            let reserved = Set(retainedPrefetch.map { retainedResultKey($0.key, media: $0.value.media) })
            if let oldest = entries.filter({ !reserved.contains($0.key) }).min(by: { $0.value.access < $1.value.access })?.key {
                entries.removeValue(forKey: oldest)
                continue
            }
            if let oldest = retainedPrefetch.min(by: { $0.value.access < $1.value.access })?.key,
               let retained = retainedPrefetch[oldest] {
                let resultKey = retainedResultKey(oldest, media: retained.media)
                retainedPrefetch.removeValue(forKey: oldest)
                entries.removeValue(forKey: resultKey)
                continue
            }
            guard let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key else { break }
            entries.removeValue(forKey: oldest)
        }
    }

    func preparedImage(for asset: GalleryMediaItem, spatial: Bool) -> GalleryPreparedImage? {
        guard asset.vaultRecord == nil || GalleryVaultStorage.shared.isUnlocked else { return nil }
        let assetKey = Self.key(for: asset)
        let key = assetKey + (spatial ? ":scene" : ":original")
        clock &+= 1
        if var entry = entries[key] ?? entries[assetKey + ":scene"] {
            entry.access = clock
            entries[entries[key] != nil ? key : assetKey + ":scene"] = entry
            return entry.image
        }
        return nil
    }

    func image(for asset: GalleryMediaItem, spatial: Bool, foreground: Bool = true, pixelBudget: Int? = nil) async throws -> GalleryPreparedImage {
        let assetKey = Self.key(for: asset)
        let expectedVaultGeneration = vaultGeneration
        let expectedPhotosGeneration = photosGeneration
        let expectedSourceGeneration = hiddenSourceGenerations[asset.localIdentifier]
        let key = assetKey + (spatial ? ":scene" : ":original")
        if let ready = preparedImage(for: asset, spatial: spatial) { return ready }
        let consumer = UUID()
        let task: Task<GalleryPreparedImage, Error>
        if var existing = pending[key], !existing.task.isCancelled {
            existing.consumers.insert(consumer)
            existing.foreground = existing.foreground || foreground
            if foreground { generationGate.promote(key: key) }
            pending[key] = existing
            task = existing.task
        } else {
            let jobID = UUID()
            task = Task(priority: foreground ? .userInitiated : .utility) { @MainActor in
                try await generationGate.acquire(key: key, foreground: pending[key]?.foreground ?? foreground)
                defer { generationGate.release() }
                try Task.checkCancellation()
                // Bound PhotoKit fetch, decoding, and scene generation as one job.
                let data = try await GalleryVaultMediaRequest.imageData(asset)
                do {
                    return try await Self.prepare(data: data, spatial: spatial) {
                        // Recheck after decoding; another viewer may have promoted
                        // this request while the detached decoder was running.
                        pending[key]?.foreground == true ? nil : pixelBudget
                    }
                } catch {
                    // Do not let a foreground consumer join a completed speculative
                    // budget rejection. A new foreground request has no such budget.
                    if case GalleryMediaError.prefetchBudgetExceeded = error,
                       pending[key]?.id == jobID { pending.removeValue(forKey: key) }
                    throw error
                }
            }
            pending[key] = Pending(id: jobID, task: task, consumers: [consumer], foreground: foreground)
        }
        // A cancelled window returns immediately even while another window still
        // needs this shared task. The small waiter holds no view or media model.
        let delivery = GalleryMediaRequest<GalleryPreparedImage>()
        return try await withTaskCancellationHandler {
            defer { release(key: key, consumer: consumer) }
            let image = try await withCheckedThrowingContinuation { continuation in
                guard delivery.start(continuation) else { return }
                Task { @MainActor in
                    do { delivery.finish(.success(try await task.value)) }
                    catch { delivery.finish(.failure(error)) }
                }
            }
            try Task.checkCancellation()
            guard (asset.vaultRecord == nil || (vaultGeneration == expectedVaultGeneration && GalleryVaultStorage.shared.isUnlocked)),
                  (asset.vaultRecord != nil || photosGeneration == expectedPhotosGeneration),
                  hiddenSourceGenerations[asset.localIdentifier] == expectedSourceGeneration else {
                throw CancellationError()
            }
            clock &+= 1
            entries[key] = Entry(image: image, access: clock)
            trim()
            return image
        } onCancel: {
            delivery.cancel()
            Task { @MainActor in self.release(key: key, consumer: consumer) }
        }
    }

    private func release(key: String, consumer: UUID) {
        guard var item = pending[key], item.consumers.remove(consumer) != nil else { return }
        if item.consumers.isEmpty {
            item.task.cancel()
            pending.removeValue(forKey: key)
        } else {
            pending[key] = item
        }
    }

    private func trim() {
        trimGlobalPreparedResults()
    }

    private static func prepare(data: Data, spatial: Bool, pixelBudget: () -> Int?) async throws -> GalleryPreparedImage {
        let decoded = try await Task.detached(priority: .userInitiated) {
            try GalleryDecodedImage(data: data)
        }.value
        try Task.checkCancellation()
        let menuPreview = GalleryMenuPreview.make(from: decoded.preview)
        let menuPreviewCost = menuPreview.cgImage.map { $0.width * $0.height } ?? 0
        if let pixelBudget = pixelBudget(), decoded.pixelCost + menuPreviewCost > pixelBudget { throw GalleryMediaError.prefetchBudgetExceeded }
        var result = GalleryPreparedImage(
            menuPreview: menuPreview,
            attemptedSpatial: spatial,
            aspectRatio: Double(decoded.preview.size.width / decoded.preview.size.height),
            pixelCost: decoded.pixelCost + menuPreviewCost
        )
        result.supportsSpatial = decoded.canGenerate
        #if targetEnvironment(simulator)
        // Simulator cannot generate spatial scenes, but it can render the real
        // image component. Use it so layout tests cover the native media plane.
        do {
            result.component = try await ImagePresentationComponent(imageSource: decoded.source)
        } catch {
            result.fallback = decoded.preview
        }
        try Task.checkCancellation()
        if spatial {
            result.status = "Spatial scenes need Apple Vision Pro. Showing Original in Simulator."
        }
        return result
        #else
        if spatial && decoded.canGenerate {
            do {
                let scene = try await ImagePresentationComponent.Spatial3DImage(imageSource: decoded.source)
                try Task.checkCancellation()
                try await scene.generate()
                try Task.checkCancellation()
                result.component = ImagePresentationComponent(spatial3DImage: scene)
                result.spatialMode = .spatial3D
                return result
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if decoded.canRetryGeneration,
                   let retryPlan = decoded.retryPlan,
                   GalleryRetryBudget.permits(
                       sourcePixels: decoded.pixelCost + decoded.previewPixelCost + menuPreviewCost,
                       retryPixels: retryPlan.pixelCost,
                       availablePixels: pixelBudget()
                   ) {
                    do {
                        try Task.checkCancellation()
                        let retrySource = try await decoded.makeRetrySource(retryPlan)
                        try Task.checkCancellation()
                        guard GalleryRetryBudget.permits(
                            sourcePixels: decoded.pixelCost + decoded.previewPixelCost + menuPreviewCost,
                            retryPixels: retrySource.pixelCost,
                            availablePixels: pixelBudget()
                        ) else {
                            throw GalleryMediaError.prefetchBudgetExceeded
                        }
                        let retry = try await ImagePresentationComponent.Spatial3DImage(imageSource: retrySource.source)
                        try Task.checkCancellation()
                        try await retry.generate()
                        try Task.checkCancellation()
                        result.component = ImagePresentationComponent(spatial3DImage: retry)
                        result.spatialMode = .spatial3D
                        result.pixelCost = retrySource.pixelCost + menuPreviewCost
                        return result
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch GalleryMediaError.prefetchBudgetExceeded {
                        result.status = "Could not create a spatial scene. Showing Original."
                    } catch {
                        result.status = "Could not create a spatial scene. Showing Original."
                    }
                } else {
                    result.status = "Could not create a spatial scene. Showing Original."
                }
            }
        } else if spatial {
            result.status = "Spatial Scene isn’t available for this photo. Showing Original."
        }
        do {
            result.component = try await ImagePresentationComponent(imageSource: decoded.source)
        } catch {
            result.fallback = decoded.preview
            result.pixelCost = decoded.previewPixelCost + menuPreviewCost
            if result.status == nil { result.status = "Showing Original." }
        }
        try Task.checkCancellation()
        return result
        #endif
    }
}

/// A cancelled queued swipe leaves the queue immediately, without decoding its image.
@MainActor
private final class GalleryGenerationGate {
    private var activeJobs = 0
    private let maximumJobs = GalleryViewerPreferences.globalPreparationJobLimit
    private struct Waiter {
        var id: UUID
        var key: String
        var foreground: Bool
        var continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []

    func promote(key: String) {
        if let index = waiters.firstIndex(where: { $0.key == key }) {
            waiters[index].foreground = true
        }
    }

    func acquire(key: String, foreground: Bool) async throws {
        try Task.checkCancellation()
        if activeJobs < maximumJobs { activeJobs += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, key: key, foreground: foreground, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor in
                if let index = self.waiters.firstIndex(where: { $0.id == id }) {
                    self.waiters.remove(at: index).continuation.resume(throwing: CancellationError())
                }
            }
        }
    }
    func release() {
        activeJobs = max(0, activeJobs - 1)
        while activeJobs < maximumJobs, !waiters.isEmpty {
            let next = waiters.firstIndex(where: { $0.foreground }) ?? 0
            let waiter = waiters.remove(at: next)
            activeJobs += 1
            waiter.continuation.resume()
        }
    }
}

private nonisolated struct GalleryDecodedImage: @unchecked Sendable {
    let source: CGImageSource
    let preview: UIImage
    let pixelCost: Int
    let previewPixelCost: Int
    let canGenerate: Bool
    let canRetryGeneration: Bool
    let retryPlan: GalleryImageSizePlan?
    private let thumbnail: CGImage

    init(data: Data) throws {
        guard let original = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw GalleryMediaError.invalidImage
        }
        let groups = (CGImageSourceCopyProperties(original, nil) as? [CFString: Any])?[kCGImagePropertyGroups]
            as? [[CFString: Any]] ?? []
        let stereoPair = groups.first {
            ($0[kCGImagePropertyGroupType] as? String) == (kCGImagePropertyGroupTypeStereoPair as String)
        }
        let leftIndex = stereoPair?[kCGImagePropertyGroupImageIndexLeft] as? Int
        let imageIndex = leftIndex.flatMap { (0..<CGImageSourceGetCount(original)).contains($0) ? $0 : nil }
            ?? CGImageSourceGetPrimaryImageIndex(original)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(original, imageIndex, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw GalleryMediaError.invalidImage }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2560,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(original, imageIndex, options as CFDictionary) else {
            throw GalleryMediaError.invalidImage
        }
        self.thumbnail = thumbnail
        // The full preview is temporary; prepared entries retain only a bounded512px menu preview.
        previewPixelCost = thumbnail.width * thumbnail.height
        preview = UIImage(cgImage: thumbnail)
        // Bake the selected eye's orientation and color into one bounded in-memory source.
        let ratio = Double(width) / Double(height)
        let shortEdge = min(thumbnail.width, thumbnail.height)
        let spatialCandidate = ratio >= 1.0 / 3.0 && ratio <= 3.0
        let spatialSource: CGImage
        if spatialCandidate && shortEdge < 320 {
            let scale = CGFloat(320) / CGFloat(shortEdge)
            let targetWidth = max(1, Int((CGFloat(thumbnail.width) * scale).rounded()))
            let targetHeight = max(1, Int((CGFloat(thumbnail.height) * scale).rounded()))
            guard let context = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: thumbnail.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw GalleryMediaError.invalidImage }
            context.interpolationQuality = .high
            context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            guard let upscaled = context.makeImage() else { throw GalleryMediaError.invalidImage }
            spatialSource = upscaled
        } else {
            spatialSource = thumbnail
        }
        let resized = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(resized, UTType.png.identifier as CFString, 1, nil) else {
            throw GalleryMediaError.invalidImage
        }
        CGImageDestinationAddImage(destination, spatialSource, nil)
        guard CGImageDestinationFinalize(destination),
              let bounded = CGImageSourceCreateWithData(resized, nil) else { throw GalleryMediaError.invalidImage }
        source = bounded
        pixelCost = spatialSource.width * spatialSource.height
        canGenerate = spatialCandidate
        canRetryGeneration = spatialCandidate
            && min(thumbnail.width, thumbnail.height) < 1024
        retryPlan = canRetryGeneration
            ? GalleryImageSizePlan(sourceWidth: thumbnail.width, sourceHeight: thumbnail.height, shortEdge: 1024, maximumLongEdge: 3072)
            : nil
    }

    func makeRetrySource(_ plan: GalleryImageSizePlan) async throws -> GalleryGeneratedSource {
        try Task.checkCancellation()
        let image = thumbnail
        let renderTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try Self.makeSource(from: image, plan: plan)
        }
        return try await withTaskCancellationHandler {
            try await renderTask.value
        } onCancel: {
            renderTask.cancel()
        }
    }

    private static func makeSource(from image: CGImage, plan: GalleryImageSizePlan) throws -> GalleryGeneratedSource {
        guard let context = CGContext(
            data: nil,
            width: plan.width,
            height: plan.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw GalleryMediaError.invalidImage }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: plan.width, height: plan.height))
        guard let upscaled = context.makeImage() else { throw GalleryMediaError.invalidImage }
        let resized = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(resized, UTType.png.identifier as CFString, 1, nil) else {
            throw GalleryMediaError.invalidImage
        }
        CGImageDestinationAddImage(destination, upscaled, nil)
        guard CGImageDestinationFinalize(destination),
              let source = CGImageSourceCreateWithData(resized, nil) else { throw GalleryMediaError.invalidImage }
        return GalleryGeneratedSource(source: source, pixelCost: upscaled.width * upscaled.height)
    }
}

private nonisolated struct GalleryImageSizePlan: Sendable {
    let width: Int
    let height: Int
    var pixelCost: Int { width * height }

    init?(sourceWidth: Int, sourceHeight: Int, shortEdge: Int, maximumLongEdge: Int) {
        guard sourceWidth > 0, sourceHeight > 0, shortEdge > 0, maximumLongEdge >= shortEdge else { return nil }
        let scale = min(
            CGFloat(shortEdge) / CGFloat(min(sourceWidth, sourceHeight)),
            CGFloat(maximumLongEdge) / CGFloat(max(sourceWidth, sourceHeight))
        )
        width = max(1, Int((CGFloat(sourceWidth) * scale).rounded()))
        height = max(1, Int((CGFloat(sourceHeight) * scale).rounded()))
    }
}

private nonisolated struct GalleryGeneratedSource: @unchecked Sendable {
    let source: CGImageSource
    let pixelCost: Int
}

private nonisolated enum GalleryRetryBudget {
    static func permits(sourcePixels: Int, retryPixels: Int, availablePixels: Int?) -> Bool {
        guard let availablePixels else { return true }
        return sourcePixels >= 0 && retryPixels >= 0 && sourcePixels + retryPixels <= availablePixels
    }
}

private nonisolated enum GalleryMediaError: LocalizedError {
    case invalidImage, missingMedia, prefetchBudgetExceeded, prefetchVideoSlotUnavailable, videoPrerollFailed
    var errorDescription: String? {
        switch self {
        case .prefetchBudgetExceeded: return "This photo exceeds the lookahead memory budget."
        case .prefetchVideoSlotUnavailable: return "A private video is already being prepared."
        case .videoPrerollFailed: return "This video could not be prepared for playback."
        case .invalidImage: return "This photo could not be opened."
        case .missingMedia: return "Photos could not load this item. Check your connection if it is stored in iCloud."
        }
    }
}

/// A completion bridge for PhotoKit callbacks and shared scene task waiters.
/// PhotoKit may call back before it returns its request ID, or after cancellation.
/// This lock owns both the continuation and request ID to cover all three races.
private nonisolated final class GalleryMediaRequest<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var requestID: PHImageRequestID?
    private var finished = false
    private var cancelled = false

    @MainActor static func value(of task: Task<Value, Error>) async throws -> Value {
        let delivery = GalleryMediaRequest<Value>()
        return try await withTaskCancellationHandler {
            let value = try await withCheckedThrowingContinuation { continuation in
                guard delivery.start(continuation) else { return }
                Task { @MainActor in
                    do { delivery.finish(.success(try await task.value)) }
                    catch { delivery.finish(.failure(error)) }
                }
            }
            try Task.checkCancellation()
            return value
        } onCancel: { delivery.cancel() }
    }

    func start(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func install(_ id: PHImageRequestID) {
        lock.lock()
        let shouldCancel = cancelled
        if !finished { requestID = id }
        lock.unlock()
        if shouldCancel { PHImageManager.default().cancelImageRequest(id) }
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = continuation
        self.continuation = nil
        requestID = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func cancel() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        cancelled = true
        let continuation = continuation
        let id = requestID
        self.continuation = nil
        requestID = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
        if let id { PHImageManager.default().cancelImageRequest(id) }
    }
}

private extension GalleryMediaRequest where Value == Data {
    static func imageData(_ asset: PHAsset) async throws -> Data {
        let request = GalleryMediaRequest<Data>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard request.start(continuation) else { return }
                let options = PHImageRequestOptions()
                options.isNetworkAccessAllowed = true
                options.deliveryMode = .highQualityFormat
                options.version = asset.mediaSubtypes.contains(.spatialMedia) ? .original : .current
                let id = PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                    if (info?[PHImageCancelledKey] as? Bool) == true { request.finish(.failure(CancellationError())) }
                    else if let error = info?[PHImageErrorKey] as? Error { request.finish(.failure(error)) }
                    else if (info?[PHImageResultIsDegradedKey] as? Bool) != true {
                        request.finish(data.map(Result.success) ?? .failure(GalleryMediaError.missingMedia))
                    }
                }
                request.install(id)
            }
        } onCancel: { request.cancel() }
    }
}

private extension GalleryMediaRequest where Value == AVAsset {
    static func video(_ asset: PHAsset) async throws -> AVAsset {
        let request = GalleryMediaRequest<AVAsset>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard request.start(continuation) else { return }
                let options = PHVideoRequestOptions()
                options.isNetworkAccessAllowed = true
                options.deliveryMode = .highQualityFormat
                options.version = asset.mediaSubtypes.contains(.spatialMedia) ? .original : .current
                let id = PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                    if (info?[PHImageCancelledKey] as? Bool) == true { request.finish(.failure(CancellationError())) }
                    else if let error = info?[PHImageErrorKey] as? Error { request.finish(.failure(error)) }
                    else { request.finish(avAsset.map(Result.success) ?? .failure(GalleryMediaError.missingMedia)) }
                }
                request.install(id)
            }
        } onCancel: { request.cancel() }
    }
}

/// Retains a decrypted video only while a player or prefetch reservation needs it.
@MainActor
private final class GalleryPreparedVideo {
    let asset: AVAsset
    private let plaintextURL: URL?
    var onPrefetchRelease: (@MainActor () -> Void)?
    var onPrerollRelease: (@MainActor () -> Void)?
    var onPrerollConsumed: (@MainActor () -> Void)?
    var onPrerollPromotion: (@MainActor () -> Void)?
    private var prerolledPlayer: AVPlayer?
    private var prerolledItem: AVPlayerItem?
    private var prerollCompletion: GalleryPrerollCompletion?
    private var prerollID: UUID?
    private var prerollCancelled = false
    var isSpatialVideo = false
    var aspectRatio: Double?
    private(set) var isForeground = false
    var isVault: Bool { plaintextURL != nil }
    var hasPrerolledPlayer: Bool { prerolledPlayer != nil }
    init(asset: AVAsset, plaintextURL: URL? = nil) {
        self.asset = asset
        self.plaintextURL = plaintextURL
    }

    deinit {
        if let plaintextURL {
            let releaseLease = onPrefetchRelease
            let releasePreroll = onPrerollRelease
            Task { @MainActor in
                if GalleryVaultStorage.shared.releasePlaintext(plaintextURL) { releaseLease?() }
                releasePreroll?()
            }
        } else if let onPrefetchRelease, let onPrerollRelease {
            Task { @MainActor in onPrefetchRelease(); onPrerollRelease() }
        } else if let onPrefetchRelease {
            Task { @MainActor in onPrefetchRelease() }
        } else if let onPrerollRelease {
            Task { @MainActor in onPrerollRelease() }
        }
    }

    func promote() {
        isForeground = true
        onPrefetchRelease?()
        onPrefetchRelease = nil
        onPrerollPromotion?()
        onPrerollPromotion = nil
    }

    /// Transfer the ready speculative player once; later windows create independent playback.
    func takePrerolledPlayer() -> AVPlayer? {
        guard let player = prerolledPlayer, let item = prerolledItem,
              player.currentItem === item, player.status == .readyToPlay,
              item.status == .readyToPlay, prerollID != nil else {
            if let activeID = prerollID { discardPrerolledPlayer(expectedID: activeID) }
            return nil
        }
        item.preferredForwardBufferDuration = 0
        prerolledPlayer = nil
        prerolledItem = nil
        prerollID = nil
        player.isMuted = false
        player.volume = 1
        onPrerollConsumed?()
        onPrerollConsumed = nil
        onPrerollRelease?()
        onPrerollRelease = nil
        onPrerollPromotion = nil
        return player
    }

    /// Cancel only this attempt so an old callback cannot discard a newer player.
    func discardPrerolledPlayer(expectedID: UUID) {
        guard prerollID == expectedID else { return }
        prerollID = nil
        prerollCancelled = true
        prerollCompletion?.finish(.failure(CancellationError()))
        prerollCompletion = nil
        onPrerollConsumed = nil
        onPrerollPromotion = nil
        prerolledPlayer?.cancelPendingPrerolls()
        prerolledPlayer?.pause()
        prerolledPlayer?.replaceCurrentItem(with: nil)
        prerolledPlayer = nil
        prerolledItem = nil
        onPrerollRelease?()
        onPrerollRelease = nil
    }

    /// Prepare a paused, muted player only after both AVPlayer and AVPlayerItem report readyToPlay.
    func preparePreroll(id: UUID) async throws {
        try Task.checkCancellation()
        if let prerolledPlayer {
            guard prerollID == id else { throw CancellationError() }
            return
        }
        prerollID = id
        prerollCancelled = false
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 1.5
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.volume = 0
        player.actionAtItemEnd = .pause
        player.pause()
        prerolledItem = item
        prerolledPlayer = player
        do {
            try await waitUntilReady(item, player: player, id: id)
            try Task.checkCancellation()
            guard prerollID == id, item.status == .readyToPlay, player.status == .readyToPlay else {
                throw GalleryMediaError.videoPrerollFailed
            }
            let completion = GalleryPrerollCompletion()
            prerollCompletion = completion
            let timeout = Task {
                try? await Task.sleep(for: .seconds(6))
                if !Task.isCancelled { completion.finish(.failure(GalleryMediaError.videoPrerollFailed)) }
            }
            defer { timeout.cancel() }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    completion.install(continuation)
                    guard !Task.isCancelled else {
                        completion.finish(.failure(CancellationError()))
                        return
                    }
                    player.preroll(atRate: 1) { finished in
                        completion.finish(finished
                            ? .success(())
                            : .failure(GalleryMediaError.videoPrerollFailed))
                    }
                }
            } onCancel: {
                player.cancelPendingPrerolls()
                player.pause()
                completion.finish(.failure(CancellationError()))
            }
            if prerollID == id, prerollCompletion === completion { prerollCompletion = nil }
            try Task.checkCancellation()
            guard prerollID == id, item.status == .readyToPlay,
                  player.status == .readyToPlay else { throw GalleryMediaError.videoPrerollFailed }
            player.pause()
        } catch {
            player.cancelPendingPrerolls()
            player.pause()
            player.replaceCurrentItem(with: nil)
            discardPrerolledPlayer(expectedID: id)
            throw error
        }
    }

    /// Bound readiness waits without blocking the main actor or assuming item readiness implies player readiness.
    private func waitUntilReady(_ item: AVPlayerItem, player: AVPlayer, id: UUID) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(6))
        // Yield between status checks so cancellation and foreground promotion can run.
        while true {
            try Task.checkCancellation()
            if prerollID != id || prerollCancelled { throw CancellationError() }
            switch item.status {
            case .readyToPlay: break
            case .failed: throw item.error ?? GalleryMediaError.videoPrerollFailed
            case .unknown: break
            @unknown default: throw GalleryMediaError.videoPrerollFailed
            }
            switch player.status {
            case .readyToPlay:
                if item.status == .readyToPlay { return }
            case .failed:
                throw player.error ?? GalleryMediaError.videoPrerollFailed
            case .unknown: break
            @unknown default: throw GalleryMediaError.videoPrerollFailed
            }
            guard clock.now < deadline else { throw GalleryMediaError.videoPrerollFailed }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Bridges AVPlayer's callback into an async wait that cancellation and timeout can always finish.
private nonisolated final class GalleryPrerollCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        let result = self.result
        if result == nil { self.continuation = continuation }
        lock.unlock()
        if let result { continuation.resume(with: result) }
    }

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

@MainActor
private enum GalleryVaultMediaRequest {
    static func imageData(_ item: GalleryMediaItem) async throws -> Data {
        switch item {
        case .photos(let asset):
            return try await GalleryMediaRequest<Data>.imageData(asset)
        case .vault(let record):
            guard GalleryVaultStorage.shared.isUnlocked,
                  let resource = GalleryVaultResourceSelection.displayResource(for: record) else {
                throw GalleryMediaError.missingMedia
            }
            let url = try await GalleryVaultStorage.shared.decryptResource(recordID: record.id, resourceID: resource.id)
            defer { GalleryVaultStorage.shared.releasePlaintext(url) }
            try Task.checkCancellation()
            guard GalleryVaultStorage.shared.isUnlocked else { throw CancellationError() }
            let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
            try Task.checkCancellation()
            guard GalleryVaultStorage.shared.isUnlocked else { throw CancellationError() }
            return data
        }
    }

    // Warm orientation and stereo metadata once so playback can attach without another fetch.
    private static func prepareVideo(_ video: GalleryPreparedVideo, spatialHint: Bool) async throws -> GalleryPreparedVideo {
        var spatial = spatialHint
        if !spatial {
            let tracks = try? await video.asset.loadTracks(withMediaCharacteristic: .containsStereoMultiviewVideo)
            spatial = !(tracks?.isEmpty ?? true)
        }
        let aspectRatio = await GalleryViewerMedia.videoAspectRatio(video.asset)
        try Task.checkCancellation()
        video.isSpatialVideo = spatial
        video.aspectRatio = aspectRatio
        return video
    }

    static func video(_ item: GalleryMediaItem) async throws -> GalleryPreparedVideo {
        switch item {
        case .photos(let asset):
            let video = GalleryPreparedVideo(asset: try await GalleryMediaRequest<AVAsset>.video(asset))
            return try await prepareVideo(video, spatialHint: item.mediaSubtypes.contains(.spatialMedia))
        case .vault(let record):
            guard GalleryVaultStorage.shared.isUnlocked,
                  let resource = GalleryVaultResourceSelection.displayResource(for: record) else {
                throw GalleryMediaError.missingMedia
            }
            let url = try await GalleryVaultStorage.shared.decryptResource(recordID: record.id, resourceID: resource.id)
            do {
                try Task.checkCancellation()
                guard GalleryVaultStorage.shared.isUnlocked else { throw CancellationError() }
                let video = GalleryPreparedVideo(asset: AVURLAsset(url: url), plaintextURL: url)
                return try await prepareVideo(video, spatialHint: item.mediaSubtypes.contains(.spatialMedia))
            } catch {
                GalleryVaultStorage.shared.releasePlaintext(url)
                throw error
            }
        }
    }
}

#endif
