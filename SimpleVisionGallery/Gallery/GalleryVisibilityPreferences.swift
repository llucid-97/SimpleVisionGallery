import Foundation

nonisolated struct GalleryVisibilityPreferences {
    private static let hiddenIDsKey = "gallery.hiddenAlbumIDs.v1"
    private static let unhiddenIDsKey = "gallery.unhiddenAlbumIDs.v1"
    private static let autoHideEmptyKey = "gallery.autoHideEmptyAlbums.v1"

    private let defaults: UserDefaults
    private(set) var hiddenAlbumIDs: Set<String>
    private(set) var unhiddenAlbumIDs: Set<String>
    private(set) var autoHideEmptyAlbums: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hiddenAlbumIDs = Set(defaults.stringArray(forKey: Self.hiddenIDsKey) ?? [])
        unhiddenAlbumIDs = Set(defaults.stringArray(forKey: Self.unhiddenIDsKey) ?? [])
        autoHideEmptyAlbums = defaults.object(forKey: Self.autoHideEmptyKey) as? Bool ?? true
    }

    func isHidden(albumID: String, assetCount: Int) -> Bool {
        hiddenAlbumIDs.contains(albumID)
            || (autoHideEmptyAlbums && assetCount == 0 && !unhiddenAlbumIDs.contains(albumID))
    }

    mutating func hide(_ albumIDs: Set<String>) {
        hiddenAlbumIDs.formUnion(albumIDs)
        unhiddenAlbumIDs.subtract(albumIDs)
        persist()
    }

    mutating func unhide(_ albumIDs: Set<String>) {
        hiddenAlbumIDs.subtract(albumIDs)
        unhiddenAlbumIDs.formUnion(albumIDs)
        persist()
    }

    mutating func setAutoHideEmptyAlbums(_ enabled: Bool) {
        autoHideEmptyAlbums = enabled
        persist()
    }

    private func persist() {
        defaults.set(hiddenAlbumIDs.sorted(), forKey: Self.hiddenIDsKey)
        defaults.set(unhiddenAlbumIDs.sorted(), forKey: Self.unhiddenIDsKey)
        defaults.set(autoHideEmptyAlbums, forKey: Self.autoHideEmptyKey)
    }
}
