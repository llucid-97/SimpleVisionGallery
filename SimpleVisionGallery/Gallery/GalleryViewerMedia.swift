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
    private var desiredPrefetchAssets: [PHAsset] = []
    private var prefetched: [String: GalleryPrefetchedMedia] = [:]
    private var prefetchFailures: Set<String> = []
    private var prefetchCoordinator: Task<Void, Never>?
    private var prefetchTask: Task<GalleryPrefetchedMedia, Error>?
    private var prefetchKey: String?
    private var prefetchPriority: GalleryPrefetchPriority?
    private var prefetchGeneration = UUID()
    private var memoryWarningObserver: GalleryNotificationToken?
    private let prefetchPixelBudget = 20_000_000
    private var currentKey: String?
    private var playerObservation: NSKeyValueObservation?
    private var playerEndObserver: GalleryNotificationToken?
    private var videoLooping = false
    private var prepared: GalleryPreparedImage?
    private var preparedKey: String?
    private var isSceneActive = true
    private var resumePlaybackWhenActive = false

    init() {
        memoryWarningObserver = GalleryNotificationToken(NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.prefetch(assets: []) }
        })
    }

    func load(asset: PHAsset, spatialEnabled: Bool) async {
        let requestedKey = GallerySceneCache.key(for: asset)
        if currentKey != requestedKey { aspectRatio = nil }
        // Keep the speculative consumer alive until the foreground consumer joins.
        let warmed = prefetched.removeValue(forKey: requestedKey)
        let promoted = prefetchKey == requestedKey ? prefetchTask : nil
        if promoted != nil {
            prefetchPriority?.foreground = true
            prefetchPriority = nil
            prefetchTask = nil
            prefetchKey = nil
        }
        cancelCurrent(releaseImage: preparedKey != requestedKey)
        cancelPrefetchWork()
        desiredPrefetchAssets.removeAll { GallerySceneCache.key(for: $0) == requestedKey }
        currentKey = requestedKey
        GallerySceneCache.shared.promote(asset: asset)
        let token = generation
        isLoading = true
        error = nil
        status = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { promoted?.cancel(); return }
            defer { promoted?.cancel() }
            do {
                if asset.mediaType == .video {
                    self.prepared = nil
                    self.preparedKey = nil
                    let avAsset: AVAsset
                    if case .video(let retained) = warmed {
                        avAsset = retained
                    } else if let promoted {
                        do {
                            guard case .video(let warmed) = try await GalleryMediaRequest.value(of: promoted) else {
                                throw GalleryMediaError.missingMedia
                            }
                            avAsset = warmed
                        } catch is CancellationError { throw CancellationError() }
                        catch { avAsset = try await GalleryMediaRequest.video(asset) }
                    } else {
                        avAsset = try await GalleryMediaRequest.video(asset)
                    }
                    var spatialVideo = asset.mediaSubtypes.contains(.spatialMedia)
                    if !spatialVideo {
                        let stereoTracks = try? await avAsset.loadTracks(withMediaCharacteristic: .containsStereoMultiviewVideo)
                        spatialVideo = !(stereoTracks?.isEmpty ?? true)
                    }
                    let videoAspectRatio = await Self.videoAspectRatio(avAsset)
                    try Task.checkCancellation()
                    guard self.generation == token else { return }
                    self.aspectRatio = videoAspectRatio
                    self.isSpatialVideo = spatialVideo
                    #if targetEnvironment(simulator)
                    if spatialVideo { self.status = "Showing a 2D preview in Simulator. Spatial video needs Apple Vision Pro." }
                    #endif
                    let item = AVPlayerItem(asset: avAsset)
                    self.player = AVPlayer(playerItem: item)
                    self.player?.actionAtItemEnd = self.videoLooping ? .none : .pause
                    self.playerEndObserver = GalleryNotificationToken(NotificationCenter.default.addObserver(
                        forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
                    ) { [weak self, weak item] _ in
                        Task { @MainActor [weak self, weak item] in
                            guard let self, let item, self.generation == token,
                                  self.videoLooping, self.isSceneActive,
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
                    if self.isSceneActive { self.player?.play() }
                    else { self.resumePlaybackWhenActive = true }
                } else {
                    let key = GallerySceneCache.key(for: asset)
                    let image: GalleryPreparedImage
                    if case .image(let retained) = warmed {
                        image = retained
                    } else if let promoted {
                        do {
                            guard case .image(let retained) = try await GalleryMediaRequest.value(of: promoted) else {
                                throw GalleryMediaError.missingMedia
                            }
                            image = retained
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
                    self.prepared = image
                    self.preparedKey = key
                    self.aspectRatio = image.aspectRatio
                    self.spatialAvailable = image.supportsSpatial
                    self.status = spatialEnabled ? image.status : nil
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

    private static func videoAspectRatio(_ asset: AVAsset) async -> Double? {
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
    func prefetch(assets: [PHAsset]) {
        var seen: Set<String> = []
        desiredPrefetchAssets = Array(assets.prefix(10)).filter {
            let key = GallerySceneCache.key(for: $0)
            return key != currentKey && seen.insert(key).inserted
        }
        let wanted = Set(desiredPrefetchAssets.map(GallerySceneCache.key(for:)))
        prefetched = prefetched.filter { wanted.contains($0.key) }
        prefetchFailures.formIntersection(wanted)
        if let prefetchKey, !wanted.contains(prefetchKey) { cancelPrefetchWork() }
        if wanted.isEmpty { cancelPrefetchWork() }
        startPrefetchIfNeeded()
    }

    private func startPrefetchIfNeeded() {
        guard isSceneActive, !isLoading, prefetchCoordinator == nil,
              !desiredPrefetchAssets.isEmpty else { return }
        let token = prefetchGeneration
        prefetchCoordinator = Task(priority: .utility) { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let (key, task) = self?.nextPrefetchRequest() else { break }
                do {
                    let result = try await task.value
                    try Task.checkCancellation()
                    guard let self, self.prefetchGeneration == token else { return }
                    self.prefetchTask = nil
                    self.prefetchKey = nil
                    self.prefetchPriority = nil
                    let used = self.prefetched.values.reduce(0) { $0 + $1.pixelCost }
                    if used + result.pixelCost <= self.prefetchPixelBudget {
                        self.prefetched[key] = result
                    } else {
                        self.prefetchFailures.insert(key)
                    }
                } catch {
                    guard let self, self.prefetchGeneration == token else { return }
                    self.prefetchTask = nil
                    self.prefetchKey = nil
                    self.prefetchPriority = nil
                    self.prefetchFailures.insert(key)
                }
            }
            if let self, self.prefetchGeneration == token { self.prefetchCoordinator = nil }
        }
    }

    private func nextPrefetchRequest() -> (String, Task<GalleryPrefetchedMedia, Error>)? {
        guard isSceneActive, !isLoading else { return nil }
        let usedPixels = prefetched.values.reduce(0) { $0 + $1.pixelCost }
        for asset in desiredPrefetchAssets {
            let key = GallerySceneCache.key(for: asset)
            guard prefetched[key] == nil, !prefetchFailures.contains(key) else { continue }
            // Ordinary photos are bounded to 2560px; spatial sources retain both views.
            let width = Double(asset.pixelWidth), height = Double(asset.pixelHeight)
            let scale = min(1, 2560 / max(1, max(width, height)))
            let pixelEstimate = asset.mediaType == .image
                ? width * height * (asset.mediaSubtypes.contains(.spatialMedia) ? 2 : scale * scale) : 0
            guard pixelEstimate <= Double(prefetchPixelBudget - usedPixels) else { continue }
            let remainingPixels = prefetchPixelBudget - usedPixels
            let priority = GalleryPrefetchPriority()
            let task = Task(priority: .utility) { @MainActor in
                try Task.checkCancellation()
                if asset.mediaType == .video {
                    // Warming never creates a player or starts playback.
                    return GalleryPrefetchedMedia.video(try await GalleryMediaRequest.video(asset))
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
            if resumePlaybackWhenActive { player?.play() }
            resumePlaybackWhenActive = false
            startPrefetchIfNeeded()
        } else {
            prefetch(assets: [])
            resumePlaybackWhenActive = player.map { $0.timeControlStatus != .paused } ?? false
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
        isSpatialVideo = false
        imageEntity = nil
        fallbackImage = nil
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

private enum GalleryPrefetchedMedia {
    case image(GalleryPreparedImage)
    case video(AVAsset)

    var pixelCost: Int {
        if case .image(let image) = self { return image.pixelCost }
        return 0
    }
}

private struct GalleryPreparedImage {
    var component: ImagePresentationComponent?
    var fallback: UIImage?
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
    private var entries: [String: Entry] = [:]
    private var pending: [String: Pending] = [:]
    private var clock: UInt64 = 0
    private var warningObserver: NSObjectProtocol?
    private let generationGate = GalleryGenerationGate()

    private init() {
        warningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.entries.removeAll() }
        }
    }

    static func key(for asset: PHAsset) -> String {
        "\(asset.localIdentifier):\(asset.modificationDate?.timeIntervalSince1970 ?? 0)"
    }

    func promote(asset: PHAsset) {
        for suffix in [":scene", ":original"] {
            let key = Self.key(for: asset) + suffix
            if var item = pending[key] {
                item.foreground = true
                pending[key] = item
                generationGate.promote(key: key)
            }
        }
    }

    func image(for asset: PHAsset, spatial: Bool, foreground: Bool = true, pixelBudget: Int? = nil) async throws -> GalleryPreparedImage {
        let assetKey = Self.key(for: asset)
        let key = assetKey + (spatial ? ":scene" : ":original")
        clock &+= 1
        if var entry = entries[key] ?? entries[assetKey + ":scene"] {
            entry.access = clock
            entries[entries[key] != nil ? key : assetKey + ":scene"] = entry
            return entry.image
        }
        let consumer = UUID()
        let task: Task<GalleryPreparedImage, Error>
        if var existing = pending[key] {
            existing.consumers.insert(consumer)
            existing.foreground = existing.foreground || foreground
            if foreground { generationGate.promote(key: key) }
            pending[key] = existing
            task = existing.task
        } else {
            let jobID = UUID()
            task = Task(priority: foreground ? .userInitiated : .utility) { @MainActor in
                let data = try await GalleryMediaRequest.imageData(asset)
                // Bound image decoding as well as generation across all open windows.
                try await generationGate.acquire(key: key, foreground: pending[key]?.foreground ?? foreground)
                defer { generationGate.release() }
                try Task.checkCancellation()
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
        while entries.count > 3 || entries.values.reduce(0, { $0 + $1.image.pixelCost }) > 20_000_000 {
            guard let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key else { break }
            entries.removeValue(forKey: oldest)
        }
    }

    private static func prepare(data: Data, spatial: Bool, pixelBudget: () -> Int?) async throws -> GalleryPreparedImage {
        let decoded = try await Task.detached(priority: .userInitiated) {
            try GalleryDecodedImage(data: data)
        }.value
        try Task.checkCancellation()
        if let pixelBudget = pixelBudget(), decoded.pixelCost > pixelBudget { throw GalleryMediaError.prefetchBudgetExceeded }
        var result = GalleryPreparedImage(
            attemptedSpatial: spatial,
            aspectRatio: Double(decoded.preview.size.width / decoded.preview.size.height),
            pixelCost: decoded.pixelCost
        )
        #if targetEnvironment(simulator)
        // Simulator cannot generate spatial scenes, but it can render the real
        // image component. Use it so layout tests cover the native media plane.
        do {
            result.component = try await ImagePresentationComponent(imageSource: decoded.source)
        } catch {
            result.fallback = decoded.preview
        }
        try Task.checkCancellation()
        result.status = "Spatial scenes need Apple Vision Pro. Showing the original in Simulator."
        return result
        #else
        let modes = ImagePresentationComponent.supportedViewingModes(for: decoded.source)
        result.supportsSpatial = modes.contains(.spatialStereo) || decoded.canGenerate
        if spatial && !modes.contains(.spatialStereo) && decoded.canGenerate {
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
                result.status = "Could not create a spatial scene. Showing the original. \(error.localizedDescription)"
            }
        } else if spatial && !modes.contains(.spatialStereo) {
            result.status = "This photo's size or shape does not support spatial scenes."
        }
        do {
            result.component = try await ImagePresentationComponent(imageSource: decoded.source)
            if modes.contains(.spatialStereo) { result.spatialMode = .spatialStereo }
        } catch {
            result.fallback = decoded.preview
            result.status = "Showing a 2D preview. \(error.localizedDescription)"
        }
        try Task.checkCancellation()
        return result
        #endif
    }
}

/// A cancelled queued swipe leaves the queue immediately, without decoding its image.
@MainActor
private final class GalleryGenerationGate {
    private var occupied = false
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
        if !occupied { occupied = true; return }
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
        if waiters.isEmpty { occupied = false }
        else {
            let next = waiters.firstIndex(where: { $0.foreground }) ?? 0
            waiters.remove(at: next).continuation.resume()
        }
    }
}

private nonisolated struct GalleryDecodedImage: @unchecked Sendable {
    let source: CGImageSource
    let preview: UIImage
    let pixelCost: Int
    let canGenerate: Bool

    init(data: Data) throws {
        guard let original = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(original, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw GalleryMediaError.invalidImage }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2560,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(original, 0, options as CFDictionary) else {
            throw GalleryMediaError.invalidImage
        }
        preview = UIImage(cgImage: thumbnail)
        // Keep every channel and all camera metadata of multi-image HEIC sources.
        // The spatial-mode query is performed on the main actor before presentation.
        if CGImageSourceGetCount(original) > 1 {
            source = original
            pixelCost = width * height * min(CGImageSourceGetCount(original), 2)
        } else {
            let resized = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(resized, UTType.png.identifier as CFString, 1, nil) else {
                throw GalleryMediaError.invalidImage
            }
            CGImageDestinationAddImage(destination, thumbnail, nil)
            guard CGImageDestinationFinalize(destination),
                  let bounded = CGImageSourceCreateWithData(resized, nil) else { throw GalleryMediaError.invalidImage }
            source = bounded
            pixelCost = thumbnail.width * thumbnail.height
        }
        let ratio = Double(width) / Double(height)
        canGenerate = min(thumbnail.width, thumbnail.height) >= 320 && ratio >= 1.0 / 3.0 && ratio <= 3.0
    }
}

private nonisolated enum GalleryMediaError: LocalizedError {
    case invalidImage, missingMedia, prefetchBudgetExceeded
    var errorDescription: String? {
        switch self {
        case .prefetchBudgetExceeded: return "This photo exceeds the lookahead memory budget."
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
#endif
