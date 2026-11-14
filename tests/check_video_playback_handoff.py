#!/usr/bin/env python3
"""Playback state contract; this does not measure native attachment or visible-frame timing."""
# Target audience: release agents. Promoted after independent review: pause/attach intent is durable behavior.
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()
source = root / "SimpleVisionGallery/Gallery/GalleryViewerMedia.swift"
swift = source.read_text()


def block(marker: str) -> str:
    start = swift.index(marker)
    brace = swift.index("{", start)
    depth = 0
    for index in range(brace, len(swift)):
        if swift[index] == "{":
            depth += 1
        elif swift[index] == "}":
            depth -= 1
            if depth == 0:
                return swift[start:index + 1]
    raise ValueError(f"unclosed production method: {marker}")


present = block("    private func presentVideo(")
attach = block("    func videoSurfaceDidAttach(")
detach = block("    func videoSurfaceDidDetach(")
request = block("    func requestVideoPlayback(")
resume = block("    private func resumeVideoPlaybackIfEligible(")
active_test = block("    private func isVideoPlaybackActive(")
covered = block("    func setPresentationCovered(")
scene_active = block("    func setSceneActive(")
cancel_current = block("    private func cancelCurrent(")

# presentVideo's AVFoundation observers and asset fields are outside this host probe.
# Verify its real intent/attachment initialization and leave its playback decision to
# the extracted, compiled production methods below.
present_body = present[present.index("{") + 1:-1]
if "self.attachedVideoPlayerID = nil" not in present_body:
    raise SystemExit("presentVideo no longer clears the previous player's attachment")
if "self.resumePlaybackWhenActive = true" not in present_body:
    raise SystemExit("presentVideo no longer records pending playback intent")
if "player.play()" in present_body:
    raise SystemExit("presentVideo must not play before its native surface attaches")

methods = "\n".join((attach, detach, request, resume, active_test, covered, scene_active, cancel_current))
probe = r'''import Foundation

@MainActor final class FakePlayer {
    var timeControlStatus: Status = .paused
    var rate: Float = 0
    private(set) var playCalls = 0
    private(set) var pauseCalls = 0
    var itemWasCleared = false
    enum Status { case paused, playing, waitingToPlayAtSpecifiedRate }
    func play() { playCalls += 1; rate = 1; timeControlStatus = .playing }
    func pause() { pauseCalls += 1; rate = 0; timeControlStatus = .paused }
    func replaceCurrentItem(with _: Any?) { itemWasCleared = true }
}
typealias AVPlayer = FakePlayer
@MainActor final class FakeObserver { func invalidate() {} }
@MainActor final class FakeLoad { func cancel() {} }
@MainActor final class FakeVideo {}
@MainActor final class FakePreview { func clear() {} }
@MainActor final class FakeCache {
    static let shared = FakeCache()
    func updatePrefetchDemand(owner _: UUID, orderedKeys _: [String]) {}
}
typealias GallerySceneCache = FakeCache
@MainActor final class Probe {
    var player: FakePlayer?
    var isSceneActive = true
    var isPresentationCovered = false
    var resumePlaybackWhenActive = false
    var attachedVideoPlayerID: ObjectIdentifier?
    var prefetchFailures: Set<String> = []
    var prefetchVideoSlotFailures: Set<String> = []
    var attemptedVideoPrerolls: Set<String> = []
    var deferredVideoPrerolls: Set<String> = []
    var prefetchOwnerID = UUID()
    var requestedPrefetchAssets: [String] = []
    var requestedExcludingCurrent: String?
    var requestedPreserving: String?
    var prefetchCoordinator: Task<Void, Never>?
    var prefetchTask: Task<Void, Never>?
    var activeLoad: FakeLoad?
    var playerEndObserver: FakeObserver?
    var playerObservation: FakeObserver?
    var prepared: FakeVideo?
    var preparedKey: String?
    var currentVideo: FakeVideo?
    var isSpatialVideo = true
    var imageEntity: String?
    var fallbackImage: String?
    var menuPreviewState = FakePreview()
    var spatialVideoComponent: String?
    var spatialAvailable = true
    var isShowingSpatial = true
    var isLoading = true
    var generation = UUID()
    func prefetch(items _: [String], excludingCurrent _: String? = nil, preserving _: String? = nil) {}
    func cancelPrefetchWork() { prefetchCoordinator?.cancel(); prefetchCoordinator = nil; prefetchTask?.cancel(); prefetchTask = nil }
    METHODS
    func cancelForTest() { cancelCurrent(releaseImage: true) }
}

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError("ASSERTION FAILED: \(message)") }
}
@MainActor func run() {
    // presentVideo sets pending intent; exact production attach gates the first play.
    let viewer = Probe(), player = FakePlayer()
    viewer.player = player
    viewer.resumePlaybackWhenActive = true
    check(player.playCalls == 0, "pending intent does not play before surface attachment")
    viewer.videoSurfaceDidAttach(player)
    check(player.playCalls == 1 && player.rate > 0, "the matching native surface starts playback")
    viewer.videoSurfaceDidAttach(player)
    check(player.playCalls == 1, "repeated attachment does not start twice")

    let pendingViewer = Probe(), pendingPlayer = FakePlayer()
    pendingViewer.player = pendingPlayer
    pendingViewer.resumePlaybackWhenActive = true
    pendingViewer.requestVideoPlayback(false, for: pendingPlayer)
    pendingViewer.videoSurfaceDidAttach(pendingPlayer)
    check(pendingPlayer.playCalls == 0 && !pendingViewer.resumePlaybackWhenActive, "manual pause cancels pending pre-attachment autoplay")

    // Stale native events cannot take or stop the current player's attachment.
    let stale = FakePlayer()
    viewer.videoSurfaceDidAttach(stale)
    check(stale.playCalls == 0 && viewer.attachedVideoPlayerID == ObjectIdentifier(player), "stale attach has no effect")
    viewer.videoSurfaceDidDetach(stale)
    check(player.rate > 0 && viewer.attachedVideoPlayerID == ObjectIdentifier(player), "stale detach cannot pause or detach current player")

    // A user pause remains authoritative through cover and detach transitions.
    viewer.requestVideoPlayback(false, for: player)
    viewer.setPresentationCovered(true)
    viewer.setPresentationCovered(false)
    check(player.rate == 0 && player.playCalls == 1, "manual pause before cover stays paused")
    viewer.videoSurfaceDidDetach(player)
    viewer.videoSurfaceDidAttach(player)
    check(player.rate == 0 && player.playCalls == 1, "manual pause before detach stays paused after reattachment")

    // Cover and inactive scene preserve an already-playing intent for the current attachment.
    viewer.requestVideoPlayback(true, for: player)
    check(player.rate > 0, "explicit play request starts attached current player")
    viewer.setPresentationCovered(true)
    check(player.rate == 0 && viewer.resumePlaybackWhenActive, "cover pauses while retaining active playback intent")
    viewer.setPresentationCovered(false)
    check(player.rate > 0, "uncover resumes only when active and attached")
    viewer.setSceneActive(false)
    check(player.rate == 0 && viewer.resumePlaybackWhenActive, "inactive scene pauses while retaining playing intent")
    viewer.setSceneActive(true)
    check(player.rate > 0, "active current uncovered attachment resumes")

    player.timeControlStatus = .waitingToPlayAtSpecifiedRate
    player.rate = 0
    viewer.setPresentationCovered(true)
    check(viewer.resumePlaybackWhenActive, "buffering playback preserves intent when covered")
    viewer.setPresentationCovered(false)
    check(player.rate > 0, "uncover resumes a previously buffering player")

    // A covered or detached current surface cannot resume until its own reattachment.
    viewer.setPresentationCovered(true)
    viewer.videoSurfaceDidDetach(player)
    viewer.setPresentationCovered(false)
    check(player.rate == 0, "detached player remains paused on uncover")
    viewer.videoSurfaceDidAttach(stale)
    check(player.rate == 0 && stale.playCalls == 0, "stale reattachment cannot resume playback")
    viewer.videoSurfaceDidAttach(player)
    check(player.rate > 0, "current reattachment resumes retained intent")

    // Cancel invalidates attachment and intent; a late native attach cannot resurrect it.
    let token = viewer.generation
    let callsBeforeCancel = player.playCalls
    viewer.cancelForTest()
    check(viewer.player == nil && viewer.attachedVideoPlayerID == nil && !viewer.resumePlaybackWhenActive, "cancel clears player, attachment, and pending intent")
    check(player.itemWasCleared && player.rate == 0, "cancel pauses and releases the old player item")
    viewer.videoSurfaceDidAttach(player)
    check(player.playCalls == callsBeforeCancel && viewer.generation != token, "late attachment after cancel cannot resurrect playback")
    print("PASS: pending attach gate, single matching attach, stale attach/detach, manual pause, cover/inactive resume, current reattachment and cancel cleanup")
}
@main struct Main { @MainActor static func main() { run() } }
'''.replace("METHODS", methods)

with tempfile.TemporaryDirectory(prefix="first-frame-playback-") as temp:
    path = Path(temp) / "probe.swift"
    path.write_text(probe)
    binary = Path(temp) / "probe"
    subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", str(path), "-o", str(binary)], cwd=root, check=True)
    subprocess.run([str(binary)], cwd=root, check=True)
