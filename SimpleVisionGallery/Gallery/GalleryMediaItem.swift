#if os(visionOS)
import Foundation
@preconcurrency import Photos

extension Notification.Name {
    static let galleryAlbumWasDeleted = Notification.Name("GalleryAlbumWasDeleted")
    static let galleryViewerAlbumDeleted = Notification.Name("GalleryViewerAlbumDeleted")
    static let galleryPhotosAccessDidRevoke = Notification.Name("GalleryPhotosAccessDidRevoke")
    static let galleryVaultDidRestoreItem = Notification.Name("GalleryVaultDidRestoreItem")
    static let galleryVaultWillLock = Notification.Name("GalleryVaultWillLock")
    static let galleryVaultDidLock = Notification.Name("GalleryVaultDidLock")
    static let galleryVaultDidHideItems = Notification.Name("GalleryVaultDidHideItems")
}

/// A library asset or an encrypted vault item. Vault IDs cannot collide with Photos IDs.
enum GalleryMediaItem {
    case photos(PHAsset)
    case vault(GalleryVaultRecord)

    var photosAsset: PHAsset? { if case .photos(let asset) = self { return asset }; return nil }
    var vaultRecord: GalleryVaultRecord? { if case .vault(let record) = self { return record }; return nil }
    var localIdentifier: String {
        switch self {
        case .photos(let asset): asset.localIdentifier
        case .vault(let record): "vault:\(record.id.uuidString)"
        }
    }
    var mediaType: PHAssetMediaType {
        switch self {
        case .photos(let asset): asset.mediaType
        case .vault(let record): PHAssetMediaType(rawValue: record.mediaType) ?? .unknown
        }
    }
    var mediaSubtypes: PHAssetMediaSubtype {
        switch self {
        case .photos(let asset): asset.mediaSubtypes
        case .vault(let record): PHAssetMediaSubtype(rawValue: record.mediaSubtypes)
        }
    }
    var pixelWidth: Int { photosAsset?.pixelWidth ?? vaultRecord?.pixelWidth ?? 0 }
    var pixelHeight: Int { photosAsset?.pixelHeight ?? vaultRecord?.pixelHeight ?? 0 }
    var duration: Double { photosAsset?.duration ?? vaultRecord?.duration ?? 0 }
    var creationDate: Date? { photosAsset?.creationDate ?? vaultRecord?.creationDate }
    var modificationDate: Date? { photosAsset?.modificationDate ?? vaultRecord?.modificationDate }
    var isFavorite: Bool { photosAsset?.isFavorite ?? vaultRecord?.isFavorite ?? false }
    var filename: String? { vaultRecord?.filename }

    var cacheKey: String { "\(localIdentifier):\(modificationDate?.timeIntervalSince1970 ?? 0)" }

    /// Removes the cache's media-kind and modification-time suffixes, even if
    /// a platform identifier itself contains a colon.
    static func sourceIdentifier(forCacheKey key: String) -> String? {
        var value = key
        for suffix in [":scene", ":original", ":video"] where value.hasSuffix(suffix) {
            value.removeLast(suffix.count)
            break
        }
        guard let separator = value.lastIndex(of: ":") else { return nil }
        return String(value[..<separator])
    }
}
/// Prefer Photos' edited full-size media for display, except spatial originals.
/// Export and restore still retain every original resource separately.
enum GalleryVaultResourceSelection {
    static func displayResource(for record: GalleryVaultRecord) -> GalleryVaultResource? {
        let spatial = PHAssetMediaSubtype(rawValue: record.mediaSubtypes).contains(.spatialMedia)
        let types: [PHAssetResourceType]
        if PHAssetMediaType(rawValue: record.mediaType) == .video {
            types = spatial ? [.video, .fullSizeVideo] : [.fullSizeVideo, .video]
        } else {
            types = spatial ? [.photo, .fullSizePhoto, .alternatePhoto] : [.fullSizePhoto, .photo, .alternatePhoto]
        }
        return types.lazy.compactMap { type in record.resources.first { $0.type == type.rawValue } }.first
    }
}
#endif
