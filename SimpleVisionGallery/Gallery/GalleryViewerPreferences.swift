#if os(visionOS)
import Foundation
import simd

enum GalleryViewerPreferences {
    static let prefetchWindowKey = "gallery.spatialPrefetchWindow.v1"
    static let backwardPrefetchWindowKey = "gallery.spatialBackwardPrefetchWindow.v1"
    static let loopVideosKey = "gallery.loopVideos.v1"
    static let pairedYawKey = "gallery.pairedYawDegrees.v1"
    static let pairedPitchKey = "gallery.pairedPitchDegrees.v1"
    static let defaultPairedYaw = 10.0
    static let defaultPairedPitch = 0.0
    static let pairedYawRange = 0.0...45.0
    static let pairedPitchRange = -30.0...30.0
    static let defaultPrefetchWindow = 5
    static let defaultBackwardPrefetchWindow = 2
    static let prefetchWindowRange = 0...10
    static let backwardPrefetchWindowRange = 0...4
    static let globalPrefetchItemBudget = 20
    static let globalPrefetchPixelBudget = 80_000_000
    static let globalPreparationJobLimit = 2

    static func pairedOrientation(yawDegrees: Float, pitchDegrees: Float) -> simd_quatf {
        let yaw = simd_quatf(angle: yawDegrees * .pi / 180, axis: [0, 1, 0])
        let pitch = simd_quatf(angle: pitchDegrees * .pi / 180, axis: [1, 0, 0])
        return pitch * yaw
    }

    static func boundedPrefetchWindow(_ value: Int) -> Int {
        min(prefetchWindowRange.upperBound, max(prefetchWindowRange.lowerBound, value))
    }
}
#endif
