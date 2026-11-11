import Foundation
final class Collection {
    enum Action { case addContent }
    let allowed: Bool
    init(_ allowed: Bool = true) { self.allowed = allowed }
    func canPerform(_ action: Action) -> Bool { allowed }
}
struct GalleryAlbum { let id: String; let title: String; let collection: Collection? }
struct GalleryVaultAlbum { let id: String; let title: String; let position: Int? }
enum GalleryVaultRecycleBin { static let id = "vault-recycle-bin" }
enum GalleryRecycleBin {
    static func isRecycleBin(_ album: GalleryAlbum) -> Bool { isRecycleBinTitle(album.title) }
    static func isRecycleBinTitle(_ title: String?) -> Bool { title?.lowercased() == "recycle bin" }
}
@main struct Harness {
    @MainActor static func main() {
        let suite = "gallery.test.history.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["legacy", "shared"], forKey: "gallery.recentMoveDestinationIDs.v1")
        let legacy = GalleryAlbum(id: "legacy", title: "Legacy", collection: Collection())
        let photo = GalleryAlbum(id: "shared", title: "Photos", collection: Collection())
        let vault = GalleryVaultAlbum(id: "shared", title: "Vault", position: nil)
        let other = GalleryVaultAlbum(id: "other", title: "Other", position: nil)
        let forbidden = GalleryVaultAlbum(id: GalleryVaultRecycleBin.id, title: "Recycle Bin", position: nil)
        let history = GalleryMoveHistory(defaults: defaults)
        precondition(history.recentAlbums(from: [legacy, photo], excluding: nil).map(\.id) == ["legacy", "shared"])
        history.recordSuccessfulVaultMove(to: vault.id)
        precondition(history.recentVaultAlbums(from: [vault, forbidden], excluding: nil).map(\.id) == ["shared"])
        precondition(history.recentAlbums(from: [legacy, photo], excluding: nil).map(\.id) == ["legacy", "shared"])
        precondition(history.recentVaultAlbums(from: [vault], excluding: "shared").isEmpty)
        precondition(history.recentVaultAlbums(from: [], excluding: nil).isEmpty)
        history.recordSuccessfulVaultMove(to: GalleryVaultRecycleBin.id)
        history.recordSuccessfulVaultMove(to: other.id)
        let reloaded = GalleryMoveHistory(defaults: defaults)
        precondition(reloaded.recentVaultAlbums(from: [vault, other, forbidden], excluding: nil).map(\.id) == ["other", "shared"])
        precondition(reloaded.recentAlbums(from: [legacy, photo], excluding: nil).map(\.id) == ["legacy"])
        reloaded.recordSuccessfulMove(to: "shared")
        precondition(reloaded.recentAlbums(from: [photo], excluding: nil).map(\.id) == ["shared"])
        precondition(defaults.stringArray(forKey: "gallery.recentMoveDestinations.v2")!.allSatisfy { !$0.contains("Vault") && !$0.contains("Photos") })
        print("PASS: migration, typed collisions, ordering, bound, lock, exclusion, persistence")
    }
}
