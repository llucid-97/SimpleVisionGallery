import Foundation

enum PHAccessLevel { case readWrite }
enum PHAuthorizationStatus { case authorized, limited, denied }
enum PHAssetEditOperation { case delete }
enum PHAssetCollectionEditOperation { case addContent, removeContent }

struct FakePhotoFailure: Error {}
enum FakePhotoMode { case succeed, failBeforeBlock, failAfterBlock }

final class FakeTransaction {
    var adds: [String: Set<String>] = [:]
    var removes: [String: Set<String>] = [:]
    var deletes = Set<String>()
}

final class PHAsset: NSObject {
    let localIdentifier: String
    var deletable = true
    init(_ id: String) { localIdentifier = id }
    func canPerform(_ operation: PHAssetEditOperation) -> Bool { deletable }
    static func fetchAssets(withLocalIdentifiers ids: [String], options: Any?) -> PHFetchResult<PHAsset> {
        PHFetchResult(ids.compactMap { FakePhotoLibrary.assets[$0] })
    }
    static func fetchAssets(in collection: PHAssetCollection, options: Any?) -> PHFetchResult<PHAsset> {
        PHFetchResult(collection.assetIDs.sorted().compactMap { FakePhotoLibrary.assets[$0] })
    }
}

final class PHAssetCollection: NSObject {
    let localIdentifier: String
    var localizedTitle: String?
    var canAdd = true
    var canRemove = true
    var assetIDs = Set<String>()
    init(_ id: String, _ title: String) { localIdentifier = id; localizedTitle = title }
    func canPerform(_ operation: PHAssetCollectionEditOperation) -> Bool {
        operation == .addContent ? canAdd : canRemove
    }
    static func fetchAssetCollections(withLocalIdentifiers ids: [String], options: Any?) -> PHFetchResult<PHAssetCollection> {
        PHFetchResult(ids.compactMap { FakePhotoLibrary.collections[$0] })
    }
}

final class PHFetchResult<Element> {
    private let values: [Element]
    init(_ values: [Element]) { self.values = values }
    var count: Int { values.count }
    func object(at index: Int) -> Element { values[index] }
    var firstObject: Element? { values.first }
    func index(of asset: PHAsset) -> Int {
        (values as? [PHAsset])?.firstIndex { $0.localIdentifier == asset.localIdentifier } ?? NSNotFound
    }
}

enum FakePhotoLibrary {
    static var assets: [String: PHAsset] = [:]
    static var collections: [String: PHAssetCollection] = [:]
    static var authorization: PHAuthorizationStatus = .authorized
    static var mode: FakePhotoMode = .succeed
    static var calls = 0
    static var blockCalls = 0
    static var committedAdds: [String: Set<String>] = [:]
    static var committedRemoves: [String: Set<String>] = [:]
    static var committedDeletes = Set<String>()
    static var active: FakeTransaction?

    static func reset() {
        assets = [:]; collections = [:]; authorization = .authorized; mode = .succeed
        calls = 0; blockCalls = 0; committedAdds = [:]; committedRemoves = [:]
        committedDeletes = []; active = nil
    }
    static func stageAdd(_ ids: [String], to collection: String) { active?.adds[collection, default: []].formUnion(ids) }
    static func stageRemove(_ ids: [String], from collection: String) { active?.removes[collection, default: []].formUnion(ids) }
    static func stageDelete(_ ids: [String]) { active?.deletes.formUnion(ids) }
    static func commit(_ transaction: FakeTransaction) {
        for (id, ids) in transaction.adds { collections[id]?.assetIDs.formUnion(ids) }
        for (id, ids) in transaction.removes { collections[id]?.assetIDs.subtract(ids) }
        for id in transaction.deletes {
            assets.removeValue(forKey: id)
            for collection in collections.values { collection.assetIDs.remove(id) }
        }
        committedAdds = transaction.adds; committedRemoves = transaction.removes; committedDeletes = transaction.deletes
    }
}

final class PHPhotoLibrary {
    static func shared() -> PHPhotoLibrary { PHPhotoLibrary() }
    static func authorizationStatus(for level: PHAccessLevel) -> PHAuthorizationStatus { FakePhotoLibrary.authorization }
    func performChanges(_ changes: () -> Void) async throws {
        FakePhotoLibrary.calls += 1
        if FakePhotoLibrary.mode == .failBeforeBlock { throw FakePhotoFailure() }
        let tx = FakeTransaction()
        FakePhotoLibrary.active = tx
        FakePhotoLibrary.blockCalls += 1
        changes()
        FakePhotoLibrary.active = nil
        if FakePhotoLibrary.mode == .failAfterBlock { throw FakePhotoFailure() }
        FakePhotoLibrary.commit(tx)
    }
}

final class PHAssetCollectionChangeRequest {
    let collection: PHAssetCollection
    var placeholderForCreatedAssetCollection: PHAssetCollection { collection }
    init?(for collection: PHAssetCollection) { self.collection = collection }
    static func creationRequestForAssetCollection(withTitle title: String) -> PHAssetCollectionChangeRequest {
        let id = "created-\(UUID().uuidString)"
        let collection = PHAssetCollection(id, title)
        FakePhotoLibrary.collections[id] = collection
        return PHAssetCollectionChangeRequest(for: collection)!
    }
    func addAssets(_ assets: NSArray) { FakePhotoLibrary.stageAdd(Self.ids(assets), to: collection.localIdentifier) }
    func removeAssets(_ assets: NSArray) { FakePhotoLibrary.stageRemove(Self.ids(assets), from: collection.localIdentifier) }
    private static func ids(_ assets: NSArray) -> [String] { (assets as? [PHAsset] ?? []).map(\.localIdentifier) }
}

final class PHAssetChangeRequest {
    static func deleteAssets(_ assets: NSArray) {
        FakePhotoLibrary.stageDelete((assets as? [PHAsset] ?? []).map(\.localIdentifier))
    }
}

enum GalleryRecycleBin {
    static let title = "Recycle Bin"
    static func isRecycleBinTitle(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(title) == .orderedSame
    }
    static func existingCollection() -> PHAssetCollection? {
        FakePhotoLibrary.collections.values.first { isRecycleBinTitle($0.localizedTitle) && $0.canAdd }
    }
}
