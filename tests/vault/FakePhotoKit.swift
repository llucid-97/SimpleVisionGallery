import Foundation
import Combine
import CoreLocation
import CryptoKit
@preconcurrency import Photos

nonisolated enum UIApplication {
    static let protectedDataWillBecomeUnavailableNotification = Notification.Name("UIApplicationProtectedDataWillBecomeUnavailable")
}
extension Notification.Name {
    static let galleryVaultWillLock = Notification.Name("GalleryVaultWillLock")
    static let galleryVaultDidLock = Notification.Name("GalleryVaultDidLock")
    static let galleryVaultDidHideItems = Notification.Name("GalleryVaultDidHideItems")
    static let galleryVaultDidRestoreItem = Notification.Name("GalleryVaultDidRestoreItem")
}
nonisolated enum PHAuthorizationStatus { case authorized, limited }
nonisolated enum PHAccessLevel { case readWrite }
nonisolated enum PHAssetCollectionType { case album }
nonisolated enum PHAssetResourceType: Int { case photo = 1, video = 2 }
nonisolated enum PHAssetMediaType: Int { case image = 1, video = 2 }
nonisolated enum PHAssetEditOperation { case delete }
nonisolated enum PHCollectionEditOperation { case addContent }
nonisolated struct PHAssetMediaSubtype: OptionSet, Sendable { let rawValue: UInt }
typealias PHAssetResourceDataRequestID = Int32
nonisolated final class PHFetchResult<T>: @unchecked Sendable {
    let values: [T]
    init(_ values: [T]) { self.values = values }
    var count: Int { values.count }
    func object(at i: Int) -> T { values[i] }
}
nonisolated final class PHAsset: @unchecked Sendable {
    let localIdentifier: String
    var mediaType: PHAssetMediaType = .image
    var mediaSubtypes = PHAssetMediaSubtype(rawValue: 0)
    var pixelWidth = 16, pixelHeight = 16
    var duration = 0.0
    var creationDate: Date? = Date(timeIntervalSince1970: 123456)
    var modificationDate: Date? = Date(timeIntervalSince1970: 123456)
    var isFavorite = false
    var location: CLLocation?
    var resources: [PHAssetResource]
    var parents: [String]
    init(_ id: String, bytes: Data = Data("photo".utf8), parents: [String] = ["album"]) {
        localIdentifier = id; resources = [PHAssetResource(source: id, filename: id + ".jpg", bytes: bytes)]; self.parents = parents
    }
    func canPerform(_ operation: PHAssetEditOperation) -> Bool { true }
    static func fetchAssets(in album: PHAssetCollection, options: Any?) -> PHFetchResult<PHAsset> {
        PHFetchResult(FakePhotos.assets.values.filter { $0.parents.contains(album.localIdentifier) })
    }
}
nonisolated final class PHAssetCollection: @unchecked Sendable {
    let localIdentifier: String
    init(_ id: String) { localIdentifier = id }
    func canPerform(_ operation: PHCollectionEditOperation) -> Bool { !FakePhotos.unavailableParents.contains(localIdentifier) }
    static func fetchAssetCollections(withLocalIdentifiers ids: [String], options: Any?) -> PHFetchResult<PHAssetCollection> {
        PHFetchResult(ids.filter { !FakePhotos.missingParents.contains($0) }.map(PHAssetCollection.init))
    }
    static func fetchAssetCollectionsContaining(_ asset: PHAsset, with type: PHAssetCollectionType, options: Any?) -> PHFetchResult<PHAssetCollection> {
        PHFetchResult(asset.parents.map(PHAssetCollection.init))
    }
}
nonisolated final class PHAssetResource: @unchecked Sendable {
    let source: String
    let type: PHAssetResourceType
    let originalFilename: String
    let uniformTypeIdentifier: String
    let bytes: Data
    init(source: String, filename: String, bytes: Data, type: PHAssetResourceType = .photo, uti: String = "public.jpeg") {
        self.source = source; self.originalFilename = filename; self.bytes = bytes; self.type = type; self.uniformTypeIdentifier = uti
    }
    static func assetResources(for asset: PHAsset) -> [PHAssetResource] { asset.resources }
}
nonisolated final class PHAssetResourceRequestOptions { var isNetworkAccessAllowed = false }
nonisolated final class PHAssetResourceCreationOptions { var originalFilename: String?; var uniformTypeIdentifier: String? }
nonisolated final class PHObjectPlaceholder { let localIdentifier: String; init(_ id: String) { localIdentifier = id } }
nonisolated final class PHAssetResourceManager: @unchecked Sendable {
    static let shared = PHAssetResourceManager()
    static func `default`() -> PHAssetResourceManager { shared }
    func requestData(for resource: PHAssetResource, options: PHAssetResourceRequestOptions?, dataReceivedHandler: @escaping (Data) -> Void, completionHandler: @escaping (Error?) -> Void) -> PHAssetResourceDataRequestID {
        FakePhotos.markStarted(resource.source)
        if resource.source == FakePhotos.delayedID {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { dataReceivedHandler(resource.bytes); completionHandler(nil) }
        } else {
            DispatchQueue.global().async { dataReceivedHandler(resource.bytes); completionHandler(nil) }
        }
        return 1
    }
    func cancelDataRequest(_ requestID: PHAssetResourceDataRequestID) {}
}
nonisolated final class PHAssetCreationRequest {
    let placeholderForCreatedAsset: PHObjectPlaceholder? = PHObjectPlaceholder(UUID().uuidString)
    var creationDate: Date?
    var isFavorite = false
    var location: CLLocation?
    var resources: [PHAssetResource] = []
    static func forAsset() -> PHAssetCreationRequest { let request = PHAssetCreationRequest(); FakePhotos.creationCalls += 1; FakePhotos.pendingCreation = request; return request }
    func addResource(with type: PHAssetResourceType, fileURL: URL, options: PHAssetResourceCreationOptions?) {
        resources.append(PHAssetResource(source: placeholderForCreatedAsset!.localIdentifier, filename: options?.originalFilename ?? "file", bytes: (try? Data(contentsOf: fileURL)) ?? Data(), type: type, uti: options?.uniformTypeIdentifier ?? "public.jpeg"))
    }
}
nonisolated final class PHAssetCollectionChangeRequest {
    let album: PHAssetCollection
    init?(for collection: PHAssetCollection, assets: PHFetchResult<PHAsset>) { album = collection }
    func insertAssets(_ assets: NSArray, at indexes: IndexSet) { FakePhotos.pendingParents.append(album.localIdentifier) }
    func addAssets(_ assets: NSArray) { FakePhotos.pendingParents.append(album.localIdentifier) }
}
nonisolated final class PHPhotoLibrary {
    static let sharedValue = PHPhotoLibrary()
    static func shared() -> PHPhotoLibrary { sharedValue }
    static func authorizationStatus(for level: PHAccessLevel) -> PHAuthorizationStatus { .authorized }
    func performChanges(_ work: () -> Void) async throws {
        FakePhotos.pendingCreation = nil; FakePhotos.pendingParents = []
        work()
        if FakePhotos.failImport { throw FakeError.injected }
        if FakePhotos.cancelImportBeforeCommit { throw CancellationError() }
        if let creation = FakePhotos.pendingCreation, let id = creation.placeholderForCreatedAsset?.localIdentifier, !creation.resources.isEmpty {
            let asset = PHAsset(id, parents: FakePhotos.pendingParents)
            asset.resources = creation.resources; asset.creationDate = creation.creationDate; asset.isFavorite = creation.isFavorite
            FakePhotos.assets[id] = asset
        }
        if FakePhotos.cancelImportAfterCommit { throw CancellationError() }
    }
}
nonisolated enum FakeError: Error { case injected, outOfSpace }
nonisolated enum FakePhotos {
    nonisolated(unsafe) static var assets: [String: PHAsset] = [:]
    nonisolated(unsafe) static var deleteCalls: [[String]] = []
    nonisolated(unsafe) static var failDelete = false, failImport = false
    nonisolated(unsafe) static var cancelImportBeforeCommit = false, cancelImportAfterCommit = false
    nonisolated(unsafe) static var creationCalls = 0
    nonisolated(unsafe) static var unavailableParents: Set<String> = []
    nonisolated(unsafe) static var missingParents: Set<String> = []
    nonisolated(unsafe) static var failCopyID: String?
    nonisolated(unsafe) static var delayedID: String?
    nonisolated(unsafe) static var pendingCreation: PHAssetCreationRequest?
    nonisolated(unsafe) static var pendingParents: [String] = []
    nonisolated(unsafe) static var resourceSource: [UUID: String] = [:]
    static let startedLock = NSLock()
    nonisolated(unsafe) static var started: Set<String> = []
    static func markStarted(_ id: String) { startedLock.lock(); started.insert(id); startedLock.unlock() }
    static func hasStarted(_ id: String) -> Bool { startedLock.lock(); defer { startedLock.unlock() }; return started.contains(id) }
    static func reset() { assets = [:]; deleteCalls = []; failDelete = false; failImport = false; cancelImportBeforeCommit = false; cancelImportAfterCommit = false; creationCalls = 0; unavailableParents = []; missingParents = []; failCopyID = nil; delayedID = nil; pendingCreation = nil; pendingParents = []; resourceSource = [:]; startedLock.lock(); started = []; startedLock.unlock() }
}
nonisolated enum GalleryVaultTransferError: LocalizedError {
    case fullAccessRequired, unsupportedItem, unsupportedResources, missingResources, locked, busy
    case albumUnavailable(String), changedOriginal, missingOriginal, photoRequestFailed, interruptedRestore
    case journalFailed, importFailed, cancelled, alreadyInVault, pendingCopyUnavailable
    var errorDescription: String? { String(describing: self) }
}
typealias PHPhotosError = Photos.PHPhotosError
nonisolated let PHPhotosErrorDomain = Photos.PHPhotosErrorDomain
nonisolated enum GalleryVaultStorageError: Error { case corruptRecord, corruptResource, incompleteItem }
nonisolated enum GalleryVaultPhotoLibrary {
    struct Prepared: @unchecked Sendable { let record: GalleryVaultRecord; let resources: [PHAssetResource] }
    static func requireFullAccess() throws {}
    static func prepare(_ asset: PHAsset, sourceAlbumID: String?, sourcePosition: Int?) throws -> Prepared {
        let id = UUID(); FakePhotos.resourceSource[id] = asset.localIdentifier
        let resource = GalleryVaultResource(id: id, type: 1, filename: asset.resources[0].originalFilename, uniformTypeIdentifier: "public.jpeg")
        let albums = asset.parents.map { GalleryVaultAlbum(id: $0, title: $0, position: $0 == sourceAlbumID ? sourcePosition : nil) }
        return Prepared(record: GalleryVaultRecord(id: UUID(), sourceIdentifier: asset.localIdentifier, filename: resource.filename, mediaType: 1, mediaSubtypes: 0, pixelWidth: 16, pixelHeight: 16, duration: 0, creationDate: asset.creationDate, modificationDate: asset.modificationDate, latitude: asset.location?.coordinate.latitude, longitude: asset.location?.coordinate.longitude, isFavorite: asset.isFavorite, albums: albums, resources: [resource], state: .copiedAwaitingDeletion, restoredIdentifier: nil), resources: asset.resources)
    }
    static func isSameVersion(_ asset: PHAsset, as record: GalleryVaultRecord) -> Bool { asset.modificationDate == record.modificationDate && asset.isFavorite == record.isFavorite && asset.location?.coordinate.latitude == record.latitude && asset.location?.coordinate.longitude == record.longitude }
    static func fetch(ids: [String]) throws -> [String: PHAsset] { Dictionary(uniqueKeysWithValues: ids.compactMap { id in FakePhotos.assets[id].map { (id, $0) } }) }
    static func delete(_ sources: [(PHAsset, GalleryVaultRecord)]) async throws {
        let ids = sources.map { $0.1.sourceIdentifier }; FakePhotos.deleteCalls.append(ids)
        if FakePhotos.failDelete { throw FakeError.injected }
        ids.forEach { FakePhotos.assets.removeValue(forKey: $0) }
    }
    static func usableParents(_ record: GalleryVaultRecord, omittingUnavailable: Bool = false) throws -> [(GalleryVaultAlbum, PHAssetCollection)] {
        try record.albums.compactMap { album in
            if FakePhotos.unavailableParents.contains(album.id) {
                if omittingUnavailable { return nil }
                throw GalleryVaultTransferError.albumUnavailable(album.title)
            }
            return (album, PHAssetCollection(album.id))
        }
    }
}
nonisolated final class GalleryVaultResourceWriter: @unchecked Sendable {
    let id: UUID; var bytes = Data()
    init(_ id: UUID) { self.id = id }
    func append(_ data: Data) throws { if FakePhotos.resourceSource[id] == FakePhotos.failCopyID { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }; bytes.append(data) }
    func finish() throws {}
}
nonisolated final class GalleryVaultStagingItem {
    let id: UUID; var writers: [UUID: GalleryVaultResourceWriter] = [:]
    init(_ id: UUID) { self.id = id }
    func writer(resourceID: UUID) throws -> GalleryVaultResourceWriter { let w = GalleryVaultResourceWriter(resourceID); writers[resourceID] = w; return w }
    func discard() {}
}
@MainActor final class GalleryVaultStorage: ObservableObject {
    static let shared = GalleryVaultStorage()
    var isUnlocked = false
    var unreadableRecordCount = 0
    var cleanupWarning: String?
    var simulatedCleanupFailure = false
    var generation = UUID()
    var pendingUnlock: CheckedContinuation<Void, Never>?
    var delayUnlock = false
    var lockAtUnlockReturn = false
    var lockAtEndBatch = false
    var failCommitSource: String?
    var failVerifyIDs: Set<UUID> = []
    var durable: [UUID: GalleryVaultRecord] = [:]
    var blobs: [UUID: Data] = [:]
    var records: [GalleryVaultRecord] { Array(durable.values) }
    func reset() { isUnlocked = false; unreadableRecordCount = 0; cleanupWarning = nil; simulatedCleanupFailure = false; generation = UUID(); pendingUnlock = nil; delayUnlock = false; lockAtUnlockReturn = false; lockAtEndBatch = false; failCommitSource = nil; failVerifyIDs = []; durable = [:]; blobs = [:] }
    func unlock() async throws {
        let expected = generation
        if delayUnlock { await withCheckedContinuation { pendingUnlock = $0 } }
        guard generation == expected else { throw GalleryVaultTransferError.locked }
        isUnlocked = true
        if lockAtUnlockReturn { GalleryVaultService.shared.lock() }
    }
    func lock() { generation = UUID(); isUnlocked = false; unreadableRecordCount = 0; cleanupWarning = simulatedCleanupFailure ? "Private media cleanup failed." : nil }
    func beginBatch() {}
    func endBatch() { if lockAtEndBatch { lockAtEndBatch = false; GalleryVaultService.shared.lock() } }
    func record(id: UUID) -> GalleryVaultRecord? { durable[id] }
    func record(sourceIdentifier: String) -> GalleryVaultRecord? { durable.values.first { $0.sourceIdentifier == sourceIdentifier } }
    func createItem(id: UUID) throws -> GalleryVaultStagingItem { guard isUnlocked else { throw GalleryVaultTransferError.locked }; return GalleryVaultStagingItem(id) }
    func commit(_ record: GalleryVaultRecord, from item: GalleryVaultStagingItem) throws { guard isUnlocked else { throw GalleryVaultTransferError.locked }; if failCommitSource == record.sourceIdentifier { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }; for (id,w) in item.writers { blobs[id] = w.bytes }; durable[record.id] = record }
    func update(_ record: GalleryVaultRecord) throws { guard isUnlocked else { throw GalleryVaultTransferError.locked }; durable[record.id] = record }
    func remove(id: UUID) throws { durable.removeValue(forKey: id) }
    func verifyCommitted(id: UUID) async throws -> GalleryVaultRecord { guard isUnlocked, let r = durable[id] else { throw GalleryVaultTransferError.locked }; if failVerifyIDs.contains(id) { throw FakeError.injected }; return r }
    func decryptResource(recordID: UUID, resourceID: UUID) async throws -> URL { guard let data = blobs[resourceID] else { throw GalleryVaultTransferError.missingResources }; let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try data.write(to: url); return url }
    func releasePlaintext(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}
