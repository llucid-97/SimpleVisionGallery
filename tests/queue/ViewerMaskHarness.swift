// Target audience: agents. Fake PhotoKit data exercises the extracted production handoff.
import Foundation
final class PHAsset { let localIdentifier: String; init(localIdentifier: String) { self.localIdentifier = localIdentifier } }
struct PHFetchResult<T> {
    let values: [PHAsset]
    var count: Int { values.count }
    func index(of asset: PHAsset) -> Int { values.firstIndex { $0.localIdentifier == asset.localIdentifier } ?? NSNotFound }
}
struct GalleryAlbum { let id: String; var title = "album"; var virtualScope: Scope? = .photos }
enum Scope { case photos, unfiled, recycleBin }
enum GalleryRecycleBin { static func isRecycleBinTitle(_ title: String) -> Bool { false } }
struct GalleryVaultRecord { let id: UUID }
enum GalleryMediaFilter { case all }
enum GalleryAssetSortMode { case photosOrder }
enum Action: Equatable { case recycle, permanent, moveToPhotos(destinationID: String?, newName: String?), moveToVault(id: String?, epoch: UUID, sourceAlbumID: String?), removeFromAlbum; func keepsVaultItemHidden(inRecycleBin: Bool) -> Bool { true } }
struct GalleryDeleteRequest {
    enum Target { case photos(String, sourceAlbumID: String?), vault(UUID, epoch: UUID) }
    let target: Target; let action: Action
    var itemID: String { switch target { case .photos(let id, _): id; case .vault(let id, _): "vault:\(id)" } }
}
@MainActor final class GalleryDeleteQueue {
    static let shared = GalleryDeleteQueue()
    var pendingRequests: [GalleryDeleteRequest] = []
    var pendingPhotoAssets: [String: PHAsset] = [:]
    var pendingVaultIDs = Set<UUID>()
}
// INDEX
// SNAPSHOT
// PLAYLIST
/// Supply the extracted manager methods with a small stale, custom-sorted Photos fetch.
@MainActor final class GalleryManager {
    var pendingDisplayIndexDirty = true
    var pendingDisplayIndex = GalleryPlaylistIndex(originalCount: 0)
    var committedNativeRemovals = IndexSet()
    var committedPhotoDeletes: [String: GalleryDeleteRequest] = [:]
    var committedPhotoAssets: [String: PHAsset] = [:]
    var backingTotalAssetCount = 3
    var assetFetchResult: PHFetchResult<PHAsset>? = .init(values: [.init(localIdentifier: "A"), .init(localIdentifier: "B"), .init(localIdentifier: "C")])
    var assetFetchAlbumID: String? = "album"
    var selectedAlbum: GalleryAlbum? = .init(id: "album")
    var assetDisplayOrder: [Int]? = [2, 0, 1]
    var nativeAssetCount: Int { assetDisplayOrder?.count ?? assetFetchResult?.count ?? 0 }
    var currentVaultPositions: [UUID: Int] = [:]
    var currentVaultDisplayIndex = GalleryPlaylistIndex(originalCount: 0)
    var currentVaultRecords: [GalleryVaultRecord] = []
    var isLoadingAlbum = false, isSortingAssets = false
    var viewerSnapshotID = UUID()
    var mediaFilter: GalleryMediaFilter = .all
    var mediaSearchQuery = ""
    var assetSortMode: GalleryAssetSortMode = .photosOrder
    var assetSortAscending = true
    var vaultShuffleSeed = UUID()
    var albums: [GalleryAlbum] = []
    // MANAGER_METHODS
    func visibleIDs() -> [String] {
        rebuildPendingDisplayIndexIfNeeded()
        return (0..<pendingDisplayIndex.count).map { assetFetchResult!.values[assetDisplayOrder![pendingDisplayIndex.index(at: $0)!]].localIdentifier }
    }
}
@MainActor final class GalleryViewerSession {
    let id = UUID(); let playlist: GalleryViewerPlaylist; var cursor: Int?
    init(playlist: GalleryViewerPlaylist, cursor: Int) { self.playlist = playlist; self.cursor = cursor }
    var canGoNext: Bool { false }; var position: Int { 0 }
    func orderedIndex(at: Int) -> Int? { nil }
    func setCursor(_ cursor: Int?) { self.cursor = cursor }
}
/// Run the extracted session and delete methods against newly created playlists.
@MainActor final class Store {
    var playlists: [UUID: GalleryViewerPlaylist] = [:]
    var sessions: [UUID: GalleryViewerSession] = [:]
    var albums: [GalleryAlbum] = []
    func notify(_ playlist: GalleryViewerPlaylist, orderChanged: Bool = false) {}
    // STORE_METHODS
}
/// Run the isolated handoff regression without linking the full app.
@main struct Check {
    /// Check a stale fetch and a pending rollback through newly created playlists.
    @MainActor static func main() {
        let manager = GalleryManager(), queue = GalleryDeleteQueue.shared
        let b = PHAsset(localIdentifier: "B")
        let request = GalleryDeleteRequest(target: .photos("B", sourceAlbumID: "album"), action: .recycle)
        manager.committedPhotoDeletes["B"] = request; manager.committedPhotoAssets["B"] = b
        let store = Store(); let session = store.createSession(from: manager, at: 0)!
        let playlist = store.sessions[session]!.playlist
        let viewerIDs = (0..<playlist.index.count).map { playlist.snapshot.fetch.values[playlist.snapshot.displayOrder![playlist.index.index(at: $0)!]].localIdentifier }
        precondition(manager.visibleIDs() == ["C", "A"] && viewerIDs == manager.visibleIDs(), "new viewer must match grid after committed delete")
        let pendingManager = GalleryManager(); queue.pendingRequests = [request]; queue.pendingPhotoAssets = ["B": b]
        let pendingStore = Store(); let pendingSession = pendingStore.createSession(from: pendingManager, at: 0)!
        let pendingPlaylist = pendingStore.sessions[pendingSession]!.playlist
        precondition(pendingPlaylist.pendingRemovals["B"] != nil && pendingPlaylist.index.count == 2)
        pendingStore.finishQueuedDelete(request, succeeded: false)
        precondition(pendingPlaylist.index.count == 3 && !pendingPlaylist.index.removed.contains(2), "failed pending delete must return")
        // A Move only removes the source membership. All Photos and unrelated albums return the item.
        let move = GalleryDeleteRequest(target: .photos("B", sourceAlbumID: "album"),
            action: .moveToPhotos(destinationID: "destination", newName: nil))
        queue.pendingRequests = [move]
        let moveStore = Store()
        let source = GalleryManager(); source.selectedAlbum = .init(id: "album", virtualScope: nil)
        let all = GalleryManager(); all.selectedAlbum = .init(id: "all", virtualScope: .photos); all.assetFetchAlbumID = "all"
        let other = GalleryManager(); other.selectedAlbum = .init(id: "other", virtualScope: nil); other.assetFetchAlbumID = "other"
        let sourceID = moveStore.createSession(from: source, at: 0)!
        let allID = moveStore.createSession(from: all, at: 0)!
        let otherID = moveStore.createSession(from: other, at: 0)!
        let sourcePlaylist = moveStore.sessions[sourceID]!.playlist
        let allPlaylist = moveStore.sessions[allID]!.playlist
        let otherPlaylist = moveStore.sessions[otherID]!.playlist
        precondition([sourcePlaylist, allPlaylist, otherPlaylist].allSatisfy { $0.index.count == 2 }, "pending move must be masked in all windows")
        moveStore.finishQueuedDelete(move, succeeded: true)
        precondition(sourcePlaylist.index.count == 2 && allPlaylist.index.count == 3 && otherPlaylist.index.count == 3,
                     "only source album keeps a committed move masked")
        source.committedPhotoDeletes["B"] = move; source.committedPhotoAssets["B"] = b
        all.committedPhotoDeletes["B"] = move; all.committedPhotoAssets["B"] = b
        other.committedPhotoDeletes["B"] = move; other.committedPhotoAssets["B"] = b
        queue.pendingRequests = []
        source.pendingDisplayIndexDirty = true; all.pendingDisplayIndexDirty = true; other.pendingDisplayIndexDirty = true
        precondition(source.visibleIDs() == ["C", "A"] && all.visibleIDs() == ["C", "A", "B"] && other.visibleIDs() == ["C", "A", "B"],
                     "fresh grid must keep a committed move only in the source album")
        print("PASS stale committed mask, pending rollback, and cross-album move masks with fake PhotoKit")
    }
}
