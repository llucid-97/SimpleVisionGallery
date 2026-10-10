#if os(visionOS)
import Foundation

enum GalleryViewerPreferences {
    static let prefetchWindowKey = "gallery.spatialPrefetchWindow.v1"
    static let loopVideosKey = "gallery.loopVideos.v1"
    static let defaultPrefetchWindow = 3
    static let prefetchWindowRange = 0...10

    static func boundedPrefetchWindow(_ value: Int) -> Int {
        min(prefetchWindowRange.upperBound, max(prefetchWindowRange.lowerBound, value))
    }
}
#endif
