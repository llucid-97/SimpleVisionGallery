//
//  GalleryManager.swift
//  simple_vision_tools
//
//  Created by Codex Vector on 24/05/2026.
//

import Combine
import Foundation
@preconcurrency import Photos
import SwiftUI
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

#if canImport(UIKit)
    typealias GalleryPlatformImage = UIImage
#elseif canImport(AppKit)
    typealias GalleryPlatformImage = NSImage
#endif

struct GalleryAlbum: Identifiable, Hashable {
    let id: String
    let title: String
    let assetCount: Int
    let collection: PHAssetCollection
    let coverAsset: PHAsset?

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: GalleryAlbum, rhs: GalleryAlbum) -> Bool {
        lhs.id == rhs.id
    }
}

struct GalleryToast: Identifiable, Equatable {
    enum Kind {
        case info
        case success
        case warning
        case error
    }

    let id = UUID()
    let kind: Kind
    let message: String
}

nonisolated enum GalleryDeletionMediaKind: String, Sendable {
    case photo
    case video
    case other
}

nonisolated struct GalleryDeletionCandidate: Hashable, Sendable {
    let localIdentifier: String
    let mediaKind: GalleryDeletionMediaKind
}

nonisolated struct GalleryDeletionPlan: Identifiable, Equatable, Sendable {
    let id: UUID
    let candidates: [GalleryDeletionCandidate]

    init?(candidates: [GalleryDeletionCandidate], id: UUID = UUID()) {
        guard !candidates.isEmpty,
            candidates.allSatisfy({ !$0.localIdentifier.isEmpty }),
            Set(candidates.map(\.localIdentifier)).count == candidates.count
        else {
            return nil
        }

        self.id = id
        self.candidates = candidates
    }

    var localIdentifiers: [String] {
        candidates.map(\.localIdentifier)
    }

    var totalCount: Int {
        candidates.count
    }

    var photoCount: Int {
        candidates.count { $0.mediaKind == .photo }
    }

    var videoCount: Int {
        candidates.count { $0.mediaKind == .video }
    }

    var otherCount: Int {
        candidates.count { $0.mediaKind == .other }
    }

    var mediaBreakdown: String {
        let parts = [
            Self.countDescription(photoCount, singular: "photo"),
            Self.countDescription(videoCount, singular: "video"),
            Self.countDescription(otherCount, singular: "other item"),
        ].compactMap { $0 }
        return parts.joined(separator: ", ")
    }

    func matchesLiveCandidates(_ liveCandidates: [GalleryDeletionCandidate]) -> Bool {
        liveCandidates.count == candidates.count
            && Set(liveCandidates) == Set(candidates)
    }

    private static func countDescription(_ count: Int, singular: String) -> String? {
        guard count > 0 else { return nil }
        return "\(count) \(singular)\(count == 1 ? "" : "s")"
    }
}

nonisolated struct GalleryDeletionReviewAuthority {
    private var pendingReview: GalleryDeletionPlan?

    mutating func issue(_ review: GalleryDeletionPlan) {
        pendingReview = review
    }

    mutating func consume(_ review: GalleryDeletionPlan) -> Bool {
        defer { pendingReview = nil }
        return pendingReview == review
    }

    mutating func invalidate() {
        pendingReview = nil
    }
}

private struct GalleryNamedAssetIndex: Sendable {
    let index: Int
    let name: String
}

enum GalleryAssetSortMode: String, CaseIterable, Identifiable {
    case photosOrder
    case name
    case date
    case random

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photosOrder:
            return "Photos Order"
        case .name:
            return "Name"
        case .date:
            return "Date"
        case .random:
            return "Random"
        }
    }

    var systemImage: String {
        switch self {
        case .photosOrder:
            return "list.number"
        case .name:
            return "textformat"
        case .date:
            return "calendar"
        case .random:
            return "shuffle"
        }
    }
}

nonisolated enum GalleryPagingPolicy {
    static let initialPageSize = 360
    static let pageSize = 240

    static func visibleCount(current: Int, total: Int, resetsForNewAlbum: Bool) -> Int {
        let boundedTotal = max(0, total)
        let startingCount = resetsForNewAlbum ? 0 : max(0, current)
        return min(max(startingCount, initialPageSize), boundedTotal)
    }
}

nonisolated enum GalleryAlbumIndexingPolicy {
    static let minimumProgressStride = 12
    static let maximumProgressUpdates = 200

    static func progressStride(total: Int) -> Int {
        max(minimumProgressStride, max(1, total / maximumProgressUpdates))
    }

    static func shouldReportProgress(processed: Int, total: Int) -> Bool {
        guard processed > 0, total > 0 else { return false }
        return processed == 1
            || processed.isMultiple(of: progressStride(total: total))
            || processed >= total
    }
}

nonisolated struct GalleryAlbumIndexingProgress: Equatable, Sendable {
    let processed: Int
    let total: Int
}

nonisolated struct GalleryAlbumIndexingRun: Sendable {
    let generation: UUID
    let total: Int
    private(set) var processed = 0

    init(generation: UUID = UUID(), total: Int) {
        self.generation = generation
        self.total = max(0, total)
    }

    mutating func advance() -> GalleryAlbumIndexingProgress? {
        guard processed < total else { return nil }

        processed += 1
        guard
            GalleryAlbumIndexingPolicy.shouldReportProgress(
                processed: processed,
                total: total
            )
        else {
            return nil
        }
        return GalleryAlbumIndexingProgress(processed: processed, total: total)
    }

    func canCommit(currentGeneration: UUID, isCancelled: Bool) -> Bool {
        !isCancelled && generation == currentGeneration && processed == total
    }
}

nonisolated struct GalleryAlbumChangeDecision: Equatable, Sendable {
    let shouldReloadAlbums: Bool
    let shouldRefreshAssets: Bool

    init(
        committedFetchChanged: Bool,
        inFlightFetchChanged: Bool,
        assetFetchChanged: Bool
    ) {
        shouldReloadAlbums = committedFetchChanged || inFlightFetchChanged
        shouldRefreshAssets = assetFetchChanged
    }
}

nonisolated struct GalleryAssetRefreshAuthority: Equatable, Sendable {
    let id: UUID
    let albumID: String
    let selectionGeneration: UUID

    static func issue(
        selectedAlbumID: String?,
        selectionGeneration: UUID,
        changedFetchAlbumIDs: Set<String>
    ) -> Self? {
        guard
            let selectedAlbumID,
            changedFetchAlbumIDs.contains(selectedAlbumID)
        else {
            return nil
        }
        return Self(
            id: UUID(),
            albumID: selectedAlbumID,
            selectionGeneration: selectionGeneration
        )
    }

    func isCurrent(albumID: String?, selectionGeneration: UUID) -> Bool {
        self.albumID == albumID && self.selectionGeneration == selectionGeneration
    }
}

nonisolated struct GalleryAlbumRemovalWarningIntent: Equatable, Sendable {
    let albumID: String

    func shouldWarn(selectedAlbumID: String?, availableAlbumIDs: Set<String>) -> Bool {
        selectedAlbumID == albumID && !availableAlbumIDs.contains(albumID)
    }
}

nonisolated struct GalleryAlbumOpenIntent: Equatable, Sendable {
    let id: UUID
    let albumID: String
    let selectionGeneration: UUID

    func isCurrent(albumID: String?, selectionGeneration: UUID) -> Bool {
        self.albumID == albumID && self.selectionGeneration == selectionGeneration
    }
}

nonisolated struct GalleryAlbumCommitActions: Equatable, Sendable {
    let shouldRefreshAssets: Bool
    let refreshesExternalAssetChange: Bool
    let shouldWarnAboutRemoval: Bool

    init(
        defaultAssetRefreshRequested: Bool,
        pendingAssetRefresh: GalleryAssetRefreshAuthority?,
        removalWarning: GalleryAlbumRemovalWarningIntent?,
        selectedAlbumID: String?,
        albumSelectionGeneration: UUID,
        availableAlbumIDs: Set<String>
    ) {
        let selectedAlbumIsAvailable = selectedAlbumID.map(availableAlbumIDs.contains) ?? false
        refreshesExternalAssetChange =
            selectedAlbumIsAvailable
            && (pendingAssetRefresh?.isCurrent(
                albumID: selectedAlbumID,
                selectionGeneration: albumSelectionGeneration
            ) ?? false)
        shouldRefreshAssets =
            selectedAlbumIsAvailable
            && (defaultAssetRefreshRequested || refreshesExternalAssetChange)
        shouldWarnAboutRemoval =
            removalWarning?.shouldWarn(
                selectedAlbumID: selectedAlbumID,
                availableAlbumIDs: availableAlbumIDs
            ) ?? false
    }
}

@MainActor
final class GalleryManager: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    static let initialPageSize = GalleryPagingPolicy.initialPageSize
    static let pageSize = GalleryPagingPolicy.pageSize
    static let preheatPadding = 120
    nonisolated static let thumbnailTargetSize = CGSize(width: 260, height: 260)
    private static let assetSortModeDefaultsKey = "gallery.assetSortMode.v1"
    private static let nameSortAscendingDefaultsKey = "gallery.nameSortAscending.v1"
    private static let dateSortAscendingDefaultsKey = "gallery.dateSortAscending.v1"

    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published var albums: [GalleryAlbum] = []
    @Published private var visibilityPreferences = GalleryVisibilityPreferences()
    @Published private(set) var assetSortMode: GalleryAssetSortMode = .photosOrder
    @Published private(set) var nameSortAscending = true
    @Published private(set) var dateSortAscending = false
    @Published private(set) var isSortingAssets = false
    @Published private(set) var sortingMessage: String?
    @Published var selectedAlbum: GalleryAlbum?
    @Published var visibleAssetCount = 0
    @Published var totalAssetCount = 0
    @Published var selectedIndexes = IndexSet()
    @Published var rangeAnchorIndex: Int?
    @Published var isLoadingAlbums = false
    @Published var isLoadingAlbum = false
    @Published var loadedAlbumCount = 0
    @Published var totalAlbumCount = 0
    @Published var isPerformingOperation = false
    @Published var operationMessage: String?
    @Published var errorMessage: String?
    @Published var toast: GalleryToast?
    @Published var selectionFeedbackSignal = 0
    @Published var successFeedbackSignal = 0
    @Published var warningFeedbackSignal = 0
    @Published var errorFeedbackSignal = 0

    private var albumFetchResult: PHFetchResult<PHAssetCollection>?
    private var assetFetchResult: PHFetchResult<PHAsset>?
    private var assetDisplayOrder: [Int]? {
        didSet { viewerSnapshotID = UUID() }
    }
    private var viewerSnapshotID = UUID()
    private var albumLoadGeneration = UUID()
    private var inFlightAlbumFetchGeneration: UUID?
    private var inFlightAlbumFetchResult: PHFetchResult<PHAssetCollection>?
    private var albumSelectionGeneration = UUID()
    private var assetLoadGeneration = UUID()
    private var assetFetchAlbumID: String?
    private var inFlightAssetFetchGeneration: UUID?
    private var inFlightAssetFetchAlbumID: String?
    private var inFlightAssetFetchResult: PHFetchResult<PHAsset>?
    private var pendingAssetRefreshAuthority: GalleryAssetRefreshAuthority?
    private var pendingAlbumRemovalWarning: GalleryAlbumRemovalWarningIntent?
    private var pendingAlbumOpenIntent: GalleryAlbumOpenIntent?
    @Published private var albumIndexingMessage: String?
    @Published private var assetLoadingMessage: String?
    private var visibleIndexes = Set<Int>()
    private var preheatedRange: Range<Int>?
    private var deletionReviewAuthority = GalleryDeletionReviewAuthority()
    private let imageManager = PHCachingImageManager()

    #if canImport(UIKit) || canImport(AppKit)
        private let thumbnailCache: NSCache<NSString, GalleryPlatformImage> = {
            let cache = NSCache<NSString, GalleryPlatformImage>()
            cache.countLimit = 600
            cache.totalCostLimit = 64 * 1024 * 1024
            return cache
        }()
    #endif

    override init() {
        super.init()
        assetSortMode = GalleryAssetSortMode(
            rawValue: UserDefaults.standard.string(forKey: Self.assetSortModeDefaultsKey) ?? ""
        ) ?? .photosOrder
        if UserDefaults.standard.object(forKey: Self.nameSortAscendingDefaultsKey) != nil {
            nameSortAscending = UserDefaults.standard.bool(forKey: Self.nameSortAscendingDefaultsKey)
        }
        if UserDefaults.standard.object(forKey: Self.dateSortAscendingDefaultsKey) != nil {
            dateSortAscending = UserDefaults.standard.bool(forKey: Self.dateSortAscendingDefaultsKey)
        }
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    var hasPhotoAccess: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }

    var loadingMessage: String? {
        if isLoadingAlbum {
            return assetLoadingMessage
        }
        if isLoadingAlbums {
            return albumIndexingMessage
        }
        return assetLoadingMessage ?? albumIndexingMessage
    }

    var isSelectionMode: Bool {
        !selectedIndexes.isEmpty
    }

    var selectedCount: Int {
        selectedIndexes.count
    }

    var visibleAlbums: [GalleryAlbum] {
        albums.filter { !isAlbumHidden($0) }
    }

    var hiddenAlbums: [GalleryAlbum] {
        albums.filter { isAlbumHidden($0) }
    }

    var hiddenAlbumIDs: Set<String> {
        visibilityPreferences.hiddenAlbumIDs
    }

    var autoHideEmptyAlbums: Bool {
        visibilityPreferences.autoHideEmptyAlbums
    }

    func isAlbumHidden(_ album: GalleryAlbum) -> Bool {
        visibilityPreferences.isHidden(albumID: album.id, assetCount: album.assetCount)
    }

    func isRecycleBin(album: GalleryAlbum) -> Bool {
        GalleryRecycleBin.isRecycleBin(album)
    }

    func setAutoHideEmptyAlbums(_ enabled: Bool) {
        visibilityPreferences.setAutoHideEmptyAlbums(enabled)
    }

    var assetSortAscending: Bool {
        switch assetSortMode {
        case .name:
            return nameSortAscending
        case .date:
            return dateSortAscending
        case .photosOrder, .random:
            return true
        }
    }

    var supportsAssetSortDirection: Bool {
        assetSortMode == .name || assetSortMode == .date
    }

    func hideAlbums(withIDs albumIDs: Set<String>) {
        let availableIDs = Set(albums.map(\.id))
        let idsToHide = albumIDs.intersection(availableIDs)
        guard !idsToHide.isEmpty else { return }

        visibilityPreferences.hide(idsToHide)
        let albumWord = idsToHide.count == 1 ? "album" : "albums"
        showToast(.success, "Hidden \(idsToHide.count) \(albumWord)")
    }

    func unhideAlbums(withIDs albumIDs: Set<String>) {
        let idsToUnhide = albumIDs.intersection(Set(hiddenAlbums.map(\.id)))
        guard !idsToUnhide.isEmpty else { return }

        visibilityPreferences.unhide(idsToUnhide)
        let albumWord = idsToUnhide.count == 1 ? "album" : "albums"
        showToast(.success, "Restored \(idsToUnhide.count) \(albumWord)")
    }

    func setAssetSortMode(_ mode: GalleryAssetSortMode) async {
        guard mode != assetSortMode else { return }

        assetSortMode = mode
        persistAssetSortPreferences()
        guard selectedAlbum != nil else { return }
        await refreshCurrentAlbum(keepingSelection: false, showSortingProgress: true)
    }

    func toggleAssetSortDirection() async {
        switch assetSortMode {
        case .name:
            nameSortAscending.toggle()
        case .date:
            dateSortAscending.toggle()
        case .photosOrder, .random:
            return
        }

        persistAssetSortPreferences()
        guard selectedAlbum != nil else { return }
        await refreshCurrentAlbum(keepingSelection: false, showSortingProgress: true)
    }

    func reshuffleAssets() {
        guard assetSortMode == .random, let assetFetchResult else { return }

        assetDisplayOrder = Array(0..<assetFetchResult.count).shuffled()
        clearSelection(silent: true)
        resetImagePreheating()
        selectionFeedbackSignal += 1
        showToast(.info, "Random order reshuffled")
    }

    func requestAuthorization() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorizationStatus = status
        if hasPhotoAccess {
            await loadAlbums()
        }
    }

    func loadAlbums(refreshSelectedAlbumAssets: Bool = true) async {
        guard hasPhotoAccess else { return }

        let generation = UUID()
        albumLoadGeneration = generation
        inFlightAlbumFetchGeneration = nil
        inFlightAlbumFetchResult = nil
        isLoadingAlbums = true
        albumIndexingMessage = "Preparing albums..."
        loadedAlbumCount = 0
        totalAlbumCount = 0
        errorMessage = nil
        var didCommit = false
        defer {
            clearInFlightAlbumFetch(generation: generation)
            if albumLoadGeneration == generation && !didCommit {
                isLoadingAlbums = false
                albumIndexingMessage = nil
                loadedAlbumCount = 0
                totalAlbumCount = 0
            }
        }

        await Task.yield()
        guard isCurrentAlbumLoad(generation) else { return }

        let fetchResult = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: nil
        )
        guard isCurrentAlbumLoad(generation) else { return }

        inFlightAlbumFetchGeneration = generation
        inFlightAlbumFetchResult = fetchResult
        var run = GalleryAlbumIndexingRun(generation: generation, total: fetchResult.count)
        totalAlbumCount = run.total

        var loadedAlbums: [GalleryAlbum] = []
        loadedAlbums.reserveCapacity(run.total)

        for index in 0..<run.total {
            guard isCurrentAlbumLoad(generation) else { return }

            let collection = fetchResult.object(at: index)
            loadedAlbums.append(makeAlbum(from: collection))

            if let progress = run.advance() {
                loadedAlbumCount = progress.processed
                albumIndexingMessage = "Indexed \(progress.processed) of \(progress.total) albums..."
                await Task.yield()
            }
        }

        let sortedSnapshot = sortedAlbums(loadedAlbums)
        guard
            run.canCommit(
                currentGeneration: albumLoadGeneration,
                isCancelled: Task.isCancelled
            )
        else {
            return
        }

        let selectedAlbumID = selectedAlbum?.id
        let refreshedSelection = selectedAlbumID.flatMap { selectedID in
            sortedSnapshot.first { $0.id == selectedID }
        }
        let availableAlbumIDs = Set(sortedSnapshot.map(\.id))
        let commitActions = GalleryAlbumCommitActions(
            defaultAssetRefreshRequested: refreshSelectedAlbumAssets,
            pendingAssetRefresh: pendingAssetRefreshAuthority,
            removalWarning: pendingAlbumRemovalWarning,
            selectedAlbumID: selectedAlbumID,
            albumSelectionGeneration: albumSelectionGeneration,
            availableAlbumIDs: availableAlbumIDs
        )
        pendingAlbumRemovalWarning = nil

        albumFetchResult = fetchResult
        clearInFlightAlbumFetch(generation: generation)
        albums = sortedSnapshot
        loadedAlbumCount = run.total
        totalAlbumCount = run.total
        albumIndexingMessage = nil
        isLoadingAlbums = false
        didCommit = true

        if selectedAlbumID != nil {
            self.selectedAlbum = refreshedSelection
            if refreshedSelection == nil {
                closeAlbum()
                if commitActions.shouldWarnAboutRemoval {
                    showToast(.warning, "The album changed outside Gallery.")
                }
            } else if commitActions.shouldRefreshAssets {
                await refreshCurrentAlbum(keepingSelection: false, showSortingProgress: false)
            }
        }
    }

    func openAlbum(_ album: GalleryAlbum) async {
        pendingAssetRefreshAuthority = nil
        pendingAlbumRemovalWarning = nil
        albumSelectionGeneration = UUID()
        assetLoadGeneration = UUID()
        assetFetchResult = nil
        assetFetchAlbumID = nil
        clearInFlightAssetFetch()
        assetDisplayOrder = nil
        totalAssetCount = 0
        visibleAssetCount = 0
        isSortingAssets = false
        sortingMessage = nil
        selectedAlbum = album
        pendingAlbumOpenIntent = GalleryAlbumOpenIntent(
            id: UUID(),
            albumID: album.id,
            selectionGeneration: albumSelectionGeneration
        )
        isLoadingAlbum = true
        assetLoadingMessage = "Opening \(album.title)..."
        errorMessage = nil
        clearSelection(silent: true)
        resetImagePreheating()
        await Task.yield()

        await refreshCurrentAlbum(
            keepingSelection: false,
            showSortingProgress: false,
            resetPaging: true
        )
    }

    func closeAlbum() {
        pendingAssetRefreshAuthority = nil
        pendingAlbumRemovalWarning = nil
        pendingAlbumOpenIntent = nil
        albumSelectionGeneration = UUID()
        assetLoadGeneration = UUID()
        selectedAlbum = nil
        assetFetchResult = nil
        assetFetchAlbumID = nil
        clearInFlightAssetFetch()
        assetDisplayOrder = nil
        totalAssetCount = 0
        visibleAssetCount = 0
        isSortingAssets = false
        sortingMessage = nil
        isLoadingAlbum = false
        assetLoadingMessage = nil
        clearSelection(silent: true)
        resetImagePreheating()
    }

    #if os(visionOS)
    /// Keep the Photos fetch and copy-on-write sort order; opening is independent of album size.
    func viewerSnapshot() -> GalleryViewerSnapshot? {
        guard let album = selectedAlbum, let fetch = assetFetchResult,
              assetFetchAlbumID == album.id, !isLoadingAlbum, !isSortingAssets else { return nil }
        return GalleryViewerSnapshot(id: viewerSnapshotID, album: album, fetch: fetch, displayOrder: assetDisplayOrder)
    }
    #endif

    func asset(at index: Int) -> PHAsset? {
        guard let assetFetchResult, index >= 0, index < totalAssetCount else {
            return nil
        }

        let sourceIndex: Int
        if let assetDisplayOrder {
            guard assetDisplayOrder.indices.contains(index) else { return nil }
            sourceIndex = assetDisplayOrder[index]
        } else {
            sourceIndex = index
        }
        guard sourceIndex >= 0, sourceIndex < assetFetchResult.count else {
            return nil
        }
        return assetFetchResult.object(at: sourceIndex)
    }

    func loadMoreIfNeeded(appearingIndex: Int) {
        guard appearingIndex >= visibleAssetCount - 48, visibleAssetCount < totalAssetCount else {
            return
        }
        visibleAssetCount = min(totalAssetCount, visibleAssetCount + Self.pageSize)
    }

    func assetDidAppear(index: Int) {
        visibleIndexes.insert(index)
        updateImagePreheating()
    }

    func assetDidDisappear(index: Int) {
        visibleIndexes.remove(index)
        updateImagePreheating()
    }

    func handleShortTap(index: Int) {
        guard index >= 0, index < totalAssetCount else { return }

        if selectedIndexes.contains(index) {
            selectedIndexes.remove(index)
            if rangeAnchorIndex == index {
                rangeAnchorIndex = nil
            }
        } else {
            selectedIndexes.insert(index)
        }
        selectionFeedbackSignal += 1

        if selectedIndexes.isEmpty {
            rangeAnchorIndex = nil
            showToast(.info, "Selection cleared")
        } else {
            showToast(.info, "\(selectedIndexes.count) selected")
        }
    }

    func handleLongPinch(index: Int) {
        guard index >= 0, index < totalAssetCount else { return }

        if let anchor = rangeAnchorIndex {
            insertSelectionRange(from: anchor, to: index)
            rangeAnchorIndex = nil
            let itemWord = selectedIndexes.count == 1 ? "item" : "items"
            showToast(.info, "Range selected. \(selectedIndexes.count) \(itemWord) selected")
        } else {
            selectedIndexes.insert(index)
            rangeAnchorIndex = index
            showToast(.info, "Range start set at item \(index + 1). Long pinch the end item")
        }

        selectionFeedbackSignal += 1
    }

    func clearSelection(silent: Bool = false) {
        selectedIndexes.removeAll()
        rangeAnchorIndex = nil
        if !silent {
            selectionFeedbackSignal += 1
        }
    }

    /// Select every asset in the current PhotoKit result, including pages not yet displayed.
    func selectAllAssets() {
        guard totalAssetCount > 0, assetFetchResult != nil else { return }
        selectedIndexes = IndexSet(integersIn: 0..<totalAssetCount)
        rangeAnchorIndex = nil
        selectionFeedbackSignal += 1
        showToast(.info, "All \(totalAssetCount) items selected")
    }

    func renameAlbum(_ album: GalleryAlbum, to title: String) async {
        let newTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newTitle.isEmpty else {
            showToast(.warning, "Enter an album name first.")
            return
        }
        guard album.collection.canPerform(.rename) else {
            handleOperationError(GalleryOperationError.albumNotRenamable(album.title), fallback: "Rename failed")
            return
        }
        guard newTitle != album.title else { return }

        do {
            try await runOperation(message: "Renaming \(album.title)...") {
                var staged = false
                try await PHPhotoLibrary.shared().performChanges {
                    guard let request = PHAssetCollectionChangeRequest(for: album.collection) else { return }
                    request.title = newTitle
                    staged = true
                }
                guard staged else { throw GalleryOperationError.changeRequestUnavailable }
            }

            let renamed = GalleryAlbum(
                id: album.id,
                title: newTitle,
                assetCount: album.assetCount,
                collection: PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album.id], options: nil).firstObject ?? album.collection,
                coverAsset: album.coverAsset
            )
            albums = sortedAlbums(albums.map { $0.id == album.id ? renamed : $0 })
            if selectedAlbum?.id == album.id { selectedAlbum = renamed }
            #if os(visionOS)
            GalleryViewerStore.shared.updateAlbumTitle(id: album.id, title: newTitle)
            #endif
            showToast(.success, "Renamed album to \(newTitle)")
        } catch {
            handleOperationError(error, fallback: "Rename failed")
        }
    }

    func moveSelection(to destinationAlbum: GalleryAlbum) async {
        guard let sourceAlbum = selectedAlbum else { return }
        guard destinationAlbum.id != sourceAlbum.id else {
            showToast(.warning, "Choose a different destination album.")
            return
        }

        do {
            let assets = try selectedAssets()
            guard sourceAlbum.collection.canPerform(.removeContent) else {
                throw GalleryOperationError.sourceAlbumNotEditable(sourceAlbum.title)
            }
            guard destinationAlbum.collection.canPerform(.addContent) else {
                throw GalleryOperationError.destinationAlbumNotEditable(destinationAlbum.title)
            }
            try await runOperation(message: "Moving \(assets.count) item\(assets.count == 1 ? "" : "s")...") {
                var didStageChange = false
                try await PHPhotoLibrary.shared().performChanges {
                    guard
                        let destinationRequest = PHAssetCollectionChangeRequest(for: destinationAlbum.collection),
                        let sourceRequest = PHAssetCollectionChangeRequest(for: sourceAlbum.collection)
                    else {
                        return
                    }

                    didStageChange = true
                    destinationRequest.addAssets(assets as NSFastEnumeration)
                    sourceRequest.removeAssets(assets as NSFastEnumeration)
                }

                guard didStageChange else {
                    throw GalleryOperationError.changeRequestUnavailable
                }
            }
            #if os(visionOS)
            GalleryViewerStore.shared.removeFromAlbum(sourceAlbum.id, assets: assets)
            #endif
            GalleryMoveHistory.shared.recordSuccessfulMove(to: destinationAlbum.id)
            showToast(.success, "Moved \(assets.count) item\(assets.count == 1 ? "" : "s")")
        } catch {
            handleOperationError(error, fallback: "Move failed")
        }
    }

    func moveSelectionToNewAlbum(named albumName: String) async {
        let trimmedName = albumName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            showToast(.warning, "Name the new album first.")
            return
        }
        guard let sourceAlbum = selectedAlbum else { return }

        do {
            let assets = try selectedAssets()
            guard sourceAlbum.collection.canPerform(.removeContent) else {
                throw GalleryOperationError.sourceAlbumNotEditable(sourceAlbum.title)
            }
            var placeholderIdentifier: String?
            try await runOperation(message: "Creating \(trimmedName)...") {
                var didStageChange = false
                try await PHPhotoLibrary.shared().performChanges {
                    guard let sourceRequest = PHAssetCollectionChangeRequest(for: sourceAlbum.collection) else {
                        return
                    }

                    let createRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: trimmedName)
                    createRequest.addAssets(assets as NSFastEnumeration)
                    placeholderIdentifier = createRequest.placeholderForCreatedAssetCollection.localIdentifier
                    sourceRequest.removeAssets(assets as NSFastEnumeration)
                    didStageChange = true
                }

                guard didStageChange, placeholderIdentifier != nil else {
                    throw GalleryOperationError.albumCreationFailed
                }
            }
            #if os(visionOS)
            GalleryViewerStore.shared.removeFromAlbum(sourceAlbum.id, assets: assets)
            #endif
            if let placeholderIdentifier {
                GalleryMoveHistory.shared.recordSuccessfulMove(to: placeholderIdentifier)
            }
            showToast(.success, "Moved \(assets.count) item\(assets.count == 1 ? "" : "s") to \(trimmedName)")
        } catch {
            handleOperationError(error, fallback: "Move failed")
        }
    }

    func removeSelectionFromCurrentAlbum() async {
        guard let selectedAlbum else {
            showToast(.warning, "Choose an album first.")
            return
        }
        guard !isRecycleBin(album: selectedAlbum) else {
            showToast(.warning, "Use Delete Permanently inside Recycle Bin.")
            return
        }
        _ = await recycleSelection()
    }

    /// Moves the current selection to Recycle Bin, or returns a frozen deletion review in the bin.
    @discardableResult
    func recycleSelection() async -> GalleryDeletionPlan? {
        guard let sourceAlbum = selectedAlbum else { return nil }

        if isRecycleBin(album: sourceAlbum) {
            return prepareDeletionReview()
        }

        do {
            let assets = try selectedAssets()
            try await runOperation(message: "Moving \(assets.count) item\(assets.count == 1 ? "" : "s") to Recycle Bin...") {
                try await GalleryRecycleBin.move(assets, from: sourceAlbum.collection)
            }
            #if os(visionOS)
            GalleryViewerStore.shared.removeFromAlbum(sourceAlbum.id, assets: assets)
            #endif
            clearSelection(silent: true)
            await loadAlbums()
            showToast(.success, "Moved \(assets.count) item\(assets.count == 1 ? "" : "s") to Recycle Bin")
        } catch {
            handleOperationError(error, fallback: "Remove failed")
        }
        return nil
    }

    func prepareDeletionReview() -> GalleryDeletionPlan? {
        do {
            guard let selectedAlbum, isRecycleBin(album: selectedAlbum) else {
                throw GalleryOperationError.permanentDeleteOnlyInRecycleBin
            }
            try requireCurrentFullPhotoAccessForDeletion(afterMutation: false)
            let assets = try selectedAssets()
            guard assets.count == selectedIndexes.count else {
                throw GalleryOperationError.invalidDeletionSnapshot
            }
            let candidates = assets.map(Self.deletionCandidate(for:))
            guard let plan = GalleryDeletionPlan(candidates: candidates) else {
                throw GalleryOperationError.invalidDeletionSnapshot
            }
            deletionReviewAuthority.issue(plan)
            return plan
        } catch {
            deletionReviewAuthority.invalidate()
            handleOperationError(error, fallback: "Could not prepare deletion review")
            return nil
        }
    }

    func deleteSelectionFromLibrary(review: GalleryDeletionPlan) async {
        do {
            guard deletionReviewAuthority.consume(review) else {
                throw GalleryOperationError.deletionReviewExpired
            }
            try requireCurrentFullPhotoAccessForDeletion(afterMutation: false)

            guard let sourceAlbum = selectedAlbum,
                  let currentSource = PHAssetCollection.fetchAssetCollections(
                    withLocalIdentifiers: [sourceAlbum.id], options: nil
                  ).firstObject,
                  GalleryRecycleBin.isRecycleBinTitle(currentSource.localizedTitle) else {
                throw GalleryOperationError.permanentDeleteOnlyInRecycleBin
            }

            let assets = fetchAssets(withLocalIdentifiers: review.localIdentifiers)
            let liveCandidates = assets.map(Self.deletionCandidate(for:))
            guard review.matchesLiveCandidates(liveCandidates) else {
                throw GalleryOperationError.deletionSelectionChanged(
                    expected: review.totalCount,
                    found: liveCandidates.count
                )
            }
            let binMembership = PHAsset.fetchAssets(in: currentSource, options: nil)
            guard assets.allSatisfy({ binMembership.index(of: $0) != NSNotFound }) else {
                throw GalleryOperationError.deletionSelectionChanged(
                    expected: review.totalCount,
                    found: assets.filter { binMembership.index(of: $0) != NSNotFound }.count
                )
            }

            let itemWord = review.totalCount == 1 ? "item" : "items"
            try await runOperation(message: "Deleting \(review.totalCount) \(itemWord)...") {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(assets as NSFastEnumeration)
                }

                await Task.yield()
                try requireCurrentFullPhotoAccessForDeletion(afterMutation: true)
                let survivors = fetchAssets(withLocalIdentifiers: review.localIdentifiers)
                guard survivors.isEmpty else {
                    throw GalleryOperationError.deletionPostconditionFailed(
                        requested: review.totalCount,
                        survivors: survivors.count
                    )
                }
            }
            #if os(visionOS)
            GalleryViewerStore.shared.removeFromAllAlbums(assets: assets)
            #endif
            showToast(
                .success,
                "Deleted \(review.totalCount) item\(review.totalCount == 1 ? "" : "s")"
            )
        } catch {
            handleOperationError(error, fallback: "Delete failed")
        }
    }

    #if canImport(UIKit) || canImport(AppKit)
        func requestThumbnail(
            for asset: PHAsset,
            targetSize: CGSize = GalleryManager.thumbnailTargetSize,
            completion: @escaping @MainActor (_ image: GalleryPlatformImage?, _ isFinal: Bool) -> Void
        ) -> PHImageRequestID? {
            let key = thumbnailCacheKey(for: asset, targetSize: targetSize)
            if let cachedImage = thumbnailCache.object(forKey: key) {
                completion(cachedImage, true)
                return nil
            }

            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true

            let requestID = imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { [weak self] image, info in
                let delivery = GalleryThumbnailDelivery(info: info)

                Task { @MainActor in
                    guard !delivery.isCancelled else {
                        completion(nil, true)
                        return
                    }

                    guard let image else {
                        completion(nil, delivery.isFinal)
                        return
                    }

                    if delivery.shouldCache {
                        self?.thumbnailCache.setObject(
                            image,
                            forKey: key,
                            cost: Self.thumbnailCost(image)
                        )
                    }
                    completion(image, delivery.isFinal)
                }
            }

            return requestID
        }
    #endif

    func cancelImageRequest(_ requestID: PHImageRequestID) {
        imageManager.cancelImageRequest(requestID)
    }

    func coverAsset(for collection: PHAssetCollection) -> PHAsset? {
        Self.coverAsset(for: collection)
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            await self?.handlePhotoLibraryChange(changeInstance)
        }
    }

    private func isCurrentAlbumLoad(_ generation: UUID) -> Bool {
        albumLoadGeneration == generation && !Task.isCancelled
    }

    private func clearInFlightAlbumFetch(generation: UUID) {
        guard inFlightAlbumFetchGeneration == generation else { return }
        inFlightAlbumFetchGeneration = nil
        inFlightAlbumFetchResult = nil
    }

    private func clearInFlightAssetFetch(generation: UUID? = nil) {
        if let generation, inFlightAssetFetchGeneration != generation {
            return
        }
        inFlightAssetFetchGeneration = nil
        inFlightAssetFetchAlbumID = nil
        inFlightAssetFetchResult = nil
    }

    private func persistAssetSortPreferences() {
        let defaults = UserDefaults.standard
        defaults.set(assetSortMode.rawValue, forKey: Self.assetSortModeDefaultsKey)
        defaults.set(nameSortAscending, forKey: Self.nameSortAscendingDefaultsKey)
        defaults.set(dateSortAscending, forKey: Self.dateSortAscendingDefaultsKey)
    }

    private func makeAlbum(from collection: PHAssetCollection) -> GalleryAlbum {
        let title = collection.localizedTitle ?? "Untitled"
        return GalleryAlbum(
            id: collection.localIdentifier,
            title: title,
            assetCount: Self.assetCountEstimate(for: collection),
            collection: collection,
            coverAsset: nil
        )
    }

    private func sortedAlbums(_ albums: [GalleryAlbum]) -> [GalleryAlbum] {
        albums.sorted { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private static func assetCountEstimate(for collection: PHAssetCollection) -> Int {
        let count = collection.estimatedAssetCount
        return count == NSNotFound ? 0 : max(0, count)
    }

    private static func coverAsset(for collection: PHAssetCollection) -> PHAsset? {
        let options = PHFetchOptions()
        options.fetchLimit = 1
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return PHAsset.fetchAssets(in: collection, options: options).firstObject
    }

    private func insertSelectionRange(from startIndex: Int, to endIndex: Int) {
        let lowerBound = min(startIndex, endIndex)
        let upperBound = max(startIndex, endIndex)
        selectedIndexes.insert(integersIn: lowerBound..<(upperBound + 1))
    }

    private func selectedAssets() throws -> [PHAsset] {
        guard assetFetchResult != nil else {
            throw GalleryOperationError.noAlbumSelected
        }

        let indexes = selectedIndexes.sorted().filter { $0 >= 0 && $0 < totalAssetCount }
        guard !indexes.isEmpty else {
            throw GalleryOperationError.noSelection
        }

        let assets = indexes.compactMap { asset(at: $0) }
        guard assets.count == indexes.count else {
            throw GalleryOperationError.noSelection
        }
        return assets
    }

    private func requireCurrentFullPhotoAccessForDeletion(afterMutation: Bool) throws {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        authorizationStatus = currentStatus
        guard currentStatus == .authorized else {
            if afterMutation {
                throw GalleryOperationError.deletionVerificationAccessChanged
            }
            throw GalleryOperationError.fullPhotoAccessRequiredForDeletion
        }
    }

    private func fetchAssets(withLocalIdentifiers localIdentifiers: [String]) -> [PHAsset] {
        let fetchResult = PHAsset.fetchAssets(
            withLocalIdentifiers: localIdentifiers,
            options: nil
        )
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetchResult.count)
        fetchResult.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
    }

    private static func deletionCandidate(for asset: PHAsset) -> GalleryDeletionCandidate {
        let mediaKind: GalleryDeletionMediaKind
        switch asset.mediaType {
        case .image:
            mediaKind = .photo
        case .video:
            mediaKind = .video
        default:
            mediaKind = .other
        }
        return GalleryDeletionCandidate(
            localIdentifier: asset.localIdentifier,
            mediaKind: mediaKind
        )
    }

    private func runOperation(message: String, operation: () async throws -> Void) async throws {
        isPerformingOperation = true
        operationMessage = message
        errorMessage = nil

        do {
            try await operation()
            clearSelection(silent: true)
            await refreshAfterMutation()
            isPerformingOperation = false
            operationMessage = nil
            successFeedbackSignal += 1
        } catch {
            isPerformingOperation = false
            operationMessage = nil
            throw error
        }
    }

    private func refreshAfterMutation() async {
        guard hasPhotoAccess else { return }

        invalidateAlbumLoad()
        await loadAlbums()
    }

    private func refreshCurrentAlbum(
        keepingSelection: Bool,
        showSortingProgress: Bool,
        resetPaging: Bool = false
    ) async {
        guard let selectedAlbum else {
            closeAlbum()
            return
        }

        let generation = UUID()
        let selectionGeneration = albumSelectionGeneration
        let externalRefreshAuthority = pendingAssetRefreshAuthority.flatMap { authority in
            authority.isCurrent(
                albumID: selectedAlbum.id,
                selectionGeneration: selectionGeneration
            ) ? authority : nil
        }
        assetLoadGeneration = generation
        isSortingAssets = true
        sortingMessage = showSortingProgress
            ? "Applying \(assetSortMode.title) order..."
            : nil

        let fetchResult = PHAsset.fetchAssets(
            in: selectedAlbum.collection,
            options: assetFetchOptions()
        )
        inFlightAssetFetchGeneration = generation
        inFlightAssetFetchAlbumID = selectedAlbum.id
        inFlightAssetFetchResult = fetchResult
        defer { clearInFlightAssetFetch(generation: generation) }
        let displayOrder = await buildAssetDisplayOrder(
            for: fetchResult,
            generation: generation
        )

        guard
            assetLoadGeneration == generation,
            self.selectedAlbum?.id == selectedAlbum.id,
            albumSelectionGeneration == selectionGeneration
        else {
            return
        }

        assetFetchResult = fetchResult
        assetFetchAlbumID = selectedAlbum.id
        clearInFlightAssetFetch(generation: generation)
        assetDisplayOrder = displayOrder
        totalAssetCount = fetchResult.count
        visibleAssetCount = GalleryPagingPolicy.visibleCount(
            current: visibleAssetCount,
            total: totalAssetCount,
            resetsForNewAlbum: resetPaging
        )
        if !keepingSelection {
            clearSelection(silent: true)
        } else {
            var validSelection = IndexSet()
            for index in selectedIndexes where index < totalAssetCount {
                validSelection.insert(index)
            }
            selectedIndexes = validSelection
        }
        resetImagePreheating()
        isSortingAssets = false
        sortingMessage = nil
        let completesAlbumOpen =
            pendingAlbumOpenIntent?.isCurrent(
                albumID: selectedAlbum.id,
                selectionGeneration: selectionGeneration
            ) ?? false
        let completesExternalRefresh =
            externalRefreshAuthority.map { authority in
                pendingAssetRefreshAuthority?.id == authority.id
            } ?? false
        if completesExternalRefresh {
            pendingAssetRefreshAuthority = nil
        }
        if completesAlbumOpen {
            pendingAlbumOpenIntent = nil
            isLoadingAlbum = false
            assetLoadingMessage = nil
            showToast(.info, "\(selectedAlbum.title) loaded")
        } else if completesExternalRefresh {
            showToast(.info, "Album updated")
        }
    }

    private func assetFetchOptions() -> PHFetchOptions? {
        guard assetSortMode == .date else { return nil }

        let options = PHFetchOptions()
        options.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: dateSortAscending)
        ]
        return options
    }

    private func buildAssetDisplayOrder(
        for fetchResult: PHFetchResult<PHAsset>,
        generation: UUID
    ) async -> [Int]? {
        switch assetSortMode {
        case .photosOrder, .date:
            return nil
        case .random:
            return Array(0..<fetchResult.count).shuffled()
        case .name:
            var records: [GalleryNamedAssetIndex] = []
            records.reserveCapacity(fetchResult.count)

            for index in 0..<fetchResult.count {
                guard assetLoadGeneration == generation else { return nil }

                let asset = fetchResult.object(at: index)
                records.append(
                    GalleryNamedAssetIndex(
                        index: index,
                        name: assetFilename(asset)
                    )
                )

                let loadedCount = index + 1
                if loadedCount == 1 || loadedCount % 50 == 0 || loadedCount == fetchResult.count {
                    updateAssetSortingProgress(
                        "Reading names \(loadedCount) of \(fetchResult.count)..."
                    )
                    await Task.yield()
                }
            }

            guard assetLoadGeneration == generation else { return nil }
            let ascending = nameSortAscending
            updateAssetSortingProgress("Sorting \(records.count) names...")

            return await Task.detached(priority: .userInitiated) {
                records.sorted { lhs, rhs in
                    let result = lhs.name.localizedStandardCompare(rhs.name)
                    if result == .orderedSame {
                        return lhs.index < rhs.index
                    }
                    return ascending
                        ? result == .orderedAscending
                        : result == .orderedDescending
                }
                .map(\.index)
            }.value
        }
    }

    private func assetFilename(_ asset: PHAsset) -> String {
        let resources = PHAssetResource.assetResources(for: asset)
        let preferredTypes: [PHAssetResourceType]

        if asset.mediaType == .video {
            preferredTypes = [.video, .fullSizeVideo]
        } else {
            preferredTypes = [.photo, .fullSizePhoto]
        }

        for type in preferredTypes {
            if let resource = resources.first(where: { $0.type == type }) {
                return resource.originalFilename
            }
        }

        return resources.first?.originalFilename ?? asset.localIdentifier
    }

    private func updateAssetSortingProgress(_ message: String) {
        if isLoadingAlbum {
            assetLoadingMessage = message
        } else {
            sortingMessage = message
        }
    }

    private func handleOperationError(_ error: Error, fallback: String) {
        let message = error.localizedDescription.isEmpty ? fallback : error.localizedDescription
        errorMessage = message
        showToast(.error, message)
        errorFeedbackSignal += 1
    }

    private func showToast(_ kind: GalleryToast.Kind, _ message: String) {
        let nextToast = GalleryToast(kind: kind, message: message)
        toast = nextToast

        switch kind {
        case .success:
            successFeedbackSignal += 1
        case .warning:
            warningFeedbackSignal += 1
        case .error:
            errorFeedbackSignal += 1
        case .info:
            break
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if self?.toast?.id == nextToast.id {
                self?.toast = nil
            }
        }
    }

    private func updateImagePreheating() {
        guard let assetFetchResult, !visibleIndexes.isEmpty else {
            resetImagePreheating()
            return
        }

        let lowerBound = max(0, (visibleIndexes.min() ?? 0) - Self.preheatPadding)
        let upperBound = min(totalAssetCount, (visibleIndexes.max() ?? 0) + Self.preheatPadding)
        let nextRange = lowerBound..<upperBound

        guard nextRange != preheatedRange else {
            return
        }

        if let preheatedRange {
            imageManager.stopCachingImages(
                for: assets(in: preheatedRange, from: assetFetchResult),
                targetSize: Self.thumbnailTargetSize,
                contentMode: .aspectFill,
                options: nil
            )
        }

        imageManager.startCachingImages(
            for: assets(in: nextRange, from: assetFetchResult),
            targetSize: Self.thumbnailTargetSize,
            contentMode: .aspectFill,
            options: nil
        )
        preheatedRange = nextRange
    }

    private func resetImagePreheating() {
        visibleIndexes.removeAll()
        imageManager.stopCachingImagesForAllAssets()
        preheatedRange = nil
    }

    private func assets(in range: Range<Int>, from fetchResult: PHFetchResult<PHAsset>) -> [PHAsset] {
        guard !range.isEmpty else {
            return []
        }

        return range.compactMap { displayIndex in
            guard displayIndex >= 0, displayIndex < totalAssetCount else {
                return nil
            }

            let sourceIndex: Int
            if let assetDisplayOrder {
                guard assetDisplayOrder.indices.contains(displayIndex) else { return nil }
                sourceIndex = assetDisplayOrder[displayIndex]
            } else {
                sourceIndex = displayIndex
            }

            guard sourceIndex >= 0, sourceIndex < fetchResult.count else { return nil }
            return fetchResult.object(at: sourceIndex)
        }
    }

    private func handlePhotoLibraryChange(_ changeInstance: PHChange) async {
        let committedAlbumsChanged =
            albumFetchResult.map {
                changeInstance.changeDetails(for: $0) != nil
            } ?? false
        let inFlightAlbumsChanged =
            inFlightAlbumFetchResult.map {
                changeInstance.changeDetails(for: $0) != nil
            } ?? false
        let committedAssetFetchChanged =
            assetFetchResult.map {
                changeInstance.changeDetails(for: $0) != nil
            } ?? false
        let inFlightAssetFetchChanged =
            inFlightAssetFetchResult.map {
                changeInstance.changeDetails(for: $0) != nil
            } ?? false
        var changedAssetFetchAlbumIDs = Set<String>()
        if committedAssetFetchChanged, let assetFetchAlbumID {
            changedAssetFetchAlbumIDs.insert(assetFetchAlbumID)
        }
        if inFlightAssetFetchChanged, let inFlightAssetFetchAlbumID {
            changedAssetFetchAlbumIDs.insert(inFlightAssetFetchAlbumID)
        }
        let refreshAuthority = GalleryAssetRefreshAuthority.issue(
            selectedAlbumID: selectedAlbum?.id,
            selectionGeneration: albumSelectionGeneration,
            changedFetchAlbumIDs: changedAssetFetchAlbumIDs
        )
        let decision = GalleryAlbumChangeDecision(
            committedFetchChanged: committedAlbumsChanged,
            inFlightFetchChanged: inFlightAlbumsChanged,
            assetFetchChanged: !changedAssetFetchAlbumIDs.isEmpty
        )

        if let refreshAuthority {
            pendingAssetRefreshAuthority = refreshAuthority
            assetLoadGeneration = UUID()
            clearInFlightAssetFetch()
            isSortingAssets = false
            sortingMessage = nil
        }

        if decision.shouldReloadAlbums {
            if let selectedAlbumID = refreshAuthority?.albumID ?? selectedAlbum?.id {
                pendingAlbumRemovalWarning = GalleryAlbumRemovalWarningIntent(
                    albumID: selectedAlbumID
                )
            }
            invalidateAlbumLoad()
            await loadAlbums(refreshSelectedAlbumAssets: false)
        }

        if !decision.shouldReloadAlbums,
            decision.shouldRefreshAssets,
            let refreshAuthority,
            refreshAuthority.isCurrent(
                albumID: selectedAlbum?.id,
                selectionGeneration: albumSelectionGeneration
            )
        {
            await refreshCurrentAlbum(keepingSelection: false, showSortingProgress: false)
        }
    }

    private func invalidateAlbumLoad() {
        albumLoadGeneration = UUID()
        inFlightAlbumFetchGeneration = nil
        inFlightAlbumFetchResult = nil
        albumIndexingMessage = nil
        loadedAlbumCount = 0
        totalAlbumCount = 0
        isLoadingAlbums = false
    }

    #if canImport(UIKit) || canImport(AppKit)
        private func thumbnailCacheKey(for asset: PHAsset, targetSize: CGSize) -> NSString {
            let modificationVersion = asset.modificationDate?.timeIntervalSinceReferenceDate ?? 0
            let dimensions = "\(Int(targetSize.width))x\(Int(targetSize.height))"
            return "\(asset.localIdentifier)|\(modificationVersion)|\(dimensions)" as NSString
        }

        private static func thumbnailCost(_ image: GalleryPlatformImage) -> Int {
            #if canImport(UIKit)
                if let cgImage = image.cgImage {
                    return cgImage.bytesPerRow * cgImage.height
                }

                let width = image.size.width * image.scale
                let height = image.size.height * image.scale
                return Int(width * height * 4)
            #else
                if let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
                    return bitmap.bytesPerRow * bitmap.pixelsHigh
                }
                return Int(image.size.width * image.size.height * 4)
            #endif
        }
    #endif
}

private enum GalleryOperationError: LocalizedError {
    case noAlbumSelected
    case noSelection
    case albumCreationFailed
    case sourceAlbumNotEditable(String)
    case destinationAlbumNotEditable(String)
    case albumNotRenamable(String)
    case changeRequestUnavailable
    case fullPhotoAccessRequiredForDeletion
    case invalidDeletionSnapshot
    case deletionReviewExpired
    case deletionSelectionChanged(expected: Int, found: Int)
    case deletionVerificationAccessChanged
    case deletionPostconditionFailed(requested: Int, survivors: Int)
    case permanentDeleteOnlyInRecycleBin

    var errorDescription: String? {
        switch self {
        case .noAlbumSelected:
            return "Choose an album first."
        case .noSelection:
            return "Select at least one item first."
        case .albumCreationFailed:
            return "Photos could not create that album."
        case .sourceAlbumNotEditable(let title):
            return "Photos does not allow removing items from \(title)."
        case .destinationAlbumNotEditable(let title):
            return "Photos does not allow adding items to \(title)."
        case .albumNotRenamable(let title):
            return "Photos does not allow renaming \(title)."
        case .changeRequestUnavailable:
            return "Photos could not prepare that album change. Nothing was changed."
        case .fullPhotoAccessRequiredForDeletion:
            return
                "Full Photos access is required for library deletion so Gallery can verify every selected item."
        case .invalidDeletionSnapshot:
            return
                "Gallery could not freeze an exact, unique list of selected items. Nothing was deleted."
        case .deletionReviewExpired:
            return
                "That deletion review is no longer current or was already used. Nothing was deleted; "
                + "review the selection again."
        case .deletionSelectionChanged(let expected, let found):
            return
                "The reviewed deletion changed before Photos opened "
                + "(expected \(expected) items, found \(found)). Nothing was deleted; "
                + "review the selection again."
        case .deletionVerificationAccessChanged:
            return
                "Photos accepted the deletion request, but full library access changed before Gallery "
                + "could verify it. Gallery will not claim completion; check Photos before retrying."
        case .deletionPostconditionFailed(let requested, let survivors):
            return
                "Photos accepted the deletion request, but \(survivors) of \(requested) items "
                + "still appear in the library. Gallery will not claim completion; "
                + "review before retrying."
        case .permanentDeleteOnlyInRecycleBin:
            return "Permanent deletion is only available for items inside Recycle Bin."
        }
    }
}
