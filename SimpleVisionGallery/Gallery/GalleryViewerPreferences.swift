#if os(visionOS)
import Foundation

enum GalleryViewerPreferences {
    static let prefetchWindowKey = "gallery.spatialPrefetchWindow.v1"
    static let backwardPrefetchWindowKey = "gallery.spatialBackwardPrefetchWindow.v1"
    static let loopVideosKey = "gallery.loopVideos.v1"
    static let defaultPrefetchWindow = 5
    static let defaultBackwardPrefetchWindow = 2
    static let prefetchWindowRange = 0...10
    static let backwardPrefetchWindowRange = 0...4
    static let globalPrefetchItemBudget = 20
    static let globalPrefetchPixelBudget = 80_000_000
    static let globalPreparationJobLimit = 2

    static func boundedPrefetchWindow(_ value: Int) -> Int {
        min(prefetchWindowRange.upperBound, max(prefetchWindowRange.lowerBound, value))
    }
}
#endif
