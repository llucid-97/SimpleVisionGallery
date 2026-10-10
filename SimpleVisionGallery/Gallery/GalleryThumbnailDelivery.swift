//
//  GalleryThumbnailDelivery.swift
//  simple_vision_tools
//

import Foundation
@preconcurrency import Photos

nonisolated struct GalleryThumbnailDelivery: Sendable {
    let isCancelled: Bool
    let isDegraded: Bool
    let hasError: Bool

    init(info: [AnyHashable: Any]?) {
        isCancelled = (info?[PHImageCancelledKey] as? NSNumber)?.boolValue == true
        isDegraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue == true
        hasError = info?[PHImageErrorKey] != nil
    }

    var isFinal: Bool {
        isCancelled || hasError || !isDegraded
    }

    var shouldCache: Bool {
        isFinal && !isCancelled && !hasError
    }
}
