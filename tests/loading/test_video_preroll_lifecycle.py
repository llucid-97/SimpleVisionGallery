#!/usr/bin/env python3
"""Extract production preroll lifecycle code and exercise it with CPU-only fakes.
The only production-code substitutions are the two six-second wait budgets,
reduced to 250ms in the generated probe so timeout cases stay fast and bounded.
No AVFoundation import or simulator/device runtime is used.
"""
# Target audience: agents.
from pathlib import Path
import hashlib
import os
import subprocess
import sys
import tempfile

ROOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()
SOURCE = ROOT / "SimpleVisionGallery/Gallery/GalleryViewerMedia.swift"


def block_after(source: str, anchor: str, start: str) -> str:
    pos = source.index(anchor)
    begin = source.index(start, pos)
    brace = source.index("{", begin)
    depth = 0
    for i in range(brace, len(source)):
        if source[i] == "{":
            depth += 1
        elif source[i] == "}":
            depth -= 1
            if depth == 0:
                return source[begin:i + 1]
    raise ValueError(f"unclosed production block: {start}")


production = SOURCE.read_text()
digest = hashlib.sha256(SOURCE.read_bytes()).hexdigest()
prepared = block_after(production, "@MainActor\nprivate final class GalleryPreparedVideo", "@MainActor\nprivate final class GalleryPreparedVideo")
completion = block_after(production, "private nonisolated final class GalleryPrerollCompletion", "private nonisolated final class GalleryPrerollCompletion")
cache_anchor = production.index("private final class GallerySceneCache")
cache_methods = "\n\n".join([
    block_after(production[cache_anchor:], "func scheduleVideoPreroll", "func scheduleVideoPreroll"),
    block_after(production[cache_anchor:], "private func releaseVideoPreroll", "private func releaseVideoPreroll"),
    block_after(production[cache_anchor:], "private func cancelVideoPrerollForPromotion", "private func cancelVideoPrerollForPromotion"),
    block_after(production[cache_anchor:], "func clearSpeculativeVideoPreroll", "func clearSpeculativeVideoPreroll"),
    block_after(production[cache_anchor:], "func updatePrefetchDemand", "func updatePrefetchDemand"),
    block_after(production[cache_anchor:], "private func trimPrefetchRetentions", "private func trimPrefetchRetentions"),
])
outcome = block_after(production[cache_anchor:], "enum GalleryVideoPrerollOutcome", "enum GalleryVideoPrerollOutcome")
if "let preparedPlayer = video.takePrerolledPlayer()" not in production:
    raise SystemExit("production foreground handoff expression is missing")
if "let item = preparedPlayer?.currentItem ?? AVPlayerItem(asset: avAsset)" not in production:
    raise SystemExit("production foreground item fallback is missing")
if "self.player = preparedPlayer ?? AVPlayer(playerItem: item)" not in production:
    raise SystemExit("production independent foreground player fallback is missing")

# Use the exact production handoff expressions, wrapped only in a host-test helper.
handoff = """@MainActor fileprivate func productionForegroundHandoff(video: GalleryPreparedVideo, avAsset: AVAsset) -> AVPlayer {
    let preparedPlayer = video.takePrerolledPlayer()
    let item = preparedPlayer?.currentItem ?? AVPlayerItem(asset: avAsset)
    return preparedPlayer ?? AVPlayer(playerItem: item)
}"""

prepared = prepared.replace(".seconds(6)", ".milliseconds(250)")
if os.environ.get("DISABLE_UUID_GUARD") == "1":
    guard = "guard prerollID == expectedID else { return }"
    if prepared.count(guard) != 1:
        raise SystemExit("controlled falsifier could not find exactly one UUID guard")
    prepared = prepared.replace(guard, "if false { return }", 1)

stub = r'''import Foundation

enum FakeStatus: Equatable { case unknown, readyToPlay, failed }
enum GalleryMediaError: Error { case videoPrerollFailed }

final class AVAsset {
    var itemReadyDelay: UInt64?
    var playerReadyDelay: UInt64?
    var prerollDelay: UInt64 = 5
    var prerollResult = true
    var duplicatePrerollCallback = false
    init(itemReadyDelay: UInt64? = 0, playerReadyDelay: UInt64? = 0,
         prerollDelay: UInt64 = 5, prerollResult: Bool = true,
         duplicatePrerollCallback: Bool = false) {
        self.itemReadyDelay = itemReadyDelay
        self.playerReadyDelay = playerReadyDelay
        self.prerollDelay = prerollDelay
        self.prerollResult = prerollResult
        self.duplicatePrerollCallback = duplicatePrerollCallback
    }
}

final class AVPlayerItem {
    let asset: AVAsset
    var status: FakeStatus
    var error: Error?
    var preferredForwardBufferDuration: Double = 0
    init(asset: AVAsset) {
        self.asset = asset
        self.status = asset.itemReadyDelay == nil ? .unknown : .readyToPlay
        if let delay = asset.itemReadyDelay, delay > 0 {
            status = .unknown
            Task { try? await Task.sleep(for: .milliseconds(delay)); self.status = .readyToPlay }
        }
    }
}

enum AVPlayerActionAtItemEnd { case pause }
final class AVPlayer {
    var currentItem: AVPlayerItem?
    var status: FakeStatus
    var error: Error?
    var isMuted = false
    var volume: Float = 1
    var actionAtItemEnd: AVPlayerActionAtItemEnd = .pause
    private(set) var isPlaying = false
    private(set) var cancelledPrerolls = 0
    private(set) var replacedWithNil = false
    private(set) var prerollStarts = 0
    private(set) var prerollCallbacksDelivered = 0
    init(playerItem: AVPlayerItem?) {
        self.currentItem = playerItem
        let asset = playerItem?.asset
        self.status = asset?.playerReadyDelay == nil ? .unknown : .readyToPlay
        if let asset, let delay = asset.playerReadyDelay, delay > 0 {
            status = .unknown
            Task { try? await Task.sleep(for: .milliseconds(delay)); self.status = .readyToPlay }
        }
    }
    func pause() { isPlaying = false }
    func play() { isPlaying = true }
    func replaceCurrentItem(with item: AVPlayerItem?) { currentItem = item; if item == nil { replacedWithNil = true } }
    func cancelPendingPrerolls() { cancelledPrerolls += 1 }
    func preroll(atRate: Float, completionHandler: @escaping (Bool) -> Void) {
        prerollStarts += 1
        let asset = currentItem!.asset
        let delay = asset.prerollDelay
        let result = asset.prerollResult
        let duplicate = asset.duplicatePrerollCallback
        Task {
            try? await Task.sleep(for: .milliseconds(delay))
            prerollCallbacksDelivered += 1
            completionHandler(result)
            if duplicate {
                prerollCallbacksDelivered += 1
                completionHandler(!result)
            }
        }
    }
}

@MainActor final class GalleryVaultStorage {
    static let shared = GalleryVaultStorage()
    func releasePlaintext(_ url: URL) -> Bool { true }
}

'''
# Production posts use NotificationCenter; map that platform notification to a counter.
cache_methods = cache_methods.replace(
    "NotificationCenter.default.post(name: Self.prefetchVideoSlotDidChange, object: nil)",
    "postSlotChange()"
)
cache_methods = cache_methods.replace(
    'NotificationCenter.default.post(name: Self.prefetchVideoSlotDidChange, object: nil,\n            userInfo: consumed ? ["consumedKey": key] : nil)',
    'postSlotChange(consumedKey: consumed ? key : nil)'
)
cache_methods = cache_methods.replace("func scheduleVideoPreroll(", "fileprivate func scheduleVideoPreroll(")
cache_stub = r'''enum GalleryViewerPreferences {
    static let globalPrefetchItemBudget = 20
    static let globalPrefetchPixelBudget = 80_000_000
}
@MainActor final class GallerySceneCacheProbe {
    struct VideoPrerollReservation {
        let key: String
        let id: UUID
        fileprivate let video: GalleryPreparedVideo
        let task: Task<Void, Never>
        var isReady: Bool
    }
    var videoPrerollReservation: VideoPrerollReservation?
    struct FakeMedia { var pixelCost = 0 }
    struct Retained { var owners: Set<UUID>; var media = FakeMedia() }
    var demands: [UUID: [String]] = [:]
    var retainedPrefetch: [String: Retained] = [:]
    static let prefetchOwnersDidChange = Notification.Name("probeOwnersChanged")
    private(set) var slotNotifications = 0
    private(set) var lastConsumedKey: String?
    func postSlotChange(consumedKey: String? = nil) {
        slotNotifications += 1
        lastConsumedKey = consumedKey
    }
    func trimGlobalPreparedResults() {}
'''
cache_class = cache_stub + "\n" + outcome + "\n" + cache_methods + "\n}\n"

tests = r'''
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError("ASSERTION FAILED: \(message)") }
}
func tick(_ ms: UInt64 = 30) async { try? await Task.sleep(for: .milliseconds(ms)) }
@MainActor func waitUntil(_ predicate: @MainActor () -> Bool, timeoutMs: UInt64 = 600) async -> Bool {
    for _ in 0..<(timeoutMs / 5) {
        if predicate() { return true }
        await tick(5)
    }
    return predicate()
}

@MainActor func runTests() async {
    // Readiness gate: neither incomplete item nor incomplete player may preroll.
    let bothReadyAsset = AVAsset(itemReadyDelay: 45, playerReadyDelay: 90, prerollDelay: 1)
    let readyVideo = GalleryPreparedVideo(asset: bothReadyAsset)
    let readyTask = Task { try await readyVideo.preparePreroll(id: UUID()) }
    await tick(65)
    check(readyVideo.hasPrerolledPlayer, "player is installed while waiting for readiness")
    check(readyVideo.testPlayer!.prerollStarts == 0, "no preroll until BOTH statuses are ready")
    try? await readyTask.value
    check(readyVideo.testPlayer!.prerollStarts == 1, "preroll starts after both statuses are ready")
    check(!readyVideo.testPlayer!.isPlaying, "warm player remains paused")
    check(readyVideo.testPlayer!.isMuted && readyVideo.testPlayer!.volume == 0, "warm player is muted")

    // First foreground consumer gets the same player, reset for user playback.
    readyVideo.testPlayer!.currentItem!.preferredForwardBufferDuration = 1.5
    let warmedPlayer = readyVideo.testPlayer!
    let taken = productionForegroundHandoff(video: readyVideo, avAsset: bothReadyAsset)
    check(taken === warmedPlayer, "first consumer takes the actual warmed player")
    check(!taken.isMuted && taken.volume == 1, "take resets mute and volume")
    check(taken.currentItem!.preferredForwardBufferDuration == 0, "take resets foreground buffer duration")
    check(!taken.isPlaying, "taken player is not autoplayed by preroll")
    check(!readyVideo.hasPrerolledPlayer, "take consumes the preroll")
    let independent = productionForegroundHandoff(video: readyVideo, avAsset: bothReadyAsset)
    check(independent !== taken, "second consumer builds an independent foreground player")
    check(independent.currentItem !== taken.currentItem, "independent consumer gets an independent item")

    // A warm player can fail after preroll succeeds but before foreground promotion.
    let lateFailed = GalleryPreparedVideo(asset: AVAsset(prerollDelay: 1))
    try? await lateFailed.preparePreroll(id: UUID())
    let brokenPlayer = lateFailed.testPlayer!
    brokenPlayer.status = .failed
    let afterLateFailure = productionForegroundHandoff(video: lateFailed, avAsset: lateFailed.asset)
    check(afterLateFailure !== brokenPlayer, "late failed warm player is discarded before foreground handoff")
    let lateDetached = GalleryPreparedVideo(asset: AVAsset(prerollDelay: 1))
    try? await lateDetached.preparePreroll(id: UUID())
    let detachedPlayer = lateDetached.testPlayer!
    detachedPlayer.replaceCurrentItem(with: nil)
    let afterDetach = productionForegroundHandoff(video: lateDetached, avAsset: lateDetached.asset)
    check(afterDetach !== detachedPlayer && afterDetach.currentItem != nil, "late detached warm item falls back to a fresh foreground player")

    // Timeout and callback failure discard the speculative player and permit fallback.
    let slow = GalleryPreparedVideo(asset: AVAsset(itemReadyDelay: 0, playerReadyDelay: 0, prerollDelay: 700))
    let slowTask = Task { try await slow.preparePreroll(id: UUID()) }
    do { try await slowTask.value; fatalError("timeout should fail") } catch { }
    check(!slow.hasPrerolledPlayer, "timeout discards warm player")
    let failed = GalleryPreparedVideo(asset: AVAsset(prerollDelay: 1, prerollResult: false))
    do { try await failed.preparePreroll(id: UUID()); fatalError("failed callback should fail") } catch { }
    check(!failed.hasPrerolledPlayer, "failed callback discards warm player")
    check(productionForegroundHandoff(video: failed, avAsset: failed.asset) !== taken, "failure falls back to a new foreground player")

    // Cancel before continuation installation / duplicate callback both settle exactly once.
    let completion = GalleryPrerollCompletion()
    completion.finish(.failure(CancellationError()))
    do {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in completion.install(c) }
        fatalError("pre-install cancellation should resume the later continuation")
    } catch { }
    let duplicate = GalleryPreparedVideo(asset: AVAsset(prerollDelay: 2, duplicatePrerollCallback: true))
    try? await duplicate.preparePreroll(id: UUID())
    check(duplicate.hasPrerolledPlayer, "duplicate callback does not corrupt successful preparation")

    // UUID replacement race: old late failure cannot clear the new attempt/reservation.
    let cache = GallerySceneCacheProbe()
    let sameVideo = GalleryPreparedVideo(asset: AVAsset(prerollDelay: 160, prerollResult: false))
    check(cache.scheduleVideoPreroll(sameVideo, key: "photo:same") == .scheduled, "old attempt scheduled")
    let oldReservation = cache.videoPrerollReservation!
    let oldStarted = await waitUntil({ sameVideo.testPlayer?.prerollStarts == 1 })
    check(oldStarted, "old attempt actually starts preroll before cancellation")
    let oldPlayer = sameVideo.testPlayer!
    check(cache.videoPrerollReservation?.id == oldReservation.id && cache.videoPrerollReservation?.isReady == false, "old callback is pending under old UUID")
    sameVideo.promote() // Evicts/cancels the old UUID before its async catch can run.
    sameVideo.asset.prerollDelay = 15
    sameVideo.asset.prerollResult = true
    check(cache.scheduleVideoPreroll(sameVideo, key: "photo:same") == .scheduled, "new same-key attempt starts")
    let newReservation = cache.videoPrerollReservation!
    check(oldReservation.id != newReservation.id, "retry uses a new attempt UUID")
    let newReady = await waitUntil({ cache.videoPrerollReservation?.id == newReservation.id && cache.videoPrerollReservation?.isReady == true && sameVideo.testPlayer !== oldPlayer })
    check(newReady, "new attempt reaches ready state while old callback remains pending")
    check(oldPlayer.prerollCallbacksDelivered == 0, "old callback has not arrived before new attempt is ready")
    let oldCallbackArrived = await waitUntil({ oldPlayer.prerollCallbacksDelivered == 1 })
    check(oldCallbackArrived, "old AVPlayer callback arrives after retry is ready")
    sameVideo.discardPrerolledPlayer(expectedID: oldReservation.id)
    check(cache.videoPrerollReservation?.id == newReservation.id, "old late cleanup preserves new reservation")
    check(sameVideo.hasPrerolledPlayer, "old attempt cannot discard new player's prepared state")
    check(oldPlayer.prerollCallbacksDelivered == 1, "old late completion was delivered exactly once")

    // One shared cache reservation serializes speculative players across photo and vault keys.
    let secondVideo = GalleryPreparedVideo(asset: AVAsset(prerollDelay: 30))
    check(cache.scheduleVideoPreroll(secondVideo, key: "vault:other") == .slotUnavailable, "global single slot spans photos and vault")
    let beforeConsumption = cache.slotNotifications
    _ = sameVideo.takePrerolledPlayer()
    check(cache.lastConsumedKey == "photo:same", "successful consumption identifies the key that remaining owners may warm again")
    check(cache.slotNotifications == beforeConsumption + 1, "consumption releases exactly once despite the ordinary release callback")

    // Withdraw one inactive owner's demand without destroying an active sibling's exact player.
    let a = UUID(), b = UUID()
    cache.updatePrefetchDemand(owner: a, orderedKeys: ["photo:shared"])
    cache.updatePrefetchDemand(owner: b, orderedKeys: ["photo:shared"])
    let shared = GalleryPreparedVideo(asset: AVAsset())
    check(cache.scheduleVideoPreroll(shared, key: "photo:shared") == .scheduled, "shared warmup scheduled")
    let sharedReady = await waitUntil({ cache.videoPrerollReservation?.isReady == true })
    check(sharedReady, "shared player ready before owner withdrawal")
    let sharedIdentity = shared.testPlayer
    cache.updatePrefetchDemand(owner: a, orderedKeys: [])
    check(shared.testPlayer === sharedIdentity && cache.videoPrerollReservation?.isReady == true,
          "inactive creator preserves exact ready player while sibling still demands it")
    cache.updatePrefetchDemand(owner: b, orderedKeys: ["photo:different"])
    check(cache.videoPrerollReservation == nil && !shared.hasPrerolledPlayer,
          "different-key sibling cannot keep an orphaned warm slot")
    cache.clearSpeculativeVideoPreroll()
    check(cache.videoPrerollReservation == nil, "clear releases global reservation")
    print("PASS: readiness, paused/muted warming, timeout/failure fallback, take/reset, independent second consumer, completion exactly-once, UUID stale-cleanup race, and shared Photos/vault slot")
}

@MainActor extension GalleryPreparedVideo {
    var testPlayer: AVPlayer? { Mirror(reflecting: self).children.first { $0.label == "prerolledPlayer" }?.value as? AVPlayer }
}

@main struct Runner {
    static func main() async {
        print("source_sha256=\(CommandLine.arguments[1])")
        await runTests()
    }
}
'''
# To keep production private state untouched, the test-only reflection accessor sees the same instance.
with tempfile.TemporaryDirectory(prefix="video-preroll-probe-") as temp_dir:
    swift_source = Path(temp_dir) / "production_preroll_probe.swift"
    swift_source.write_text(stub + "\n" + prepared + "\n" + completion + "\n" + handoff + "\n" + cache_class + "\n" + tests)
    print(f"source={SOURCE}")
    print(f"source_sha256={digest}")
    print(f"extracted prepared video lines={prepared.count(chr(10)) + 1}; completion lines={completion.count(chr(10)) + 1}; cache lifecycle lines={cache_methods.count(chr(10)) + 1}")
    if os.environ.get("DISABLE_UUID_GUARD") == "1": print("controlled_falsifier=UUID guard disabled in generated copy")
    binary = Path(temp_dir) / "production_preroll_probe"
    subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", str(swift_source), "-o", str(binary)], cwd=ROOT, check=True)
    subprocess.run([str(binary), digest], cwd=ROOT, check=True)
